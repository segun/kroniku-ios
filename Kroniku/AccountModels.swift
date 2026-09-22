import Foundation

// MARK: - Account API payloads

struct UpdateRetrievalOptInRequest: Encodable {
    let enabled: Bool
}

struct RetrievalOptInResponse: Decodable {
    let userId: String
    let retrievalOptIn: Bool
    let updatedAt: Date
}

struct ExportedAccountInfo: Codable {
    let id: String
    let email: String
    let retrievalOptIn: Bool
    let createdAt: Date
}

struct ExportAccountResponse: Codable {
    let exportedAt: Date
    let account: ExportedAccountInfo
    let devices: [ExportedDevice]
    let events: [PullEventResponse]
}

struct ExportedDevice: Codable {
    let id: String
    let clientDeviceId: String
}

struct DeleteAccountResponse: Decodable {
    let deleted: Bool
    let deletedAt: Date
}
