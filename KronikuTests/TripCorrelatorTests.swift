import XCTest
@testable import Kroniku

@MainActor
final class TripCorrelatorTests: XCTestCase {
    private var repository: MockMemoryRepository!
    private var correlator: TripCorrelator!

    override func setUp() {
        super.setUp()
        repository = MockMemoryRepository()
        correlator = TripCorrelator(repository: repository, defaults: UserDefaults(suiteName: #file)!)
    }

    func testDrivingThenStationaryProducesTripEvent() {
        let start = Date()
        correlator.handle(KronikuEvent(timestamp: start, type: .locationSignificantChange, source: "test", metadata: [
            "placeName": "Home", "latitude": "6.5", "longitude": "3.3"
        ]))
        correlator.handle(KronikuEvent(timestamp: start, type: .motionChanged, source: "test", metadata: ["state": "driving"]))

        let end = start.addingTimeInterval(20 * 60)
        correlator.handle(KronikuEvent(timestamp: end, type: .locationSignificantChange, source: "test", metadata: [
            "placeName": "Office", "latitude": "6.6", "longitude": "3.4"
        ]))
        correlator.handle(KronikuEvent(timestamp: end, type: .motionChanged, source: "test", metadata: ["state": "stationary"]))

        let trips = repository.events.filter { $0.source == "trip" }
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.occurredAt, start)
        XCTAssertEqual(trips.first?.derivedEndedAt, end)
        XCTAssertEqual(trips.first?.detail, "Home → Office")
    }

    func testWorkoutEndedProducesWorkoutEventWithoutOpenState() {
        let started = Date().addingTimeInterval(-30 * 60)
        let ended = Date()
        correlator.handle(KronikuEvent(timestamp: ended, type: .workoutEnded, source: "test", metadata: [
            "startedAt": ISO8601DateFormatter().string(from: started),
            "activityType": "Outdoor Run",
            "durationMinutes": "30"
        ]))

        let workouts = repository.events.filter { $0.source == "workout" }
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.title, "Outdoor Run")
        XCTAssertEqual(workouts.first?.detail, "30 min")
        XCTAssertEqual(workouts.first?.derivedEndedAt, ended)
    }

    func testWalkingThenStationaryProducesWalkTripEvent() {
        let start = Date()
        correlator.handle(KronikuEvent(timestamp: start, type: .motionChanged, source: "test", metadata: ["state": "walking"]))

        let end = start.addingTimeInterval(15 * 60)
        correlator.handle(KronikuEvent(timestamp: end, type: .motionChanged, source: "test", metadata: ["state": "stationary"]))

        let trips = repository.events.filter { $0.source == "trip" }
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.title, "Walk")
        XCTAssertEqual(trips.first?.occurredAt, start)
        XCTAssertEqual(trips.first?.derivedEndedAt, end)
    }

    func testJoggingMidWalkDoesNotSplitIntoTwoTrips() {
        let start = Date()
        correlator.handle(KronikuEvent(timestamp: start, type: .motionChanged, source: "test", metadata: ["state": "walking"]))
        correlator.handle(KronikuEvent(timestamp: start.addingTimeInterval(5 * 60), type: .motionChanged, source: "test", metadata: ["state": "running"]))

        let end = start.addingTimeInterval(15 * 60)
        correlator.handle(KronikuEvent(timestamp: end, type: .motionChanged, source: "test", metadata: ["state": "stationary"]))

        let trips = repository.events.filter { $0.source == "trip" }
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.occurredAt, start)
        XCTAssertEqual(trips.first?.derivedEndedAt, end)
    }

    func testStationaryWithoutPriorTransitionProducesNoTrip() {
        correlator.handle(KronikuEvent(type: .motionChanged, source: "test", metadata: ["state": "stationary"]))

        XCTAssertTrue(repository.events.isEmpty)
    }
}
