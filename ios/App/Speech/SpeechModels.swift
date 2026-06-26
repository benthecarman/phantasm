import Foundation
import Observation
import WhisperKit

/// Owns the on-device dictation pipeline (WhisperKit for speech-to-text) and
/// tracks its load state for the UI. Read-aloud (TTS) uses the system
/// `AVSpeechSynthesizer` directly (see `SpeechSynthesizer`) and needs no model.
///
/// The model is *downloaded at first use* (not bundled) and cached on disk by the
/// Argmax SDK, so construction is async and can take a while the first time (and
/// needs network). We build it lazily, cache the instance, and coalesce
/// concurrent callers onto a single in-flight load.
@MainActor
@Observable
final class SpeechModels {
    /// Coarse readiness for the pipeline. The first load includes a model
    /// download; we don't surface a byte-level fraction (the SDK's auto-download
    /// path doesn't expose one cleanly), just "preparing".
    enum Status: Equatable {
        case notLoaded
        case preparing
        case ready
        case failed(String)
    }

    private(set) var sttStatus: Status = .notLoaded

    private var whisperTask: Task<WhisperKit, Error>?

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

    /// Begin loading the dictation pipeline in the background (e.g. from Settings)
    /// so the first dictation isn't gated on a cold download.
    func prepareAll() {
        Task { _ = try? await whisper() }
    }

    private static func message(for error: Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain {
            return "Couldn't download the speech model. Check your connection and try again."
        }
        return error.localizedDescription
    }
}
