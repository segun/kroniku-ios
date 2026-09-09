import Foundation

/// Secure storage for authentication tokens and device identifiers using Keychain
final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()

    private let service = "com.kroniku.auth"

    enum KeychainKey: String {
        case accessToken = "accessToken"
        case clientDeviceId = "clientDeviceId"
        case deviceId = "deviceId"
        case userId = "userId"
        case userEmail = "userEmail"
        case retrievalOptIn = "retrievalOptIn"
    }

    // MARK: - Store

    func store(_ value: String, for key: KeychainKey) throws {
        let data = value.data(using: .utf8) ?? Data()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Delete existing value first
        SecItemDelete(query as CFDictionary)

        // Add new value
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.failedToStore(status: status)
        }
    }

    // MARK: - Retrieve

    func retrieve(_ key: KeychainKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.failedToRetrieve(status: status)
        }

        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return string
    }

    // MARK: - Delete

    func delete(_ key: KeychainKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failedToDelete(status: status)
        }
    }

    // MARK: - Delete All

    func deleteAll() throws {
        for key in KeychainKey.allCases {
            try? delete(key)
        }
    }
}

extension KeychainService.KeychainKey: CaseIterable {}

enum KeychainError: LocalizedError {
    case failedToStore(status: OSStatus)
    case failedToRetrieve(status: OSStatus)
    case failedToDelete(status: OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .failedToStore(let status):
            return "Failed to store to Keychain (status: \(status))"
        case .failedToRetrieve(let status):
            return "Failed to retrieve from Keychain (status: \(status))"
        case .failedToDelete(let status):
            return "Failed to delete from Keychain (status: \(status))"
        case .invalidData:
            return "Keychain data is invalid"
        }
    }
}
