import Foundation

/// Typed errors matching the backend API contract response shapes
enum HTTPError: LocalizedError, Equatable {
    case validationError(messages: [String])
    case unauthorized(message: String)
    case forbidden(message: String)
    case notFound(message: String)
    case conflict(message: String)
    case serverError(statusCode: Int, message: String)
    case networkError(Error?)
    case decodingError(Error?)
    case unknownError(message: String)

    var errorDescription: String? {
        switch self {
        case .validationError(let messages):
            return "Validation Error: \(messages.joined(separator: ", "))"
        case .unauthorized(let message):
            return "Unauthorized: \(message)"
        case .forbidden(let message):
            return "Forbidden: \(message)"
        case .notFound(let message):
            return "Not Found: \(message)"
        case .conflict(let message):
            return "Conflict: \(message)"
        case .serverError(let statusCode, let message):
            return "Server Error (\(statusCode)): \(message)"
        case .networkError(let error):
            return "Network Error: \(error?.localizedDescription ?? "Unknown")"
        case .decodingError(let error):
            return "Decoding Error: \(error?.localizedDescription ?? "Unknown")"
        case .unknownError(let message):
            return message
        }
    }

    static func == (lhs: HTTPError, rhs: HTTPError) -> Bool {
        switch (lhs, rhs) {
        case (.validationError(let a), .validationError(let b)):
            return a == b
        case (.unauthorized(let a), .unauthorized(let b)):
            return a == b
        case (.forbidden(let a), .forbidden(let b)):
            return a == b
        case (.notFound(let a), .notFound(let b)):
            return a == b
        case (.conflict(let a), .conflict(let b)):
            return a == b
        case (.serverError(let codeA, let msgA), .serverError(let codeB, let msgB)):
            return codeA == codeB && msgA == msgB
        case (.unknownError(let a), .unknownError(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Standard backend error response structure
struct BackendErrorResponse: Decodable {
    let statusCode: Int
    let message: MessageValue
    let error: String?

    enum MessageValue: Decodable {
        case string(String)
        case array([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
            } else if let arrayValue = try? container.decode([String].self) {
                self = .array(arrayValue)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "message must be string or array"
                )
            }
        }
    }
}
