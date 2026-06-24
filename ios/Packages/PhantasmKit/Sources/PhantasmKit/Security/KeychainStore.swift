import Foundation
import Security

/// Minimal Keychain Services wrapper for the bearer token (NFR-A2). Only the
/// token is stored here, keyed by profile id; profile metadata lives elsewhere.
public struct KeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.phantasm.tokens") {
        self.service = service
    }

    public enum KeychainError: Error, Equatable {
        case unhandled(OSStatus)
    }

    public func setToken(_ token: String, for profileID: UUID) throws {
        let account = profileID.uuidString
        try? delete(for: profileID) // upsert
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    public func token(for profileID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every profile id that currently has a stored token. Keychain items
    /// survive app uninstall while the UserDefaults profile list does not, so a
    /// reinstall can leave tokens with no owning profile; this lets the app
    /// reconcile the two.
    public func storedProfileIDs() -> Set<UUID> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init) })
    }

    /// Removes any stored token whose profile id is not in `keep`. Returns the
    /// number of orphaned tokens deleted.
    @discardableResult
    public func deleteTokens(notIn keep: Set<UUID>) -> Int {
        let orphans = storedProfileIDs().subtracting(keep)
        for id in orphans { try? delete(for: id) }
        return orphans.count
    }

    public func delete(for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
