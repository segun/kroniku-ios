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

    // MARK: - Provider Login

    /// Logs in or registers using a provider (Google or Apple) OpenID Connect ID token
    func loginWithProvider(
        provider: String, // "google" or "apple"
        idToken: String,
        clientDeviceId: String,
        platform: String = "ios",
        appVersion: String,
        publicKey: String? = nil
    ) async throws -> (response: ProviderAuthResponse, isNewAccount: Bool) {
        let request = ProviderLoginRequest(
            provider: provider,
            idToken: idToken,
            clientDeviceId: clientDeviceId,
            platform: platform,
            appVersion: appVersion,
            publicKey: publicKey
        )

        let response: ProviderAuthResponse = try await apiClient.post("/auth/provider", body: request)
        
        // Save the auth response
        let basicResponse = AuthResponse(
            accessToken: response.accessToken,
            user: response.user,
            device: response.device
        )
        try saveAuthResponse(basicResponse, clientDeviceId: clientDeviceId)

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

    /// Checks if user is currently authenticated
    var isAuthenticated: Bool {
        (try? getAccessToken()) != nil
    }

    // MARK: - Private Helpers

    private func saveAuthResponse(_ response: AuthResponse, clientDeviceId: String) throws {
        try keychain.store(response.accessToken, for: .accessToken)
        try keychain.store(response.user.id, for: .userId)
        try keychain.store(response.user.email, for: .userEmail)
        try keychain.store(response.user.retrievalOptIn ? "true" : "false", for: .retrievalOptIn)
        try keychain.store(clientDeviceId, for: .clientDeviceId)
        try keychain.store(response.device.id, for: .deviceId)
    }
}
