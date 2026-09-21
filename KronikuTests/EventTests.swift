import XCTest
@testable import Kroniku

final class EventTests: XCTestCase {
    func testAddingContactMomentCreatesTypedEventWithContextCard() throws {
        let repo = MockMemoryRepository()
        let occurredAt = Date()

        try repo.addContactMoment(personName: "Alice", interactionType: "call", occurredAt: occurredAt, note: "Called Alice")

        let events = repo.fetchAll()
        XCTAssertEqual(events.count, 1)

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.source, "contactMoment")
        XCTAssertEqual(event.title, "Called Alice")
        XCTAssertEqual(event.detail, "Alice")
        XCTAssertEqual(event.context, "Call")
        XCTAssertEqual(event.symbolName, "phone.fill")

        let contextCard = try XCTUnwrap(event.contextCard)
        XCTAssertEqual(contextCard.source, "contactMoment")
        XCTAssertEqual(contextCard.category, "moment")
        XCTAssertEqual(contextCard.summary, "Called Alice")
        XCTAssertTrue(contextCard.metadata.contains(where: { $0.key == "interactionType" && $0.value == "call" }))
        XCTAssertTrue(contextCard.metadata.contains(where: { $0.key == "captureMethod" && $0.value == "typed" }))
    }

    func testAddingContactMomentCreatesEventAndOrdering() throws {
        let repo = MockMemoryRepository()

        let now = Date()
        let earlier = now.addingTimeInterval(-3600)
        let later = now.addingTimeInterval(3600)

        try repo.addContactMoment(personName: "Alice", interactionType: "call", occurredAt: now, note: "Called Alice")
        try repo.addContactMoment(personName: "Bob", interactionType: "text", occurredAt: earlier, note: "Texted Bob")
        try repo.addContactMoment(personName: "Carol", interactionType: "meeting", occurredAt: later, note: "Met Carol")

        let events = repo.fetchAll()
        XCTAssertEqual(events.count, 3)

        // Expect newest first
        XCTAssertEqual(events[0].detail, "Carol")
        XCTAssertEqual(events[1].detail, "Alice")
        XCTAssertEqual(events[2].detail, "Bob")
    }

    func testAddingContactMomentRejectsEmptyPayload() throws {
        let repo = MockMemoryRepository()

        XCTAssertThrowsError(try repo.addContactMoment(personName: "  ", interactionType: "call", occurredAt: Date(), note: "   ")) { error in
            XCTAssertEqual(error as? MemoryRepositoryError, .emptyContactMoment)
        }
    }
}
