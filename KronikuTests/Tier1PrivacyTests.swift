import XCTest
@testable import Kroniku

final class Tier1PrivacyTests: XCTestCase {
    @MainActor
    func testCalendarImportSkipsWhenPermissionDenied() async {
        let calendarProvider = FakeCalendarProvider(
            permission: .denied,
            events: [
                TimelineCalendarImportEvent(
                    externalID: "evt-1",
                    title: "Board meeting",
                    startsAt: Date(),
                    endsAt: Date().addingTimeInterval(1800),
                    locationName: "HQ",
                    attendeeNames: ["Alice", "Bob"],
                    timeSemanticLabels: []
                )
            ]
        )

        let store = makeStore()
        store.update {
            $0.calendarImportEnabled = true
            $0.calendarAttendeesAndLocationsEnabled = true
        }

        let controller = Tier1ContextController(
            consentStore: store,
            calendarProvider: calendarProvider,
            locationProvider: FakeLocationProvider(permission: .denied, visit: nil),
            weatherProvider: FakeWeatherProvider(),
            motionProvider: FakeMotionProvider(permission: .denied, state: nil),
            timeLabelProvider: FakeLabelProvider(labels: [])
        )

        let repo = MockMemoryRepository()
        await controller.syncCalendarEvents(into: repo)

        XCTAssertTrue(repo.fetchAll().isEmpty)
    }

    @MainActor
    func testCalendarPartialConsentStripsAttendeesAndLocation() async {
        let calendarProvider = FakeCalendarProvider(
            permission: .authorized,
            events: [
                TimelineCalendarImportEvent(
                    externalID: "evt-2",
                    title: "Partner lunch",
                    startsAt: Date(),
                    endsAt: Date().addingTimeInterval(3600),
                    locationName: "Noma",
                    attendeeNames: ["Partner A"],
                    timeSemanticLabels: ["weekend"]
                )
            ]
        )

        let store = makeStore()
        store.update {
            $0.calendarImportEnabled = true
            $0.calendarAttendeesAndLocationsEnabled = false
        }

        let controller = Tier1ContextController(
            consentStore: store,
            calendarProvider: calendarProvider,
            locationProvider: FakeLocationProvider(permission: .denied, visit: nil),
            weatherProvider: FakeWeatherProvider(),
            motionProvider: FakeMotionProvider(permission: .denied, state: nil),
            timeLabelProvider: FakeLabelProvider(labels: [])
        )

        let repo = MockMemoryRepository()
        await controller.syncCalendarEvents(into: repo)

        let event = try XCTUnwrap(repo.fetchAll().first)
        XCTAssertEqual(event.source, "calendar")
        XCTAssertEqual(event.detail, nil)
        XCTAssertTrue(event.isReadOnlySource)
        XCTAssertFalse(event.contextCard?.metadata.contains(where: { $0.key == "attendees" }) ?? true)
        XCTAssertFalse(event.contextCard?.metadata.contains(where: { $0.key == "location" }) ?? true)
    }

    @MainActor
    func testRevokedLocationAndMotionYieldPartialContextOnly() async {
        let store = makeStore()
        store.update {
            $0.locationCaptureEnabled = true
            $0.weatherSnapshotsEnabled = true
            $0.motionAttachmentEnabled = true
            $0.timeSemanticsEnabled = true
        }

        let weatherProvider = FakeWeatherProvider()
        let controller = Tier1ContextController(
            consentStore: store,
            calendarProvider: FakeCalendarProvider(permission: .denied, events: []),
            locationProvider: FakeLocationProvider(permission: .denied, visit: nil),
            weatherProvider: weatherProvider,
            motionProvider: FakeMotionProvider(permission: .denied, state: .walking),
            timeLabelProvider: FakeLabelProvider(labels: ["weekend"])
        )

        let enrichment = await controller.buildEnrichment(for: Date())

        XCTAssertNil(enrichment.visit)
        XCTAssertNil(enrichment.weather)
        XCTAssertNil(enrichment.motionState)
        XCTAssertEqual(enrichment.timeSemanticLabels, ["weekend"])
        XCTAssertFalse(weatherProvider.called)
    }

    @MainActor
    func testCalendarCachingReusesFetchedDay() async {
        let targetDay = Date(timeIntervalSince1970: 1_754_281_600)
        let calendarProvider = FakeCalendarProvider(
            permission: .authorized,
            events: [
                TimelineCalendarImportEvent(
                    externalID: "evt-cache",
                    title: "Cached day",
                    startsAt: targetDay.addingTimeInterval(9 * 60 * 60),
                    endsAt: targetDay.addingTimeInterval(10 * 60 * 60),
                    locationName: nil,
                    attendeeNames: [],
                    timeSemanticLabels: []
                )
            ]
        )

        let store = makeStore()
        store.update { $0.calendarImportEnabled = true }

        let controller = Tier1ContextController(
            consentStore: store,
            calendarProvider: calendarProvider,
            locationProvider: FakeLocationProvider(permission: .denied, visit: nil),
            weatherProvider: FakeWeatherProvider(),
            motionProvider: FakeMotionProvider(permission: .denied, state: nil),
            timeLabelProvider: FakeLabelProvider(labels: [])
        )

        let repo = MockMemoryRepository()
        await controller.syncCalendarEvents(into: repo, for: targetDay)
        await controller.syncCalendarEvents(into: repo, for: targetDay)

        XCTAssertEqual(calendarProvider.fetchCallCount, 1)
        XCTAssertEqual(repo.fetchAll().count, 1)
    }

