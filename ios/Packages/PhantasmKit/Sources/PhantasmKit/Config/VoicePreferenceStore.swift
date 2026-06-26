import Foundation

/// Persists voice (text-to-speech) preferences. Small, non-secret values, so
/// `UserDefaults` is sufficient — same approach as `ModelPreferenceStore`.
///
/// These are global (not per-backend): the speech models run on-device and are
/// independent of which chat backend is connected.
public final class VoicePreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let autoSpeakKey = "phantasm.voice.autoSpeak"
    private let instructionKey = "phantasm.voice.instruction"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read every assistant reply aloud automatically when its turn completes.
    /// Off by default.
    public var autoSpeak: Bool {
        get { defaults.bool(forKey: autoSpeakKey) }
        set { defaults.set(newValue, forKey: autoSpeakKey) }
    }

    /// Optional Qwen3-TTS instruction (e.g. "read calmly"). `nil`/empty means the
    /// model's default delivery.
    public var instruction: String? {
        get {
            let s = defaults.string(forKey: instructionKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty ?? true) ? nil : s
        }
        set { defaults.set(newValue, forKey: instructionKey) }
    }
}
