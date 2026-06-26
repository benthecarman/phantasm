import AVFoundation
import Foundation

/// A dictation failure with a message suitable for showing in the composer.
enum DictationError: LocalizedError {
    case microphoneDenied
    case speechRecognitionDenied
    case localeUnsupported
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is needed for dictation. Enable it in Settings."
        case .speechRecognitionDenied:
            return "Speech recognition access is needed for dictation. Enable it in Settings."
        case .localeUnsupported:
            return "On-device dictation isn't available for your language."
        case .unavailable(let message):
            return message
        }
    }
}

/// One dictation session: capture microphone audio and transcribe it on-device.
/// Implementations are *single-use* — create a fresh one per recording.
///
/// We use the platform's own speech models (iOS 26 `SpeechAnalyzer`, or
/// `SFSpeechRecognizer` on older systems) rather than bundling our own. The OS
/// manages the model assets — they're shared system-wide, persist across app
/// launches, and add nothing to the app bundle.
protocol DictationEngine: AnyObject {
    /// Begin capturing + transcribing. Throws if mic permission, the on-device
    /// language model, or the audio engine isn't available.
    ///
    /// `onPartial` is called as recognition progresses with the running
    /// transcript so far (finalized text plus the in-progress tail). It may be
    /// invoked off the main thread and any number of times.
    func start(onPartial: @escaping @Sendable (String) -> Void) async throws

    /// Stop capture, finalize, and return the trimmed transcript (best effort —
    /// returns whatever was recognized, never throws).
    func finishTranscript() async -> String

    /// Stop and discard without producing a transcript.
    func cancel() async
}

/// Build the best dictation engine for this OS: the iOS 26 `SpeechAnalyzer`
/// pipeline when available, otherwise the classic `SFSpeechRecognizer` path.
@MainActor
func makeDictationEngine() -> DictationEngine {
    if #available(iOS 26.0, *) {
        return SpeechAnalyzerDictationEngine()
    } else {
        return LegacySpeechDictationEngine()
    }
}

/// Request microphone permission, resolving with the current grant.
func requestMicrophonePermission() async -> Bool {
    if AVAudioApplication.shared.recordPermission == .granted { return true }
    return await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { granted in
            continuation.resume(returning: granted)
        }
    }
}

/// Activate the shared audio session for on-device speech capture. `.measurement`
/// minimizes input processing, which improves recognition; `.duckOthers` lowers
/// other audio (e.g. an in-progress read-aloud) while dictating.
func activateDictationAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
    try session.setActive(true, options: [])
}

/// Release the audio session after a dictation session ends, letting other
/// audio (e.g. read-aloud) resume.
func deactivateDictationAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
}
