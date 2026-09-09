import Foundation

final class SyncService: @unchecked Sendable {
    static let shared = SyncService()

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func pushSync(events: [PushEventRequest]) async throws -> PushSyncResponse {
        let request = PushSyncRequest(events: events)
        return try await apiClient.post("/sync/push", body: request)
    }

    func pullSync(since: Date? = nil) async throws -> PullSyncResponse {
        if let since {
            let sinceString = ISO8601DateFormatter().string(from: since)
            return try await apiClient.get(
                "/sync/pull",
                queryItems: [URLQueryItem(name: "since", value: sinceString)]
            )
        }

        return try await apiClient.get("/sync/pull")
    }
}

private struct PushSyncRequest: Encodable {
    let events: [PushEventRequest]
}

