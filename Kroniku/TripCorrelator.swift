import Foundation
import CoreLocation

private enum ReconciledMotionCategory: String, Codable {
    case driving
    case walk

    var title: String {
        switch self {
        case .driving: return "Drive"
        case .walk: return "Walk"
        }
    }

    var motionState: MotionState {
        switch self {
        case .driving: return .driving
        case .walk: return .walking
        }
    }

    static func category(for state: MotionState) -> ReconciledMotionCategory? {
        switch state {
        case .driving: return .driving
        case .walking, .running: return .walk
        default: return nil
        }
    }
}

private struct MotionObservation: Codable, Hashable {
    var timestamp: Date
    var state: MotionState
    var bluetoothContext: BluetoothContextKind?
}

private struct WorkoutObservation: Codable, Hashable {
    var title: String
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double?
    var route: WorkoutRoute?
}

private struct MediaObservation: Codable, Hashable {
    var timestamp: Date
    var media: MediaNowPlaying
}

private struct CorrelationObservationStore: Codable {
    var motion: [MotionObservation] = []
    var locations: [VisitSnapshot] = []
    var workouts: [WorkoutObservation] = []
    var media: [MediaObservation] = []
}

/// Retains normalized sensor observations and repeatedly reduces them into one canonical,
/// non-overlapping recent timeline. It never treats a callback as a finished trip by itself.
@MainActor
final class TripCorrelator {
    private let repository: MemoryRepositoryProtocol
    private let defaults: UserDefaults
    private let weatherProvider: WeatherContextProviding
    private let healthProvider: HealthContextProviding
    private let consentStore: Tier1ConsentStore
    private let contextRequestStore: ContextRequestStore
    private var observations: CorrelationObservationStore
    private var subscriptionTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var weatherEnrichmentTask: Task<Void, Never>?
    private var healthEnrichmentTask: Task<Void, Never>?

    private static let observationStoreKey = "timelineCorrelationObservationsV2"
    private static let retentionWindow: TimeInterval = 2 * 24 * 60 * 60
    private static let minimumDriveDuration: TimeInterval = 2 * 60
    private static let minimumWalkDuration: TimeInterval = 5 * 60
    private static let minimumStopDuration: TimeInterval = 2 * 60
    private static let maximumStopDuration: TimeInterval = 90 * 60
    private static let maximumInferredMotionDuration: TimeInterval = 2 * 60 * 60
    private static let locationBoundaryTolerance: TimeInterval = 5 * 60
    private static let weatherReuseWindow: TimeInterval = 90 * 60
    private static let historicalWeatherWindow: TimeInterval = 2 * 24 * 60 * 60
    private static let duplicateWorkoutCoverage = 0.8

    init(
        repository: MemoryRepositoryProtocol,
        defaults: UserDefaults = .standard,
        weatherProvider: WeatherContextProviding = WeatherKitSnapshotProvider(),
        healthProvider: HealthContextProviding = HealthKitSummaryProvider(),
        consentStore: Tier1ConsentStore = Tier1ConsentStore(),
        contextRequestStore: ContextRequestStore = .shared
    ) {
        self.repository = repository
        self.defaults = defaults
        self.weatherProvider = weatherProvider
        self.healthProvider = healthProvider
        self.consentStore = consentStore
        self.contextRequestStore = contextRequestStore
        self.observations = defaults.data(forKey: Self.observationStoreKey)
            .flatMap { try? JSONDecoder.iso8601.decode(CorrelationObservationStore.self, from: $0) }
            ?? CorrelationObservationStore()
        pruneObservations(relativeTo: Date())
    }

    func start() async {
        subscriptionTask?.cancel()
        reconcile()
        // cleanupDuplicateSleepEvents()
        let stream = await KronikuEventBus.shared.subscribe()
        subscriptionTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        weatherEnrichmentTask?.cancel()
        weatherEnrichmentTask = nil
        healthEnrichmentTask?.cancel()
        healthEnrichmentTask = nil
    }

