import Foundation

struct NamedPlaceResponse: Codable, Equatable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let createdAt: Date
    let updatedAt: Date
}

struct CreateNamedPlaceRequest: Encodable {
    let name: String
    let latitude: Double
    let longitude: Double
}
