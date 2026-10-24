import Foundation
import Security

/// The TDLib database encryption key, generated once per account and kept in the Keychain.
nonisolated enum DatabaseKeyStore {
    private static let service = "com.Farsonic.Telemessage.tdlib-database-key"

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            }
        }
    }

    /// Returns the existing key for `account`, or creates and stores a new 32-byte key.
    static func key(for account: String) throws -> Data {
        if let existing = try read(account) { return existing }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        try store(key, for: account)
        return key
    }

    /// Removes the key, e.g. after logout once TDLib has deleted the database.
    static func delete(for account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    private static func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    private static func store(_ key: Data, for account: String) throws {
        var query = baseQuery(account)
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
