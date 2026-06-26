import Foundation
import Observation
import UIKit

/// Drives on-device dictation: while the user holds the mic, a `DictationEngine`
/// captures audio and transcribes it with the platform speech models (iOS 26
/// `SpeechAnalyzer`, or `SFSpeechRecognizer` on older systems). On release we
/// finalize and hand the composer the transcript.
///
/// A fresh engine is created per recording session — the speech APIs are
/// single-use per utterance, and this keeps each session's state isolated.
@MainActor
@Observable
final class DictationController {
    /// Readiness of dictation (permissions + on-device model assets). Surfaced
    /// in Settings so the user can grant access / fetch the language model ahead
    /// of first use.
    enum ReadyState: Equatable {
        case unknown
        case preparing
        case ready
        case failed(String)
    }

    /// Capturing audio (the user is holding / locked-recording).
    private(set) var isRecording = false
    /// Stopped; finalizing the transcript.
    private(set) var isTranscribing = false
    /// The running transcript, updated live as the user speaks and replaced with
    /// the finalized text on stop. Empty while idle and reset to empty on
    /// start/cancel. The composer mirrors this into the text field.
    private(set) var liveTranscript = ""
    /// User-facing error (mic denied, language unsupported, …); nil when fine.
    private(set) var errorMessage: String?
    /// Coarse readiness for the Settings screen.
    private(set) var readyState: ReadyState = .unknown

    /// The active session's engine, stored only once it has actually started.
    private var engine: DictationEngine?
    /// Bumped each `start()`/`cancel()`; a session only applies its result while
    /// it's still the current generation.
    private var generation = 0

    func start() {
        guard !isRecording else { return }
        errorMessage = nil
        liveTranscript = ""
        isTranscribing = false
        isRecording = true
        readyState = .preparing
        generation += 1
        let gen = generation
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        Task {
            let engine = makeDictationEngine()
            do {
                try await engine.start(onPartial: { [weak self] text in
                    Task { @MainActor in
                        guard let self, gen == self.generation else { return }
                        self.liveTranscript = text
                    }
                })
            } catch {
                await engine.cancel()
                readyState = .failed(Self.message(for: error))
                if gen == generation {
                    isRecording = false
                    errorMessage = Self.message(for: error)
                }
                return
            }
            // Permissions + language model are confirmed available.
            readyState = .ready
            // The user may have released (stop) or cancelled while we were
            // starting up. Both run on the main actor, so by the time we resume
            // here `isRecording`/`generation` reflect that — tear down if so.
            guard gen == generation, isRecording else {
                await engine.cancel()
                return
            }
            self.engine = engine
        }
    }

    /// Stop and finalize the captured audio into a transcript.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // If the engine hasn't finished starting yet, `engine` is nil; the
        // in-flight start() sees `isRecording == false` and tears itself down.
        guard let engine else { return }
        self.engine = nil
        let gen = generation
        isTranscribing = true

        Task {
            let text = await engine.finishTranscript()
            guard gen == generation else { return }
            isTranscribing = false
            if !text.isEmpty { liveTranscript = text }
        }
    }

    /// Stop and discard — no transcription. Clearing `liveTranscript` reverts the
    /// live text the composer mirrored in while recording.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        isTranscribing = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        generation += 1 // invalidate any in-flight start/finish/partials
        liveTranscript = ""
        let engine = self.engine
        self.engine = nil
        if let engine { Task { await engine.cancel() } }
    }

    private static func message(for error: Error) -> String {
        (error as? DictationError)?.errorDescription ?? error.localizedDescription
    }
}
