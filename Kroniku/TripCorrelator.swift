import Foundation

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
}

private struct WorkoutObservation: Codable, Hashable {
    var title: String
    var startedAt: Date
    var endedAt: Date
}

private struct CorrelationObservationStore: Codable {
    var motion: [MotionObservation] = []
    var locations: [VisitSnapshot] = []
    var workouts: [WorkoutObservation] = []
}

/// Retains normalized sensor observations and repeatedly reduces them into one canonical,
/// non-overlapping recent timeline. It never treats a callback as a finished trip by itself.
@MainActor
final class TripCorrelator {
    private let repository: MemoryRepositoryProtocol
    private let defaults: UserDefaults
    private let weatherProvider: WeatherContextProviding
    private let consentStore: Tier1ConsentStore
    private var observations: CorrelationObservationStore
    private var subscriptionTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var weatherEnrichmentTask: Task<Void, Never>?

    private static let observationStoreKey = "timelineCorrelationObservationsV2"
    private static let retentionWindow: TimeInterval = 2 * 24 * 60 * 60
    private static let minimumDriveDuration: TimeInterval = 2 * 60
    private static let minimumWalkDuration: TimeInterval = 5 * 60
    private static let maximumInferredMotionDuration: TimeInterval = 2 * 60 * 60
    private static let locationBoundaryTolerance: TimeInterval = 5 * 60
    private static let weatherReuseWindow: TimeInterval = 90 * 60
    private static let duplicateWorkoutCoverage = 0.8

    init(
        repository: MemoryRepositoryProtocol,
        defaults: UserDefaults = .standard,
        weatherProvider: WeatherContextProviding = WeatherKitSnapshotProvider(),
        consentStore: Tier1ConsentStore = Tier1ConsentStore()
    ) {
        self.repository = repository
        self.defaults = defaults
        self.weatherProvider = weatherProvider
        self.consentStore = consentStore
        self.observations = defaults.data(forKey: Self.observationStoreKey)
            .flatMap { try? JSONDecoder.iso8601.decode(CorrelationObservationStore.self, from: $0) }
            ?? CorrelationObservationStore()
        pruneObservations(relativeTo: Date())
    }

    func start() async {
        subscriptionTask?.cancel()
        reconcile()
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
    }

    func handle(_ event: KronikuEvent) {
        SensorDiagnostics.log(
            "RECONCILER receive type=\(event.type.rawValue) timestamp=\(SensorDiagnostics.timestamp(event.timestamp))"
        )

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
            observations.motion.append(MotionObservation(timestamp: event.timestamp, state: state))

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

        case .workoutStarted:
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
        let drafts = (workoutDrafts + motionDrafts).sorted { $0.occurredAt < $1.occurredAt }

        do {
            try repository.reconcileDerivedEvents(drafts, in: interval)
            SensorDiagnostics.log(
                "RECONCILER applied observations motion=\(observations.motion.count) " +
                    "locations=\(observations.locations.count) workouts=\(observations.workouts.count) " +
                    "derived=\(drafts.count)"
            )
                    scheduleWeatherEnrichment()
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

    private func enrichMissingWeather() async {
        let allEvents = repository.fetchAll()
        let candidates = allEvents.filter {
            ($0.source == "trip" || $0.source == "workout") && $0.weatherSnapshot == nil && $0.place != nil
        }

        for event in candidates where !Task.isCancelled {
            guard let coordinate = coordinate(for: event.place),
                  let startedAt = event.occurredAt,
                  let endedAt = event.derivedEndedAt else { continue }
            let midpoint = startedAt.addingTimeInterval(endedAt.timeIntervalSince(startedAt) / 2)

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
                try? repository.update(event: event)
                SensorDiagnostics.log("RECONCILER weather reused event=\(event.id)")
                continue
            }

            guard abs(Date().timeIntervalSince(endedAt)) <= Self.weatherReuseWindow,
                  let reading = await weatherProvider.weather(at: Date(), coordinate: coordinate) else { continue }
            event.weatherSnapshot = WeatherSnapshot(
                observedAt: reading.observedAt,
                condition: reading.condition,
                temperatureC: reading.temperatureC
            )
            try? repository.update(event: event)
            SensorDiagnostics.log("RECONCILER weather fetched event=\(event.id)")
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
        return DerivedEventDraft(
            source: "workout",
            title: workout.title,
            detail: "\(minutes) min",
            occurredAt: workout.startedAt,
            endedAt: workout.endedAt,
            motion: nil,
            place: locations(in: interval).last,
            confidenceScore: 1
        )
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
                drafts.append(motionDraft(category: category, interval: interval, locations: evidence))
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
        locations: [VisitSnapshot]
    ) -> DerivedEventDraft {
        let minutes = max(1, Int((interval.duration / 60).rounded()))
        let names = locations.map(\.name).reduce(into: [String]()) { names, name in
            if names.last != name { names.append(name) }
        }
        let route: String?
        if names.count >= 2 {
            route = "\(names.first!) → \(names.last!)"
        } else {
            route = names.first
        }
        let detail = [route, "\(minutes) min"].compactMap { $0 }.joined(separator: " · ")
        return DerivedEventDraft(
            source: "trip",
            title: category.title,
            detail: detail,
            occurredAt: interval.start,
            endedAt: interval.end,
            motion: category.motionState,
            place: locations.first,
            confidenceScore: category == .driving ? 0.8 : 0.7
        )
    }

    private func locations(in interval: DateInterval) -> [VisitSnapshot] {
        observations.locations
            .filter { interval.contains($0.capturedAt) }
            .sorted { $0.capturedAt < $1.capturedAt }
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
        return WorkoutObservation(
            title: event.metadata["activityType"] ?? "Workout",
            startedAt: derivedStart,
            endedAt: end
        )
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