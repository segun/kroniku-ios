import Foundation

extension Notification.Name {
    static let authSessionExpired = Notification.Name("authSessionExpired")
}

/// Centralized HTTP client with JWT handling and error parsing.
final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    // MARK: - Initialization

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? Self.defaultBaseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        
        self.session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    private static var defaultBaseURL: URL {
        #if DEBUG
        return URL(string: "https://kroniku.segun.me")!
        #else
        return URL(string: "https://api.kroniku.app")!
        #endif
    }

    // MARK: - Public Methods

    /// Performs a GET request
    func get<T: Decodable>(_ path: String) async throws -> T {
        try await get(path, queryItems: [])
    }

    /// Performs a GET request with URL-encoded query parameters.
    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]) async throws -> T {
        try await request(path: path, method: "GET", body: nil, queryItems: queryItems)
    }

    /// Performs a POST request with an Encodable body
    func post<T: Decodable, U: Encodable>(_ path: String, body: U) async throws -> T {
        try await request(path: path, method: "POST", body: try encoder.encode(body))
    }

    /// Performs a POST request without a response body
    func post<U: Encodable>(_ path: String, body: U) async throws {
        let _: EmptyResponse = try await post(path, body: body)
    }

    /// Performs a PATCH request with an Encodable body
    func patch<T: Decodable, U: Encodable>(_ path: String, body: U) async throws -> T {
        try await request(path: path, method: "PATCH", body: try encoder.encode(body))
    }

    /// Performs a PATCH request without a response body
    func patch<U: Encodable>(_ path: String, body: U) async throws {
        let _: EmptyResponse = try await patch(path, body: body)
    }

    /// Performs a PUT request with an Encodable body
    func put<T: Decodable, U: Encodable>(_ path: String, body: U) async throws -> T {
        try await request(path: path, method: "PUT", body: try encoder.encode(body))
    }

    /// Performs a PUT request without a response body
    func put<U: Encodable>(_ path: String, body: U) async throws {
        let _: EmptyResponse = try await put(path, body: body)
    }

    /// Performs a DELETE request
    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await request(path: path, method: "DELETE", body: nil)
    }

    /// Performs a DELETE request without a response body
    func delete(_ path: String) async throws {
        let _: EmptyResponse = try await delete(path)
    }

    // MARK: - Private Methods

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw HTTPError.unknownError(message: "Invalid request URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Inject JWT if available
        if let token = try? KeychainService.shared.retrieve(.accessToken) {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Encode body if present
        urlRequest.httpBody = body

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            print("🛑 [CANCELLED] [\(method)] \(url) request task was cancelled before a response")
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            print("🛑 [CANCELLED] [\(method)] \(url) URLSession cancelled the request")
            throw error
        } catch {
            print("🌐 [NETWORK ERROR] [\(method)] \(url) \(error.localizedDescription)")
            throw error
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw HTTPError.unknownError(message: "Invalid response type")
        }

        try handleHTTPStatus(httpResponse.statusCode, data: data)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPError.decodingError(error)
        }
    }

    private func handleHTTPStatus(_ statusCode: Int, data: Data) throws {
        guard (200..<300).contains(statusCode) else {
            let errorResponse = try? decoder.decode(BackendErrorResponse.self, from: data)
            let message: String

            if let errorResponse = errorResponse {
                switch errorResponse.message {
                case .string(let str):
                    message = str
                case .array(let arr):
                    message = arr.joined(separator: ", ")
                }
            } else {
                message = "Unknown error"
            }

            switch statusCode {
            case 400:
                if let errorResponse = errorResponse, case .array(let messages) = errorResponse.message {
                    throw HTTPError.validationError(messages: messages)
                } else {
                    throw HTTPError.validationError(messages: [message])
                }
            case 401:
                NotificationCenter.default.post(name: .authSessionExpired, object: nil)
                throw HTTPError.unauthorized(message: message)
            case 403:
                throw HTTPError.forbidden(message: message)
            case 404:
                throw HTTPError.notFound(message: message)
            case 409:
                throw HTTPError.conflict(message: message)
            default:
                throw HTTPError.serverError(statusCode: statusCode, message: message)
            }
        }
    }

}

// MARK: - Empty Response

struct EmptyResponse: Decodable {}
