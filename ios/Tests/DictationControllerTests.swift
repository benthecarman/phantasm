import Foundation
@testable import Phantasm
import XCTest

@MainActor
final class DictationControllerTests: XCTestCase {
    func testLateFinalTranscriptCannotCrossConversationOwnership() async throws {
        let firstEngine = FakeDictationEngine()
        let secondEngine = FakeDictationEngine()
        let factory = FakeDictationEngineFactory([firstEngine, secondEngine])
        let controller = DictationController { factory.next() }
        let firstConversation = UUID()
        let secondConversation = UUID()

        controller.start(ownerID: firstConversation)
        try await waitUntil { await firstEngine.didStart }
        await firstEngine.emitPartial("first partial")
        try await waitUntil { controller.liveTranscript == "first partial" }

        controller.stop(ownerID: firstConversation)
        XCTAssertTrue(controller.isTranscribing)

        controller.start(ownerID: secondConversation)
        XCTAssertEqual(controller.ownerID, secondConversation)
        XCTAssertEqual(controller.liveTranscript, "")
        XCTAssertTrue(controller.isPreparing)
        XCTAssertFalse(controller.isRecording)
        let secondStartedBeforeFirstFinished = await secondEngine.didStart
        XCTAssertFalse(secondStartedBeforeFirstFinished)

        await firstEngine.resolveFinish(with: "first final")
        try await waitUntil { await secondEngine.didStart && controller.isRecording }
        XCTAssertEqual(controller.ownerID, secondConversation)
        XCTAssertEqual(controller.liveTranscript, "")
        XCTAssertFalse(controller.isPreparing)

        await secondEngine.emitPartial("second partial")
        try await waitUntil { controller.liveTranscript == "second partial" }
        controller.cancel(ownerID: secondConversation)
    }

    func testRelinquishingOwnershipInvalidatesFinalization() async throws {
        let engine = FakeDictationEngine()
        let nextEngine = FakeDictationEngine()
        let factory = FakeDictationEngineFactory([engine, nextEngine])
        let controller = DictationController { factory.next() }
        let conversation = UUID()

        controller.start(ownerID: conversation)
        try await waitUntil { await engine.didStart }
        controller.stop(ownerID: conversation)
        XCTAssertTrue(controller.isTranscribing)

        controller.relinquish(ownerID: conversation)
        XCTAssertNil(controller.ownerID)
        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isTranscribing)

        await engine.resolveFinish(with: "too late")
        let nextConversation = UUID()
        controller.start(ownerID: nextConversation)
        try await waitUntil { await nextEngine.didStart && controller.isRecording }
        XCTAssertEqual(controller.liveTranscript, "")
        controller.cancel(ownerID: nextConversation)
    }

    func testInterruptionCancelsOnlyOwningConversation() async throws {
        let engine = FakeDictationEngine()
        let factory = FakeDictationEngineFactory([engine])
        let controller = DictationController { factory.next() }
        let owner = UUID()

        controller.start(ownerID: owner)
        try await waitUntil { await engine.didStart }

        controller.interrupt(ownerID: UUID())
        XCTAssertTrue(controller.isRecording)

        controller.interrupt(ownerID: owner)
        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isTranscribing)
        XCTAssertEqual(controller.ownerID, owner)
        XCTAssertEqual(
            controller.errorMessage,
            "Dictation stopped because audio was interrupted."
        )
        try await waitUntil { await engine.cancelCount == 1 }
    }

    func testRelinquishingDuringStartupPreventsLaterCapture() async throws {
        let engine = FakeDictationEngine(suspendsStart: true)
        let factory = FakeDictationEngineFactory([engine])
        let controller = DictationController { factory.next() }
        let owner = UUID()

        controller.start(ownerID: owner)
        try await waitUntil { await engine.didEnterStart }
        XCTAssertTrue(controller.isPreparing)
        XCTAssertFalse(controller.isRecording)

        controller.relinquish(ownerID: owner)
        XCTAssertNil(controller.ownerID)
        XCTAssertFalse(controller.isPreparing)

        await engine.resumeStart()
        try await waitUntil {
            let finished = await engine.startFinished
            let cancellations = await engine.cancelCount
            return finished && cancellations > 0
        }
        let capturedAfterRelinquishing = await engine.didStart
        XCTAssertFalse(capturedAfterRelinquishing)
    }

    func testStopWhilePreparingCancelsWithoutStartingCapture() async throws {
        let engine = FakeDictationEngine(suspendsStart: true)
        let factory = FakeDictationEngineFactory([engine])
        let controller = DictationController { factory.next() }
        let owner = UUID()

        controller.start(ownerID: owner)
        try await waitUntil { await engine.didEnterStart }
        controller.stop(ownerID: owner)

        XCTAssertFalse(controller.isPreparing)
        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isTranscribing)

        await engine.resumeStart()
        try await waitUntil {
            let finished = await engine.startFinished
            let cancellations = await engine.cancelCount
            return finished && cancellations > 0
        }
        let capturedAfterStopping = await engine.didStart
        XCTAssertFalse(capturedAfterStopping)
        XCTAssertEqual(controller.liveTranscript, "")
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

@MainActor
private final class FakeDictationEngineFactory {
    private var engines: [FakeDictationEngine]

    init(_ engines: [FakeDictationEngine]) {
        self.engines = engines
    }

    func next() -> any DictationEngine {
        precondition(!engines.isEmpty, "No scripted dictation engine remains")
        return engines.removeFirst()
    }
}

private actor FakeDictationEngine: DictationEngine {
    private let suspendsStart: Bool
    private(set) var didEnterStart = false
    private(set) var didStart = false
    private(set) var startFinished = false
    private(set) var cancelCount = 0
    private var onPartial: (@Sendable (String) -> Void)?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<String, Never>?
    private var pendingFinish: String?

    init(suspendsStart: Bool = false) {
        self.suspendsStart = suspendsStart
    }

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        didEnterStart = true
        defer { startFinished = true }
        if suspendsStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        try Task.checkCancellation()
        self.onPartial = onPartial
        didStart = true
    }

    func finishTranscript() async -> String {
        if let pendingFinish {
            self.pendingFinish = nil
            return pendingFinish
        }
        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func cancel() async {
        cancelCount += 1
        finishContinuation?.resume(returning: "")
        finishContinuation = nil
    }

    func emitPartial(_ text: String) {
        onPartial?(text)
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resolveFinish(with text: String) {
        if let finishContinuation {
            self.finishContinuation = nil
            finishContinuation.resume(returning: text)
        } else {
            pendingFinish = text
        }
    }
}
