import Foundation

/// HTTP methods for the `/v1/me/geofences` resource (user-named geofence places).
final class GeofenceService: @unchecked Sendable {
    static let shared = GeofenceService()

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func list() async throws -> [NamedGeofence] {
        try await apiClient.get("/v1/me/geofences")
    }

    func upsert(_ place: NamedGeofence) async throws -> NamedGeofence {
        try await apiClient.put("/v1/me/geofences/\(place.id.uuidString)", body: place)
    }

    func delete(id: UUID) async throws {
        try await apiClient.delete("/v1/me/geofences/\(id.uuidString)")
    }
}
