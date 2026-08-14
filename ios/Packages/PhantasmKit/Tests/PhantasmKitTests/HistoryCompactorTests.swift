import XCTest
@testable import PhantasmKit

final class HistoryCompactorTests: XCTestCase {
    private let conversationID = UUID()

    private func chat(
        role: String,
        content: String,
        position: Int,
        toolCalls: String? = nil,
        toolCallID: String? = nil,
        attachments: [Attachment] = []
    ) -> ChatMessage {
        ChatMessage(
            message: Message(
                conversationId: conversationID,
                role: role,
                content: content,
                toolCalls: toolCalls,
                toolCallId: toolCallID,
                position: position
            ),
            attachments: attachments
        )
    }

    func testShortHistoryStaysVerbatim() {
        let history = [
            chat(role: "user", content: "hello", position: 1),
            chat(role: "assistant", content: "hi", position: 2),
        ]

        let prepared = HistoryCompactor.prepare(history, contextLength: 8_192)

        XCTAssertEqual(prepared.messages, history)
        XCTAssertNil(prepared.earlierSummary)
    }

    func testLargeOlderPrefixBecomesSummaryAndNewestMessageRemains() {
        let history = [
            chat(role: "user", content: "old " + String(repeating: "x", count: 3_000), position: 1),
            chat(role: "assistant", content: "middle " + String(repeating: "y", count: 3_000), position: 2),
            chat(role: "user", content: "newest " + String(repeating: "z", count: 3_000), position: 3),
        ]

        let prepared = HistoryCompactor.prepare(history, contextLength: 4_096)

        XCTAssertEqual(prepared.messages.map(\.message.position), [3])
        XCTAssertTrue(prepared.earlierSummary?.contains("User: old") == true)
        XCTAssertTrue(prepared.earlierSummary?.contains("Assistant: middle") == true)
        XCTAssertEqual(prepared.wireHistory().first?.role, "system")
    }

    func testToolCallAndResultsAreNeverSplit() {
        let history = [
            chat(role: "user", content: String(repeating: "o", count: 5_000), position: 1),
            chat(
                role: "assistant",
                content: String(repeating: "a", count: 1_500),
                position: 2,
                toolCalls: #"[{"id":"call-1"}]"#
            ),
            chat(
                role: "tool",
                content: String(repeating: "t", count: 1_500),
                position: 3,
                toolCallID: "call-1"
            ),
        ]

        let prepared = HistoryCompactor.prepare(history, contextLength: 4_096)

        XCTAssertEqual(prepared.messages.map(\.message.position), [2, 3])
    }

    func testOnlyRetainedInferenceImagesAreHydrated() {
        let oldMessageID = UUID()
        let newMessageID = UUID()
        let oldImage = Attachment(
            messageId: oldMessageID,
            kind: .image,
            name: "old.jpg"
        )
        let newImage = Attachment(
            messageId: newMessageID,
            kind: .image,
            name: "new.jpg"
        )
        let history = [
            chat(
                role: "user",
                content: String(repeating: "o", count: 5_000),
                position: 1,
                attachments: [oldImage]
            ),
            chat(
                role: "user",
                content: "latest image",
                position: 2,
                attachments: [newImage]
            ),
        ]

        let prepared = HistoryCompactor.prepare(history, contextLength: 4_096)
        XCTAssertEqual(prepared.requiredAttachmentIDs, [newImage.id])

        let bytes = Data([1, 2, 3])
        let hydrated = prepared.hydratingAttachments(from: [newImage.id: bytes])
        XCTAssertEqual(hydrated.messages.first?.attachments.first?.data, bytes)
    }
}
