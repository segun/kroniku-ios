import Foundation

// MARK: - Sync API payloads

struct PushEventRequest: Codable {
    let eventId: String
    let version: Int
    let occurredAt: Date
    let source: String
    let title: String?
    let detail: String?
    let searchText: String?
    let encryptedPayload: String
    let payloadHash: String
    let isDeleted: Bool
}

struct AppliedEvent: Codable, Equatable {
    let eventId: String
    let version: Int
    let updatedAt: Date
}

struct ConflictEvent: Codable, Equatable {
    let eventId: String
    let strategy: String
    let serverVersion: Int
    let incomingVersion: Int
}

struct IgnoredEvent: Codable, Equatable {
    let eventId: String
    let reason: String?
}

struct PushSyncResponse: Codable, Equatable {
    let applied: [AppliedEvent]
    let conflicts: [ConflictEvent]
    let ignored: [IgnoredEvent]
}

struct PullEventResponse: Codable, Equatable {
    let id: String
    let eventId: String
    let version: Int
    let occurredAt: Date
    let source: String
    let title: String?
    let detail: String?
    let searchText: String?
    let encryptedPayload: String
    let payloadHash: String
    let isDeleted: Bool
    let createdAt: Date
    let updatedAt: Date
}

struct PullSyncResponse: Codable, Equatable {
    let events: [PullEventResponse]
    let cursor: Date?
}

// MARK: - Sync convenience helpers

extension PullSyncResponse {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decode([PullEventResponse].self, forKey: .events)
        self.cursor = try container.decodeIfPresent(Date.self, forKey: .cursor)
    }
}
