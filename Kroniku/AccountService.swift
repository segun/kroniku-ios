import Foundation

final class AccountService: @unchecked Sendable {
    static let shared = AccountService()

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    @discardableResult
    func setRetrievalOptIn(_ enabled: Bool) async throws -> RetrievalOptInResponse {
        let response: RetrievalOptInResponse = try await apiClient.patch(
            "/account/retrieval-opt-in",
            body: UpdateRetrievalOptInRequest(enabled: enabled)
        )
        try KeychainService.shared.store(response.retrievalOptIn ? "true" : "false", for: .retrievalOptIn)
        return response
    }

    func exportAccountData() async throws -> ExportAccountResponse {
        try await apiClient.get("/account/export")
    }

    func deleteAccount() async throws -> DeleteAccountResponse {
        try await apiClient.delete("/account")
    }
}