    func handle(_ event: KronikuEvent) {
        SensorDiagnostics.log(
            "RECONCILER receive type=\(event.type.rawValue) timestamp=\(SensorDiagnostics.timestamp(event.timestamp))"
        )

        if let media = MediaNowPlayingProvider.current() {
            observations.media.removeAll { $0.timestamp == event.timestamp }
            observations.media.append(MediaObservation(timestamp: event.timestamp, media: media))
        }

        switch event.type {
        case .locationSignificantChange:
            guard let location = locationObservation(from: event) else {
                SensorDiagnostics.log("RECONCILER ignored location reason=invalidPayload")
                return
            }
            observations.locations.removeAll {
                $0.capturedAt == location.capturedAt && $0.coordinate == location.coordinate
            }
            observations.locations.append(location)

        case .motionChanged:
            guard let rawState = event.metadata["state"], let state = MotionState(rawValue: rawState) else {
                SensorDiagnostics.log("RECONCILER ignored motion reason=invalidState")
                return
            }
            observations.motion.removeAll { $0.timestamp == event.timestamp }
            observations.motion.append(MotionObservation(
                timestamp: event.timestamp,
                state: state,
                bluetoothContext: event.metadata["bluetoothContext"].flatMap(BluetoothContextKind.init(rawValue:))
            ))

        case .workoutEnded:
            guard let workout = normalizedWorkout(from: event) else {
                SensorDiagnostics.log("RECONCILER ignored workout reason=insufficientTimeFields")
                return
            }
            observations.workouts.removeAll {
                $0.title == workout.title &&
                    abs($0.startedAt.timeIntervalSince(workout.startedAt)) <= 2 &&
                    abs($0.endedAt.timeIntervalSince(workout.endedAt)) <= 2
            }
            observations.workouts.append(workout)
            healthEnrichmentTask?.cancel()
            healthEnrichmentTask = Task { [weak self] in
                guard let self else { return }
                await self.enrichWorkoutHealth(workout)
            }

        case .workoutStarted:
            return

        case .geofenceEntered, .geofenceExited:
            handleGeofenceEvent(event)
            return

        case .sleepAnalysisRecorded:
            handleSleepEvent(event)
            return
        }

        pruneObservations(relativeTo: max(event.timestamp, Date()))
        persistObservations()
        if event.metadata["origin"] == "history" {
            scheduleReconciliation()
        } else {
            reconcile()
        }
    }

    private func scheduleReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func reconcile() {
        guard let interval = reconciliationInterval else { return }
        let workouts = canonicalWorkouts()
        let workoutDrafts = workouts.map(workoutDraft)
        let motionDrafts = canonicalMotionDrafts(excluding: workouts.map { DateInterval(start: $0.startedAt, end: $0.endedAt) })
        let stopDrafts = stopDrafts(between: motionDrafts)
        let drafts = (workoutDrafts + motionDrafts + stopDrafts).sorted { $0.occurredAt < $1.occurredAt }

        do {
            try repository.reconcileDerivedEvents(drafts, in: interval)
            SensorDiagnostics.log(
                "RECONCILER applied observations motion=\(observations.motion.count) " +
                    "locations=\(observations.locations.count) workouts=\(observations.workouts.count) " +
                    "media=\(observations.media.count) " +
                    "derived=\(drafts.count)"
            )
                    enqueueContextRequests(for: stopDrafts)
                    scheduleWeatherEnrichment()
                    scheduleHealthEnrichment()
        } catch {
            SensorDiagnostics.log("RECONCILER failed error=\(error.localizedDescription)")
        }
    }

