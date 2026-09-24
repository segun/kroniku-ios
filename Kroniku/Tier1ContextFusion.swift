import Foundation
import SwiftUI
import Combine
import EventKit
import CoreLocation
import CoreMotion
import Photos
#if canImport(HealthKit)
import HealthKit
#endif
#if canImport(WeatherKit)
import WeatherKit
#endif

@MainActor
protocol CalendarContextProviding {
    var authorizationState: PermissionState { get }
    func requestAccess() async -> PermissionState
    func fetchEvents(in interval: DateInterval) async throws -> [TimelineCalendarImportEvent]
}

@MainActor
protocol LocationContextProviding {
    var authorizationState: PermissionState { get }
    func requestAccess() async -> PermissionState
    func captureVisit(around date: Date) async -> VisitSnapshot?
    /// Escalates to "always" authorization; required before background monitoring can start.
    func requestAlwaysAccess() async -> PermissionState
    /// Starts significant-location-change monitoring, publishing events to `KronikuEventBus`.
    func startBackgroundMonitoring()
    func stopBackgroundMonitoring()
    /// Starts CLCircularRegion enter/exit monitoring for the given saved places (capped at 20 by iOS).
    func startMonitoringGeofences(_ places: [NamedGeofence])
    func stopMonitoringGeofences()
}

extension LocationContextProviding {
    func requestAlwaysAccess() async -> PermissionState { authorizationState }
    func startBackgroundMonitoring() {}
    func stopBackgroundMonitoring() {}
    func startMonitoringGeofences(_ places: [NamedGeofence]) {}
    func stopMonitoringGeofences() {}
}

@MainActor
protocol WeatherContextProviding {
    func weather(at date: Date, coordinate: GeoCoordinate) async -> WeatherReading?
}

@MainActor
protocol MotionContextProviding {
    var authorizationState: PermissionState { get }
    func requestAccess() async -> PermissionState
    func motionState(at date: Date) async -> MotionState?
    /// Starts continuous background activity updates, publishing `.motionChanged` events to `KronikuEventBus`.
    func startContinuousUpdates()
    func stopContinuousUpdates()
}

extension MotionContextProviding {
    func startContinuousUpdates() {}
    func stopContinuousUpdates() {}
}

@MainActor
protocol HealthContextProviding {
    var authorizationState: PermissionState { get }
    func requestAccess(for metrics: Set<Tier1HealthMetric>) async -> PermissionState
    func summary(for date: Date, metrics: Set<Tier1HealthMetric>) async -> HealthSummary?
    func summary(in interval: DateInterval, metrics: Set<Tier1HealthMetric>) async -> HealthSummary?
}

extension HealthContextProviding {
    func summary(in interval: DateInterval, metrics: Set<Tier1HealthMetric>) async -> HealthSummary? {
        await summary(for: interval.end, metrics: metrics)
    }
}

/// Background HealthKit workout observation, independent of the Tier1 metric summaries above.
@MainActor
protocol WorkoutContextProviding {
    func requestAccess() async -> PermissionState
    func startBackgroundDelivery()
    func stopBackgroundDelivery()
}

/// Background HealthKit sleep-analysis observation, surfaced as "Went to bed"/"Woke up" memories.
@MainActor
protocol SleepContextProviding {
    func requestAccess() async -> PermissionState
    func startBackgroundDelivery()
    func stopBackgroundDelivery()
}

@MainActor
protocol TimeSemanticLabelProviding {
    func labels(for date: Date, coordinate: GeoCoordinate?) -> [String]
}

@MainActor
final class Tier1ConsentStore: ObservableObject {
    @Published private(set) var consent: Tier1ConsentState

    private let storage: UserDefaults
    private let key = "tier1ConsentState"

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        if let raw = storage.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Tier1ConsentState.self, from: raw) {
            self.consent = decoded
        } else {
            self.consent = Tier1ConsentState()
        }
    }

    func update(_ mutate: (inout Tier1ConsentState) -> Void) {
        var next = consent
        mutate(&next)
        consent = next
        persist()
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(consent) else { return }
        storage.set(encoded, forKey: key)
    }
}

@MainActor
final class Tier1ContextController: ObservableObject {
    private struct CachedCalendarDay {
        var fetchedAt: Date
        var events: [TimelineCalendarImportEvent]
    }

    @Published private(set) var calendarPermission: PermissionState
    @Published private(set) var locationPermission: PermissionState
    @Published private(set) var motionPermission: PermissionState
    @Published private(set) var healthPermission: PermissionState
    @Published private(set) var backgroundTripDetectionSetupIssue: String?

    let consentStore: Tier1ConsentStore
    private let calendarProvider: CalendarContextProviding
    private let locationProvider: LocationContextProviding
    private let weatherProvider: WeatherContextProviding
    private let motionProvider: MotionContextProviding
    private let healthProvider: HealthContextProviding
    private let workoutProvider: WorkoutContextProviding
    private let sleepProvider: SleepContextProviding
    private let timeLabelProvider: TimeSemanticLabelProviding
    private var cachedCalendarEventsByDay: [Date: CachedCalendarDay] = [:]
    private var recentVisitSnapshot: VisitSnapshot?
    private var recentWeatherSnapshot: (coordinate: GeoCoordinate, reading: WeatherReading)?
    private var consentCancellable: AnyCancellable?

    init(
        consentStore: Tier1ConsentStore = Tier1ConsentStore(),
        calendarProvider: CalendarContextProviding = EventKitCalendarProvider(),
        locationProvider: LocationContextProviding = CoreLocationVisitProvider.shared,
        weatherProvider: WeatherContextProviding = WeatherKitSnapshotProvider(),
        motionProvider: MotionContextProviding = CoreMotionStateProvider.shared,
        healthProvider: HealthContextProviding = HealthKitSummaryProvider(),
        workoutProvider: WorkoutContextProviding = HealthKitWorkoutObserver.shared,
        sleepProvider: SleepContextProviding = HealthKitSleepObserver.shared,
        timeLabelProvider: TimeSemanticLabelProviding = DefaultTimeSemanticLabelProvider()
    ) {
        self.consentStore = consentStore
        self.calendarProvider = calendarProvider
        self.locationProvider = locationProvider
        self.weatherProvider = weatherProvider
        self.motionProvider = motionProvider
        self.healthProvider = healthProvider
        self.workoutProvider = workoutProvider
        self.sleepProvider = sleepProvider
        self.timeLabelProvider = timeLabelProvider
        // Defer permission introspection until a privacy UI/action path requests it.
        self.calendarPermission = .notDetermined
        self.locationPermission = .notDetermined
        self.motionPermission = .notDetermined
        self.healthPermission = .notDetermined
        // consentStore is its own ObservableObject, so its changes (e.g. from a background Task after an
        // async permission grant) wouldn't otherwise trigger a re-render of views observing this controller.
        consentCancellable = consentStore.$consent.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var consent: Tier1ConsentState { consentStore.consent }

    func markOnboardingComplete() {
        consentStore.update {
            $0.hasCompletedOnboarding = true
            $0.needsOnboardingResume = false
        }
        ContextRequestStore.shared.enqueuePlacesSetupPromptIfNeeded()
    }

    func markOnboardingDismissed(at page: Int) {
        consentStore.update {
            $0.needsOnboardingResume = true
            $0.onboardingPage = page
        }
    }

    func updateOnboardingPage(_ page: Int) {
        consentStore.update { $0.onboardingPage = page }
    }

    func setCalendarImportEnabled(_ enabled: Bool) {
        consentStore.update { $0.calendarImportEnabled = enabled }
    }

    func setCalendarAttendeeLocationEnabled(_ enabled: Bool) {
        consentStore.update { $0.calendarAttendeesAndLocationsEnabled = enabled }
    }

    func setLocationCaptureEnabled(_ enabled: Bool) {
        consentStore.update { $0.locationCaptureEnabled = enabled }
    }

    func setWeatherSnapshotsEnabled(_ enabled: Bool) {
        consentStore.update { $0.weatherSnapshotsEnabled = enabled }
    }

    func setMotionAttachmentEnabled(_ enabled: Bool) {
        consentStore.update { $0.motionAttachmentEnabled = enabled }
    }

    func setHealthMetric(_ metric: Tier1HealthMetric, enabled: Bool) {
        consentStore.update {
            if enabled {
                $0.healthConsent.enabledMetrics.insert(metric)
            } else {
                $0.healthConsent.enabledMetrics.remove(metric)
            }
        }
    }

    func healthSummary(in interval: DateInterval) async -> HealthSummary? {
        let metrics = consent.healthConsent.enabledMetrics
        guard consent.healthConsent.isEnabled,
              consent.healthAuthorizationState == .authorized,
              !metrics.isEmpty else { return nil }
        return await healthProvider.summary(in: interval, metrics: metrics)
    }

    func setPhotoAttachmentEnabled(_ enabled: Bool) {
        guard enabled else {
            consentStore.update { $0.photoAttachmentEnabled = false }
            return
        }

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            consentStore.update {
                $0.photoAttachmentEnabled = status == .authorized || status == .limited
            }
        }
    }

