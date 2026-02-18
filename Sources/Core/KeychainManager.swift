import Foundation
import Security

// MARK: - Keychain Manager
// Stores and retrieves secrets (API keys) securely in macOS Keychain.
// Never stores secrets in UserDefaults, plists, or logs.

public enum KeychainError: LocalizedError, Sendable {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case dataConversionFailed
    case itemNotFound

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed (OSStatus \(status))"
        case .readFailed(let status):
            return "Keychain read failed (OSStatus \(status))"
        case .deleteFailed(let status):
            return "Keychain delete failed (OSStatus \(status))"
        case .dataConversionFailed:
            return "Failed to convert Keychain data"
        case .itemNotFound:
            return "Item not found in Keychain"
        }
    }
}

public final class KeychainManager: Sendable {
    public static let shared = KeychainManager()

    private let service = "com.immichvault.app"

    // Well-known key identifiers
    public enum Key: String, Sendable {
        case immichAPIKey = "immich-api-key"
        case cloudConvertAPIKey = "cloudconvert-api-key"
        case convertioAPIKey = "convertio-api-key"
        case freeConvertAPIKey = "freeconvert-api-key"
    }

    private init() {}

    // MARK: - Public API

    public func save(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)
        try save(data: data, account: key.rawValue)
    }

    public func read(_ key: Key) throws -> String {
        let data = try readData(account: key.rawValue)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        return string
    }

    public func delete(_ key: Key) throws {
        try deleteItem(account: key.rawValue)
    }

    public func exists(_ key: Key) -> Bool {
        do {
            _ = try read(key)
            return true
        } catch {
            return false
        }
    }

    /// Returns a redacted version for display (e.g., "abc...xyz")
    public func readRedacted(_ key: Key) -> String? {
        guard let value = try? read(key) else { return nil }
        return redact(value)
    }

    // MARK: - Private

    private func save(data: Data, account: String) throws {
        // Delete existing item first (upsert pattern)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func readData(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }
        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    private func deleteItem(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private func redact(_ value: String) -> String {
        guard value.count > 8 else {
            return String(repeating: "*", count: value.count)
        }
        let prefix = String(value.prefix(4))
        let suffix = String(value.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}
