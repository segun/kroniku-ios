import Foundation

// MARK: - Search API payloads

struct KeywordSearchRequest: Encodable {
    let query: String?
    let source: String?
    let limit: Int
}

struct NaturalSearchRequest: Encodable {
    let query: String
    let limit: Int
}

struct KeywordSearchResponse: Decodable {
    let mode: String
    let query: String
    let source: String?
    let count: Int
    let results: [PullEventResponse]
}

struct ScoredSearchResult: Decodable {
    let event: PullEventResponse
    let score: Double
}

struct NaturalSearchResponse: Decodable {
    let mode: String
    let query: String
    let rationale: String
    let count: Int
    let results: [ScoredSearchResult]
}
