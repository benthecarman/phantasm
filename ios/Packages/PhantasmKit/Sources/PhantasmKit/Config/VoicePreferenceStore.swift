import Foundation

/// Persists voice (text-to-speech) preferences. Small, non-secret values, so
/// `UserDefaults` is sufficient — same approach as `ModelPreferenceStore`.
///
/// These are global (not per-backend): the speech models run on-device and are
/// independent of which chat backend is connected.
public final class VoicePreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let autoSpeakKey = "phantasm.voice.autoSpeak"
    private let voiceIdentifierKey = "phantasm.voice.identifier"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read every assistant reply aloud automatically when its turn completes.
    /// Off by default.
    public var autoSpeak: Bool {
        get { defaults.bool(forKey: autoSpeakKey) }
        set { defaults.set(newValue, forKey: autoSpeakKey) }
    }

    /// The chosen system speech-voice identifier (an `AVSpeechSynthesisVoice`
    /// identifier). `nil` means "automatic" — pick the best installed voice for
    /// the current language. Stored as a plain string so this type stays free of
    /// any AVFoundation dependency (keeps `PhantasmKit` host-testable).
    public var voiceIdentifier: String? {
        get {
            let s = defaults.string(forKey: voiceIdentifierKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty ?? true) ? nil : s
        }
        set { defaults.set(newValue, forKey: voiceIdentifierKey) }
    }
}
