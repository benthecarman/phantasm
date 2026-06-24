import Foundation

/// A saved backend connection (NFR-A6). The token is NOT stored here — it lives
/// in the Keychain keyed by `id`.
public struct BackendProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var baseURLString: String
    public var defaultModel: String?

    public init(id: UUID = UUID(), name: String, baseURLString: String, defaultModel: String? = nil) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.defaultModel = defaultModel
    }

    public var baseURL: URL? {
        URL(string: baseURLString)
    }
}

/// Persists the profile list + active selection in `UserDefaults` (small,
/// non-secret). Tokens are managed separately via `KeychainStore`.
public final class ProfileStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let listKey = "phantasm.profiles"
    private let activeKey = "phantasm.activeProfileID"
    private let modelsKey = "phantasm.cachedModels"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [BackendProfile] {
        guard let data = defaults.data(forKey: listKey),
              let profiles = try? JSONDecoder().decode([BackendProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    public func save(_ profiles: [BackendProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: listKey)
        }
    }

    public var activeProfileID: UUID? {
        get {
            guard let s = defaults.string(forKey: activeKey) else { return nil }
            return UUID(uuidString: s)
        }
        set { defaults.set(newValue?.uuidString, forKey: activeKey) }
    }

    // MARK: - Per-profile model cache

    /// The last-known model list for a backend, so the picker is populated
    /// instantly on launch while a fresh probe runs in the background. Keyed by
    /// profile id; non-secret, so it lives alongside the profile list.
    public func cachedModels(for id: UUID) -> [String] {
        let all = defaults.dictionary(forKey: modelsKey) as? [String: [String]] ?? [:]
        return all[id.uuidString] ?? []
    }

    public func cacheModels(_ models: [String], for id: UUID) {
        var all = defaults.dictionary(forKey: modelsKey) as? [String: [String]] ?? [:]
        all[id.uuidString] = models
        defaults.set(all, forKey: modelsKey)
    }

    public func clearCachedModels(for id: UUID) {
        guard var all = defaults.dictionary(forKey: modelsKey) as? [String: [String]] else { return }
        all[id.uuidString] = nil
        defaults.set(all, forKey: modelsKey)
    }
}
