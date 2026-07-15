import AVFoundation
import Foundation
import Speech

/// Dictation for iOS 18–25 (pre-`SpeechAnalyzer`) via `SFSpeechRecognizer`.
/// All session lifecycle state is actor-confined. The audio callback sees only
/// a small synchronized sink, so teardown cannot nil/end a request while the
/// callback is appending to it.
actor LegacySpeechDictationEngine: DictationEngine {
    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioSink: LegacyAudioBufferSink?
    private var tapInstalled = false
    private var acceptsCallbacks = false
    private var recognitionGeneration: UInt = 0

    private var latestTranscript = ""
    private var finalReceived = false
    private var finalContinuation: CheckedContinuation<Void, Never>?

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - DictationEngine

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        try await ensureAuthorized()
        try Task.checkCancellation()
        guard let recognizer else {
            throw DictationError.unavailable("Speech recognition isn't available.")
        }

        latestTranscript = ""
        finalReceived = false
        acceptsCallbacks = true
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        let callbackQueue = LegacyRecognitionCallbackQueue()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let sink = LegacyAudioBufferSink(request: request)
        audioSink = sink

        // Permissions can outlive the owning chat/scene. Never activate the
        // microphone after the controller has cancelled this startup task.
        try Task.checkCancellation()
        try activateDictationAudioSession()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        try Task.checkCancellation()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let failed = error != nil
            callbackQueue.enqueue { [weak self] in
                await self?.receiveRecognition(
                    generation: generation,
                    text: text,
                    isFinal: isFinal,
                    failed: failed,
                    onPartial: onPartial
                )
            }
        }
    }

    func finishTranscript() async -> String {
        teardownAudio()
        audioSink?.finish()

        // Wait for the final-result callback, but don't hang if it never comes.
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.signalFinal()
        }
        await waitForFinal()
        timeout.cancel()
        let text = latestTranscript
        cleanup()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        acceptsCallbacks = false
        teardownAudio()
        recognitionTask?.cancel()
        audioSink?.finish()
        signalFinal()
        cleanup()
    }

    // MARK: - Helpers

    private func receiveRecognition(
        generation: UInt,
        text: String?,
        isFinal: Bool,
        failed: Bool,
        onPartial: @escaping @Sendable (String) -> Void
    ) {
        guard acceptsCallbacks,
              generation == recognitionGeneration else { return }
        if let text {
            latestTranscript = text
            onPartial(text)
        }
        if isFinal || failed { signalFinal() }
    }

    private func teardownAudio() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        deactivateDictationAudioSession()
    }

    private func cleanup() {
        acceptsCallbacks = false
        recognitionTask = nil
        audioSink = nil
        finalContinuation = nil
    }

    /// Ensure mic + speech-recognition permission and that a recognizer exists.
    private func ensureAuthorized() async throws {
        guard await requestMicrophonePermission() else { throw DictationError.microphoneDenied }
        try Task.checkCancellation()
        try await requestSpeechAuthorization()
        try Task.checkCancellation()
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.unavailable("Speech recognition isn't available right now.")
        }
    }

    private func requestSpeechAuthorization() async throws {
        let status = await withCheckedContinuation {
            (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw DictationError.speechRecognitionDenied }
    }

    /// Resume the waiter exactly once, whether triggered by a final result, an
    /// error, the stop timeout, or cancellation.
    private func signalFinal() {
        guard !finalReceived else { return }
        finalReceived = true
        let continuation = finalContinuation
        finalContinuation = nil
        continuation?.resume()
    }

    private func waitForFinal() async {
        guard !finalReceived else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if finalReceived {
                continuation.resume()
            } else {
                finalContinuation = continuation
            }
        }
    }
}

/// Preserves recognition callback order while their work crosses to the actor.
/// A terminal error can carry no transcript, so merely discarding older actor
/// jobs would lose the last valid partial if that error job ran first.
private final class LegacyRecognitionCallbackQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task {
                await previous?.value
                await operation()
            }
        }
    }
}

/// Bridges the real-time audio callback to the actor-owned lifecycle. AVAudioEngine
/// invokes the callback on its own thread, so request access must stay synchronous;
/// the lock makes `append` and `finish` mutually exclusive.
private final class LegacyAudioBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }

    func finish() {
        lock.withLock {
            request?.endAudio()
            request = nil
        }
    }
}
