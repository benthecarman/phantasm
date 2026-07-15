import Foundation
import Security

/// Minimal Keychain Services wrapper for the bearer token (NFR-A2). Only the
/// token is stored here, keyed by profile id; profile metadata lives elsewhere.
public struct KeychainStore: Sendable {
    private let service: String
    private let updateItem: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    private let addItem: @Sendable (CFDictionary) -> OSStatus

    public init(service: String = "com.phantasm.tokens") {
        self.service = service
        self.updateItem = { query, attributes in
            SecItemUpdate(query, attributes)
        }
        self.addItem = { query in
            SecItemAdd(query, nil)
        }
    }

    init(
        service: String,
        updateItem: @escaping @Sendable (CFDictionary, CFDictionary) -> OSStatus,
        addItem: @escaping @Sendable (CFDictionary) -> OSStatus
    ) {
        self.service = service
        self.updateItem = updateItem
        self.addItem = addItem
    }

    public enum KeychainError: Error, Equatable {
        case unhandled(OSStatus)
    }

    public func setToken(_ token: String, for profileID: UUID) throws {
        let account = profileID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = updateItem(
            query as CFDictionary,
            attributes as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let item = query.merging(attributes) { _, new in new }
            let addStatus = addItem(item as CFDictionary)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        default:
            // The existing item remains untouched when an update fails.
            throw KeychainError.unhandled(updateStatus)
        }
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
