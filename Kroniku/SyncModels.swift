import Foundation

// MARK: - Sync API payloads

struct SyncPlaceData: Codable, Equatable {
    let name: String
    let latitude: Double?
    let longitude: Double?
}

struct SyncWeatherData: Codable, Equatable {
    let observedAt: Date
    let condition: String?
    let temperatureC: Double?
}

struct SyncPhotoReference: Codable, Equatable {
    let assetIdentifier: String
    let filename: String?
    let addedAt: Date
}

struct SyncHealthEntryData: Codable, Equatable {
    let metric: String
    let value: String
}

struct SyncGeoCoordinateData: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct SyncWorkoutRouteData: Codable, Equatable {
    let coordinates: [SyncGeoCoordinateData]
}

struct SyncEventContextData: Codable, Equatable {
    let place: SyncPlaceData?
    let weather: SyncWeatherData?
    let motion: String?
    let bluetoothContext: String?
    let timeSemantics: [String]?
    let photoReferences: [SyncPhotoReference]?
    let contacts: [String]?
    let userNote: String?
    let endedAt: Date?
    let healthSummary: [SyncHealthEntryData]?
    let distanceMeters: Double?
    let workoutRoute: SyncWorkoutRouteData?
    // Stable EventKit identifier for calendar-sourced events; lets other devices reconcile the same occurrence.
    let externalSourceID: String?

    var isEmpty: Bool {
        place == nil && weather == nil && motion == nil && bluetoothContext == nil &&
        (timeSemantics?.isEmpty ?? true) && (photoReferences?.isEmpty ?? true) &&
        (contacts?.isEmpty ?? true) && (userNote?.isEmpty ?? true) && endedAt == nil &&
        (healthSummary?.isEmpty ?? true) && distanceMeters == nil && workoutRoute == nil &&
        externalSourceID == nil
    }
}

struct PushEventRequest: Codable {
    let eventId: String
    let version: Int
    let occurredAt: Date
    let source: String
    let title: String?
    let detail: String?
    let searchText: String?
    let contextData: SyncEventContextData?
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
    let contextData: SyncEventContextData?
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