    /// Requests always-location + workout access and starts/stops the background event bus monitors accordingly.
    func setBackgroundTripDetectionEnabled(_ enabled: Bool) {
        guard enabled else {
            consentStore.update { $0.backgroundTripDetectionEnabled = false }
            backgroundTripDetectionSetupIssue = nil
            locationProvider.stopBackgroundMonitoring()
            motionProvider.stopContinuousUpdates()
            workoutProvider.stopBackgroundDelivery()
            return
        }

        Task {
            let alwaysLocation = await locationProvider.requestAlwaysAccess()
            let motion = await motionProvider.requestAccess()
            let workout = await workoutProvider.requestAccess()
            let granted = alwaysLocation == .authorized && motion == .authorized && workout == .authorized
            consentStore.update { $0.backgroundTripDetectionEnabled = granted }
            guard granted else {
                backgroundTripDetectionSetupIssue = missingPermissionMessage(location: alwaysLocation, motion: motion, workout: workout)
                return
            }
            backgroundTripDetectionSetupIssue = nil
            locationProvider.startBackgroundMonitoring()
            motionProvider.startContinuousUpdates()
            workoutProvider.startBackgroundDelivery()
            await ContextRequestStore.shared.requestPermissionAndSchedulePending()
        }
    }

    private func missingPermissionMessage(location: PermissionState, motion: PermissionState, workout: PermissionState) -> String {
        var missing: [String] = []
        if location != .authorized { missing.append("Location set to Always") }
        if motion != .authorized { missing.append("Motion & Fitness") }
        if workout != .authorized { missing.append("Health (workouts)") }
        return "Turn on \(missing.joined(separator: ", ")) in Settings > Kroniku, then try again."
    }

    /// Re-attaches the background monitors after a process relaunch; a no-op if the toggle is off.
    func resumeBackgroundMonitoringIfNeeded() {
        guard consent.backgroundTripDetectionEnabled else { return }
        locationProvider.startBackgroundMonitoring()
        motionProvider.startContinuousUpdates()
        workoutProvider.startBackgroundDelivery()
    }

    /// Requests HealthKit sleep-analysis read access and starts/stops the background observer accordingly.
    func setSleepTrackingEnabled(_ enabled: Bool) {
        guard enabled else {
            consentStore.update { $0.sleepTrackingEnabled = false }
            sleepProvider.stopBackgroundDelivery()
            return
        }

        Task {
            let granted = await sleepProvider.requestAccess() == .authorized
            consentStore.update { $0.sleepTrackingEnabled = granted }
            guard granted else { return }
            sleepProvider.startBackgroundDelivery()
        }
    }

    /// Re-attaches the sleep observer after a process relaunch; a no-op if the toggle is off.
    func resumeSleepTrackingIfNeeded() {
        guard consent.sleepTrackingEnabled else { return }
        sleepProvider.startBackgroundDelivery()
    }

    /// Keeps `geofencingEnabled` and CLLocationManager region monitoring in sync with the saved-places list;
    /// call after the place list changes or on relaunch. Requests Always access on the way from 0 -> 1+ places.
    func refreshGeofenceMonitoringIfNeeded() {
        let places = GeofenceStore.shared.places
        guard !places.isEmpty else {
            consentStore.update { $0.geofencingEnabled = false }
            locationProvider.stopMonitoringGeofences()
            return
        }

        Task {
            let always = await locationProvider.requestAlwaysAccess()
            consentStore.update { $0.geofencingEnabled = always == .authorized }
            guard always == .authorized else { return }
            locationProvider.startMonitoringGeofences(places)
        }
    }

    func captureCurrentCoordinate() async -> GeoCoordinate? {
        await locationProvider.captureVisit(around: Date())?.coordinate
    }

    func setTimeSemanticsEnabled(_ enabled: Bool) {
        consentStore.update { $0.timeSemanticsEnabled = enabled }
    }

    func setDayPeriodSchedule(_ schedule: DayPeriodSchedule) {
        guard schedule.isValid else { return }
        consentStore.update {
            $0.dayPeriodSchedule = schedule
            $0.dayPeriodScheduleUpdatedAt = Date()
            $0.dayPeriodSchedulePendingSync = true
        }
        Task { await pushDayPeriodsIfNeeded() }
    }

    /// Best-effort push of an unsynced local day-period schedule; safe to call repeatedly (e.g. on app launch).
    func pushDayPeriodsIfNeeded() async {
        guard consent.dayPeriodSchedulePendingSync, let schedule = consent.dayPeriodSchedule else { return }
        do {
            let response = try await PreferencesService.shared.updateDayPeriods(schedule)
            consentStore.update {
                $0.dayPeriodSchedule = response.dayPeriods.schedule
                $0.dayPeriodScheduleUpdatedAt = response.updatedAt
                $0.dayPeriodSchedulePendingSync = false
            }
        } catch {
            // Stays flagged as pending; retried on the next app launch or edit.
            print("Day period preferences push failed: \(error.localizedDescription)")
        }
    }

    /// Pulls the server-side day-period schedule and applies it locally unless an unsynced local edit is pending.
    func pullDayPeriodsIfNeeded() async {
        guard !consent.dayPeriodSchedulePendingSync else { return }
        do {
            let response = try await PreferencesService.shared.getPreferences()
            if let localUpdatedAt = consent.dayPeriodScheduleUpdatedAt, localUpdatedAt >= response.updatedAt {
                return
            }
            consentStore.update {
                $0.dayPeriodSchedule = response.dayPeriods.schedule
                $0.dayPeriodScheduleUpdatedAt = response.updatedAt
            }
        } catch {
            print("Day period preferences pull failed: \(error.localizedDescription)")
        }
    }

    func setVoiceTranscriptionEnabled(_ enabled: Bool) {
        consentStore.update { $0.voiceTranscriptionEnabled = enabled }
    }

    func setNoteIngestionEnabled(_ enabled: Bool) {
        consentStore.update { $0.noteIngestionEnabled = enabled }
    }

    func setContactsResolutionEnabled(_ enabled: Bool) {
        consentStore.update { $0.contactsResolutionEnabled = enabled }
    }

    func setBluetoothContextEnabled(_ enabled: Bool) {
        consentStore.update { $0.bluetoothContextEnabled = enabled }
    }

    func refreshPermissions() {
        calendarPermission = calendarProvider.authorizationState
        locationPermission = locationProvider.authorizationState
        motionPermission = motionProvider.authorizationState
        let providerHealthState = healthProvider.authorizationState
        if providerHealthState == .denied, consent.healthAuthorizationState == .authorized {
            // HealthKit read permissions can look denied on relaunch for read-only requests.
            // Preserve the last known authorized state unless a fresh request/probe says otherwise.
            healthPermission = .authorized
        } else {
            healthPermission = providerHealthState
        }
        if calendarPermission != .authorized {
            cachedCalendarEventsByDay.removeAll()
        }
    }

    func requestCalendarPermission() async {
        calendarPermission = await calendarProvider.requestAccess()
        if calendarPermission != .authorized {
            cachedCalendarEventsByDay.removeAll()
        }
    }

    func requestLocationPermission() async {
        locationPermission = await locationProvider.requestAccess()
        if locationPermission == .authorized {
            consentStore.update {
                $0.locationCaptureEnabled = true
                $0.weatherSnapshotsEnabled = true
            }
        }
    }

    func requestMotionPermission() async {
        motionPermission = await motionProvider.requestAccess()
        if motionPermission == .authorized {
            consentStore.update {
                $0.motionAttachmentEnabled = true
            }
        }
    }

    func requestHealthPermission() async {
        let defaultMetrics = Set(Tier1HealthMetric.allCases)
        let selectedMetrics = consent.healthConsent.enabledMetrics
        let requestedMetrics = selectedMetrics.isEmpty ? defaultMetrics : selectedMetrics

        let nextState = await healthProvider.requestAccess(for: requestedMetrics)
        healthPermission = nextState
        consentStore.update {
            $0.healthAuthorizationState = nextState
            if nextState == .authorized && $0.healthConsent.enabledMetrics.isEmpty {
                $0.healthConsent.enabledMetrics = requestedMetrics
            }
        }
    }