    @MainActor
    func testCalendarCachingKeepsPreviouslyVisitedDays() async {
        let dayOne = Date(timeIntervalSince1970: 1_754_281_600)
        let dayTwo = dayOne.addingTimeInterval(24 * 60 * 60)
        let calendarProvider = FakeCalendarProvider(permission: .authorized, events: [])
        calendarProvider.fetchHandler = { interval in
            if Calendar.current.isDate(interval.start, inSameDayAs: dayOne) {
                return [
                    TimelineCalendarImportEvent(
                        externalID: "evt-day-1",
                        title: "Day one",
                        startsAt: dayOne.addingTimeInterval(8 * 60 * 60),
                        endsAt: dayOne.addingTimeInterval(9 * 60 * 60),
                        locationName: nil,
                        attendeeNames: [],
                        timeSemanticLabels: []
                    )
                ]
            }

            return [
                TimelineCalendarImportEvent(
                    externalID: "evt-day-2",
                    title: "Day two",
                    startsAt: dayTwo.addingTimeInterval(8 * 60 * 60),
                    endsAt: dayTwo.addingTimeInterval(9 * 60 * 60),
                    locationName: nil,
                    attendeeNames: [],
                    timeSemanticLabels: []
                )
            ]
        }

        let store = makeStore()
        store.update { $0.calendarImportEnabled = true }

        let controller = Tier1ContextController(
            consentStore: store,
            calendarProvider: calendarProvider,
            locationProvider: FakeLocationProvider(permission: .denied, visit: nil),
            weatherProvider: FakeWeatherProvider(),
            motionProvider: FakeMotionProvider(permission: .denied, state: nil),
            timeLabelProvider: FakeLabelProvider(labels: [])
        )

        let repo = MockMemoryRepository()
        await controller.syncCalendarEvents(into: repo, for: dayOne)
        await controller.syncCalendarEvents(into: repo, for: dayTwo)

        let titles = repo.fetchAll().compactMap(\ .title)
        XCTAssertTrue(titles.contains("Day one"))
        XCTAssertTrue(titles.contains("Day two"))
        XCTAssertEqual(calendarProvider.fetchCallCount, 2)
    }

    @MainActor
    private func makeStore() -> Tier1ConsentStore {
        let suite = "Tier1PrivacyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Tier1ConsentStore(storage: defaults)
    }
}

private final class FakeCalendarProvider: CalendarContextProviding {
    var permission: PermissionState
    var events: [TimelineCalendarImportEvent]
    var fetchCallCount = 0
    var fetchHandler: ((DateInterval) -> [TimelineCalendarImportEvent])?

    init(permission: PermissionState, events: [TimelineCalendarImportEvent]) {
        self.permission = permission
        self.events = events
    }

    var authorizationState: PermissionState { permission }

    func requestAccess() async -> PermissionState {
        permission
    }

    func fetchEvents(in interval: DateInterval) async throws -> [TimelineCalendarImportEvent] {
        fetchCallCount += 1
        if let fetchHandler {
            return fetchHandler(interval)
        }
        return events
    }
}

private final class FakeLocationProvider: LocationContextProviding {
    var permission: PermissionState
    var visit: VisitSnapshot?

    init(permission: PermissionState, visit: VisitSnapshot?) {
        self.permission = permission
        self.visit = visit
    }

    var authorizationState: PermissionState { permission }

    func requestAccess() async -> PermissionState {
        permission
    }

    func captureVisit(around date: Date) async -> VisitSnapshot? {
        _ = date
        return visit
    }
}

private final class FakeWeatherProvider: WeatherContextProviding {
    var called = false

    func weather(at date: Date, coordinate: GeoCoordinate) async -> WeatherReading? {
        called = true
        return WeatherReading(observedAt: date, condition: "clear", temperatureC: 24)
    }
}

private final class FakeMotionProvider: MotionContextProviding {
    var permission: PermissionState
    var state: MotionState?

    init(permission: PermissionState, state: MotionState?) {
        self.permission = permission
        self.state = state
    }

    var authorizationState: PermissionState { permission }

    func requestAccess() async -> PermissionState {
        permission
    }

    func motionState(at date: Date) async -> MotionState? {
        _ = date
        return state
    }
}

private struct FakeLabelProvider: TimeSemanticLabelProviding {
    var labels: [String]

    func labels(for date: Date, coordinate: GeoCoordinate?) -> [String] {
        _ = date
        _ = coordinate
        return labels
    }
}
