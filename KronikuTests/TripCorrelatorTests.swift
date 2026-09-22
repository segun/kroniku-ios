import XCTest
@testable import Kroniku

@MainActor
final class TripCorrelatorTests: XCTestCase {
    private var repository: MockMemoryRepository!
    private var correlator: TripCorrelator!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        repository = MockMemoryRepository()
        defaults = UserDefaults(suiteName: #file)!
        defaults.removePersistentDomain(forName: #file)
        correlator = TripCorrelator(repository: repository, defaults: defaults)
    }

    func testMotionTransitionsProduceConsecutiveNonOverlappingIntervals() {
        let start = Date().addingTimeInterval(-60 * 60)
        sendLocation("Road A2", at: start, latitude: 6.45, longitude: 3.52)
        sendMotion(.driving, at: start)
        sendMotion(.walking, at: start.addingTimeInterval(3 * 60))
        sendMotion(.driving, at: start.addingTimeInterval(9 * 60))
        sendLocation("Road A4", at: start.addingTimeInterval(35 * 60), latitude: 6.46, longitude: 3.53)
        sendMotion(.stationary, at: start.addingTimeInterval(40 * 60))

        let events = derivedEvents
        XCTAssertEqual(events.count, 3)
        assertNoOverlaps(events)
        XCTAssertEqual(events.map(\.title), ["Drive", "Walk", "Drive"])
    }

    func testWalkShorterThanFiveMinutesIsDiscarded() {
        let start = Date().addingTimeInterval(-10 * 60)
        sendMotion(.walking, at: start)
        sendMotion(.stationary, at: start.addingTimeInterval(4 * 60 + 59))

        XCTAssertFalse(derivedEvents.contains { $0.title == "Walk" })
    }

    func testFiveMinuteWalkIsRetained() {
        let start = Date().addingTimeInterval(-10 * 60)
        sendMotion(.walking, at: start)
        sendMotion(.stationary, at: start.addingTimeInterval(5 * 60))

        let walk = derivedEvents.first { $0.title == "Walk" }
        XCTAssertEqual(walk?.detail, "5 min")
    }

    func testWorkoutClipsConflictingDriveAndRemovesMotionInsideWorkout() {
        let start = Date().addingTimeInterval(-2 * 60 * 60)
        sendLocation("Road A2", at: start, latitude: 6.45, longitude: 3.52)
        sendMotion(.driving, at: start)
        sendLocation("Road A4", at: start.addingTimeInterval(25 * 60), latitude: 6.46, longitude: 3.53)
        sendMotion(.stationary, at: start.addingTimeInterval(41 * 60))

        let workoutStart = start.addingTimeInterval(32 * 60)
        let workoutEnd = workoutStart.addingTimeInterval(69 * 60)
        sendWorkout(title: "Outdoor Walk", start: workoutStart, end: workoutEnd)

        let drive = derivedEvents.first { $0.title == "Drive" }
        let workout = derivedEvents.first { $0.title == "Outdoor Walk" }
        XCTAssertEqual(drive?.derivedEndedAt, workoutStart)
        XCTAssertEqual(workout?.occurredAt, workoutStart)
        XCTAssertEqual(workout?.derivedEndedAt, workoutEnd)
        assertNoOverlaps(derivedEvents)
    }

    func testDriveWithoutFreshLocationIsDiscarded() {
        let start = Date().addingTimeInterval(-60 * 60)
        sendLocation("Stale Place", at: start.addingTimeInterval(-30 * 60), latitude: 6.45, longitude: 3.52)
        sendMotion(.driving, at: start)
        sendMotion(.stationary, at: start.addingTimeInterval(20 * 60))

        XCTAssertFalse(derivedEvents.contains { $0.title == "Drive" })
    }

    func testWalkUsesLocationsObservedAtItsBoundaries() {
        let start = Date().addingTimeInterval(-30 * 60)
        sendLocation("Road A2", at: start, latitude: 6.45, longitude: 3.52)
        sendMotion(.walking, at: start)
        sendLocation("Road A4", at: start.addingTimeInterval(19 * 60), latitude: 6.46, longitude: 3.53)
        sendMotion(.stationary, at: start.addingTimeInterval(20 * 60))

        let walk = derivedEvents.first { $0.title == "Walk" }
        XCTAssertEqual(walk?.detail, "Road A2 → Road A4 · 20 min")
        XCTAssertEqual(walk?.place?.name, "Road A2")
    }

    func testLocationInsideWorkoutEnrichesWorkoutWithoutCreatingRouteClaim() {
        let start = Date().addingTimeInterval(-70 * 60)
        sendLocation("Road A4", at: start.addingTimeInterval(50 * 60), latitude: 6.45, longitude: 3.52)
        sendWorkout(title: "Outdoor Walk", start: start, end: start.addingTimeInterval(69 * 60))

        let workout = derivedEvents.first
        XCTAssertEqual(workout?.title, "Outdoor Walk")
        XCTAssertEqual(workout?.place?.name, "Road A4")
        XCTAssertEqual(workout?.detail, "69 min")
    }

    func testDuplicateWorkoutObservationProducesOneEvent() {
        let start = Date().addingTimeInterval(-30 * 60)
        let end = Date()
        sendWorkout(title: "Outdoor Run", start: start, end: end)
        sendWorkout(title: "Outdoor Run", start: start, end: end)

        XCTAssertEqual(derivedEvents.filter { $0.source == "workout" }.count, 1)
    }

    func testWorkoutWithOnlyEndTimeIsDiscarded() {
        correlator.handle(KronikuEvent(
            timestamp: Date(),
            type: .workoutEnded,
            source: "test",
            metadata: ["activityType": "Outdoor Walk"]
        ))

        XCTAssertTrue(derivedEvents.isEmpty)
    }

    func testObservationsSurviveCorrelatorRestart() {
        let start = Date().addingTimeInterval(-20 * 60)
        sendMotion(.walking, at: start)

        correlator = TripCorrelator(repository: repository, defaults: defaults)
        sendMotion(.stationary, at: Date())

        XCTAssertEqual(derivedEvents.filter { $0.title == "Walk" }.count, 1)
    }

    func testNoArrivalEventsAreInferred() {
        let start = Date().addingTimeInterval(-20 * 60)
        sendLocation("Office", at: start, latitude: 6.45, longitude: 3.52)
        sendMotion(.driving, at: start)
        sendMotion(.stationary, at: Date())

        XCTAssertFalse(derivedEvents.contains { $0.title?.hasPrefix("Arrived at ") == true })
    }

    private var derivedEvents: [MemoryEvent] {
        repository.events
            .filter { $0.source == "trip" || $0.source == "workout" }
            .sorted { ($0.occurredAt ?? .distantPast) < ($1.occurredAt ?? .distantPast) }
    }

    private func sendMotion(_ state: MotionState, at date: Date) {
        correlator.handle(KronikuEvent(
            timestamp: date,
            type: .motionChanged,
            source: "test",
            metadata: ["state": state.rawValue]
        ))
    }

    private func sendLocation(_ name: String, at date: Date, latitude: Double, longitude: Double) {
        correlator.handle(KronikuEvent(
            timestamp: date,
            type: .locationSignificantChange,
            source: "test",
            metadata: [
                "placeName": name,
                "latitude": "\(latitude)",
                "longitude": "\(longitude)"
            ]
        ))
    }

    private func sendWorkout(title: String, start: Date, end: Date) {
        correlator.handle(KronikuEvent(
            timestamp: end,
            type: .workoutEnded,
            source: "test",
            metadata: [
                "startedAt": ISO8601DateFormatter().string(from: start),
                "endedAt": ISO8601DateFormatter().string(from: end),
                "durationMinutes": "\(Int((end.timeIntervalSince(start) / 60).rounded()))",
                "activityType": title
            ]
        ))
    }

    private func assertNoOverlaps(_ events: [MemoryEvent], file: StaticString = #filePath, line: UInt = #line) {
        for pair in zip(events, events.dropFirst()) {
            guard let firstEnd = pair.0.derivedEndedAt, let secondStart = pair.1.occurredAt else {
                XCTFail("Expected ranged events", file: file, line: line)
                return
            }
            XCTAssertLessThanOrEqual(firstEnd, secondStart, file: file, line: line)
        }
    }
}