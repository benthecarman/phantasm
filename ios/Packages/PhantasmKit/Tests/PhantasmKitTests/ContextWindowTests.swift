import XCTest

@testable import PhantasmKit

final class ContextWindowTests: XCTestCase {
    private func msg(_ content: String, role: String = "user", isComplete: Bool = true) -> ChatMessage {
        ChatMessage(
            message: Message(
                conversationId: UUID(),
                role: role,
                content: content,
                isComplete: isComplete
            )
        )
    }

    func testEstimatesTokensFromCharacters() {
        // 40 characters / 4 chars-per-token = 10 tokens.
        let messages = [msg(String(repeating: "a", count: 40))]
        XCTAssertEqual(ContextWindow.estimatedTokens(for: messages), 10)
    }

    func testIncludesTextAttachmentsAndSkipsIncomplete() {
        let id = UUID()
        let withFile = ChatMessage(
            message: Message(id: id, conversationId: UUID(), role: "user", content: "abcd"),
            attachments: [
                Attachment(messageId: id, kind: .text, name: "f.txt", text: String(repeating: "x", count: 16))
            ]
        )
        // 4 content + 16 file = 20 chars / 4 = 5 tokens. The incomplete message is ignored.
        let messages = [withFile, msg(String(repeating: "z", count: 400), role: "assistant", isComplete: false)]
        XCTAssertEqual(ContextWindow.estimatedTokens(for: messages), 5)
    }

    func testImagesCarryFlatCost() {
        let id = UUID()
        let withImage = ChatMessage(
            message: Message(id: id, conversationId: UUID(), role: "user", content: ""),
            attachments: [Attachment(messageId: id, kind: .image, name: "p.jpg", data: Data([0x1, 0x2]))]
        )
        XCTAssertEqual(ContextWindow.estimatedTokens(for: [withImage]), ContextWindow.imageTokenCost)
    }

    func testUsageIsNilWhenWindowUnknown() {
        XCTAssertNil(ContextWindow.usage(for: [msg("hi")], contextLength: nil))
        XCTAssertNil(ContextWindow.usage(for: [msg("hi")], contextLength: 0))
    }

    func testNearLimitBand() {
        // ~850 tokens against a 1000 window = 0.85 → near limit, not over.
        let usage = ContextWindow.usage(
            for: [msg(String(repeating: "a", count: 3400))],
            contextLength: 1000
        )
        XCTAssertEqual(usage?.isNearLimit, true)
        XCTAssertEqual(usage?.isOverLimit, false)
    }

    func testOverLimitTakesPrecedenceOverNear() {
        // 1000 tokens against a 1000 window = at the limit → over, not "near".
        let usage = ContextWindow.usage(
            for: [msg(String(repeating: "a", count: 4000))],
            contextLength: 1000
        )
        XCTAssertEqual(usage?.isOverLimit, true)
        XCTAssertEqual(usage?.isNearLimit, false)
    }

    func testDisplayedFractionStaysInProgressRange() {
        XCTAssertEqual(
            ContextUsage(estimatedTokens: 1_250, contextLength: 1_000).displayedFraction,
            1
        )
        XCTAssertEqual(
            ContextUsage(estimatedTokens: -100, contextLength: 1_000).displayedFraction,
            0
        )
    }

    func testComfortablyUnderLimitDoesNotWarn() {
        let usage = ContextWindow.usage(for: [msg("short")], contextLength: 32768)
        XCTAssertEqual(usage?.isNearLimit, false)
        XCTAssertEqual(usage?.isOverLimit, false)
    }

    func testEstimatedGenerationThroughput() {
        XCTAssertEqual(
            ContextWindow.estimatedTokensPerSecond(characterCount: 400, duration: 2),
            50
        )
        XCTAssertNil(ContextWindow.estimatedTokensPerSecond(characterCount: 0, duration: 2))
        XCTAssertNil(ContextWindow.estimatedTokensPerSecond(characterCount: 400, duration: 0.01))
    }

    func testFormatTokens() {
        XCTAssertEqual(ContextWindow.formatTokens(512), "512")
        XCTAssertEqual(ContextWindow.formatTokens(8192), "8K")
        XCTAssertEqual(ContextWindow.formatTokens(32768), "32K")
        XCTAssertEqual(ContextWindow.formatTokens(131072), "128K")
        XCTAssertEqual(ContextWindow.formatTokens(1_048_576), "1.0M")
    }
}
