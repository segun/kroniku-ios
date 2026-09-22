import Foundation

final class SearchService: @unchecked Sendable {
    static let shared = SearchService()

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func keywordSearch(query: String?, source: String?, limit: Int = 20) async throws -> KeywordSearchResponse {
        try await apiClient.post("/search/keyword", body: KeywordSearchRequest(query: query, source: source, limit: limit))
    }

    func naturalSearch(query: String, limit: Int = 20) async throws -> NaturalSearchResponse {
        try await apiClient.post("/search/natural", body: NaturalSearchRequest(query: query, limit: limit))
    }
}
