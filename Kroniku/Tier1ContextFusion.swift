import Foundation
import SwiftUI
import EventKit
import CoreLocation
import CoreMotion
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
}

@MainActor
protocol HealthContextProviding {
    var authorizationState: PermissionState { get }
    func requestAccess(for metrics: Set<Tier1HealthMetric>) async -> PermissionState
    func summary(for date: Date, metrics: Set<Tier1HealthMetric>) async -> HealthSummary?
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

    let consentStore: Tier1ConsentStore
    private let calendarProvider: CalendarContextProviding
    private let locationProvider: LocationContextProviding
    private let weatherProvider: WeatherContextProviding
    private let motionProvider: MotionContextProviding
    private let healthProvider: HealthContextProviding
    private let timeLabelProvider: TimeSemanticLabelProviding
    private var cachedCalendarEventsByDay: [Date: CachedCalendarDay] = [:]
    private var recentVisitSnapshot: VisitSnapshot?
    private var recentWeatherSnapshot: (coordinate: GeoCoordinate, reading: WeatherReading)?

    init(
        consentStore: Tier1ConsentStore = Tier1ConsentStore(),
        calendarProvider: CalendarContextProviding = EventKitCalendarProvider(),
        locationProvider: LocationContextProviding = CoreLocationVisitProvider(),
        weatherProvider: WeatherContextProviding = WeatherKitSnapshotProvider(),
        motionProvider: MotionContextProviding = CoreMotionStateProvider(),
        healthProvider: HealthContextProviding = HealthKitSummaryProvider(),
        timeLabelProvider: TimeSemanticLabelProviding = DefaultTimeSemanticLabelProvider()
    ) {
        self.consentStore = consentStore
        self.calendarProvider = calendarProvider
        self.locationProvider = locationProvider
        self.weatherProvider = weatherProvider
        self.motionProvider = motionProvider
        self.healthProvider = healthProvider
        self.timeLabelProvider = timeLabelProvider
        // Defer permission introspection until a privacy UI/action path requests it.
        self.calendarPermission = .notDetermined
        self.locationPermission = .notDetermined
        self.motionPermission = .notDetermined
        self.healthPermission = .notDetermined
    }

    var consent: Tier1ConsentState { consentStore.consent }

    func markOnboardingComplete() {
        consentStore.update {
            $0.hasCompletedOnboarding = true
            $0.needsOnboardingResume = false
        }
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

    func setPhotoAttachmentEnabled(_ enabled: Bool) {
        consentStore.update { $0.photoAttachmentEnabled = enabled }
    }

    func setTimeSemanticsEnabled(_ enabled: Bool) {
        consentStore.update { $0.timeSemanticsEnabled = enabled }
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

    func syncCalendarEvents(into repo: MemoryRepositoryProtocol, for day: Date = Date()) async {
        guard consent.calendarImportEnabled else { return }
        guard calendarPermission == .authorized else { return }

        let calendar = Calendar.current
        let startOfSelectedDay = calendar.startOfDay(for: day)
        let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfSelectedDay) ?? startOfSelectedDay.addingTimeInterval(24 * 60 * 60)
        let interval = DateInterval(start: startOfSelectedDay, end: startOfNextDay)
        do {
            var imported = try await rawCalendarEvents(in: interval, for: startOfSelectedDay)
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
            try repo.syncCalendarEvents(imported, for: startOfSelectedDay)
        } catch {
            print("Calendar sync failed: \(error)")
        }
    }

    private func rawCalendarEvents(in interval: DateInterval, for dayKey: Date) async throws -> [TimelineCalendarImportEvent] {
        if let cached = cachedCalendarEventsByDay[dayKey], shouldReuseCalendarCache(cached, for: dayKey) {
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
        await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(locationName) { placemarks, _ in
                guard let coordinate = placemarks?.first?.location?.coordinate else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
        }
    }

    func buildEnrichment(for occurredAt: Date) async -> ContextEnrichment {
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
        if consent.healthConsent.isEnabled && healthPermission == .authorized {
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
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<VisitSnapshot?, Never>?

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

    func requestAccess() async -> PermissionState {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            _ = await waitForAuthorizationChange(timeoutSeconds: 8)
        }
        return authorizationState
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
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }

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
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location fetch failed: \(error)")
        continuation?.resume(returning: nil)
        continuation = nil
    }

    private func waitForAuthorizationChange(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if manager.authorizationStatus != .notDetermined {
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

        var current: Current?
    }

    private func openMeteoFallback(at date: Date, coordinate: GeoCoordinate) async -> WeatherReading? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: "\(coordinate.latitude)"),
            URLQueryItem(name: "longitude", value: "\(coordinate.longitude)"),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
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
    private let manager = CMMotionActivityManager()

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
        guard authorizationState == .authorized else { return nil }
        var entries: [HealthSummary.Entry] = []
        let dayInterval = Calendar.current.dateInterval(of: .day, for: date) ?? DateInterval(start: date, end: date.addingTimeInterval(24 * 60 * 60))

        if metrics.contains(.steps), let total = try? await cumulativeSum(for: .stepCount, unit: .count(), in: dayInterval) {
            entries.append(.init(metric: .steps, value: "\(Int(total.rounded())) steps"))
        }

        if metrics.contains(.heartRate), let avg = try? await discreteAverage(for: .heartRate, unit: HKUnit.count().unitDivided(by: .minute()), in: dayInterval) {
            entries.append(.init(metric: .heartRate, value: "\(Int(avg.rounded())) bpm avg"))
        }

        if metrics.contains(.mindfulMinutes), let total = try? await mindfulMinutes(in: dayInterval) {
            entries.append(.init(metric: .mindfulMinutes, value: "\(Int(total.rounded())) mindful min"))
        }

        if metrics.contains(.sleep), let hours = try? await sleepHours(in: dayInterval) {
            entries.append(.init(metric: .sleep, value: String(format: "%.1f hr sleep", hours)))
        }

        guard !entries.isEmpty else { return nil }
        return HealthSummary(capturedAt: date, entries: entries)
#else
        _ = date
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
        case .sleep:
            return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .mindfulMinutes:
            return HKObjectType.categoryType(forIdentifier: .mindfulSession)
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

    private func sleepHours(in interval: DateInterval) async throws -> Double {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let totalSeconds = (samples as? [HKCategorySample] ?? [])
                    .filter { $0.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue || $0.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue || $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue || $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue }
                    .reduce(0.0) { partial, sample in
                        partial + sample.endDate.timeIntervalSince(sample.startDate)
                    }
                continuation.resume(returning: totalSeconds / 3600)
            }
            store.execute(query)
        }
    }

    private func mindfulMinutes(in interval: DateInterval) async throws -> Double {
        guard let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let totalSeconds = (samples as? [HKCategorySample] ?? [])
                    .reduce(0.0) { partial, sample in
                        partial + sample.endDate.timeIntervalSince(sample.startDate)
                    }
                continuation.resume(returning: totalSeconds / 60)
            }
            store.execute(query)
        }
    }

    private func probeReadAuthorization(for sampleTypes: Set<HKSampleType>) async -> PermissionState {
        guard let sampleType = sampleTypes.first else { return .notDetermined }

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
