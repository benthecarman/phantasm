import Foundation
import Observation
import TTSKit
import WhisperKit

/// Owns the on-device speech pipelines (WhisperKit for dictation, TTSKit /
/// Qwen3-TTS for read-aloud) and tracks their load state for the UI.
///
/// Both models are *downloaded at first use* (not bundled) and cached on disk by
/// the Argmax SDK, so construction is async and can take a while the first time
/// (and needs network). We build each lazily, cache the instance, and coalesce
/// concurrent callers onto a single in-flight load.
@MainActor
@Observable
final class SpeechModels {
    /// Coarse readiness for a pipeline. The first load includes a model download;
    /// we don't surface a byte-level fraction (the SDK's auto-download path
    /// doesn't expose one cleanly), just "preparing".
    enum Status: Equatable {
        case notLoaded
        case preparing
        case ready
        case failed(String)
    }

    private(set) var sttStatus: Status = .notLoaded
    private(set) var ttsStatus: Status = .notLoaded

    /// The loaded TTS instance, once ready — used by `SpeechSynthesizer` to stop
    /// playback synchronously without re-awaiting the loader.
    private(set) var loadedTTS: TTSKit?

    private var whisperTask: Task<WhisperKit, Error>?
    private var ttsTask: Task<TTSKit, Error>?

    /// Lazily build (downloading on first use) and cache the WhisperKit pipeline.
    func whisper() async throws -> WhisperKit {
        if let whisperTask { return try await whisperTask.value }
        sttStatus = .preparing
        let task = Task { () -> WhisperKit in
            let kit = try await WhisperKit()
            // `WhisperKit()` doesn't always load the weights/tokenizer in its
            // initializer (it only does so when a model folder is already known),
            // so force a load — otherwise `tokenizer` is nil and dictation fails
            // with "model isn't ready".
            if kit.tokenizer == nil {
                try await kit.loadModels()
            }
            return kit
        }
        whisperTask = task
        do {
            let kit = try await task.value
            sttStatus = .ready
            return kit
        } catch {
            whisperTask = nil
            sttStatus = .failed(Self.message(for: error))
            throw error
        }
    }

    /// Lazily build (downloading the default Qwen3-TTS 0.6B model on first use)
    /// and cache the TTSKit pipeline.
    func tts() async throws -> TTSKit {
        if let ttsTask { return try await ttsTask.value }
        ttsStatus = .preparing
        let task = Task { try await TTSKit() }
        ttsTask = task
        do {
            let kit = try await task.value
            loadedTTS = kit
            ttsStatus = .ready
            return kit
        } catch {
            ttsTask = nil
            ttsStatus = .failed(Self.message(for: error))
            throw error
        }
    }

    /// Begin loading both pipelines in the background (e.g. from Settings) so the
    /// first dictation / read-aloud isn't gated on a cold download.
    func prepareAll() {
        Task { _ = try? await whisper() }
        Task { _ = try? await tts() }
    }

    private static func message(for error: Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain {
            return "Couldn't download the speech model. Check your connection and try again."
        }
        return error.localizedDescription
    }
}
