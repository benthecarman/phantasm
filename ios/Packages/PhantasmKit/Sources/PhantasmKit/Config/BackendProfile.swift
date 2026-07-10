import Foundation

/// The HTTP envelope a backend profile requires. Maple is still OpenAI-
/// compatible above this layer; the persisted marker lets launch select its
/// encrypted session immediately while capability refresh runs.
public enum BackendTransport: String, Codable, Sendable, Hashable {
    case standard
    case mapleEncrypted = "maple_encrypted"
}

/// A saved backend connection (NFR-A6). The token is NOT stored here — it lives
/// in the Keychain keyed by `id`.
public struct BackendProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var baseURLString: String
    public var defaultModel: String?
    public var transport: BackendTransport
    /// Preload the active model after connecting / switching backends so the
    /// first turn skips cold-start. Opt-in (off by default): warming wakes the
    /// backend and can pull a model into memory, which isn't always wanted.
    public var autoWarm: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        baseURLString: String,
        defaultModel: String? = nil,
        transport: BackendTransport = .standard,
        autoWarm: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.defaultModel = defaultModel
        self.transport = transport
        self.autoWarm = autoWarm
    }

    // Custom decoding so profiles saved before `transport` / `autoWarm`
    // existed still load (the synthesized decoder would fail on missing keys).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURLString = try c.decode(String.self, forKey: .baseURLString)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        transport = try c.decodeIfPresent(BackendTransport.self, forKey: .transport) ?? .standard
        autoWarm = try c.decodeIfPresent(Bool.self, forKey: .autoWarm) ?? false
    }

    public var baseURL: URL? {
        URL(string: Self.normalizedBaseURLString(baseURLString))
    }

    /// Normalizes a user-entered base URL to the host root the networking layer
    /// expects. The clients append `v1/...` (and `api/...`) paths themselves, so
    /// a pasted OpenAI-style `https://host/v1` would otherwise double up to
    /// `/v1/v1/chat/completions`. Trims surrounding whitespace, drops trailing
    /// slashes, and strips a single trailing `/v1` segment (case-insensitive).
    public static func normalizedBaseURLString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/v1") {
            s.removeLast(3)
            while s.hasSuffix("/") { s.removeLast() }
        }
        return s
    }

    /// Canonical form for *equivalence checks only* (never stored or displayed):
    /// `normalizedBaseURLString` plus lowercased scheme/host and default-port
    /// elision. Needed because producers normalize differently — the
    /// orchestrator's `pair` URL serializer lowercases hosts and drops `:443`,
    /// so a scanned "https://host.example" must match a hand-typed
    /// "https://Host.Example:443" when pairing dedups by backend (FR-A12).
    public static func canonicalBaseURLString(_ raw: String) -> String {
        let normalized = normalizedBaseURLString(raw)
        guard var components = URLComponents(string: normalized) else { return normalized }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string ?? normalized
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

    /// The persisted profile list, plus whether it decoded in full.
    ///
    /// `isComplete` separates "nothing stored" (fresh install — complete and
    /// empty) from "stored data that didn't fully decode". The distinction is
    /// load-bearing: launch reconciles keychain tokens against this list and
    /// deletes any without a matching profile, so treating a failed decode as
    /// an empty list would permanently destroy every backend token. Callers
    /// must skip destructive reconciliation when `isComplete` is false.
    public struct LoadedProfiles {
        public let profiles: [BackendProfile]
        public let isComplete: Bool
    }

    public func load() -> LoadedProfiles {
        guard let data = defaults.data(forKey: listKey) else {
            return LoadedProfiles(profiles: [], isComplete: true)
        }
        // Lossy per-element decode: one undecodable profile drops that entry,
        // not the whole list.
        guard let lossy = try? JSONDecoder().decode([LossyProfile].self, from: data) else {
            return LoadedProfiles(profiles: [], isComplete: false)
        }
        let profiles = lossy.compactMap(\.profile)
        return LoadedProfiles(profiles: profiles, isComplete: profiles.count == lossy.count)
    }

    private struct LossyProfile: Decodable {
        let profile: BackendProfile?
        init(from decoder: Decoder) {
            profile = try? BackendProfile(from: decoder)
        }
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
