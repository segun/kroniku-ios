import Foundation

/// Service for handling authentication operations
final class AuthService: @unchecked Sendable {
    static let shared = AuthService()

    private let apiClient: APIClient
    private let keychain: KeychainService

    init(apiClient: APIClient = .shared, keychain: KeychainService = .shared) {
        self.apiClient = apiClient
        self.keychain = keychain
    }

    // MARK: - Status

    /// Checks if backend is reachable
    func getBackendStatus() async throws -> HealthResponse {
        try await apiClient.get("/")
    }

    // MARK: - Device Identity

    /// Returns a stable device identifier for this app install and persists it to Keychain.
    func getOrCreateClientDeviceId() throws -> String {
        if let existing = try keychain.retrieve(.clientDeviceId), !existing.isEmpty {
            return existing
        }

        let newIdentifier = "ios-\(UUID().uuidString.prefix(8))"
        try keychain.store(String(newIdentifier), for: .clientDeviceId)
        return String(newIdentifier)
    }

    /// Returns a stable device public key for provider auth, generating one on first use if missing.
    func getOrCreateDevicePublicKey() throws -> String {
        if let existing = try keychain.retrieve(.devicePublicKey), !existing.isEmpty {
            return existing
        }

        let randomBytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        let publicKey = Data(randomBytes).base64EncodedString()
        try keychain.store(publicKey, for: .devicePublicKey)
        return publicKey
    }

    // MARK: - Provider Login

    /// Logs in or registers using a provider (Google or Apple) OpenID Connect ID token
    func loginWithProvider(
        provider: String, // "google" or "apple"
        idToken: String,
        clientDeviceId: String? = nil,
        platform: String = "ios",
        appVersion: String,
        publicKey: String? = nil
    ) async throws -> (response: ProviderAuthResponse, isNewAccount: Bool) {
        let resolvedClientDeviceId = try clientDeviceId ?? getOrCreateClientDeviceId()
        let resolvedPublicKey = try publicKey ?? getOrCreateDevicePublicKey()

        let request = ProviderLoginRequest(
            provider: provider,
            idToken: idToken,
            clientDeviceId: resolvedClientDeviceId,
            platform: platform,
            appVersion: appVersion,
            publicKey: resolvedPublicKey
        )

        let response: ProviderAuthResponse = try await apiClient.post("/auth/provider", body: request)

        let basicResponse = AuthResponse(
            accessToken: response.accessToken,
            user: response.user,
            device: response.device
        )
        try saveAuthResponse(basicResponse, clientDeviceId: resolvedClientDeviceId)

        return (response, response.isNewAccount)
    }

    // MARK: - Session Management

    /// Clears all authentication data
    func logout() throws {
        try keychain.deleteAll()
    }

    /// Returns the current access token if available
    func getAccessToken() throws -> String? {
        try keychain.retrieve(.accessToken)
    }

    /// Returns the stored user email if available
    func getUserEmail() throws -> String? {
        try keychain.retrieve(.userEmail)
    }

    /// Returns the stored user ID if available
    func getUserId() throws -> String? {
        try keychain.retrieve(.userId)
    }

    /// Returns the stored retrieval opt-in status
    func getRetrievalOptIn() throws -> Bool {
        guard let value = try keychain.retrieve(.retrievalOptIn) else {
            return false
        }
        return value == "true"
    }

    /// Returns the stored server-managed device identifier if present.
    func getDeviceId() throws -> String? {
        try keychain.retrieve(.deviceId)
    }

    /// Checks if user is currently authenticated
    var isAuthenticated: Bool {
        (try? getAccessToken()) != nil
    }

    // MARK: - Helpers

    func saveAuthResponse(_ response: AuthResponse, clientDeviceId: String) throws {
        try keychain.store(response.accessToken, for: .accessToken)
        try keychain.store(response.user.id, for: .userId)
        try keychain.store(response.user.email, for: .userEmail)
        try keychain.store(response.user.retrievalOptIn ? "true" : "false", for: .retrievalOptIn)
        try keychain.store(clientDeviceId, for: .clientDeviceId)
        try keychain.store(response.device.id, for: .deviceId)
    }
}
