import AVFoundation
import Foundation
import Speech

/// iOS 26+ dictation via `SpeechAnalyzer` + `SpeechTranscriber`. Session
/// lifecycle and transcript state are actor-confined; the real-time audio
/// callback owns only a synchronized conversion sink.
@available(iOS 26.0, *)
actor SpeechAnalyzerDictationEngine: DictationEngine {
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<Void, Never>?
    private var audioSink: AnalyzerAudioInputSink?
    private var tapInstalled = false
    private var acceptsResults = false
    private var finalizedText = ""

    private let desiredLocale: Locale

    init() {
        desiredLocale = Locale.current
    }

    // MARK: - DictationEngine

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        finalizedText = ""
        acceptsResults = true
        guard await requestMicrophonePermission() else { throw DictationError.microphoneDenied }
        try Task.checkCancellation()

        let (transcriber, locale) = try await makeTranscriber()
        try Task.checkCancellation()
        try await ensureModelInstalled(for: transcriber, locale: locale)
        try Task.checkCancellation()
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw DictationError.unavailable(
                "Couldn't find a compatible audio format for dictation."
            )
        }
        try Task.checkCancellation()

        // Consume results as they stream in: commit finalized segments and track
        // the in-progress (volatile) tail, emitting the running transcript.
        resultsTask = Task { [weak self, transcriber] in
            var volatileText = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        volatileText = ""
                    } else {
                        volatileText = text
                    }
                    await self?.receiveResult(
                        text: text,
                        isFinal: result.isFinal,
                        volatileText: volatileText,
                        onPartial: onPartial
                    )
                }
            } catch {
                // Stream ended (or errored); finishTranscript returns what we have.
            }
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)
        try Task.checkCancellation()

        // Activating the recording session can change the hardware input format,
        // so resolve that format only after activation.
        try activateDictationAudioSession()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let sink = try AnalyzerAudioInputSink(
            inputFormat: inputFormat,
            analyzerFormat: format,
            continuation: inputBuilder
        )
        audioSink = sink

        // Mic capture -> convert to the analyzer format -> feed the input stream.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            sink.consume(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        try Task.checkCancellation()
    }

    func finishTranscript() async -> String {
        teardownAudio()
        audioSink?.finish()
        // Flush the trailing (volatile) audio into a final result, then wait for
        // the results task to drain it before reading the transcript.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        let text = finalizedText
        releaseModules()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        acceptsResults = false
        teardownAudio()
        resultsTask?.cancel()
        audioSink?.finish()
        await resultsTask?.value
        releaseModules()
    }

    // MARK: - Helpers

    private func receiveResult(
        text: String,
        isFinal: Bool,
        volatileText: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) {
        guard acceptsResults else { return }
        if isFinal { finalizedText += text }
        onPartial((finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func teardownAudio() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        deactivateDictationAudioSession()
    }

    private func releaseModules() {
        acceptsResults = false
        resultsTask = nil
        audioSink = nil
        analyzer = nil
        transcriber = nil
    }

    /// Build a transcriber for the best supported locale, preferring the user's.
    /// Returns the locale too, since `SpeechTranscriber` doesn't expose it.
    private func makeTranscriber() async throws -> (SpeechTranscriber, Locale) {
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = Self.bestLocale(for: desiredLocale, in: supported) else {
            throw DictationError.localeUnsupported
        }
        // Tuned for real-time feel: `.volatileResults` streams in-progress
        // guesses as you speak, and `.fastResults` lowers latency.
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
        let language = desired.language.languageCode?.identifier
        if let language,
           let sameLanguage = supported.first(where: {
               $0.language.languageCode?.identifier == language
           }) {
            return sameLanguage
        }
        return supported.first { $0.identifier(.bcp47) == "en-US" } ?? supported.first
    }

    /// Download + install the on-device model for this locale if iOS doesn't
    /// already have it. The asset is OS-managed and shared across apps.
    private func ensureModelInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        let installed = await Set(
            SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        )
        if installed.contains(locale.identifier(.bcp47)) { return }
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }
    }
}

/// Synchronous bridge used only by AVAudioEngine's real-time callback. The lock
/// serializes conversion/yield with `finish`, so the callback never observes a
/// converter or continuation being torn down underneath it.
@available(iOS 26.0, *)
private final class AnalyzerAudioInputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let analyzerFormat: AVAudioFormat
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init(
        inputFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw DictationError.unavailable("Couldn't prepare audio conversion for dictation.")
        }
        self.converter = converter
        self.analyzerFormat = analyzerFormat
        self.continuation = continuation
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let converter, let continuation,
                  let converted = convert(buffer, using: converter) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
            converter = nil
        }
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: capacity
        ) else { return nil }
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