    func applyRetention(into repo: MemoryRepositoryProtocol) async {
        do {
            try repo.applyRetentionPolicy(for: consent)
        } catch {
            print("Retention cleanup failed: \(error)")
        }
    }

    func syncCalendarEvents(into repo: MemoryRepositoryProtocol, for day: Date = Date(), forceRefresh: Bool = false) async {
        guard consent.calendarImportEnabled else { return }
        guard calendarPermission == .authorized else { return }

        let calendar = Calendar.current
        let startOfSelectedDay = calendar.startOfDay(for: day)
        let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfSelectedDay) ?? startOfSelectedDay.addingTimeInterval(24 * 60 * 60)
        let interval = DateInterval(start: startOfSelectedDay, end: startOfNextDay)
        do {
            var imported = try await rawCalendarEvents(in: interval, for: startOfSelectedDay, forceRefresh: forceRefresh)
            if consent.timeSemanticsEnabled {
                imported = imported.map {
                    var event = $0
                    event.timeSemanticLabels = timeLabelProvider.labels(for: event.startsAt, coordinate: nil)
                    return event
                }
            }
            if consent.weatherSnapshotsEnabled && consent.calendarAttendeesAndLocationsEnabled {
                imported = await enrichCalendarEventsWithWeather(imported)
            }
            if !consent.calendarAttendeesAndLocationsEnabled {
                imported = imported.map {
                    TimelineCalendarImportEvent(
                        externalID: $0.externalID,
                        title: $0.title,
                        startsAt: $0.startsAt,
                        endsAt: $0.endsAt,
                        locationName: nil,
                        locationCoordinate: nil,
                        weather: nil,
                        attendeeNames: [],
                        timeSemanticLabels: $0.timeSemanticLabels
                    )
                }
            }
            try repo.syncCalendarEvents(imported, for: startOfSelectedDay, attendeeLocationSharingEnabled: consent.calendarAttendeesAndLocationsEnabled)
        } catch {
            print("Calendar sync failed: \(error)")
        }
    }

    private func rawCalendarEvents(in interval: DateInterval, for dayKey: Date, forceRefresh: Bool = false) async throws -> [TimelineCalendarImportEvent] {
        if !forceRefresh, let cached = cachedCalendarEventsByDay[dayKey], shouldReuseCalendarCache(cached, for: dayKey) {
            return cached.events
        }

        let fetched = try await calendarProvider.fetchEvents(in: interval)
        cachedCalendarEventsByDay[dayKey] = CachedCalendarDay(fetchedAt: Date(), events: fetched)
        return fetched
    }

    private func shouldReuseCalendarCache(_ cached: CachedCalendarDay, for dayKey: Date) -> Bool {
        let isToday = Calendar.current.isDate(dayKey, inSameDayAs: Date())
        guard isToday else { return true }
        return Date().timeIntervalSince(cached.fetchedAt) < 300
    }

    private func enrichCalendarEventsWithWeather(_ events: [TimelineCalendarImportEvent]) async -> [TimelineCalendarImportEvent] {
        var enriched: [TimelineCalendarImportEvent] = []
        enriched.reserveCapacity(events.count)

        for var event in events {
            guard let locationName = event.locationName, !locationName.isEmpty else {
                enriched.append(event)
                continue
            }

            if let coordinate = await geocodeLocationName(locationName) {
                event.locationCoordinate = coordinate
                event.weather = await weatherProvider.weather(at: event.startsAt, coordinate: coordinate)
            }

            enriched.append(event)
        }

        return enriched
    }

    private func geocodeLocationName(_ locationName: String) async -> GeoCoordinate? {
        return await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(locationName) { placemarks, _ in
                guard let coordinate = placemarks?.first?.location?.coordinate else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
        }
    }

    func buildEnrichment(for occurredAt: Date, includeHealthData: Bool = false) async -> ContextEnrichment {
        // Keep permission state in sync with the OS right before a capture attempt.
        refreshPermissions()

        var visit: VisitSnapshot?
        var locationSnapshot: VisitSnapshot?
        var weather: WeatherReading?
        var motionState: MotionState?

        if locationPermission == .authorized,
           (consent.locationCaptureEnabled || consent.weatherSnapshotsEnabled || consent.timeSemanticsEnabled) {
            locationSnapshot = await locationProvider.captureVisit(around: occurredAt)
            if let locationSnapshot {
                recentVisitSnapshot = locationSnapshot
            } else if let fallbackVisit = recentVisitSnapshot,
                      abs(fallbackVisit.capturedAt.timeIntervalSince(occurredAt)) <= 90 * 60 {
                // Reuse a very recent successful location when live capture is temporarily unavailable.
                locationSnapshot = fallbackVisit
            }
        }

        if consent.locationCaptureEnabled {
            visit = locationSnapshot
        }

        if consent.weatherSnapshotsEnabled, let coordinate = locationSnapshot?.coordinate {
            weather = await weatherProvider.weather(at: occurredAt, coordinate: coordinate)
            if let weather {
                recentWeatherSnapshot = (coordinate: coordinate, reading: weather)
            } else if let fallback = recentWeatherSnapshot,
                      abs(fallback.reading.observedAt.timeIntervalSince(occurredAt)) <= 90 * 60,
                      isLikelySameArea(lhs: coordinate, rhs: fallback.coordinate) {
                weather = WeatherReading(
                    observedAt: occurredAt,
                    condition: fallback.reading.condition,
                    temperatureC: fallback.reading.temperatureC
                )
            }
        }

        if consent.motionAttachmentEnabled && motionPermission == .authorized {
            motionState = await motionProvider.motionState(at: occurredAt)
        }

        let healthSummary: HealthSummary?
        if includeHealthData && consent.healthConsent.isEnabled && healthPermission == .authorized {
            healthSummary = await healthProvider.summary(for: occurredAt, metrics: consent.healthConsent.enabledMetrics)
        } else {
            healthSummary = nil
        }

        let labels = consent.timeSemanticsEnabled
            ? timeLabelProvider.labels(for: occurredAt, coordinate: locationSnapshot?.coordinate)
            : []

        return ContextEnrichment(visit: visit, weather: weather, motionState: motionState, healthSummary: healthSummary, timeSemanticLabels: labels)
    }

    private func isLikelySameArea(lhs: GeoCoordinate, rhs: GeoCoordinate) -> Bool {
        return abs(lhs.latitude - rhs.latitude) <= 0.02 && abs(lhs.longitude - rhs.longitude) <= 0.02
    }
}

@MainActor
final class EventKitCalendarProvider: CalendarContextProviding {
    private let store = EKEventStore()

    var authorizationState: PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized, .fullAccess, .writeOnly: return .authorized
        @unknown default: return .restricted
        }
    }

    func requestAccess() async -> PermissionState {
        do {
            if #available(iOS 17.0, *) {
                _ = try await store.requestFullAccessToEvents()
            } else {
                _ = try await withCheckedThrowingContinuation { continuation in
                    store.requestAccess(to: .event) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                } as Bool
            }
        } catch {
            print("Calendar permission request failed: \(error)")
        }
        return authorizationState
    }

    func fetchEvents(in interval: DateInterval) async throws -> [TimelineCalendarImportEvent] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let events = store.events(matching: predicate)

        return events.map { event in
            let attendees = (event.attendees ?? [])
                .compactMap { $0.name }
                .filter { !$0.isEmpty }

            return TimelineCalendarImportEvent(
                externalID: event.eventIdentifier,
                title: event.title.isEmpty ? "Untitled event" : event.title,
                startsAt: event.startDate,
                endsAt: event.endDate,
                locationName: event.location,
                attendeeNames: attendees,
                timeSemanticLabels: []
            )
        }
    }
}

