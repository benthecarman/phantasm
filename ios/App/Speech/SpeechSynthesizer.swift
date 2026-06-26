import AVFoundation
import Foundation
import Observation
import os
import PhantasmKit
import TTSKit

/// Reads assistant messages aloud with the on-device TTSKit / Qwen3-TTS model.
///
/// Only one message plays at a time; `speakingMessageID` lets each bubble show a
/// Speak/Stop toggle. Markdown is reduced to plain prose first (`SpeakableText`)
/// so URLs, code, and base64 image data aren't read out.
@MainActor
@Observable
final class SpeechSynthesizer {
    private let models: SpeechModels
    private let voicePrefs: VoicePreferenceStore

    /// The message currently being spoken, or nil when idle.
    private(set) var speakingMessageID: UUID?
    private(set) var errorMessage: String?

    private var task: Task<Void, Never>?
    /// Per-utterance stop flag, read from the (off-main, @Sendable) TTS callback.
    private var stopFlag = OSAllocatedUnfairLock(initialState: false)

    init(models: SpeechModels, voicePrefs: VoicePreferenceStore) {
        self.models = models
        self.voicePrefs = voicePrefs
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
        let instruction = voicePrefs.instruction
        let flag = OSAllocatedUnfairLock(initialState: false)
        stopFlag = flag

        task = Task {
            do {
                try Self.activateAudioSession()
                let tts = try await models.tts()
                var options = GenerationOptions()
                options.instruction = instruction
                _ = try await tts.play(text: spoken, options: options) { _ in
                    // Returning false cancels generation + streaming playback.
                    flag.withLock { $0 } ? false : true
                }
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                self.errorMessage = error.localizedDescription
            }
            Self.deactivateAudioSession()
            if self.speakingMessageID == messageID {
                self.speakingMessageID = nil
            }
        }
    }

    func stop() {
        stopFlag.withLock { $0 = true }
        task?.cancel()
        task = nil
        // Halt any audio already buffered so playback stops immediately.
        if let tts = models.loadedTTS {
            Task { await tts.audioOutput.stopPlayback(waitForCompletion: false) }
        }
        speakingMessageID = nil
        Self.deactivateAudioSession()
    }

    private static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    private static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
