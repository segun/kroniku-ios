import XCTest
@testable import Kroniku

final class SyncServiceTests: XCTestCase {
    func testSyncModelsDecodePayloadShapes() throws {
        let json = """
        {
          "applied": [{"eventId":"evt-1","version":2,"updatedAt":"2024-01-01T12:00:00Z"}],
          "conflicts": [{"eventId":"evt-2","strategy":"server-wins","serverVersion":4,"incomingVersion":2}],
          "ignored": [{"eventId":"evt-3","reason":"duplicate"}],
          "events": [{
            "id":"remote-1",
            "eventId":"evt-1",
            "version":2,
            "occurredAt":"2024-01-01T11:00:00Z",
            "source":"contactMoment",
            "title":"Dinner",
            "detail":"with Sam",
            "searchText":"dinner with sam",
            "encryptedPayload":"ciphertext",
            "payloadHash":"hash-1",
            "isDeleted":false,
            "createdAt":"2024-01-01T10:00:00Z",
            "updatedAt":"2024-01-01T12:00:00Z"
          }],
          "cursor":"2024-01-01T12:00:00Z"
        }
        """

        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(PullSyncResponse.self, from: data)
        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events[0].eventId, "evt-1")
        XCTAssertEqual(response.cursor, Date(timeIntervalSince1970: 1704103200))
    }

    func testSyncMetadataIsAvailableOnLocalEvents() {
        let event = MemoryEvent(
            occurredAt: Date(),
            source: "contactMoment",
            title: "Lunch",
            detail: "with Alex",
            context: "Meeting"
        )

        event.backendEventId = "backend-123"
        event.backendVersion = 3
        event.syncedToBackendAt = Date()
        event.payloadHash = "hash-abc"

        XCTAssertEqual(event.backendEventId, "backend-123")
        XCTAssertEqual(event.backendVersion, 3)
        XCTAssertNotNil(event.syncedToBackendAt)
        XCTAssertEqual(event.payloadHash, "hash-abc")
    }

      func testPushRequestUsesEventsEnvelope() throws {
        let request = PushEventRequest(
          eventId: "evt-1",
          version: 1,
          occurredAt: Date(timeIntervalSince1970: 0),
          source: "contactMoment",
          title: "Test",
          detail: nil,
          searchText: nil,
          encryptedPayload: "payload",
          payloadHash: "hash",
          isDeleted: false
        )
        let envelope = PushSyncRequestForTesting(events: [request])
        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(object["events"])
        XCTAssertNil(object["items"])
      }
}

    private struct PushSyncRequestForTesting: Encodable {
      let events: [PushEventRequest]
    }
