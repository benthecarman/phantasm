import AVFoundation
import Foundation
import Speech

/// Dictation for iOS 18–25 (pre-`SpeechAnalyzer`) via `SFSpeechRecognizer`.
/// Streams mic buffers into a recognition request, prefers on-device
/// recognition, and returns the best transcription when stopped.
final class LegacySpeechDictationEngine: DictationEngine {
    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private let lock = NSLock()
    private var latestTranscript = ""
    private var finalReceived = false
    private var finalContinuation: CheckedContinuation<Void, Never>?

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - DictationEngine

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        try await ensureAuthorized()
        guard let recognizer else { throw DictationError.unavailable("Speech recognition isn't available.") }

        lock.withLock {
            latestTranscript = ""
            finalReceived = false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        try activateDictationAudioSession()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.withLock { self.latestTranscript = text }
                onPartial(text)
                if result.isFinal { self.signalFinal() }
            }
            if error != nil { self.signalFinal() }
        }
    }

    func finishTranscript() async -> String {
        teardownAudio()
        request?.endAudio()
        // Wait for the final-result callback, but don't hang if it never comes.
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.signalFinal()
        }
        await waitForFinal()
        timeout.cancel()
        let text = lock.withLock { latestTranscript }
        cleanup()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        teardownAudio()
        task?.cancel()
        request?.endAudio()
        signalFinal()
        cleanup()
    }

    // MARK: - Helpers

    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        deactivateDictationAudioSession()
    }

    private func cleanup() {
        task = nil
        request = nil
    }

    /// Ensure mic + speech-recognition permission and that a recognizer exists.
    private func ensureAuthorized() async throws {
        guard await requestMicrophonePermission() else { throw DictationError.microphoneDenied }
        try await requestSpeechAuthorization()
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.unavailable("Speech recognition isn't available right now.")
        }
    }

    private func requestSpeechAuthorization() async throws {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw DictationError.speechRecognitionDenied }
    }

    /// Resume the waiter exactly once, whether triggered by a final result, an
    /// error, the stop timeout, or cancellation.
    private func signalFinal() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            if finalReceived { return nil }
            finalReceived = true
            let cont = finalContinuation
            finalContinuation = nil
            return cont
        }
        continuation?.resume()
    }

    private func waitForFinal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFinal = lock.withLock { () -> Bool in
                if finalReceived { return true }
                finalContinuation = continuation
                return false
            }
            if alreadyFinal { continuation.resume() }
        }
    }
}
