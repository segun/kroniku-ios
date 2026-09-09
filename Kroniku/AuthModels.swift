import Foundation

// MARK: - Auth Responses

struct AuthResponse: Decodable {
    let accessToken: String
    let user: User
    let device: Device

    enum CodingKeys: String, CodingKey {
        case accessToken
        case user
        case device
    }
}

struct ProviderAuthResponse: Decodable {
    let accessToken: String
    let user: User
    let device: Device
    let isNewAccount: Bool

    enum CodingKeys: String, CodingKey {
        case accessToken
        case user
        case device
        case isNewAccount
    }
}

struct User: Decodable, Hashable {
    let id: String
    let email: String
    let retrievalOptIn: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case retrievalOptIn
    }
}

struct Device: Decodable, Hashable {
    let id: String
    let clientDeviceId: String

    enum CodingKeys: String, CodingKey {
        case id
        case clientDeviceId
    }
}

// MARK: - Health Response

struct HealthResponse: Decodable {
    let service: String
    let status: String
}

// MARK: - Auth Requests

struct ProviderLoginRequest: Encodable {
    let provider: String // "google" or "apple"
    let idToken: String
    let clientDeviceId: String
    let platform: String?
    let appVersion: String?
    let publicKey: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken
        case clientDeviceId
        case platform
        case appVersion
        case publicKey
    }
}
