import AVFoundation
import Foundation
import Observation
import PhantasmKit

/// Reads assistant messages aloud with the on-device system speech synthesizer
/// (`AVSpeechSynthesizer`).
///
/// Only one message plays at a time; `speakingMessageID` lets each bubble show a
/// Speak/Stop toggle. Markdown is reduced to plain prose first (`SpeakableText`)
/// so URLs, code, and base64 image data aren't read out.
///
/// We pick the highest-quality installed voice for the user's language (premium
/// > enhanced > default). The richer voices are downloaded by the user in
/// Settings ▸ Accessibility ▸ Spoken Content ▸ Voices; when none are installed,
/// iOS falls back to the compact system voice.
@MainActor
@Observable
final class SpeechSynthesizer {
    /// The message currently being spoken, or nil when idle.
    private(set) var speakingMessageID: UUID?
    private(set) var errorMessage: String?

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SynthDelegate()
    private let voicePrefs: VoicePreferenceStore

    /// Serial queue for the blocking AVFoundation work — `AVAudioSession`
    /// activation and resolving (possibly on-disk) premium/enhanced voice assets
    /// must not run on the main actor or they jank the UI. Serial so session
    /// activate/deactivate stay ordered and can't race.
    private let audioQueue = DispatchQueue(label: "com.phantasm.speech-synth")

    /// The utterance currently playing. Used to ignore stale finish/cancel
    /// callbacks from an utterance we already superseded or stopped — otherwise
    /// the old utterance's `didCancel` could clear the *new* `speakingMessageID`.
    private var activeUtterance: AVSpeechUtterance?

    init(voicePrefs: VoicePreferenceStore) {
        self.voicePrefs = voicePrefs
        delegate.onDone = { [weak self] utterance in self?.handleDone(utterance) }
        synthesizer.delegate = delegate
    }

    /// Toggle: speak `text` for `messageID`, or stop if it's already speaking.
    func toggle(_ text: String, messageID: UUID) {
        if speakingMessageID == messageID {
            stop()
        } else {
            speak(text, messageID: messageID)
        }
    }

    func speak(_ text: String, messageID: UUID) {
        stop()
        let spoken = SpeakableText.plainText(from: text)
        guard !spoken.isEmpty else { return }
        errorMessage = nil
        speakingMessageID = messageID
        play(spoken, voiceIdentifier: voicePrefs.voiceIdentifier)
    }

    /// Speak a short sample with the given voice so the user can audition it from
    /// the Voice settings screen. Independent of `speakingMessageID` (no chat
    /// bubble is involved), and interrupts anything already playing.
    func preview(voiceIdentifier: String?, sample: String = "Hello — this is how I sound.") {
        stop()
        play(sample, voiceIdentifier: voiceIdentifier)
    }

    func stop() {
        // Drop the active utterance first so the resulting `didCancel` callback
        // is treated as stale and doesn't clobber a subsequent `speak`.
        activeUtterance = nil
        speakingMessageID = nil
        // Safe to use across the serial `audioQueue`; AVFoundation types just
        // aren't marked `Sendable`.
        nonisolated(unsafe) let synth = synthesizer
        audioQueue.async {
            if synth.isSpeaking || synth.isPaused {
                synth.stopSpeaking(at: .immediate)
            }
            Self.deactivateAudioSession()
        }
    }

    /// Resolve the voice, activate the session, and start speaking — all off the
    /// main actor. Only `activeUtterance` is touched on the main actor (for the
    /// stale-callback guard); the heavy AVFoundation calls run on `audioQueue`.
    private func play(_ text: String, voiceIdentifier: String?) {
        let utterance = AVSpeechUtterance(string: text)
        activeUtterance = utterance
        // Safe to use across the serial `audioQueue`; AVFoundation types just
        // aren't marked `Sendable`.
        nonisolated(unsafe) let job = utterance
        nonisolated(unsafe) let synth = synthesizer
        audioQueue.async {
            job.voice = Self.voice(forIdentifier: voiceIdentifier)
            try? Self.activateAudioSession()
            synth.speak(job)
        }
    }

