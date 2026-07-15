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
    typealias EngineFactory = @MainActor () -> any DictationEngine

    /// Readiness of dictation (permissions + on-device model assets). Surfaced
    /// in Settings so the user can grant access / fetch the language model ahead
    /// of first use.
    enum ReadyState: Equatable {
        case unknown
        case preparing
        case ready
        case failed(String)
    }

    /// Preparing permissions/models/audio; capture has not started yet.
    private(set) var isPreparing = false
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
    /// The conversation whose composer owns the transcript and lifecycle state.
    /// Keeping this explicit prevents late partial/final results from one chat
    /// being observed as input by another chat's composer.
    private(set) var ownerID: UUID?

    /// The active session's engine, including while startup is awaiting system
    /// permissions/assets, so an ownership change can serialize behind it.
    private var engine: DictationEngine?
    /// Serializes startup, finalization, and cancellation across owners. A new
    /// microphone session never begins until the previous engine has completely
    /// torn down its shared AVAudioSession.
    private var lifecycleTask: Task<Void, Never>?
    /// True from the beginning of startup through final transcription. Unlike
    /// `isRecording`, this remains true while `stop()` is finalizing, so a
    /// navigation/background cancellation can invalidate that work too.
    private var sessionIsActive = false
    /// Bumped each `start()`/`cancel()`; a session only applies its result while
    /// it's still the current generation.
    private var generation = 0
    private let engineFactory: EngineFactory

    init(engineFactory: @escaping EngineFactory = { makeDictationEngine() }) {
        self.engineFactory = engineFactory
    }

    func start(ownerID newOwnerID: UUID) {
        guard ownerID != newOwnerID || !sessionIsActive else { return }

        // Taking ownership for another composer invalidates its predecessor
        // before any asynchronous engine work begins.
        let previousTask = lifecycleTask
        previousTask?.cancel()
        let previousEngine = resetSession(releaseOwnership: true)
        ownerID = newOwnerID
        errorMessage = nil
        liveTranscript = ""
        isTranscribing = false
        isPreparing = true
        isRecording = false
        sessionIsActive = true
        readyState = .preparing
        generation += 1
        let gen = generation
        Haptics.impact(.medium)

        let task = Task {
            // A rapid chat switch can otherwise activate a new audio session
            // before the previous engine has finished tearing its session down.
            await previousTask?.value
            if let previousEngine { await previousEngine.cancel() }
            guard !Task.isCancelled,
                  gen == generation,
                  ownerID == newOwnerID else { return }

            let engine = engineFactory()
            self.engine = engine
            do {
                try await engine.start(onPartial: { [weak self] text in
                    Task { @MainActor in
                        guard let self,
                              gen == self.generation,
                              self.ownerID == newOwnerID else { return }
                        self.liveTranscript = text
                    }
                })
                try Task.checkCancellation()
            } catch {
                await engine.cancel()
                guard gen == generation, ownerID == newOwnerID else { return }
                self.engine = nil
                isPreparing = false
                isRecording = false
                sessionIsActive = false
                if error is CancellationError {
                    if readyState == .preparing { readyState = .unknown }
                    return
                }
                readyState = .failed(Self.message(for: error))
                errorMessage = Self.message(for: error)
                return
            }
            guard !Task.isCancelled,
                  gen == generation,
                  ownerID == newOwnerID else {
                await engine.cancel()
                return
            }
            // Permissions + language model are confirmed available.
            readyState = .ready
            isPreparing = false
            isRecording = true
        }
        lifecycleTask = task
    }

    /// Stop and finalize the captured audio into a transcript.
    func stop(ownerID: UUID) {
        guard self.ownerID == ownerID, sessionIsActive else { return }
        if isPreparing {
            Haptics.impact(.light)
            let previousTask = lifecycleTask
            let engine = resetSession(releaseOwnership: false)
            scheduleCancellation(after: previousTask, engine: engine)
            return
        }
        guard isRecording else { return }
        isRecording = false
        Haptics.impact(.light)
        // `isRecording` only becomes true after startup succeeds, so a capturing
        // session always has an engine available for finalization.
        guard let engine else { return }
        self.engine = nil
        let previousTask = lifecycleTask
        let gen = generation
        isTranscribing = true

        let task = Task {
            await previousTask?.value
            let text = await engine.finishTranscript()
            guard gen == generation, self.ownerID == ownerID else { return }
            isTranscribing = false
            sessionIsActive = false
            if !text.isEmpty { liveTranscript = text }
        }
        lifecycleTask = task
    }

    /// Stop and discard — no transcription. Clearing `liveTranscript` reverts the
    /// live text the composer mirrored in while recording.
    func cancel(ownerID: UUID) {
        guard self.ownerID == ownerID, sessionIsActive else { return }
        Haptics.impact(.light)
        let previousTask = lifecycleTask
        let engine = resetSession(releaseOwnership: false)
        scheduleCancellation(after: previousTask, engine: engine)
    }

    /// Give up a composer's ownership when its chat disappears or the scene is
    /// no longer active. This also invalidates a finalization already in flight.
    func relinquish(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        let previousTask = lifecycleTask
        let engine = resetSession(releaseOwnership: true)
        scheduleCancellation(after: previousTask, engine: engine)
    }

    /// Audio-session interruptions never resume microphone capture implicitly.
    /// The user can deliberately start a fresh session after the interruption.
    func interrupt(ownerID: UUID) {
        guard self.ownerID == ownerID, sessionIsActive else { return }
        let previousTask = lifecycleTask
        let engine = resetSession(releaseOwnership: false)
        errorMessage = "Dictation stopped because audio was interrupted."
        scheduleCancellation(after: previousTask, engine: engine)
    }

    /// Invalidate every callback/result belonging to the current session and
    /// return the running engine, if any, for asynchronous teardown.
    @discardableResult
    private func resetSession(releaseOwnership: Bool) -> DictationEngine? {
        generation += 1
        isPreparing = false
        isRecording = false
        isTranscribing = false
        sessionIsActive = false
        liveTranscript = ""
        if readyState == .preparing { readyState = .unknown }
        let engine = self.engine
        self.engine = nil
        if releaseOwnership {
            ownerID = nil
            errorMessage = nil
        }
        return engine
    }

    private func scheduleCancellation(
        after previousTask: Task<Void, Never>?,
        engine: DictationEngine?
    ) {
        previousTask?.cancel()
        let task = Task {
            await previousTask?.value
            if let engine { await engine.cancel() }
        }
        lifecycleTask = task
    }

    private static func message(for error: Error) -> String {
        (error as? DictationError)?.errorDescription ?? error.localizedDescription
    }
}
