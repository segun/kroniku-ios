import Foundation

/// HTTP methods for the `/v1/me/places` resource (user-named locations).
final class NamedPlacesService: @unchecked Sendable {
    static let shared = NamedPlacesService()

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func list() async throws -> [NamedPlaceResponse] {
        try await apiClient.get("/v1/me/places")
    }

    func create(name: String, latitude: Double, longitude: Double) async throws -> NamedPlaceResponse {
        let body = CreateNamedPlaceRequest(name: name, latitude: latitude, longitude: longitude)
        return try await apiClient.post("/v1/me/places", body: body)
    }
}
