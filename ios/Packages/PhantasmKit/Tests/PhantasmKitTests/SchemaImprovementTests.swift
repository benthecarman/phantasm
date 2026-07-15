import XCTest
@testable import PhantasmKit

/// The write-time invariants the collapsed schema leans on: inline base64
/// images never reach persisted content (extracted to attachment rows, restored
/// on the wire), `position` is the one message order, and per-chat tool
/// settings round-trip through their single JSON column.
final class SchemaImprovementTests: XCTestCase {
    // A tiny valid payload; the round-trip must be byte-exact.
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
    private var pngB64: String { pngBytes.base64EncodedString() }

    private func makeConversation(_ db: AppDatabase) async throws -> Conversation {
        let convo = Conversation(title: "Chat")
        try await db.insertConversation(convo)
        return convo
    }

    // MARK: - Inline image extraction

    func testInsertExtractsInlineImageAndWireRestoresIt() async throws {
        let db = try AppDatabase.empty()
        let convo = try await makeConversation(db)
        let original = "Here you go:\n\n![generated](data:image/png;base64,\(pngB64))\n\nEnjoy!"
        try await db.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: original),
            attachments: []
        )

        let detail = try await db.conversationDetail(id: convo.id)
        let stored = try XCTUnwrap(detail?.messages.first)
        // Persisted content is compact: a phantasm-file:// link, no base64.
        XCTAssertFalse(stored.message.content.contains("base64"))
        XCTAssertTrue(stored.message.content.contains("![generated](phantasm-file://"))
        XCTAssertTrue(stored.message.content.hasSuffix("Enjoy!"))
        // The payload lives in an inline_image attachment row.
        let inline = stored.attachments.filter { $0.kind == AttachmentKind.inlineImage.rawValue }
        XCTAssertEqual(inline.map(\.data), [pngBytes])
        XCTAssertEqual(inline.first?.mimeType, "image/png")
        // The wire sees exactly the markdown the model produced.
        guard case .text(let wire) = stored.wireContent() else {
            return XCTFail("expected plain text wire content")
        }
        XCTAssertEqual(wire, original)
    }

    func testPersistedInlineImageRendersThroughBinaryPlaceholder() {
        let result = InlineImageRef.placeholders(
            in: "![generated](phantasm-file://saved-id)",
            images: ["saved-id": .init(data: pngBytes, mime: "image/png")]
        )
        XCTAssertEqual(result.markdown, "![generated](phantasm-img://0)")
        XCTAssertEqual(result.images, [0: pngBytes])
        XCTAssertFalse(result.markdown.contains("base64"))
    }

    func testContentRewriteReplacesExtractedImages() async throws {
        let db = try AppDatabase.empty()
        let convo = try await makeConversation(db)
        let message = Message(
            conversationId: convo.id, role: "assistant",
            content: "![a](data:image/png;base64,\(pngB64))"
        )
        try await db.insertMessage(message, attachments: [])

        let newBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let newContent = "now a jpeg ![b](data:image/jpeg;base64,\(newBytes.base64EncodedString()))"
        try await db.updateMessage(
            id: message.id, content: newContent, reasoning: "", isComplete: true, createdAt: nil
        )

        let detail = try await db.conversationDetail(id: convo.id)
        let stored = try XCTUnwrap(detail?.messages.first)
        let inline = stored.attachments.filter { $0.kind == AttachmentKind.inlineImage.rawValue }
        // The old row is gone; only the new image remains.
        XCTAssertEqual(inline.map(\.data), [newBytes])
        XCTAssertEqual(inline.first?.mimeType, "image/jpeg")
    }

    func testReasoningDurationPersistsOnCompletion() async throws {
        let db = try AppDatabase.empty()
        let convo = try await makeConversation(db)
        let message = Message(
            conversationId: convo.id,
            role: "assistant",
            content: "",
            reasoning: "",
            isComplete: false
        )
        try await db.insertMessage(message, attachments: [])

        try await db.updateMessage(
            id: message.id,
            content: "answer",
            reasoning: "thinking",
            reasoningDuration: 12.5,
            isComplete: true,
            createdAt: nil
        )

        let detail = try await db.conversationDetail(id: convo.id)
        let stored = try XCTUnwrap(detail?.messages.first?.message)
        XCTAssertEqual(stored.reasoningDuration, 12.5)
    }

    func testUndecodablePayloadIsDroppedNotStored() async throws {
        let db = try AppDatabase.empty()
        let convo = try await makeConversation(db)
        // Valid base64 charset, invalid length — matches the pattern but
        // fails strict decoding.
        let message = Message(
            conversationId: convo.id, role: "assistant",
            content: "broken ![x](data:image/png;base64,AAAAA) end"
        )
        try await db.insertMessage(message, attachments: [])
        let detail = try await db.conversationDetail(id: convo.id)
        let stored = try XCTUnwrap(detail?.messages.first)
        XCTAssertEqual(stored.message.content, "broken *(image)* end")
        XCTAssertTrue(stored.attachments.isEmpty)
    }

    func testSearchStillMatchesTextAroundExtractedImage() async throws {
        let db = try AppDatabase.empty()
        let convo = try await makeConversation(db)
        try await db.insertMessage(
            Message(
                conversationId: convo.id, role: "assistant",
                content: "A watercolor of Lisbon ![generated](data:image/png;base64,\(pngB64))"
            ),
            attachments: []
        )
        let hits = try await db.searchConversations(matching: "watercolor")
        XCTAssertEqual(hits.map(\.id), [convo.id])
    }

    // MARK: - Position ordering

    func testPositionOrdersSameTimestampInserts() async throws {
        let db = try AppDatabase.empty()
        let convo = try await makeConversation(db)
        // Burst inserts with an identical createdAt — the tool-flow shape that
        // used to need rowid tie-breaking.
        let stamp = Date()
        for text in ["first", "second", "third"] {
            try await db.insertMessage(
                Message(conversationId: convo.id, role: "assistant", content: text, createdAt: stamp),
                attachments: []
            )
        }
        let detail = try await db.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.map(\.message.content), ["first", "second", "third"])
        XCTAssertEqual(detail?.messages.map(\.message.position), [1, 2, 3])
    }

    func testTruncationCutsByPositionNotTimestamp() async throws {
        let db = try AppDatabase.empty()
        let convo = try await makeConversation(db)
        let stamp = Date()
        let messages = ["keep", "drop-a", "drop-b"].map {
            Message(conversationId: convo.id, role: "user", content: $0, createdAt: stamp)
        }
        for m in messages {
            try await db.insertMessage(m, attachments: [])
        }
        try await db.deleteMessagesAfter(id: messages[0].id)
        let detail = try await db.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.map(\.message.content), ["keep"])

        // A completion-time createdAt restamp can no longer reorder anything.
        try await db.updateMessage(
            id: messages[0].id, content: "keep", reasoning: "",
            isComplete: true, createdAt: stamp.addingTimeInterval(120)
        )
        let after = try await db.conversationDetail(id: convo.id)
        XCTAssertEqual(after?.messages.first?.message.position, 1)
    }

    // MARK: - Tool settings

    func testToolSettingsRoundTripThroughStore() async throws {
        let db = try AppDatabase.empty()
        let settings = ToolSettings(
            webSearch: false, imageGeneration: true, location: true, health: false, calendar: true
        )
        let convo = Conversation(title: "Chat", toolSettings: settings, turnModeID: "deep-research")
        try await db.insertConversation(convo)
        try await db.setConversationOptions(
            id: convo.id,
            toolSettings: ToolSettings(webSearch: true, imageGeneration: false),
            turnModeID: nil
        )
        let fetched = try await db.conversationDetail(id: convo.id)?.conversation
        XCTAssertEqual(fetched?.toolSettings, ToolSettings(webSearch: true, imageGeneration: false))
        XCTAssertNil(fetched?.turnModeID)
    }

    // MARK: - On-disk store

    func testOnDiskStoreReopensWithDataIntact() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("phantasm.sqlite")

        let convo = Conversation(title: "Keep me")
        do {
            let db = try AppDatabase.open(at: url)
            try await db.insertConversation(convo)
        }
        let reopened = try AppDatabase.open(at: url)
        let fetched = try await reopened.reader.read { db in
            try Conversation.fetchOne(db, key: convo.id)
        }
        XCTAssertEqual(fetched?.title, "Keep me")
    }

    func testAttachmentLookupHasChildKeyIndex() throws {
        let db = try AppDatabase.empty()
        let columns = try db.reader.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_index_info('attachment_message_created_at') ORDER BY seqno"
            )
        }
        XCTAssertEqual(columns, ["messageId", "createdAt"])
    }

    // MARK: - Tool settings forward compatibility

    func testToolSettingsDecodeDefaultsMissingKeys() throws {
        // A future field must decode to its default from rows written before
        // it existed — that's the whole point of the JSON column.
        let partial = #"{"webSearch": false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ToolSettings.self, from: partial)
        XCTAssertFalse(decoded.webSearch)
        XCTAssertTrue(decoded.imageGeneration)
        XCTAssertFalse(decoded.location)
    }
}
