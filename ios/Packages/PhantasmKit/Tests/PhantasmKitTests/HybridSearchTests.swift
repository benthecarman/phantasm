import XCTest
@testable import PhantasmKit

/// Deterministic embedder for tests: texts map to fixed axes by keyword, so
/// "semantic similarity" is scriptable without a real model. Vectors are
/// normalized, matching the `TextEmbedder` contract.
private struct StubEmbedder: TextEmbedder {
    var identifier = "stub.v1"
    /// keyword (contained in the text, case-insensitive) → vector
    var axes: [String: [Float]]
    var failsForTextContaining: Set<String> = []

    func prepareIfNeeded() async throws {}

    func embed(_ text: String) async throws -> [Float] {
        let lowered = text.lowercased()
        for needle in failsForTextContaining where lowered.contains(needle) {
            throw ContextualTextEmbedder.EmbedderError.emptyEmbedding
        }
        var sum = [Float](repeating: 0, count: 3)
        for (needle, axis) in axes where lowered.contains(needle) {
            for i in axis.indices { sum[i] += axis[i] }
        }
        return VectorCodec.normalized(sum)
    }
}

final class HybridSearchTests: XCTestCase {
    private let travelAxes: [String: [Float]] = [
        "portugal": [1, 0, 0], "trip": [1, 0, 0], "vacation": [1, 0, 0],
        "compiler": [0, 1, 0], "swift": [0, 1, 0],
    ]

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.empty()
    }

    @discardableResult
    private func insertConversation(
        _ db: AppDatabase, title: String, messages: [String], role: String = "user"
    ) async throws -> Conversation {
        let convo = Conversation(title: title)
        try await db.insertConversation(convo)
        for content in messages {
            try await db.insertMessage(
                Message(conversationId: convo.id, role: role, content: content),
                attachments: []
            )
        }
        return convo
    }

    private func embeddingRowCount(_ db: AppDatabase) throws -> Int {
        try db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_embedding") ?? 0
        }
    }

    private func index(_ db: AppDatabase, embedder: StubEmbedder) async {
        await EmbeddingIndexer(database: db, embedder: embedder).indexPending()
    }

    // MARK: - VectorCodec

    func testVectorCodecRoundTrip() {
        let vector: [Float] = [0.25, -1, 3.5, 0]
        XCTAssertEqual(VectorCodec.decode(VectorCodec.encode(vector)), vector)
        XCTAssertEqual(VectorCodec.decode(Data()), [])
    }

    func testNormalizedAndDot() {
        let normalized = VectorCodec.normalized([3, 4])
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.0001)
        XCTAssertEqual(VectorCodec.dot(normalized, normalized), 1, accuracy: 0.0001)
        // Zero vector stays zero rather than dividing by zero.
        XCTAssertEqual(VectorCodec.normalized([0, 0]), [0, 0])
        // Mismatched lengths are incomparable, not a crash.
        XCTAssertEqual(VectorCodec.dot([1], [1, 0]), 0)
    }

    // MARK: - RRF fusion

    private func result(_ id: UUID, title: String = "t", snippet: String? = nil) -> ConversationSearchResult {
        ConversationSearchResult(
            conversation: Conversation(id: id, title: title), snippet: snippet
        )
    }

    func testFuseRanksDoubleListedConversationFirst() {
        let both = UUID(), keywordOnly = UUID(), semanticOnly = UUID()
        let fused = HybridSearchRanker.fuse(
            keyword: [result(keywordOnly), result(both)],
            semantic: [result(semanticOnly), result(both)]
        )
        XCTAssertEqual(fused.map(\.id), [both, keywordOnly, semanticOnly])
    }

    func testFusePrefersKeywordSnippetAndFillsMissingFromSemantic() {
        let a = UUID(), b = UUID()
        let fused = HybridSearchRanker.fuse(
            keyword: [result(a, snippet: "keyword snip"), result(b, snippet: nil)],
            semantic: [result(a, snippet: "semantic snip"), result(b, snippet: "filled")]
        )
        XCTAssertEqual(fused.first { $0.id == a }?.snippet, "keyword snip")
        XCTAssertEqual(fused.first { $0.id == b }?.snippet, "filled")
    }

    func testFuseWithEmptySemanticPreservesKeywordOrder() {
        let a = UUID(), b = UUID()
        let fused = HybridSearchRanker.fuse(
            keyword: [result(a), result(b)], semantic: []
        )
        XCTAssertEqual(fused.map(\.id), [a, b])
    }

    // MARK: - Indexer

    func testIndexerEmbedsOnlyCompletedChatMessagesWithText() async throws {
        let db = try makeDatabase()
        let convo = try await insertConversation(db, title: "Chat", messages: ["hello portugal"])
        // Ineligible rows: tool-role, incomplete, and empty content.
        try await db.insertMessage(
            Message(conversationId: convo.id, role: "tool", content: "result", toolCallId: "t1"),
            attachments: []
        )
        try await db.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "", isComplete: false),
            attachments: []
        )
        try await db.insertMessage(
            Message(conversationId: convo.id, role: "user", content: "   "),
            attachments: []
        )

        await index(db, embedder: StubEmbedder(axes: travelAxes))

        XCTAssertEqual(try embeddingRowCount(db), 1)
        let pending = try await db.messagesNeedingEmbedding(model: "stub.v1", limit: 10)
        XCTAssertTrue(pending.isEmpty)
    }

    func testContentRewriteInvalidatesAndReindexes() async throws {
        let db = try makeDatabase()
        let embedder = StubEmbedder(axes: travelAxes)
        let convo = try await insertConversation(db, title: "Chat", messages: ["all about portugal"])
        await index(db, embedder: embedder)

        let messageID = try await db.reader.read { db in
            try Message.fetchOne(db)!.id
        }
        try await db.updateMessage(
            id: messageID, content: "actually the swift compiler",
            reasoning: "", isComplete: true, createdAt: nil
        )
        let pending = try await db.messagesNeedingEmbedding(model: "stub.v1", limit: 10)
        XCTAssertEqual(pending.map(\.id), [messageID])

        await index(db, embedder: embedder)
        let hits = try await db.reader.read { db in
            try AppDatabase.semanticSearch(db, queryVector: [0, 1, 0], model: "stub.v1")
        }
        XCTAssertEqual(hits.map(\.id), [convo.id])
    }

    func testEmbedFailureMarksRowUnembeddableAndSearchSkipsIt() async throws {
        let db = try makeDatabase()
        var embedder = StubEmbedder(axes: travelAxes)
        embedder.failsForTextContaining = ["poison"]
        try await insertConversation(db, title: "Bad", messages: ["poison text"])
        await index(db, embedder: embedder)

        // Stored (as an empty sentinel), so it's no longer a candidate…
        XCTAssertEqual(try embeddingRowCount(db), 1)
        let pending = try await db.messagesNeedingEmbedding(model: "stub.v1", limit: 10)
        XCTAssertTrue(pending.isEmpty)
        // …and never surfaces as a hit.
        let hits = try await db.reader.read { db in
            try AppDatabase.semanticSearch(db, queryVector: [1, 0, 0], model: "stub.v1")
        }
        XCTAssertTrue(hits.isEmpty)
    }

    func testModelRevisionBumpReembedsAndPrunesOldGeneration() async throws {
        let db = try makeDatabase()
        try await insertConversation(db, title: "Chat", messages: ["trip planning"])
        await index(db, embedder: StubEmbedder(axes: travelAxes))

        // The bumped revision sees the message as unembedded (old vectors are
        // incomparable)…
        let pending = try await db.messagesNeedingEmbedding(model: "stub.v2", limit: 10)
        XCTAssertEqual(pending.count, 1)

        // …and a full pass with the new revision retires the old generation.
        var bumped = StubEmbedder(axes: travelAxes)
        bumped.identifier = "stub.v2"
        await index(db, embedder: bumped)
        let models = try await db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT model FROM message_embedding")
        }
        XCTAssertEqual(models, ["stub.v2"])
    }

    // MARK: - Semantic + hybrid search

    func testSemanticSearchRanksByBestMessageAndExcludesTombstoned() async throws {
        let db = try makeDatabase()
        let embedder = StubEmbedder(axes: travelAxes)
        let travel = try await insertConversation(
            db, title: "A", messages: ["my trip to portugal", "unrelated filler"]
        )
        let code = try await insertConversation(db, title: "B", messages: ["swift compiler bug"])
        let deleted = try await insertConversation(db, title: "C", messages: ["another portugal trip"])
        await index(db, embedder: embedder)
        try await db.deleteConversation(id: deleted.id)

        let hits = try await db.reader.read { db in
            try AppDatabase.semanticSearch(db, queryVector: [1, 0, 0], model: "stub.v1")
        }
        XCTAssertEqual(hits.first?.id, travel.id)
        XCTAssertFalse(hits.map(\.id).contains(deleted.id))
        XCTAssertTrue(hits.map(\.id).contains(code.id))
        XCTAssertEqual(hits.first?.snippet, "my trip to portugal")
    }

    func testHybridSearchFindsParaphraseWithNoKeywordOverlap() async throws {
        let db = try makeDatabase()
        let embedder = StubEmbedder(axes: travelAxes)
        let travel = try await insertConversation(db, title: "Planning", messages: ["my trip to portugal"])
        try await insertConversation(db, title: "Coding", messages: ["swift compiler bug"])
        await index(db, embedder: embedder)

        // "vacation" appears nowhere in the history — keyword search alone
        // returns nothing; the embedding axis rescues it.
        let vector = try await embedder.embed("vacation")
        let results = try await db.hybridSearchConversations(
            matching: "vacation", queryVector: vector, model: "stub.v1"
        )
        XCTAssertEqual(results.first?.id, travel.id)
    }

    func testHybridSearchRanksKeywordPlusSemanticAgreementFirst() async throws {
        let db = try makeDatabase()
        let embedder = StubEmbedder(axes: travelAxes)
        // Both conversations mention "swift"; only one is *about* the compiler.
        let compiler = try await insertConversation(
            db, title: "Build", messages: ["the swift compiler crashed"]
        )
        try await insertConversation(
            db, title: "Birds", messages: ["saw a swift flying south to portugal on my trip"]
        )
        await index(db, embedder: embedder)

        let vector = try await embedder.embed("swift compiler")
        let results = try await db.hybridSearchConversations(
            matching: "swift", queryVector: vector, model: "stub.v1"
        )
        XCTAssertEqual(results.first?.id, compiler.id)
        XCTAssertEqual(results.count, 2)
    }
}