@MainActor
final class CoreLocationVisitProvider: NSObject, LocationContextProviding, @preconcurrency CLLocationManagerDelegate {
    /// Shared instance so a background relaunch keeps delivering to the same `CLLocationManager` delegate.
    static let shared = CoreLocationVisitProvider()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<VisitSnapshot?, Never>?
    private var isMonitoringBackground = false
    private var lastGeofenceTransition: [String: (isEntry: Bool, date: Date)] = [:]
    private static let geofenceDedupeWindow: TimeInterval = 180

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationState: PermissionState {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .restricted
        }
    }

    var isAuthorizedAlways: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    func requestAccess() async -> PermissionState {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            _ = await waitForAuthorizationChange(from: .notDetermined, timeoutSeconds: 8)
        }
        return authorizationState
    }

    /// Escalates to always authorization, required for significant-location-change wake-ups while backgrounded.
    /// Handles both a fresh (notDetermined) request and an upgrade from an existing when-in-use grant.
    /// Returns `.authorized` only for a true "Always" grant, since when-in-use alone can't back background monitoring.
    func requestAlwaysAccess() async -> PermissionState {
        if manager.authorizationStatus != .authorizedAlways {
            let statusBeforeFirstRequest = manager.authorizationStatus
            manager.requestAlwaysAuthorization()
            _ = await waitForAuthorizationChange(from: statusBeforeFirstRequest, timeoutSeconds: 8)

            if manager.authorizationStatus == .authorizedWhenInUse {
                // iOS asked for when-in-use first; follow up so the user sees the Always upgrade prompt too.
                let statusBeforeUpgrade = manager.authorizationStatus
                manager.requestAlwaysAuthorization()
                _ = await waitForAuthorizationChange(from: statusBeforeUpgrade, timeoutSeconds: 8)
            }
        }
        return manager.authorizationStatus == .authorizedAlways ? .authorized : .denied
    }

    /// Starts significant-location-change monitoring, which can relaunch the app in the background.
    /// Publishes `.locationSignificantChange` events to `KronikuEventBus` instead of resolving `captureVisit`.
    func startBackgroundMonitoring() {
        guard isAuthorizedAlways else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startMonitoringSignificantLocationChanges()
        isMonitoringBackground = true
    }

    func stopBackgroundMonitoring() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        isMonitoringBackground = false
    }

    func startMonitoringGeofences(_ places: [NamedGeofence]) {
        stopMonitoringGeofences()
        manager.allowsBackgroundLocationUpdates = true
        for place in places.prefix(GeofenceStore.maxMonitoredRegions) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                radius: max(place.radiusMeters, 50),
                identifier: place.id.uuidString
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            SensorDiagnostics.log(
                "GEOFENCE monitoring registered title=Arrived/Left \(place.name) " +
                    "regionId=\(region.identifier) radiusMeters=\(region.radius)"
            )
            manager.requestState(for: region)
        }
    }

    func stopMonitoringGeofences() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
    }

    func captureVisit(around date: Date) async -> VisitSnapshot? {
        guard authorizationState == .authorized else { return nil }
        manager.requestLocation()
        guard let visit = await withCheckedContinuation({ (continuation: CheckedContinuation<VisitSnapshot?, Never>) in
            self.continuation = continuation
        }) else {
            return nil
        }

        // Bound retained precision to avoid over-precise location retention.
        let roundedLat = (visit.coordinate.latitude * 1_000).rounded() / 1_000
        let roundedLon = (visit.coordinate.longitude * 1_000).rounded() / 1_000

        return VisitSnapshot(
            name: visit.name,
            coordinate: GeoCoordinate(latitude: roundedLat, longitude: roundedLon),
            capturedAt: date
        )
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            SensorDiagnostics.log("LOCATION callback samples=0")
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }

        SensorDiagnostics.log(
            "LOCATION callback samples=\(locations.count) timestamp=\(SensorDiagnostics.timestamp(location.timestamp)) " +
            "latitude=\(location.coordinate.latitude) longitude=\(location.coordinate.longitude) " +
            "horizontalAccuracy=\(location.horizontalAccuracy) speed=\(location.speed) " +
            "oneShot=\(continuation != nil) backgroundMonitoring=\(isMonitoringBackground)"
        )

        // A one-shot `captureVisit` request is in flight; resolve it and don't also publish a background event.
        guard continuation == nil else {
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                Task { @MainActor in
                    let placeName = placemarks?.first?.name ?? "Nearby"
                    self.continuation?.resume(returning: VisitSnapshot(
                        name: placeName,
                        coordinate: GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                        capturedAt: Date()
                    ))
                    self.continuation = nil
                }
            }
            return
        }

        guard isMonitoringBackground else { return }
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            let resolvedName = placemarks?.first?.name
            let latitude = location.coordinate.latitude
            let longitude = location.coordinate.longitude
            Task { @MainActor in
                let placeName = resolvedName ?? "Nearby"

                await KronikuEventBus.shared.publish(KronikuEvent(
                    timestamp: location.timestamp,
                    type: .locationSignificantChange,
                    source: "coreLocation",
                    metadata: [
                        "placeName": placeName,
                        "latitude": "\(latitude)",
                        "longitude": "\(longitude)"
                    ]
                ))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location fetch failed: \(error)")
        continuation?.resume(returning: nil)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        handleGeofenceTransition(region, isEntry: true)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        handleGeofenceTransition(region, isEntry: false)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        let stateName: String
        switch state {
        case .inside: stateName = "inside"
        case .outside: stateName = "outside"
        case .unknown: stateName = "unknown"
        @unknown default: stateName = "unknown"
        }
        SensorDiagnostics.log(
            "GEOFENCE OS state state=\(stateName) regionId=\(region.identifier) " +
                "timestamp=\(SensorDiagnostics.timestamp(Date()))"
        )
    }

    /// CoreLocation can refire the same enter/exit transition; ignore repeats within a short window.
    private func handleGeofenceTransition(_ region: CLRegion, isEntry: Bool) {
        let now = Date()
        let transitionTitle: String
        if let place = GeofenceStore.shared.place(forRegionId: region.identifier) {
            transitionTitle = isEntry ? "Arrived \(place.name)" : "Left \(place.name)"
        } else {
            transitionTitle = isEntry ? "Arrived (unknown place)" : "Left (unknown place)"
        }
        SensorDiagnostics.log(
            "GEOFENCE OS received title=\(transitionTitle) regionId=\(region.identifier) " +
                "timestamp=\(SensorDiagnostics.timestamp(now))"
        )
        if let last = lastGeofenceTransition[region.identifier], last.isEntry == isEntry,
           now.timeIntervalSince(last.date) < Self.geofenceDedupeWindow {
            return
        }
        lastGeofenceTransition[region.identifier] = (isEntry, now)
        Task {
            await KronikuEventBus.shared.publish(KronikuEvent(
                timestamp: now,
                type: isEntry ? .geofenceEntered : .geofenceExited,
                source: "coreLocation",
                metadata: ["regionId": region.identifier]
            ))
        }
    }

    private func waitForAuthorizationChange(from initialStatus: CLAuthorizationStatus, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if manager.authorizationStatus != initialStatus {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }
}

@MainActor
struct WeatherKitSnapshotProvider: WeatherContextProviding {
    func weather(at date: Date, coordinate: GeoCoordinate) async -> WeatherReading? {
        if abs(Date().timeIntervalSince(date)) > 90 * 60 {
            return await openMeteoFallback(at: date, coordinate: coordinate)
        }
#if canImport(WeatherKit)
        let weatherService = WeatherService.shared
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let weather = try await weatherService.weather(for: location)
            return WeatherReading(
                observedAt: date,
                condition: weather.currentWeather.condition.description,
                temperatureC: weather.currentWeather.temperature.converted(to: .celsius).value
            )
        } catch {
            print("Weather fetch failed: \(error)")
            return await openMeteoFallback(at: date, coordinate: coordinate)
        }
#else
        return await openMeteoFallback(at: date, coordinate: coordinate)
#endif
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            var temperature2m: Double
            var weatherCode: Int

            private enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case weatherCode = "weather_code"
            }
        }

        struct Hourly: Decodable {
            var time: [String]
            var temperature2m: [Double]
            var weatherCode: [Int]

            private enum CodingKeys: String, CodingKey {
                case time
                case temperature2m = "temperature_2m"
                case weatherCode = "weather_code"
            }
        }

        var current: Current?
        var hourly: Hourly?
    }

    private func openMeteoFallback(at date: Date, coordinate: GeoCoordinate) async -> WeatherReading? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: "\(coordinate.latitude)"),
            URLQueryItem(name: "longitude", value: "\(coordinate.longitude)"),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "past_days", value: "2"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "UTC")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            if let hourly = decoded.hourly,
               let index = nearestHourlyIndex(to: date, times: hourly.time),
               hourly.temperature2m.indices.contains(index),
               hourly.weatherCode.indices.contains(index) {
                return WeatherReading(
                    observedAt: date,
                    condition: openMeteoCondition(for: hourly.weatherCode[index]),
                    temperatureC: hourly.temperature2m[index]
                )
            }
            guard let current = decoded.current else { return nil }
            return WeatherReading(
                observedAt: date,
                condition: openMeteoCondition(for: current.weatherCode),
                temperatureC: current.temperature2m
            )
        } catch {
            print("Open-Meteo fallback failed: \(error)")
            return nil
        }
    }

    private func nearestHourlyIndex(to date: Date, times: [String]) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return times.enumerated().compactMap { index, value -> (Int, TimeInterval)? in
            guard let parsed = formatter.date(from: value) else { return nil }
            return (index, abs(parsed.timeIntervalSince(date)))
        }
        .min { $0.1 < $1.1 }?.0
    }

    private func openMeteoCondition(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67: return "Rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Weather"
        }
    }
}

