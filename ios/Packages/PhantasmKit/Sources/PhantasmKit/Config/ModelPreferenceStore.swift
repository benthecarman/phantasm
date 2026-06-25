import Foundation

/// Persists per-backend, per-model preferences that are not conversation state.
/// Values are small and non-secret, so UserDefaults is sufficient.
public final class ModelPreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let thinkingKey = "phantasm.modelThinking"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadThinkingPreferences() -> [String: [String: Bool]] {
        defaults.dictionary(forKey: thinkingKey) as? [String: [String: Bool]] ?? [:]
    }

    public func saveThinkingPreferences(_ preferences: [String: [String: Bool]]) {
        defaults.set(preferences, forKey: thinkingKey)
    }

    public func thinkingEnabled(for model: String, profileID: UUID) -> Bool {
        loadThinkingPreferences()[profileID.uuidString]?[model] ?? false
    }

    public func setThinkingEnabled(_ enabled: Bool, for model: String, profileID: UUID) {
        var preferences = loadThinkingPreferences()
        var byModel = preferences[profileID.uuidString] ?? [:]
        byModel[model] = enabled
        preferences[profileID.uuidString] = byModel
        saveThinkingPreferences(preferences)
    }

    public func clearThinkingPreferences(for profileID: UUID) {
        var preferences = loadThinkingPreferences()
        preferences[profileID.uuidString] = nil
        saveThinkingPreferences(preferences)
    }
}
