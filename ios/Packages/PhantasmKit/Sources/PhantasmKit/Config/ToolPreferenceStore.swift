import Foundation

/// Persists sticky defaults for the per-chat tool selectors. The tools stay
/// per-conversation (each chat keeps its own choice), but the *default a new chat
/// starts with* follows the last value the user picked — so enabling a tool keeps
/// it on across new chats. Small, non-secret values, so `UserDefaults` is
/// sufficient (same approach as `VoicePreferenceStore`).
public final class ToolPreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let locationDefaultKey = "phantasm.tools.location.defaultEnabled"
    private let healthDefaultKey = "phantasm.tools.health.defaultEnabled"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a new chat should start with the location tool enabled. Off until
    /// the user turns it on in any chat, then sticks on for subsequent new chats.
    public var locationEnabledDefault: Bool {
        get { defaults.bool(forKey: locationDefaultKey) }
        set { defaults.set(newValue, forKey: locationDefaultKey) }
    }

    /// Whether a new chat should start with the health tool enabled. Off until the
    /// user turns it on in any chat, then sticks on for subsequent new chats.
    public var healthEnabledDefault: Bool {
        get { defaults.bool(forKey: healthDefaultKey) }
        set { defaults.set(newValue, forKey: healthDefaultKey) }
    }
}
