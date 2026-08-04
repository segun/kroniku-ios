import Foundation
import SwiftUI
import EventKit
import CoreLocation
import CoreMotion
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

    let consentStore: Tier1ConsentStore
    private let calendarProvider: CalendarContextProviding
    private let locationProvider: LocationContextProviding
    private let weatherProvider: WeatherContextProviding
    private let motionProvider: MotionContextProviding
    private let timeLabelProvider: TimeSemanticLabelProviding
    private var cachedCalendarEventsByDay: [Date: CachedCalendarDay] = [:]

    init(
        consentStore: Tier1ConsentStore = Tier1ConsentStore(),
        calendarProvider: CalendarContextProviding = EventKitCalendarProvider(),
        locationProvider: LocationContextProviding = CoreLocationVisitProvider(),
        weatherProvider: WeatherContextProviding = WeatherKitSnapshotProvider(),
        motionProvider: MotionContextProviding = CoreMotionStateProvider(),
        timeLabelProvider: TimeSemanticLabelProviding = DefaultTimeSemanticLabelProvider()
    ) {
        self.consentStore = consentStore
        self.calendarProvider = calendarProvider
        self.locationProvider = locationProvider
        self.weatherProvider = weatherProvider
        self.motionProvider = motionProvider
        self.timeLabelProvider = timeLabelProvider
        // Defer permission introspection until a privacy UI/action path requests it.
        self.calendarPermission = .notDetermined
        self.locationPermission = .notDetermined
        self.motionPermission = .notDetermined
    }

    var consent: Tier1ConsentState { consentStore.consent }

    func markOnboardingComplete() {
        consentStore.update { $0.hasCompletedOnboarding = true }
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

    func setTimeSemanticsEnabled(_ enabled: Bool) {
        consentStore.update { $0.timeSemanticsEnabled = enabled }
    }

    func refreshPermissions() {
        calendarPermission = calendarProvider.authorizationState
        locationPermission = locationProvider.authorizationState
        motionPermission = motionProvider.authorizationState
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
    }

    func requestMotionPermission() async {
        motionPermission = await motionProvider.requestAccess()
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
        var visit: VisitSnapshot?
        var weather: WeatherReading?
        var motionState: MotionState?

        if consent.locationCaptureEnabled && locationPermission == .authorized {
            visit = await locationProvider.captureVisit(around: occurredAt)
        }

        if consent.weatherSnapshotsEnabled, let coordinate = visit?.coordinate {
            weather = await weatherProvider.weather(at: occurredAt, coordinate: coordinate)
        }

        if consent.motionAttachmentEnabled && motionPermission == .authorized {
            motionState = await motionProvider.motionState(at: occurredAt)
        }

        let labels = consent.timeSemanticsEnabled
            ? timeLabelProvider.labels(for: occurredAt, coordinate: visit?.coordinate)
            : []

        return ContextEnrichment(visit: visit, weather: weather, motionState: motionState, timeSemanticLabels: labels)
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
            return nil
        }
#else
        _ = date
        _ = coordinate
        return nil
#endif
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
