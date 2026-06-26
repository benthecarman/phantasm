import Foundation
import Observation
import UIKit
import WhisperKit

/// Drives on-device dictation: captures microphone audio while the user holds
/// the mic, then transcribes the whole recording once on stop.
///
/// We deliberately do *not* use WhisperKit's realtime `AudioStreamTranscriber`:
/// it only surfaces text after accumulating >1s buffers, drops the trailing
/// audio on stop, and runs transcriptions on the shared decoder concurrently
/// across sessions (which corrupts it after a few cycles). Capturing raw audio
/// and running a single `transcribe` on stop is reliable and loses nothing.
@MainActor
@Observable
final class DictationController {
    private let models: SpeechModels

    /// Capturing audio (the user is holding / locked-recording).
    private(set) var isRecording = false
    /// Stopped; transcribing the captured audio.
    private(set) var isTranscribing = false
    /// The finished transcript. The composer applies it, then calls `clearResult`.
    private(set) var result: String?
    /// User-facing error (mic denied, model download failed, …); nil when fine.
    private(set) var errorMessage: String?

    private var audioProcessor: AudioProcessor?
    /// Bumped each `start()`/`cancel()`; a session only applies its result while
    /// it's still the current generation.
    private var generation = 0

    init(models: SpeechModels) {
        self.models = models
    }

    func start() {
        guard !isRecording else { return }
        errorMessage = nil
        result = nil
        isTranscribing = false
        isRecording = true
        generation += 1
        let gen = generation
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        Task {
            // Ask for the mic up front so the prompt can't pop mid-recording.
            guard await AudioProcessor.requestRecordPermission() else {
                if gen == generation {
                    isRecording = false
                    errorMessage = "Microphone access is needed for dictation. Enable it in Settings."
                }
                return
            }
            guard gen == generation, isRecording else { return }

            let processor = AudioProcessor()
            do {
                try processor.startRecordingLive(callback: nil)
            } catch {
                if gen == generation {
                    isRecording = false
                    errorMessage = Self.message(for: error)
                }
                return
            }
            // The user may have released during the permission prompt.
            guard gen == generation, isRecording else {
                processor.stopRecording()
                return
            }
            self.audioProcessor = processor
            // Warm the model while the user speaks so stop → text is quick.
            Task { _ = try? await models.whisper() }
        }
    }

    /// Stop and transcribe the captured audio.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let processor = audioProcessor else { return }
        audioProcessor = nil
        let gen = generation
        isTranscribing = true

        Task {
            processor.stopRecording()
            let samples = Array(processor.audioSamples)
            // Need ~0.4s of audio to be worth transcribing.
            guard samples.count > WhisperKit.sampleRate / 2 else {
                if gen == generation { isTranscribing = false }
                return
            }
            do {
                let whisper = try await models.whisper()
                guard gen == generation else { return }
                let results = try await whisper.transcribe(audioArray: samples)
                guard gen == generation else { return }
                let text = results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                isTranscribing = false
                if !text.isEmpty { result = text }
            } catch {
                if gen == generation {
                    isTranscribing = false
                    errorMessage = Self.message(for: error)
                }
            }
        }
    }

    /// Stop and discard — no transcription.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        isTranscribing = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let processor = audioProcessor
        audioProcessor = nil
        generation += 1 // invalidate any in-flight transcription
        processor?.stopRecording()
    }

    /// Called by the composer once it has consumed `result`.
    func clearResult() {
        result = nil
    }

    private static func message(for error: Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain {
            return "Couldn't download the dictation model. Check your connection."
        }
        return error.localizedDescription
    }
}