@MainActor
final class CoreMotionStateProvider: MotionContextProviding {
    private struct ActivitySnapshot: Sendable {
        let startDate: Date
        let confidence: Int
        let stationary: Bool
        let walking: Bool
        let running: Bool
        let automotive: Bool
        let cycling: Bool
        let unknown: Bool

        init(_ activity: CMMotionActivity) {
            startDate = activity.startDate
            confidence = activity.confidence.rawValue
            stationary = activity.stationary
            walking = activity.walking
            running = activity.running
            automotive = activity.automotive
            cycling = activity.cycling
            unknown = activity.unknown
        }
    }

    static let shared = CoreMotionStateProvider()

    private let manager = CMMotionActivityManager()
    private let bluetoothProvider = BluetoothAccessoryProvider()
    private let defaults: UserDefaults
    private static let checkpointKey = "coreMotionLastProcessedAtV2"
    private static let stateKey = "coreMotionLastPublishedStateV2"
    private var lastPublishedState: MotionState?
    private var catchUpTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lastPublishedState = defaults.string(forKey: Self.stateKey).flatMap(MotionState.init(rawValue:))
    }

    var authorizationState: PermissionState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .restricted
        }
    }

    func requestAccess() async -> PermissionState {
        guard CMMotionActivityManager.isActivityAvailable() else { return .restricted }
        if authorizationState == .notDetermined {
            let start = Date().addingTimeInterval(-30)
            _ = try? await queryMotionState(from: start, to: Date())
        }
        return authorizationState
    }

    func motionState(at date: Date) async -> MotionState? {
        guard authorizationState == .authorized else { return nil }
        let start = date.addingTimeInterval(-15 * 60)
        do {
            return try await queryMotionState(from: start, to: date)
        } catch {
            print("Motion activity query failed: \(error)")
            return nil
        }
    }

    /// Starts a continuous background feed; publishes `.motionChanged` only on high-confidence state transitions.
    func startContinuousUpdates() {
        guard CMMotionActivityManager.isActivityAvailable(), authorizationState == .authorized else { return }
        catchUpTask?.cancel()
        manager.stopActivityUpdates()
        catchUpTask = Task { [weak self] in
            await self?.catchUpAndStartLiveUpdates()
        }
    }

    private func catchUpAndStartLiveUpdates() async {
        let end = Date()
        let startOfToday = Calendar.current.startOfDay(for: end)
        let checkpoint = defaults.object(forKey: Self.checkpointKey) as? Date
        let start = max(checkpoint ?? startOfToday, startOfToday)

        do {
            let activities = try await queryActivities(from: start, to: end)
                .sorted { $0.startDate < $1.startDate }
            SensorDiagnostics.log(
                "MOTION catchUp start=\(SensorDiagnostics.timestamp(start)) " +
                "end=\(SensorDiagnostics.timestamp(end)) samples=\(activities.count)"
            )
            for activity in activities where !Task.isCancelled {
                await process(activity, origin: "history")
            }
        } catch {
            SensorDiagnostics.log("MOTION catchUp failed error=\(error.localizedDescription)")
        }

        guard !Task.isCancelled else { return }
        startLiveUpdates()
    }

    private func startLiveUpdates() {
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            let snapshot = ActivitySnapshot(activity)
            Task { @MainActor in
                await self.process(snapshot, origin: "live")
            }
        }
    }

    func stopContinuousUpdates() {
        catchUpTask?.cancel()
        catchUpTask = nil
        manager.stopActivityUpdates()
    }

    private func process(_ activity: ActivitySnapshot, origin: String) async {
        let state = mappedState(for: activity)
        let classification = state?.rawValue ?? "nil"
        let attributes = [
            "stationary=\(activity.stationary)",
            "walking=\(activity.walking)",
            "running=\(activity.running)",
            "automotive=\(activity.automotive)",
            "cycling=\(activity.cycling)",
            "unknown=\(activity.unknown)"
        ].joined(separator: " ")
        SensorDiagnostics.log(
            "MOTION callback origin=\(origin) start=\(SensorDiagnostics.timestamp(activity.startDate)) " +
            "confidence=\(activity.confidence) \(attributes) mapped=\(classification)"
        )
        advanceCheckpoint(to: activity.startDate)
        guard activity.confidence != CMMotionActivityConfidence.low.rawValue else {
            SensorDiagnostics.log("MOTION ignored reason=lowConfidence")
            return
        }
        guard let state else { return }
        guard state != lastPublishedState else {
            SensorDiagnostics.log("MOTION ignored reason=duplicate state=\(state.rawValue)")
            return
        }
        lastPublishedState = state
        defaults.set(state.rawValue, forKey: Self.stateKey)
        let bluetoothContext: BluetoothContextKind?
        if origin == "live", Tier1ConsentStore().consent.bluetoothContextEnabled {
            bluetoothContext = await bluetoothProvider.captureNearbyContext()
        } else {
            bluetoothContext = nil
        }
        var metadata = ["state": state.rawValue, "origin": origin]
        if let bluetoothContext {
            metadata["bluetoothContext"] = bluetoothContext.rawValue
        }
        await KronikuEventBus.shared.publish(KronikuEvent(
            timestamp: activity.startDate,
            type: .motionChanged,
            source: "coreMotion",
            metadata: metadata
        ))
    }

    private func advanceCheckpoint(to date: Date) {
        let checkpoint = defaults.object(forKey: Self.checkpointKey) as? Date
        if checkpoint == nil || date > checkpoint! {
            defaults.set(date, forKey: Self.checkpointKey)
        }
    }

    private func mappedState(for activity: CMMotionActivity) -> MotionState? {
        if activity.automotive { return .driving }
        if activity.cycling { return .cycling }
        if activity.running { return .running }
        if activity.walking { return .walking }
        if activity.stationary { return .stationary }
        return nil
    }

    private func mappedState(for activity: ActivitySnapshot) -> MotionState? {
        if activity.automotive { return .driving }
        if activity.cycling { return .cycling }
        if activity.running { return .running }
        if activity.walking { return .walking }
        if activity.stationary { return .stationary }
        return .unknown
    }

    private func queryMotionState(from start: Date, to end: Date) async throws -> MotionState? {
        try await withCheckedThrowingContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    guard let latest = activities?.last else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if latest.automotive {
                        continuation.resume(returning: .driving)
                    } else if latest.cycling {
                        continuation.resume(returning: .cycling)
                    } else if latest.running {
                        continuation.resume(returning: .running)
                    } else if latest.walking {
                        continuation.resume(returning: .walking)
                    } else if latest.stationary {
                        continuation.resume(returning: .stationary)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    private func queryActivities(from start: Date, to end: Date) async throws -> [ActivitySnapshot] {
        try await withCheckedThrowingContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (activities ?? []).map(ActivitySnapshot.init))
                }
            }
        }
    }
}

@MainActor
struct HealthKitSummaryProvider: HealthContextProviding {
#if canImport(HealthKit)
    private let store = HKHealthStore()
#endif

    var authorizationState: PermissionState {
#if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { return .restricted }
        let sampleTypes = Set(Tier1HealthMetric.allCases.compactMap(sampleType(for:)))
        guard !sampleTypes.isEmpty else { return .notDetermined }

        var sawAuthorized = false
        var sawDenied = false
        var sawNotDetermined = false

        for sampleType in sampleTypes {
            switch store.authorizationStatus(for: sampleType) {
            case .sharingAuthorized:
                sawAuthorized = true
            case .sharingDenied:
                sawDenied = true
            case .notDetermined:
                sawNotDetermined = true
            @unknown default:
                sawDenied = true
            }
        }

        if sawAuthorized { return .authorized }
        if sawDenied { return .denied }
        if sawNotDetermined { return .notDetermined }
        return .notDetermined
#else
        return .restricted
#endif
    }

    func requestAccess(for metrics: Set<Tier1HealthMetric>) async -> PermissionState {
#if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { return .restricted }
        let sampleTypes = Set(metrics.compactMap(sampleType(for:)))
        guard !sampleTypes.isEmpty else { return authorizationState }

        do {
            try await store.requestAuthorization(toShare: [], read: sampleTypes)
            return await probeReadAuthorization(for: sampleTypes)
        } catch {
            print("Health permission request failed: \(error)")
            return .denied
        }
#else
        _ = metrics
        return .restricted
#endif
    }

