import AVFoundation
import Foundation
import Speech

/// iOS 26+ dictation via `SpeechAnalyzer` + `SpeechTranscriber`. Captures mic
/// audio with `AVAudioEngine`, converts it to the analyzer's preferred format,
/// streams it in, and accumulates finalized transcript segments.
@available(iOS 26.0, *)
final class SpeechAnalyzerDictationEngine: DictationEngine {
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    /// Accumulated finalized transcript. Mutated from the results task and read
    /// when finishing, so guard it with a lock.
    private let lock = NSLock()
    private var finalizedText = ""

    private let desiredLocale: Locale

    init() {
        desiredLocale = Locale.current
    }

    // MARK: - DictationEngine

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        lock.withLock { finalizedText = "" }
        guard await requestMicrophonePermission() else { throw DictationError.microphoneDenied }

        let (transcriber, locale) = try await makeTranscriber()
        try await ensureModelInstalled(for: transcriber, locale: locale)
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.unavailable("Couldn't find a compatible audio format for dictation.")
        }
        analyzerFormat = format

        // Consume results as they stream in: commit finalized segments and track
        // the in-progress (volatile) tail, emitting the running transcript.
        resultsTask = Task { [weak self] in
            guard let self, let transcriber = self.transcriber else { return }
            var volatileText = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.lock.withLock { self.finalizedText += text }
                        volatileText = ""
                    } else {
                        volatileText = text
                    }
                    let finalized = self.lock.withLock { self.finalizedText }
                    onPartial((finalized + volatileText).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } catch {
                // Stream ended (or errored); finishTranscript returns what we have.
            }
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder
        try await analyzer.start(inputSequence: inputSequence)

        // Mic capture → convert to the analyzer format → feed the input stream.
        try activateDictationAudioSession()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: format)
        // Small buffer → audio reaches the analyzer sooner (lower latency).
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }
            self.inputBuilder?.yield(AnalyzerInput(buffer: converted))
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    func finishTranscript() async -> String {
        teardownAudio()
        inputBuilder?.finish()
        inputBuilder = nil
        // Flush the trailing (volatile) audio into a final result, then wait for
        // the results task to drain it before reading the transcript.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        let text = lock.withLock { finalizedText }
        releaseModules()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        teardownAudio()
        resultsTask?.cancel()
        resultsTask = nil
        inputBuilder?.finish()
        inputBuilder = nil
        releaseModules()
    }

    // MARK: - Helpers

    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        converter = nil
        deactivateDictationAudioSession()
    }

    private func releaseModules() {
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
    }

    /// Build a transcriber for the best supported locale, preferring the user's.
    /// Returns the locale too, since `SpeechTranscriber` doesn't expose it.
    private func makeTranscriber() async throws -> (SpeechTranscriber, Locale) {
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = Self.bestLocale(for: desiredLocale, in: supported) else {
            throw DictationError.localeUnsupported
        }
        // Tuned for real-time feel: `.volatileResults` streams in-progress
        // guesses as you speak, and `.fastResults` lowers latency (trading a
        // little accuracy) so text appears with minimal delay.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        return (transcriber, locale)
    }

    private static func bestLocale(for desired: Locale, in supported: [Locale]) -> Locale? {
        let desiredID = desired.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == desiredID }) {
            return exact
        }
        // Same language, different region (e.g. desired en-GB, available en-US).
        let lang = desired.language.languageCode?.identifier
        if let lang, let sameLanguage = supported.first(where: { $0.language.languageCode?.identifier == lang }) {
            return sameLanguage
        }
        return supported.first { $0.identifier(.bcp47) == "en-US" } ?? supported.first
    }

    /// Download + install the on-device model for this locale if iOS doesn't
    /// already have it. The asset is OS-managed and shared across apps.
    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if installed.contains(locale.identifier(.bcp47)) { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// Convert a mic buffer to the analyzer's format (handles sample-rate change).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let analyzerFormat else { return nil }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