    private func handleDone(_ utterance: AVSpeechUtterance) {
        // Ignore callbacks from a superseded/stopped utterance.
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
        speakingMessageID = nil
        nonisolated(unsafe) let synth = synthesizer
        audioQueue.async {
            // Don't tear down the session if another utterance has already
            // started (e.g. a rapid re-selection in the voice picker).
            if !synth.isSpeaking { Self.deactivateAudioSession() }
        }
    }

    /// Resolve a stored voice identifier to a voice, falling back to the best
    /// installed voice for the current language when the identifier is `nil` or
    /// the chosen voice has since been uninstalled.
    nonisolated static func voice(forIdentifier identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return preferredVoice()
    }

    /// The best installed voice for the user's current language: premium, else
    /// enhanced, else the compact default. Falls back to the language default
    /// when no voice matches.
    nonisolated static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices()

        // Prefer an exact language match (e.g. "en-US"); fall back to the same
        // base language (e.g. any "en-*") if the exact locale isn't installed.
        let exact = voices.filter { $0.language == language }
        let basePrefix = String(language.prefix(2))
        let pool = exact.isEmpty ? voices.filter { $0.language.hasPrefix(basePrefix) } : exact

        let best = pool.max { rank($0.quality) < rank($1.quality) }
        return best ?? AVSpeechSynthesisVoice(language: language)
    }

    nonisolated private static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }

    /// A selectable voice for the settings picker. `Sendable` (unlike
    /// `AVSpeechSynthesisVoice`) so the list can be built off the main thread and
    /// handed back to the view.
    struct VoiceOption: Identifiable, Hashable, Sendable {
        /// The `AVSpeechSynthesisVoice` identifier.
        let id: String
        let label: String
    }

    /// Build the picker's voice options off the main thread (enumerating voices
    /// and resolving their display labels can be slow enough to jank the UI).
    nonisolated static func voiceOptionsForCurrentLanguage() -> [VoiceOption] {
        installedVoicesForCurrentLanguage().map {
            VoiceOption(id: $0.identifier, label: displayLabel(for: $0))
        }
    }

    /// Display name for a voice, avoiding a doubled quality tag for voices whose
    /// `name` already includes it (e.g. iOS 26's "Zoe (Premium)").
    nonisolated static func displayLabel(for voice: AVSpeechSynthesisVoice) -> String {
        guard let quality = qualityLabel(voice.quality),
            !voice.name.localizedCaseInsensitiveContains(quality)
        else { return voice.name }
        return "\(voice.name) (\(quality))"
    }

    /// Installed voices for the user's current base language (e.g. all "en-*"),
    /// best quality first then alphabetical — the candidates shown in the Voice
    /// settings picker. Excludes the legacy novelty voices (Bells, Bubbles,
    /// Trinoids, …), which aren't usable speech voices.
    nonisolated static func installedVoicesForCurrentLanguage() -> [AVSpeechSynthesisVoice] {
        let basePrefix = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(basePrefix) }
            .filter { !$0.identifier.hasPrefix("com.apple.speech.synthesis.voice.") }
            .sorted {
                rank($0.quality) != rank($1.quality)
                    ? rank($0.quality) > rank($1.quality)
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Human-readable quality tag for a voice, or `nil` for the basic default
    /// (no tag needed).
    nonisolated static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String? {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return nil
        @unknown default: return nil
        }
    }

    nonisolated private static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    nonisolated private static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Forwards `AVSpeechSynthesizer` finish/cancel callbacks onto the main actor.
/// Kept separate from `SpeechSynthesizer` so that class can stay `@MainActor`
/// while this conforms to the non-isolated delegate protocol.
private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onDone: ((AVSpeechUtterance) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        forward(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        forward(utterance)
    }

    private func forward(_ utterance: AVSpeechUtterance) {
        let callback = onDone
        Task { @MainActor in callback?(utterance) }
    }
}