    func summary(for date: Date, metrics: Set<Tier1HealthMetric>) async -> HealthSummary? {
#if canImport(HealthKit)
        let dayInterval = Calendar.current.dateInterval(of: .day, for: date) ?? DateInterval(start: date, end: date.addingTimeInterval(24 * 60 * 60))
        return await summary(in: dayInterval, metrics: metrics)
#else
        _ = date
        _ = metrics
        return nil
    #endif
    }

    func summary(in interval: DateInterval, metrics: Set<Tier1HealthMetric>) async -> HealthSummary? {
#if canImport(HealthKit)
        let requestedMetrics = metrics.map(\.rawValue).sorted().joined(separator: ",")
        SensorDiagnostics.log(
            "HEALTH summary request start=\(SensorDiagnostics.timestamp(interval.start)) end=\(SensorDiagnostics.timestamp(interval.end)) metrics=[\(requestedMetrics)] " +
            "authorization=\(authorizationState.rawValue)"
        )
        // HealthKit hides read authorization status. The caller gates queries on saved user opt-in.
        var entries: [HealthSummary.Entry] = []

        if metrics.contains(.steps) {
            do {
                let total = try await cumulativeSum(for: .stepCount, unit: .count(), in: interval)
                entries.append(.init(metric: .steps, value: "\(Int(total.rounded())) steps"))
            } catch {
                SensorDiagnostics.log("HEALTH steps query failed error=\(error.localizedDescription)")
            }
        }
        if metrics.contains(.heartRate) {
            do {
                let avg = try await discreteAverage(for: .heartRate, unit: HKUnit.count().unitDivided(by: .minute()), in: interval)
                entries.append(.init(metric: .heartRate, value: "\(Int(avg.rounded())) bpm avg"))
            } catch {
                SensorDiagnostics.log("HEALTH heartRate query failed error=\(error.localizedDescription)")
            }
        }
        if metrics.contains(.respiratoryRate) {
            do {
                let avg = try await discreteAverage(for: .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), in: interval)
                entries.append(.init(metric: .respiratoryRate, value: "\(String(format: "%.1f", avg)) breaths/min avg"))
            } catch {
                SensorDiagnostics.log("HEALTH respiratoryRate query failed error=\(error.localizedDescription)")
            }
        }
        if metrics.contains(.heartRateVariability) {
            do {
                let avg = try await discreteAverage(for: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), in: interval)
                entries.append(.init(metric: .heartRateVariability, value: "\(Int(avg.rounded())) ms avg"))
            } catch {
                SensorDiagnostics.log("HEALTH heartRateVariability query failed error=\(error.localizedDescription)")
            }
        }
        guard !entries.isEmpty else { return nil }
        return HealthSummary(capturedAt: interval.end, entries: entries)
#else
        _ = interval
        _ = metrics
        return nil
#endif
    }

#if canImport(HealthKit)
    private func sampleType(for metric: Tier1HealthMetric) -> HKSampleType? {
        switch metric {
        case .steps:
            return HKObjectType.quantityType(forIdentifier: .stepCount)
        case .heartRate:
            return HKObjectType.quantityType(forIdentifier: .heartRate)
        case .respiratoryRate:
            return HKObjectType.quantityType(forIdentifier: .respiratoryRate)
        case .heartRateVariability:
            return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        }
    }

    private func cumulativeSum(for identifier: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async throws -> Double {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let value = result?.sumQuantity()?.doubleValue(for: unit) ?? 0
                    continuation.resume(returning: value)
                }
            }
            store.execute(query)
        }
    }

    private func discreteAverage(for identifier: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async throws -> Double {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let value = result?.averageQuantity()?.doubleValue(for: unit) ?? 0
                    continuation.resume(returning: value)
                }
            }
            store.execute(query)
        }
    }

    private func probeReadAuthorization(for sampleTypes: Set<HKSampleType>) async -> PermissionState {
        guard !sampleTypes.isEmpty else { return .notDetermined }

        // Probe every requested type individually; HealthKit's aggregate authorizationStatus(for:) only
        // reflects share (write) status, so a per-type read denial must be discovered via a real query.
        var results: [PermissionState] = []
        for sampleType in sampleTypes {
            results.append(await probeReadAuthorization(for: sampleType))
        }
        if results.allSatisfy({ $0 == .authorized }) { return .authorized }
        if results.contains(.denied) { return .denied }
        if results.contains(.notDetermined) { return .notDetermined }
        return .restricted
    }

    private func probeReadAuthorization(for sampleType: HKSampleType) async -> PermissionState {

        let end = Date()
        let start = end.addingTimeInterval(-24 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples ?? [])
                    }
                }
                store.execute(query)
            }
            return .authorized
        } catch {
            if let hkError = error as? HKError {
                switch hkError.code {
                case .errorAuthorizationDenied:
                    return .denied
                case .errorAuthorizationNotDetermined:
                    return .notDetermined
                default:
                    return .restricted
                }
            }
            return .restricted
        }
    }
#endif
}

/// Observes HealthKit workouts in the background and publishes `.workoutStarted`/`.workoutEnded` to `KronikuEventBus`.
@MainActor
final class HealthKitWorkoutObserver: WorkoutContextProviding {
    static let shared = HealthKitWorkoutObserver()

#if canImport(HealthKit)
    private struct WorkoutSnapshot: Sendable {
        var id: UUID
        var startDate: Date
        var endDate: Date
        var duration: TimeInterval
        var activityName: String
        var distanceMeters: Double?
    }

    private let store = HKHealthStore()
    private var observerQuery: HKObserverQuery?
    private var publishedWorkoutIDs: Set<UUID> = []