    private func scheduleWeatherEnrichment() {
        guard consentStore.consent.weatherSnapshotsEnabled else { return }
        weatherEnrichmentTask?.cancel()
        weatherEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            await self.enrichMissingWeather()
        }
    }

    private func scheduleHealthEnrichment() {
          guard consentStore.consent.healthAuthorizationState == .authorized,
              !consentStore.consent.healthConsent.enabledMetrics.isEmpty else { return }
        healthEnrichmentTask?.cancel()
        healthEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            await self.enrichMissingWorkoutHealth()
            await self.enrichMissingSleepHealth()
        }
    }

    private func enrichMissingWorkoutHealth() async {
        let metrics = consentStore.consent.healthConsent.enabledMetrics
        guard consentStore.consent.healthAuthorizationState == .authorized, !metrics.isEmpty else { return }
        let candidates = repository.fetchAll().filter {
            $0.includeHealthData && $0.source == "workout" && $0.healthSummary == nil && !$0.isDeleted
        }

        for event in candidates where !Task.isCancelled {
            guard let start = event.occurredAt,
                  let end = event.derivedEndedAt,
                  end > start else { continue }
            await attachHealthSummary(to: event, interval: DateInterval(start: start, end: end), metrics: metrics)
        }
    }

    /// Mirrors `enrichMissingWorkoutHealth`, so a "Woke up" memory that missed enrichment (e.g. health
    /// consent was granted after the sleep event was created) gets retried on every reconcile pass too,
    /// instead of only when the HealthKit sleep observer happens to fire again.
    private func enrichMissingSleepHealth() async {
        guard consentStore.consent.sleepTrackingEnabled else { return }
        let metrics = consentStore.consent.healthConsent.enabledMetrics
        guard consentStore.consent.healthAuthorizationState == .authorized, !metrics.isEmpty else { return }
        let sleepEvents = repository.fetchAll().filter { $0.source == "sleep" && !$0.isDeleted }
        let bedtimes = sleepEvents.filter { $0.title == "Went to bed" }.compactMap(\.occurredAt).sorted()
        let candidates = sleepEvents.filter { $0.includeHealthData && $0.title == "Woke up" && $0.healthSummary == nil }

        for event in candidates where !Task.isCancelled {
            guard let wakeTime = event.occurredAt,
                  let bedTime = bedtimes.last(where: { $0 < wakeTime }) else { continue }
            await attachHealthSummary(to: event, interval: DateInterval(start: bedTime, end: wakeTime), metrics: metrics)
        }
    }

    private func enrichWorkoutHealth(_ workout: WorkoutObservation) async {
        let consent = consentStore.consent
        let metrics = consent.healthConsent.enabledMetrics
        guard consent.healthAuthorizationState == .authorized, !metrics.isEmpty else { return }
        let interval = DateInterval(start: workout.startedAt, end: workout.endedAt)
        let event = repository.fetchAll().first {
            $0.source == "workout" && $0.title == workout.title &&
                abs(($0.occurredAt ?? .distantPast).timeIntervalSince(workout.startedAt)) <= 2 &&
                abs(($0.derivedEndedAt ?? .distantPast).timeIntervalSince(workout.endedAt)) <= 2
        }
        guard let event else { return }
        await attachHealthSummary(to: event, interval: interval, metrics: metrics)
    }

    private func attachHealthSummary(to event: MemoryEvent, interval: DateInterval, metrics: Set<Tier1HealthMetric>) async {
        guard let summary = await healthProvider.summary(in: interval, metrics: metrics), !summary.isEmpty else { return }
        event.healthSummary = summary
        do {
            try repository.update(event: event)
        } catch {
            SensorDiagnostics.log(
                "RECONCILER health saveFailed event=\(event.id) error=\(error.localizedDescription)"
            )
        }
    }

    private func enrichMissingWeather() async {
        let allEvents = repository.fetchAll()
        let candidates = allEvents.filter {
            ($0.source == "trip" || $0.source == "workout") && $0.weatherSnapshot == nil
        }

        for event in candidates where !Task.isCancelled {
            guard let startedAt = event.occurredAt,
                  let endedAt = event.derivedEndedAt else {
                SensorDiagnostics.log(
                    "RECONCILER weather skipped event=\(event.id) reason=missingTimeRange"
                )
                continue
            }
            guard let coordinate = coordinate(for: event.place) else {
                SensorDiagnostics.log(
                    "RECONCILER weather skipped event=\(event.id) reason=missingCoordinate " +
                        "start=\(SensorDiagnostics.timestamp(startedAt)) " +
                        "end=\(SensorDiagnostics.timestamp(endedAt))"
                )
                continue
            }
            let midpoint = startedAt.addingTimeInterval(endedAt.timeIntervalSince(startedAt) / 2)
            let age = Date().timeIntervalSince(endedAt)
            SensorDiagnostics.log(
                "RECONCILER weather candidate event=\(event.id) source=\(event.source ?? "unknown") " +
                    "start=\(SensorDiagnostics.timestamp(startedAt)) " +
                    "end=\(SensorDiagnostics.timestamp(endedAt)) " +
                    "midpoint=\(SensorDiagnostics.timestamp(midpoint)) " +
                    "place=\(event.place?.name ?? "unknown") ageSeconds=\(Int(age))"
            )

            if let nearbyWeather = nearestStoredWeather(
                in: DateInterval(start: startedAt, end: endedAt),
                coordinate: coordinate,
                excluding: event.id,
                events: allEvents
            ) {
                event.weatherSnapshot = WeatherSnapshot(
                    observedAt: nearbyWeather.observedAt,
                    condition: nearbyWeather.condition,
                    temperatureC: nearbyWeather.temperatureC
                )
                do {
                    try repository.update(event: event)
                    SensorDiagnostics.log("RECONCILER weather reused event=\(event.id)")
                } catch {
                    SensorDiagnostics.log(
                        "RECONCILER weather saveFailed event=\(event.id) " +
                            "source=reused error=\(error.localizedDescription)"
                    )
                }
                continue
            }

            guard abs(age) <= Self.historicalWeatherWindow else {
                SensorDiagnostics.log(
                    "RECONCILER weather skipped event=\(event.id) reason=outsideWindow " +
                        "ageSeconds=\(Int(age)) windowSeconds=\(Int(Self.historicalWeatherWindow))"
                )
                continue
            }
            guard let reading = await weatherProvider.weather(at: midpoint, coordinate: coordinate) else {
                SensorDiagnostics.log(
                    "RECONCILER weather providerReturnedNil event=\(event.id) " +
                        "requestedAt=\(SensorDiagnostics.timestamp(midpoint))"
                )
                continue
            }
            event.weatherSnapshot = WeatherSnapshot(
                observedAt: reading.observedAt,
                condition: reading.condition,
                temperatureC: reading.temperatureC
            )
            do {
                try repository.update(event: event)
                SensorDiagnostics.log(
                    "RECONCILER weather fetched event=\(event.id) " +
                        "requestedAt=\(SensorDiagnostics.timestamp(midpoint)) " +
                        "observedAt=\(SensorDiagnostics.timestamp(reading.observedAt))"
                )
            } catch {
                SensorDiagnostics.log(
                    "RECONCILER weather saveFailed event=\(event.id) " +
                        "source=fetched error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func nearestStoredWeather(
        in interval: DateInterval,
        coordinate targetCoordinate: GeoCoordinate,
        excluding eventID: UUID,
        events: [MemoryEvent]
    ) -> WeatherSnapshot? {
        events.compactMap { event -> WeatherSnapshot? in
            guard event.id != eventID,
                  let weather = event.weatherSnapshot else { return nil }
            if interval.contains(weather.observedAt) {
                return weather
            }
            guard let eventCoordinate = coordinate(for: event.place),
                  abs(weather.observedAt.timeIntervalSince(interval.start)) <= Self.weatherReuseWindow ||
                    abs(weather.observedAt.timeIntervalSince(interval.end)) <= Self.weatherReuseWindow,
                  isLikelySameArea(targetCoordinate, eventCoordinate) else { return nil }
            return weather
        }
        .min { lhs, rhs in
            let midpoint = interval.start.addingTimeInterval(interval.duration / 2)
            return abs(lhs.observedAt.timeIntervalSince(midpoint)) < abs(rhs.observedAt.timeIntervalSince(midpoint))
        }
    }

    private func coordinate(for place: Place?) -> GeoCoordinate? {
        guard let latitude = place?.latitude, let longitude = place?.longitude else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    private func isLikelySameArea(_ lhs: GeoCoordinate, _ rhs: GeoCoordinate) -> Bool {
        abs(lhs.latitude - rhs.latitude) <= 0.02 && abs(lhs.longitude - rhs.longitude) <= 0.02
    }

    private var reconciliationInterval: DateInterval? {
        let dates = observations.motion.map(\.timestamp) +
            observations.locations.map(\.capturedAt) +
            observations.workouts.flatMap { [$0.startedAt, $0.endedAt] }
        guard let earliest = dates.min(), let latest = dates.max() else { return nil }
        return DateInterval(
            start: Calendar.current.startOfDay(for: earliest),
            end: max(Date(), latest).addingTimeInterval(1)
        )
    }

    private func canonicalWorkouts() -> [WorkoutObservation] {
        var result: [WorkoutObservation] = []
        for workout in observations.workouts.sorted(by: { $0.startedAt < $1.startedAt }) {
            let interval = DateInterval(start: workout.startedAt, end: workout.endedAt)
            let duplicateIndex = result.firstIndex { existing in
                guard existing.title == workout.title else { return false }
                let existingInterval = DateInterval(start: existing.startedAt, end: existing.endedAt)
                return coverage(of: interval, by: existingInterval) >= Self.duplicateWorkoutCoverage ||
                    coverage(of: existingInterval, by: interval) >= Self.duplicateWorkoutCoverage
            }
            if let duplicateIndex {
                let existing = result[duplicateIndex]
                if interval.duration > existing.endedAt.timeIntervalSince(existing.startedAt) {
                    result[duplicateIndex] = workout
                }
            } else {
                result.append(workout)
            }
        }
        return result
    }

    private func workoutDraft(_ workout: WorkoutObservation) -> DerivedEventDraft {
        let interval = DateInterval(start: workout.startedAt, end: workout.endedAt)
        let minutes = max(1, Int((interval.duration / 60).rounded()))
        var detail = "\(minutes) min"
        if let distanceMeters = workout.distanceMeters {
            detail += " · \(String(format: "%.1f", distanceMeters / 1000)) km"
        }
        return DerivedEventDraft(
            source: "workout",
            title: workout.title,
            detail: detail,
            occurredAt: workout.startedAt,
            endedAt: workout.endedAt,
            motion: nil,
            bluetoothContext: bluetoothContext(in: interval),
            place: locations(in: interval).last,
            confidenceScore: 1,
            distanceMeters: workout.distanceMeters,
            route: workout.route,
            mediaNowPlaying: media(in: interval)
        )
    }

    private func bluetoothContext(in interval: DateInterval) -> BluetoothContextKind? {
        guard consentStore.consent.bluetoothContextEnabled else { return nil }
        let startWithTolerance = interval.start.addingTimeInterval(-Self.locationBoundaryTolerance)
        return observations.motion
            .filter { $0.timestamp >= startWithTolerance && $0.timestamp <= interval.end }
            .compactMap { observation in
                observation.bluetoothContext.map { (observation.timestamp, $0) }
            }
            .max { $0.0 < $1.0 }?
            .1
    }

    private func canonicalMotionDrafts(excluding authoritativeIntervals: [DateInterval]) -> [DerivedEventDraft] {
        let sorted = deduplicatedMotionObservations()
        guard sorted.count >= 2 else { return [] }
        var drafts: [DerivedEventDraft] = []

        for index in 0..<(sorted.count - 1) {
            let current = sorted[index]
            let next = sorted[index + 1]
            guard let category = ReconciledMotionCategory.category(for: current.state) else { continue }
            let duration = next.timestamp.timeIntervalSince(current.timestamp)
            let minimumDuration = category == .walk ? Self.minimumWalkDuration : Self.minimumDriveDuration
            guard duration >= minimumDuration, duration <= Self.maximumInferredMotionDuration else {
                SensorDiagnostics.log(
                    "RECONCILER ignored motion interval category=\(category.rawValue) duration=\(duration)"
                )
                continue
            }

            let base = DateInterval(start: current.timestamp, end: next.timestamp)
            for interval in subtract(authoritativeIntervals, from: base) where interval.duration >= minimumDuration {
                let evidence = locationsSupporting(interval)
                guard category != .driving || !evidence.isEmpty else {
                    SensorDiagnostics.log("RECONCILER ignored drive reason=noFreshLocation")
                    continue
                }
                drafts.append(motionDraft(
                    category: category,
                    interval: interval,
                    locations: evidence,
                    bluetoothContext: current.bluetoothContext
                ))
            }
        }
        return drafts
    }

    private func deduplicatedMotionObservations() -> [MotionObservation] {
        let sorted = observations.motion.sorted { $0.timestamp < $1.timestamp }
        var result: [MotionObservation] = []
        for observation in sorted {
            if result.last?.state == observation.state { continue }
            result.append(observation)
        }
        return result
    }

    private func motionDraft(
        category: ReconciledMotionCategory,
        interval: DateInterval,
        locations: [VisitSnapshot],
        bluetoothContext: BluetoothContextKind?
    ) -> DerivedEventDraft {
        let minutes = max(1, Int((interval.duration / 60).rounded()))
        let names = locations.map(\.name).reduce(into: [String]()) { names, name in
            if names.last != name { names.append(name) }
        }
        let routeText: String?
        if names.count >= 2 {
            routeText = "\(names.first!) → \(names.last!)"
        } else {
            routeText = names.first
        }
        let detail = [routeText, "\(minutes) min"].compactMap { $0 }.joined(separator: " · ")
        // Coarse route from significant-location-change points; not a continuous GPS trace like a workout's.
        let route = category == .driving && locations.count >= 2
            ? WorkoutRoute(coordinates: locations.map(\.coordinate))
            : nil
        let distanceMeters = category == .driving ? Self.coarseDistanceMeters(for: locations) : nil
        return DerivedEventDraft(
            source: "trip",
            title: category.title,
            detail: detail,
            occurredAt: interval.start,
            endedAt: interval.end,
            motion: category.motionState,
            bluetoothContext: bluetoothContext,
            place: locations.first,
            confidenceScore: category == .driving ? 0.8 : 0.7,
            distanceMeters: distanceMeters,
            route: route,
            mediaNowPlaying: media(in: interval)
        )
    }

    private static func coarseDistanceMeters(for locations: [VisitSnapshot]) -> Double? {
        guard locations.count >= 2 else { return nil }
        let clLocations = locations.map { CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        let total = zip(clLocations, clLocations.dropFirst()).reduce(0.0) { partial, pair in
            partial + pair.0.distance(from: pair.1)
        }
        return total > 0 ? total : nil
    }


    private func stopDrafts(between motionDrafts: [DerivedEventDraft]) -> [DerivedEventDraft] {
        let drives = motionDrafts
            .filter { $0.motion == .driving }
            .sorted { $0.occurredAt < $1.occurredAt }
        guard drives.count >= 2 else { return [] }

        return zip(drives, drives.dropFirst()).compactMap { previous, next in
            let duration = next.occurredAt.timeIntervalSince(previous.endedAt)
            guard duration >= Self.minimumStopDuration,
                  duration <= Self.maximumStopDuration,
                  let place = next.place else { return nil }
            let minutes = max(1, Int((duration / 60).rounded()))
            return DerivedEventDraft(
                source: "trip",
                title: "Stop",
                detail: "\(place.name) · \(minutes) min",
                occurredAt: previous.endedAt,
                endedAt: next.occurredAt,
                motion: .stationary,
                bluetoothContext: nil,
                place: place,
                confidenceScore: 0.8,
                mediaNowPlaying: media(in: DateInterval(start: previous.endedAt, end: next.occurredAt))
            )
        }
    }

    private func enqueueContextRequests(for stopDrafts: [DerivedEventDraft]) {
        let events = repository.fetchAll()
        for draft in stopDrafts {
            guard let event = events.first(where: {
                $0.source == "trip" && $0.title == "Stop" &&
                    abs(($0.occurredAt ?? .distantPast).timeIntervalSince(draft.occurredAt)) <= 2 &&
                    abs(($0.derivedEndedAt ?? .distantPast).timeIntervalSince(draft.endedAt)) <= 2
            }), let placeName = draft.place?.name else { continue }
            let minutes = max(1, Int((draft.endedAt.timeIntervalSince(draft.occurredAt) / 60).rounded()))
            contextRequestStore.enqueueStop(
                eventID: event.id,
                placeName: placeName,
                durationMinutes: minutes,
                createdAt: draft.endedAt
            )
        }
    }

    private func locations(in interval: DateInterval) -> [VisitSnapshot] {
        observations.locations
            .filter { interval.contains($0.capturedAt) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private func media(in interval: DateInterval) -> MediaNowPlaying? {
        let tolerance: TimeInterval = 2 * 60
        return observations.media
            .filter {
                $0.timestamp >= interval.start.addingTimeInterval(-tolerance) &&
                    $0.timestamp <= interval.end.addingTimeInterval(tolerance)
            }
            .min { lhs, rhs in
                abs(lhs.timestamp.timeIntervalSince(interval.start)) < abs(rhs.timestamp.timeIntervalSince(interval.start))
            }?.media
    }

    private func locationsSupporting(_ interval: DateInterval) -> [VisitSnapshot] {
        observations.locations
            .filter {
                $0.capturedAt >= interval.start.addingTimeInterval(-Self.locationBoundaryTolerance) &&
                    $0.capturedAt <= interval.end.addingTimeInterval(Self.locationBoundaryTolerance)
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private func subtract(_ exclusions: [DateInterval], from interval: DateInterval) -> [DateInterval] {
        exclusions.reduce([interval]) { fragments, exclusion in
            fragments.flatMap { fragment in
                guard fragment.intersects(exclusion) else { return [fragment] }
                var remaining: [DateInterval] = []
                if fragment.start < exclusion.start {
                    remaining.append(DateInterval(start: fragment.start, end: min(fragment.end, exclusion.start)))
                }
                if exclusion.end < fragment.end {
                    remaining.append(DateInterval(start: max(fragment.start, exclusion.end), end: fragment.end))
                }
                return remaining.filter { $0.duration > 0 }
            }
        }
    }

    private func coverage(of candidate: DateInterval, by reference: DateInterval) -> Double {
        guard candidate.duration > 0 else { return 0 }
        let overlap = max(0, min(candidate.end, reference.end).timeIntervalSince(max(candidate.start, reference.start)))
        return overlap / candidate.duration
    }

    private func normalizedWorkout(from event: KronikuEvent) -> WorkoutObservation? {
        let formatter = ISO8601DateFormatter()
        let start = event.metadata["startedAt"].flatMap(formatter.date(from:))
        let end = event.metadata["endedAt"].flatMap(formatter.date(from:)) ?? event.timestamp
        let duration = event.metadata["durationMinutes"].flatMap(Double.init).flatMap { $0 > 0 ? $0 * 60 : nil }
        let suppliedCount = (start == nil ? 0 : 1) + 1 + (duration == nil ? 0 : 1)
        guard suppliedCount >= 2 else { return nil }
        let derivedStart = start ?? end.addingTimeInterval(-(duration ?? 0))
        guard end > derivedStart else { return nil }
        let distanceMeters = event.metadata["distanceMeters"].flatMap(Double.init)
        let route = event.metadata["routeCoordinates"]
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(WorkoutRoute.self, from: $0) }
        return WorkoutObservation(
            title: event.metadata["activityType"] ?? "Workout",
            startedAt: derivedStart,
            endedAt: end,
            distanceMeters: distanceMeters,
            route: route
        )
    }

    /// Creates an instantaneous "Arrived <place>"/"Left <place>" memory for a geofence transition.
    private func handleGeofenceEvent(_ event: KronikuEvent) {
        guard consentStore.consent.geofencingEnabled,
              let regionId = event.metadata["regionId"],
              let place = GeofenceStore.shared.place(forRegionId: regionId) else { return }
        let isEntry = event.type == .geofenceEntered
        do {
            _ = try repository.addDerivedEvent(
                source: "geofence",
                title: isEntry ? "Arrived \(place.name)" : "Left \(place.name)",
                detail: nil,
                occurredAt: event.timestamp,
                endedAt: event.timestamp,
                motion: nil,
                place: VisitSnapshot(
                    name: place.name,
                    coordinate: GeoCoordinate(latitude: place.latitude, longitude: place.longitude),
                    capturedAt: event.timestamp
                ),
                confidenceScore: 1
            )
        } catch {
            SensorDiagnostics.log("RECONCILER geofence saveFailed error=\(error.localizedDescription)")
        }
    }

    // /// One-time sweep for duplicates left over from before `handleSleepEvent` checked persisted state
    // /// (each relaunch re-published the same finalized session since the in-memory dedup set was empty again).
    // /// Keeps the *richest* duplicate (detail + health summary present) rather than just the oldest one,
    // /// since earlier runs may have been created before those enrichments existed.
    // private func cleanupDuplicateSleepEvents() {
    //     let sleepEvents = repository.fetchAll().filter { !$0.isDeleted && $0.source == "sleep" }
    //     var groups: [String: [MemoryEvent]] = [:]
    //     for candidate in sleepEvents {
    //         guard let occurredAt = candidate.occurredAt, let title = candidate.title else { continue }
    //         let key = "\(title)|\(Int(occurredAt.timeIntervalSince1970 / 60))"
    //         groups[key, default: []].append(candidate)
    //     }

    //     for (_, group) in groups where group.count > 1 {
    //         let richest = group.max { lhs, rhs in
    //             richness(of: lhs) < richness(of: rhs) ||
    //                 (richness(of: lhs) == richness(of: rhs) && lhs.createdAt < rhs.createdAt)
    //         }
    //         for duplicate in group where duplicate !== richest {
    //             do {
    //                 try repository.delete(event: duplicate)
    //             } catch {
    //                 SensorDiagnostics.log("RECONCILER sleep cleanupFailed error=\(error.localizedDescription)")
    //             }
    //         }
    //     }
    // }

    private func richness(of event: MemoryEvent) -> Int {
        (event.detail?.isEmpty == false ? 1 : 0) + (event.healthSummary?.entries.isEmpty == false ? 1 : 0)
    }

    /// Creates "Went to bed"/"Woke up" memories for a finalized HealthKit sleep session.
    private func handleSleepEvent(_ event: KronikuEvent) {
        guard consentStore.consent.sleepTrackingEnabled,
              let bedTime = event.metadata["bedTime"].flatMap(ISO8601DateFormatter().date(from:)),
              let wakeTime = event.metadata["wakeTime"].flatMap(ISO8601DateFormatter().date(from:)),
              wakeTime > bedTime else { return }
        let asleepSeconds = event.metadata["asleepSeconds"].flatMap(Double.init)
        let inBedSeconds = event.metadata["inBedSeconds"].flatMap(Double.init)
        let detail = Self.sleepSummaryDetail(asleepSeconds: asleepSeconds, inBedSeconds: inBedSeconds)

        // The observer's in-memory publish dedup resets on every relaunch, so re-check against what's
        // already persisted before inserting — otherwise the same finalized session gets recreated each run.
        let existingSleepEvents = repository.fetchAll().filter { !$0.isDeleted && $0.source == "sleep" }
        let existingBedtime = existingSleepEvents.first {
            $0.title == "Went to bed" && abs(($0.occurredAt ?? .distantPast).timeIntervalSince(bedTime)) <= 60
        }
        let existingWake = existingSleepEvents.first {
            $0.title == "Woke up" && abs(($0.occurredAt ?? .distantPast).timeIntervalSince(wakeTime)) <= 60
        }

        do {
            if existingBedtime == nil {
                _ = try repository.addDerivedEvent(
                    source: "sleep",
                    title: "Went to bed",
                    detail: nil,
                    occurredAt: bedTime,
                    endedAt: bedTime,
                    motion: nil,
                    place: nil,
                    confidenceScore: 1
                )
            }

            let metrics = consentStore.consent.healthConsent.enabledMetrics
            let healthEnrichmentEligible = consentStore.consent.healthAuthorizationState == .authorized && !metrics.isEmpty

            let wakeEvent: MemoryEvent
            if let existingWake {
                existingWake.includeHealthData = true
                // Backfills an older duplicate/relaunch's sparse record (created before detail/health enrichment
                // existed, or before health consent was granted) rather than leaving it stuck bare forever.
                guard existingWake.detail == nil || (healthEnrichmentEligible && existingWake.healthSummary == nil) else { return }
                if existingWake.detail == nil {
                    existingWake.detail = detail
                    try repository.update(event: existingWake)
                }
                wakeEvent = existingWake
            } else {
                wakeEvent = try repository.addDerivedEvent(
                    source: "sleep",
                    title: "Woke up",
                    detail: detail,
                    occurredAt: wakeTime,
                    endedAt: wakeTime,
                    motion: nil,
                    place: nil,
                    confidenceScore: 1
                )
            }

            guard healthEnrichmentEligible, wakeEvent.healthSummary == nil else { return }
            healthEnrichmentTask?.cancel()
            healthEnrichmentTask = Task { [weak self] in
                guard let self else { return }
                await self.attachHealthSummary(to: wakeEvent, interval: DateInterval(start: bedTime, end: wakeTime), metrics: metrics)
            }
        } catch {
            SensorDiagnostics.log("RECONCILER sleep saveFailed error=\(error.localizedDescription)")
        }
    }

    /// "7h 42m asleep · 8h 10m in bed · 94% efficient", trimmed to whatever pieces we have data for.
    private static func sleepSummaryDetail(asleepSeconds: Double?, inBedSeconds: Double?) -> String? {
        var parts: [String] = []
        if let asleepSeconds {
            parts.append("\(formatDuration(asleepSeconds)) asleep")
        }
        if let inBedSeconds {
            parts.append("\(formatDuration(inBedSeconds)) in bed")
        }
        if let asleepSeconds, let inBedSeconds, inBedSeconds > 0 {
            let efficiency = Int(((asleepSeconds / inBedSeconds) * 100).rounded())
            parts.append("\(efficiency)% efficient")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func locationObservation(from event: KronikuEvent) -> VisitSnapshot? {
        guard let name = event.metadata["placeName"],
              let latitude = event.metadata["latitude"].flatMap(Double.init),
              let longitude = event.metadata["longitude"].flatMap(Double.init) else { return nil }
        return VisitSnapshot(
            name: name,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            capturedAt: event.timestamp
        )
    }

    private func pruneObservations(relativeTo date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retentionWindow)
        observations.motion.removeAll { $0.timestamp < cutoff }
        observations.locations.removeAll { $0.capturedAt < cutoff }
        observations.workouts.removeAll { $0.endedAt < cutoff }
    }

    private func persistObservations() {
        guard let data = try? JSONEncoder.iso8601.encode(observations) else { return }
        defaults.set(data, forKey: Self.observationStoreKey)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}