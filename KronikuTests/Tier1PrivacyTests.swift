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
            healthProvider: FakeHealthProvider(permission: .denied, summary: nil),
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
            healthProvider: FakeHealthProvider(permission: .denied, summary: nil),
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
            $0.healthConsent.enabledMetrics = [.steps]
            $0.timeSemanticsEnabled = true
        }

        let weatherProvider = FakeWeatherProvider()
        let controller = Tier1ContextController(
            consentStore: store,
            calendarProvider: FakeCalendarProvider(permission: .denied, events: []),
            locationProvider: FakeLocationProvider(permission: .denied, visit: nil),
            weatherProvider: weatherProvider,
            motionProvider: FakeMotionProvider(permission: .denied, state: .walking),
            healthProvider: FakeHealthProvider(permission: .denied, summary: HealthSummary(capturedAt: Date(), entries: [.init(metric: .steps, value: "3000 steps")])),
            timeLabelProvider: FakeLabelProvider(labels: ["weekend"])
        )

        let enrichment = await controller.buildEnrichment(for: Date())

        XCTAssertNil(enrichment.visit)
        XCTAssertNil(enrichment.weather)
        XCTAssertNil(enrichment.motionState)
        XCTAssertNil(enrichment.healthSummary)
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
            healthProvider: FakeHealthProvider(permission: .denied, summary: nil),
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
            healthProvider: FakeHealthProvider(permission: .denied, summary: nil),
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
    func testRetentionPolicyScrubsDisabledSources() async throws {
        let repo = MockMemoryRepository()
        let healthSummary = HealthSummary(capturedAt: Date(), entries: [.init(metric: .steps, value: "4200 steps")])
        let photo = PhotoAttachment(filename: "test.jpg", imageData: Data([0x00, 0x01]))

        try repo.addContactMoment(
            personName: "Alice",
            interactionType: "call",
            occurredAt: Date(),
            note: "Follow-up",
            contextEnrichment: ContextEnrichment(
                visit: VisitSnapshot(name: "HQ", coordinate: GeoCoordinate(latitude: 1, longitude: 2), capturedAt: Date()),
                weather: WeatherReading(observedAt: Date(), condition: "clear", temperatureC: 20),
                motionState: .walking,
                healthSummary: healthSummary,
                timeSemanticLabels: ["weekend"]
            ),
            photoAttachments: [photo]
        )

        let consent = Tier1ConsentState(
            calendarImportEnabled: false,
            calendarAttendeesAndLocationsEnabled: false,
            locationCaptureEnabled: false,
            weatherSnapshotsEnabled: false,
            motionAttachmentEnabled: false,
            healthConsent: Tier1HealthConsent(enabledMetrics: []),
            photoAttachmentEnabled: false,
            timeSemanticsEnabled: false,
            hasCompletedOnboarding: false,
            needsOnboardingResume: false,
            onboardingPage: 0
        )

        try repo.applyRetentionPolicy(for: consent)

        let event = try XCTUnwrap(repo.fetchAll().first)
        XCTAssertNil(event.place)
        XCTAssertNil(event.weatherSnapshot)
        XCTAssertNil(event.healthSummary)
        XCTAssertTrue(event.photoAttachments.isEmpty)
        XCTAssertFalse(event.contextCard?.metadata.contains(where: { $0.key == "motion" }) ?? true)
        XCTAssertFalse(event.contextCard?.metadata.contains(where: { $0.key == "timeSemantics" }) ?? true)
    }

    @MainActor
    func testHealthPermissionRequestPersistsAuthorizedState() async {
        let store = makeStore()
        store.update { $0.healthConsent.enabledMetrics = [.steps, .heartRate] }

        let controller = Tier1ContextController(
            consentStore: store,
            calendarProvider: FakeCalendarProvider(permission: .denied, events: []),
            locationProvider: FakeLocationProvider(permission: .denied, visit: nil),
            weatherProvider: FakeWeatherProvider(),
            motionProvider: FakeMotionProvider(permission: .denied, state: nil),
            healthProvider: FakeHealthProvider(permission: .authorized, summary: nil),
            timeLabelProvider: FakeLabelProvider(labels: [])
        )

        await controller.requestHealthPermission()

        XCTAssertEqual(controller.healthPermission, .authorized)
        XCTAssertEqual(store.consent.healthAuthorizationState, .authorized)
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

private final class FakeHealthProvider: HealthContextProviding {
    var permission: PermissionState
    var summaryValue: HealthSummary?

    init(permission: PermissionState, summary: HealthSummary?) {
        self.permission = permission
        self.summaryValue = summary
    }

    var authorizationState: PermissionState { permission }

    func requestAccess(for metrics: Set<Tier1HealthMetric>) async -> PermissionState {
        _ = metrics
        return permission
    }

    func summary(for date: Date, metrics: Set<Tier1HealthMetric>) async -> HealthSummary? {
        _ = date
        _ = metrics
        return summaryValue
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