    func requestAccess() async -> PermissionState {
        guard HKHealthStore.isHealthDataAvailable() else { return .restricted }
        do {
            try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()])
        } catch {
            print("Workout permission request failed: \(error)")
            return .denied
        }
        // Read-only authorizationStatus(for:) always reflects share (write) status, which we never requested,
        // so it can't tell us whether read access was granted — probe with an actual sample query instead.
        return await probeWorkoutReadAuthorization()
    }

    private func probeWorkoutReadAuthorization() async -> PermissionState {
        let end = Date()
        let start = end.addingTimeInterval(-24 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples ?? [])
                    }
                }
                store.execute(query)
            }
            return .authorized
        } catch {
            if let hkError = error as? HKError {
                switch hkError.code {
                case .errorAuthorizationDenied:
                    return .denied
                case .errorAuthorizationNotDetermined:
                    return .notDetermined
                default:
                    return .restricted
                }
            }
            return .restricted
        }
    }

    func startBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable(), observerQuery == nil else { return }
        let workoutType = HKObjectType.workoutType()
        let query = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completionHandler, error in
            defer { completionHandler() }
            guard error == nil else {
                print("Workout observer query failed: \(error!)")
                return
            }
            Task { await self?.publishRecentWorkouts() }
        }
        observerQuery = query
        store.execute(query)
        Task { await publishRecentWorkouts() }
        store.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { success, error in
            if let error {
                print("Enabling workout background delivery failed: \(error)")
            } else if !success {
                print("Workout background delivery could not be enabled.")
            }
        }
    }

    func stopBackgroundDelivery() {
        if let observerQuery {
            store.stop(observerQuery)
        }
        observerQuery = nil
        store.disableBackgroundDelivery(for: HKObjectType.workoutType(), withCompletion: { _, _ in })
    }

    private func publishRecentWorkouts() async {
        let workouts = await fetchRecentWorkouts()
        guard !workouts.isEmpty else {
            SensorDiagnostics.log("WORKOUT observer result=none")
            return
        }

        let formatter = ISO8601DateFormatter()
        for workout in workouts.sorted(by: { $0.startDate < $1.startDate }) {
            let isDuplicate = publishedWorkoutIDs.contains(workout.id)
            SensorDiagnostics.log(
                "WORKOUT callback start=\(SensorDiagnostics.timestamp(workout.startDate)) " +
                "end=\(SensorDiagnostics.timestamp(workout.endDate)) durationSeconds=\(workout.duration) " +
                "activity=\(workout.activityName) duplicate=\(isDuplicate)"
            )
            guard !isDuplicate else { continue }
            publishedWorkoutIDs.insert(workout.id)
            let minutes = Int((workout.duration / 60).rounded())
            var metadata = [
                "startedAt": formatter.string(from: workout.startDate),
                "endedAt": formatter.string(from: workout.endDate),
                "activityType": workout.activityName,
                "durationMinutes": "\(minutes)"
            ]
            if let distanceMeters = workout.distanceMeters {
                metadata["distanceMeters"] = "\(distanceMeters)"
            }
            if let route = await routeCoordinates(for: workout.id),
               let routeData = try? JSONEncoder().encode(route),
               let routeJSON = String(data: routeData, encoding: .utf8) {
                metadata["routeCoordinates"] = routeJSON
            }
            await KronikuEventBus.shared.publish(KronikuEvent(
                timestamp: workout.endDate,
                type: .workoutEnded,
                source: "healthKit",
                metadata: metadata
            ))
        }
    }

    private func fetchRecentWorkouts() async -> [WorkoutSnapshot] {
        let end = Date()
        let start = end.addingTimeInterval(-2 * 24 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, _ in
                let snapshots = (samples as? [HKWorkout] ?? []).map { workout in
                    WorkoutSnapshot(
                        id: workout.uuid,
                        startDate: workout.startDate,
                        endDate: workout.endDate,
                        duration: workout.duration,
                        activityName: Self.workoutActivityName(for: workout),
                        distanceMeters: workout.totalDistance?.doubleValue(for: .meter())
                    )
                }
                continuation.resume(returning: snapshots)
            }
            store.execute(query)
        }
    }

    /// Fetches the workout's route as a downsampled coordinate list, since raw GPS traces can hold thousands of points.
    private func routeCoordinates(for workoutID: UUID) async -> WorkoutRoute? {
        let predicate = HKQuery.predicateForObject(with: workoutID)
        guard let workout = await fetchWorkoutObject(matching: predicate) else { return nil }

        let routePredicate = HKQuery.predicateForObjects(from: workout)
        guard let route = await fetchWorkoutRouteSample(matching: routePredicate) else { return nil }

        var locations: [CLLocation] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let routeQuery = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                if let batch, error == nil {
                    locations.append(contentsOf: batch)
                }
                if done || error != nil {
                    continuation.resume()
                }
            }
            self.store.execute(routeQuery)
        }
        guard !locations.isEmpty else { return nil }
        return WorkoutRoute(coordinates: Self.downsample(locations).map {
            GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        })
    }

    private func fetchWorkoutObject(matching predicate: NSPredicate) async -> HKWorkout? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout])?.first)
            }
            store.execute(query)
        }
    }

    private func fetchWorkoutRouteSample(matching predicate: NSPredicate) async -> HKWorkoutRoute? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkoutRoute])?.first)
            }
            store.execute(query)
        }
    }

    /// Caps stored route points at 150, evenly spaced, to keep the persisted memory event small.
    private static func downsample(_ locations: [CLLocation], maxPoints: Int = 150) -> [CLLocation] {
        guard locations.count > maxPoints else { return locations }
        let stride = Double(locations.count) / Double(maxPoints)
        return (0..<maxPoints).map { locations[Int(Double($0) * stride)] }
    }

    /// Covers the common Health/Fitness activity types (indoor/outdoor and pool/open-water are
    /// distinguished via workout metadata, since HealthKit doesn't split them into separate types).
    nonisolated private static func workoutActivityName(for workout: HKWorkout) -> String {
        let isIndoor = (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
        switch workout.workoutActivityType {
        case .running: return isIndoor ? "Indoor Run" : "Outdoor Run"
        case .walking: return isIndoor ? "Indoor Walk" : "Outdoor Walk"
        case .cycling: return isIndoor ? "Indoor Cycle" : "Outdoor Cycle"
        case .hiking: return "Hiking"
        case .swimming:
            if let locationRaw = workout.metadata?[HKMetadataKeySwimmingLocationType] as? Int,
               let location = HKWorkoutSwimmingLocationType(rawValue: locationRaw), location == .openWater {
                return "Open Water Swim"
            }
            return "Pool Swim"
        case .highIntensityIntervalTraining: return "High Intensity Interval Training"
        case .traditionalStrengthTraining: return "Traditional Strength Training"
        case .functionalStrengthTraining: return "Functional Strength Training"
        case .coreTraining: return "Core Training"
        case .elliptical: return "Elliptical"
        case .rowing: return isIndoor ? "Indoor Row" : "Rowing"
        case .stairClimbing: return "Stair Climbing"
        case .crossTraining: return "Cross Training"
        case .mixedCardio: return "Mixed Cardio"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .dance: return "Dance"
        case .cooldown: return "Cooldown"
        case .flexibility: return "Flexibility"
        case .stepTraining: return "Step Training"
        case .boxing, .kickboxing: return "Boxing"
        case .martialArts: return "Martial Arts"
        case .climbing: return "Climbing"
        case .golf: return "Golf"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        case .badminton: return "Badminton"
        case .squash: return "Squash"
        case .volleyball: return "Volleyball"
        case .americanFootball: return "Football"
        case .baseball: return "Baseball"
        case .softball: return "Softball"
        case .cricket: return "Cricket"
        case .hockey: return "Hockey"
        case .rugby: return "Rugby"
        case .handball: return "Handball"
        case .tableTennis: return "Table Tennis"
        case .sailing: return "Sailing"
        case .surfingSports: return "Surfing"
        case .waterFitness: return "Water Fitness"
        case .waterPolo: return "Water Polo"
        case .paddleSports: return "Paddle Sports"
        case .fencing: return "Fencing"
        case .wrestling: return "Wrestling"
        case .taiChi: return "Tai Chi"
        case .mindAndBody: return "Mind and Body"
        default: return "Workout"
        }
    }
#else
    func requestAccess() async -> PermissionState { .restricted }
    func startBackgroundDelivery() {}
    func stopBackgroundDelivery() {}
#endif
}

/// Observes HealthKit sleep analysis in the background and publishes finalized sleep sessions
/// (bedtime -> wake time) as `.sleepAnalysisRecorded` events to `KronikuEventBus`.
@MainActor
final class HealthKitSleepObserver: SleepContextProviding {
    static let shared = HealthKitSleepObserver()

#if canImport(HealthKit)
    private enum SleepStage: Sendable {
        case inBed
        case asleep
        case awake
    }

    private struct RawSleepSample: Sendable {
        var start: Date
        var end: Date
        var stage: SleepStage
    }

    private struct SleepSession: Sendable {
        var key: String
        var bedTime: Date
        var wakeTime: Date
        var asleepSeconds: TimeInterval
        var inBedSeconds: TimeInterval
    }

    /// Samples this close together are treated as one continuous sleep session (naps and brief wake-ups included).
    private static let sessionGapTolerance: TimeInterval = 60 * 60
    /// A session isn't reported until this long after its last sample, so late-arriving samples can still merge in.
    private static let finalizationDelay: TimeInterval = 90 * 60

    private let store = HKHealthStore()
    private var observerQuery: HKObserverQuery?
    private var publishedSessionKeys: Set<String> = []

    func requestAccess() async -> PermissionState {
        guard HKHealthStore.isHealthDataAvailable(), let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return .restricted
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType])
        } catch {
            print("Sleep permission request failed: \(error)")
            return .denied
        }
        return await probeSleepReadAuthorization(sleepType: sleepType)
    }

    private func probeSleepReadAuthorization(sleepType: HKCategoryType) async -> PermissionState {
        let end = Date()
        let start = end.addingTimeInterval(-24 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples ?? [])
                    }
                }
                store.execute(query)
            }
            return .authorized
        } catch {
            if let hkError = error as? HKError {
                switch hkError.code {
                case .errorAuthorizationDenied:
                    return .denied
                case .errorAuthorizationNotDetermined:
                    return .notDetermined
                default:
                    return .restricted
                }
            }
            return .restricted
        }
    }

    func startBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable(),
              observerQuery == nil,
              let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let query = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, completionHandler, error in
            defer { completionHandler() }
            guard error == nil else {
                print("Sleep observer query failed: \(error!)")
                return
            }
            Task { await self?.publishFinalizedSessions(sleepType: sleepType) }
        }
        observerQuery = query
        store.execute(query)
        Task { await publishFinalizedSessions(sleepType: sleepType) }
        store.enableBackgroundDelivery(for: sleepType, frequency: .immediate) { success, error in
            if let error {
                print("Enabling sleep background delivery failed: \(error)")
            } else if !success {
                print("Sleep background delivery could not be enabled.")
            }
        }
    }

    func stopBackgroundDelivery() {
        if let observerQuery {
            store.stop(observerQuery)
        }
        observerQuery = nil
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            store.disableBackgroundDelivery(for: sleepType, withCompletion: { _, _ in })
        }
    }

    private func publishFinalizedSessions(sleepType: HKCategoryType) async {
        let samples = await fetchRecentSleepSamples(sleepType: sleepType)
        guard !samples.isEmpty else {
            SensorDiagnostics.log("SLEEP observer result=none")
            return
        }

        let now = Date()
        for session in Self.sessions(from: samples) where !Task.isCancelled {
            let isFinalized = now.timeIntervalSince(session.wakeTime) >= Self.finalizationDelay
            let isDuplicate = publishedSessionKeys.contains(session.key)
            SensorDiagnostics.log(
                "SLEEP session bedTime=\(SensorDiagnostics.timestamp(session.bedTime)) " +
                "wakeTime=\(SensorDiagnostics.timestamp(session.wakeTime)) finalized=\(isFinalized) duplicate=\(isDuplicate)"
            )
            guard isFinalized, !isDuplicate else { continue }
            publishedSessionKeys.insert(session.key)
            let formatter = ISO8601DateFormatter()
            await KronikuEventBus.shared.publish(KronikuEvent(
                timestamp: session.wakeTime,
                type: .sleepAnalysisRecorded,
                source: "healthKit",
                metadata: [
                    "sessionKey": session.key,
                    "bedTime": formatter.string(from: session.bedTime),
                    "wakeTime": formatter.string(from: session.wakeTime),
                    "asleepSeconds": "\(Int(session.asleepSeconds.rounded()))",
                    "inBedSeconds": "\(Int(session.inBedSeconds.rounded()))"
                ]
            ))
        }
    }

    /// Merges non-awake samples into per-night sessions (tolerating brief wake-ups mid-night), then aggregates
    /// asleep vs. in-bed duration across every sample (including awake gaps) within each session's bounds.
    private static func sessions(from samples: [RawSleepSample]) -> [SleepSession] {
        let sorted = samples.sorted { $0.start < $1.start }
        var bounds: [(start: Date, end: Date)] = []
        var current: (start: Date, end: Date)?

        for sample in sorted where sample.stage != .awake {
            if let existing = current, sample.start.timeIntervalSince(existing.end) <= sessionGapTolerance {
                current = (existing.start, max(existing.end, sample.end))
            } else {
                if let existing = current { bounds.append(existing) }
                current = (sample.start, sample.end)
            }
        }
        if let existing = current { bounds.append(existing) }

        return bounds.map { bedTime, wakeTime in
            var asleepSeconds: TimeInterval = 0
            var inBedSeconds: TimeInterval = 0
            var hasExplicitInBed = false
            for sample in sorted where sample.start < wakeTime && sample.end > bedTime {
                let clippedStart = max(sample.start, bedTime)
                let clippedEnd = min(sample.end, wakeTime)
                guard clippedEnd > clippedStart else { continue }
                let duration = clippedEnd.timeIntervalSince(clippedStart)
                switch sample.stage {
                case .asleep:
                    asleepSeconds += duration
                case .inBed:
                    inBedSeconds += duration
                    hasExplicitInBed = true
                case .awake:
                    break
                }
            }
            if !hasExplicitInBed {
                inBedSeconds = wakeTime.timeIntervalSince(bedTime)
            }
            return SleepSession(
                key: sessionKey(bedTime, wakeTime),
                bedTime: bedTime,
                wakeTime: wakeTime,
                asleepSeconds: asleepSeconds,
                inBedSeconds: inBedSeconds
            )
        }
    }

    private static func sessionKey(_ start: Date, _ end: Date) -> String {
        "\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))"
    }

    private func fetchRecentSleepSamples(sleepType: HKCategoryType) async -> [RawSleepSample] {
        let end = Date()
        let start = end.addingTimeInterval(-3 * 24 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, _ in
                let mapped = (samples as? [HKCategorySample] ?? []).compactMap { sample -> RawSleepSample? in
                    guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
                    let stage: SleepStage
                    switch value {
                    case .inBed: stage = .inBed
                    case .awake: stage = .awake
                    default: stage = .asleep
                    }
                    return RawSleepSample(start: sample.startDate, end: sample.endDate, stage: stage)
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }
    }
#else
    func requestAccess() async -> PermissionState { .restricted }
    func startBackgroundDelivery() {}
    func stopBackgroundDelivery() {}
#endif
}

@MainActor
struct DefaultTimeSemanticLabelProvider: TimeSemanticLabelProviding {
    private let calendar = Calendar.current

    func labels(for date: Date, coordinate: GeoCoordinate?) -> [String] {
        var labels: [String] = []
        if calendar.isDateInWeekend(date) {
            labels.append("weekend")
        }
        if isPublicHoliday(date) {
            labels.append("public-holiday")
        }
        if let coordinate,
           let phase = dayPhaseLabel(for: date, coordinate: coordinate) {
            labels.append(phase)
        }
        return labels
    }

    private func isPublicHoliday(_ date: Date) -> Bool {
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let month = comps.month, let day = comps.day, let weekday = comps.weekday else { return false }

        if (month == 1 && day == 1) || (month == 7 && day == 4) || (month == 12 && day == 25) {
            return true
        }

        // US Thanksgiving: 4th Thursday of November.
        if month == 11 && weekday == 5 {
            let weekOfMonth = ((day - 1) / 7) + 1
            return weekOfMonth == 4
        }
        return false
    }

    private func dayPhaseLabel(for date: Date, coordinate: GeoCoordinate) -> String? {
        guard let sun = sunriseSunset(for: date, latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return nil
        }
        let sunriseWindow = DateInterval(start: sun.sunrise.addingTimeInterval(-45 * 60), end: sun.sunrise.addingTimeInterval(45 * 60))
        if sunriseWindow.contains(date) {
            return "sunrise"
        }

        let sunsetWindow = DateInterval(start: sun.sunset.addingTimeInterval(-45 * 60), end: sun.sunset.addingTimeInterval(45 * 60))
        if sunsetWindow.contains(date) {
            return "sunset"
        }
        return nil
    }

    // Basic solar estimation adapted from NOAA equations for local labels.
    private func sunriseSunset(for date: Date, latitude: Double, longitude: Double) -> (sunrise: Date, sunset: Date)? {
        let zenith = 90.833
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let lngHour = longitude / 15.0

        func approximateTime(isSunrise: Bool) -> Double {
            let base = isSunrise ? 6.0 : 18.0
            return Double(dayOfYear) + (base - lngHour) / 24.0
        }

        func trueLongitude(_ t: Double) -> Double {
            let m = (0.9856 * t) - 3.289
            var l = m + (1.916 * sin(m * .pi / 180)) + (0.020 * sin(2 * m * .pi / 180)) + 282.634
            while l < 0 { l += 360 }
            while l >= 360 { l -= 360 }
            return l
        }

        func rightAscension(_ l: Double) -> Double {
            var ra = atan(0.91764 * tan(l * .pi / 180)) * 180 / .pi
            while ra < 0 { ra += 360 }
            while ra >= 360 { ra -= 360 }
            let lQuadrant = floor(l / 90) * 90
            let raQuadrant = floor(ra / 90) * 90
            ra += lQuadrant - raQuadrant
            return ra / 15
        }

        func localHourAngle(_ l: Double, isSunrise: Bool) -> Double? {
            let sinDec = 0.39782 * sin(l * .pi / 180)
            let cosDec = cos(asin(sinDec))
            let cosH = (cos(zenith * .pi / 180) - (sinDec * sin(latitude * .pi / 180))) / (cosDec * cos(latitude * .pi / 180))
            if cosH > 1 || cosH < -1 {
                return nil
            }
            let h = isSunrise ? 360 - acos(cosH) * 180 / .pi : acos(cosH) * 180 / .pi
            return h / 15
        }

        func utcHours(isSunrise: Bool) -> Double? {
            let t = approximateTime(isSunrise: isSunrise)
            let l = trueLongitude(t)
            let ra = rightAscension(l)
            guard let h = localHourAngle(l, isSunrise: isSunrise) else { return nil }
            let localMean = h + ra - (0.06571 * t) - 6.622
            var utc = localMean - lngHour
            while utc < 0 { utc += 24 }
            while utc >= 24 { utc -= 24 }
            return utc
        }

        guard let sunriseUTC = utcHours(isSunrise: true), let sunsetUTC = utcHours(isSunrise: false) else {
            return nil
        }

        var dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dateComponents.timeZone = TimeZone(secondsFromGMT: 0)

        func buildDate(hourFraction: Double) -> Date? {
            let hour = Int(hourFraction)
            let minute = Int((hourFraction - Double(hour)) * 60)
            let second = Int((((hourFraction - Double(hour)) * 60) - Double(minute)) * 60)
            dateComponents.hour = hour
            dateComponents.minute = minute
            dateComponents.second = second
            guard let utcDate = Calendar(identifier: .gregorian).date(from: dateComponents) else { return nil }
            return utcDate
        }

        guard let sunrise = buildDate(hourFraction: sunriseUTC), let sunset = buildDate(hourFraction: sunsetUTC) else {
            return nil
        }
        return (sunrise, sunset)
    }
}
