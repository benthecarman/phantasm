import Foundation
import GRDB

/// GRDB-backed `ChatStore`: owns the SQLite connection, runs schema migrations
/// (incl. the FTS5 full-text indexes), and implements all writes/search.
///
/// Reactive reads in the UI use GRDBQuery against `reader` (see the app target);
/// this is the one place the read path touches GRDB directly.
public final class AppDatabase: Sendable {
    private let dbWriter: any DatabaseWriter

    /// Read access for GRDBQuery's database context.
    public var reader: any DatabaseReader { dbWriter }

    private init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    /// On-disk database in Application Support (NFR-A3: on-device history).
    public static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent("Phantasm", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return try open(at: dir.appendingPathComponent("phantasm.sqlite"))
    }

    /// Open (or create) an on-disk store at `url`. Internal so tests can
    /// exercise on-disk behavior against a scratch file.
    static func open(at url: URL) throws -> AppDatabase {
        try AppDatabase(DatabasePool(path: url.path))
    }

    /// In-memory database for tests and SwiftUI previews.
    public static func empty() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // The schema as of first release. Applied migrations are immutable:
        // schema changes append new migrations below — never edit this one.
        migrator.registerMigration("v1") { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                // Retained for compatibility with the original on-disk schema.
                // Current local-only deletes remove the whole conversation row.
                t.column("deletedAt", .datetime)
                t.column("modelID", .text)
                t.column("profileID", .blob)
                // Per-chat tool selection as one JSON document (`ToolSettings`)
                // so a new tool is a new field with a default, not a new
                // column + migration.
                t.column("toolSettings", .text).notNull()
                // Selected research/turn mode (nil = ordinary turn). Reaches
                // the wire only as a `<base>:<mode>` model-id suffix
                // (redesign §7).
                t.column("turnModeID", .text)
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("conversationId", .blob).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                // Model thinking for an assistant response — separate from
                // `content` so it's hidden by default and excluded from
                // future prompts.
                t.column("reasoning", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                // false while streaming; flipped once the turn finishes.
                t.column("isComplete", .boolean).notNull()
                // Client-executed (app-hosted) tools: an assistant message
                // can carry forwarded calls (JSON `[WireToolCall]`); a
                // `tool`-role message records the answer to `toolCallId`
                // from tool `name`. Re-sent in history so the model sees its
                // own call paired with the result (§2.3).
                t.column("toolCalls", .text)
                t.column("toolCallId", .text)
                t.column("name", .text)
                // Explicit per-conversation ordinal (assigned on insert under
                // the write lock) — the one message order. `createdAt` is
                // display-only: burst inserts collide at millisecond
                // precision, and a restamp on completion must never reorder.
                t.column("position", .integer).notNull()
            }
            try db.create(
                index: "message_conversation_position",
                on: "message", columns: ["conversationId", "position"]
            )
            try db.create(table: "attachment") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("messageId", .blob).notNull()
                    .references("message", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("data", .blob).notNull()
                t.column("mimeType", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Semantic search index: one vector per message *per embedder
            // revision* — vectors from different revisions are never
            // comparable, so a revision bump re-embeds everything while the
            // old generation keeps serving search until the indexer prunes
            // it. An *empty* vector marks a message that failed to embed, so
            // the indexer doesn't retry it forever. Rows cascade-delete with
            // their message; content rewrites delete them explicitly so the
            // indexer re-embeds.
            try db.create(table: "message_embedding") { t in
                t.column("messageId", .blob).notNull()
                    .references("message", onDelete: .cascade)
                t.column("model", .text).notNull()
                t.column("vector", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["messageId", "model"])
            }

            // FTS5 external-content indexes, kept in sync by triggers that GRDB
            // installs via `synchronize(withTable:)`. unicode61 removes diacritics
            // by default; searches use prefix patterns for search-as-you-type.
            // Indexing `content` directly is safe because the store extracts
            // inline base64 images at write time (`InlineImageRef`), so content
            // never carries megabyte payloads.
            try db.create(virtualTable: "message_ft", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61()
                t.column("content")
            }
            try db.create(virtualTable: "conversation_ft", using: FTS5()) { t in
                t.synchronize(withTable: "conversation")
                t.tokenizer = .unicode61()
                t.column("title")
            }
        }
        migrator.registerMigration("v2_reasoning_duration") { db in
            try db.alter(table: "message") { t in
                t.add(column: "reasoningDuration", .double)
            }
        }
        migrator.registerMigration("v3_attachment_lookup_index") { db in
            // Transcript loads fetch every attachment for a bounded set of
            // message ids and then order them chronologically. Without this
            // child-key index SQLite scans the whole attachment table.
            try db.create(
                index: "attachment_message_created_at",
                on: "attachment", columns: ["messageId", "createdAt"]
            )
        }
        return migrator
    }
}

// MARK: - Column names

private enum Col {
    static let conversationId = Column("conversationId")
    static let deletedAt = Column("deletedAt")
    static let createdAt = Column("createdAt")
    static let position = Column("position")
}

// MARK: - ChatStore

extension AppDatabase: ChatStore {
    public func insertConversation(_ conversation: Conversation) async throws {
        try await dbWriter.write { db in
            // Lazy create: re-inserting an existing conversation is a no-op.
            try conversation.insert(db, onConflict: .ignore)
        }
    }

    public func insertMessage(_ message: Message, attachments: [Attachment]) async throws {
        try await dbWriter.write { db in
            var message = message
            message.position = try Self.nextPosition(db, conversationId: message.conversationId)
            let inline = InlineImageRef.extract(message.content)
            message.content = inline.text
            try message.insert(db)
            try Self.insertInlineImages(db, inline.images, messageId: message.id)
            for attachment in attachments {
                try attachment.insert(db)
            }
        }
    }

    public func addAttachments(messageID: UUID, attachments: [Attachment]) async throws {
        guard !attachments.isEmpty else { return }
        try await dbWriter.write { db in
            // Skip if the message was deleted between commit and fetch completing.
            guard try Message.exists(db, key: messageID) else { return }
            for attachment in attachments {
                try attachment.insert(db)
            }
        }
    }

    public func updateMessage(
        id: UUID,
        content: String,
        reasoning: String,
        reasoningDuration: TimeInterval? = nil,
        isComplete: Bool,
        createdAt: Date?
    ) async throws {
        try await dbWriter.write { db in
            guard var message = try Message.fetchOne(db, key: id) else { return }
            try Self.rewriteContent(db, of: &message, to: content)
            message.reasoning = reasoning
            message.reasoningDuration = reasoningDuration
            message.isComplete = isComplete
            // Display-only restamp: ordering is `position`, so this can't reorder.
            if let createdAt { message.createdAt = createdAt }
            message.updatedAt = Date()
            try message.update(db)
            try Self.invalidateEmbedding(db, messageId: id)
        }
    }

    public func completeToolCallMessage(id: UUID, toolCalls: String, content: String) async throws {
        try await dbWriter.write { db in
            guard var message = try Message.fetchOne(db, key: id) else { return }
            message.toolCalls = toolCalls
            try Self.rewriteContent(db, of: &message, to: content)
            message.isComplete = true
            message.updatedAt = Date()
            try message.update(db)
            try Self.invalidateEmbedding(db, messageId: id)
        }
    }

    public func deleteMessage(id: UUID) async throws {
        try await dbWriter.write { db in
            _ = try Message.deleteOne(db, key: id)
        }
    }

    public func updateConversation(
        id: UUID, title: String?, modelID: String?, updatedAt: Date?
    ) async throws {
        try await dbWriter.write { db in
            guard var convo = try Conversation.fetchOne(db, key: id) else { return }
            if let title { convo.title = title }
            if let modelID { convo.modelID = modelID }
            if let updatedAt { convo.updatedAt = updatedAt }
            try convo.update(db)
        }
    }

    public func bindConversation(id: UUID, toProfileID profileID: UUID) async throws {
        try await dbWriter.write { db in
            guard var conversation = try Conversation.fetchOne(db, key: id) else { return }
            conversation.profileID = profileID
            conversation.modelID = nil
            conversation.turnModeID = nil
            try conversation.update(db)
        }
    }

    public func setConversationOptions(
        id: UUID,
        toolSettings: ToolSettings,
        turnModeID: String?
    ) async throws {
        try await dbWriter.write { db in
            guard var convo = try Conversation.fetchOne(db, key: id) else { return }
            convo.toolSettings = toolSettings
            convo.turnModeID = turnModeID
            try convo.update(db)
        }
    }

    public func editUserMessage(id: UUID, newContent: String) async throws {
        try await dbWriter.write { db in
            guard var message = try Message.fetchOne(db, key: id) else { return }
            let now = Date()
            // Truncate everything after the edited message (cascades to
            // attachments + fires the FTS triggers), then update it in place.
            try Self.messagesAfter(message, inclusive: false)
                .deleteAll(db)
            try Self.rewriteContent(db, of: &message, to: newContent)
            message.updatedAt = now
            try message.update(db)
            try Self.invalidateEmbedding(db, messageId: id)
            // Bump the conversation so the edit re-sorts it to the top.
            if var convo = try Conversation.fetchOne(db, key: message.conversationId) {
                convo.updatedAt = now
                try convo.update(db)
            }
        }
    }

    public func deleteMessagesFrom(id: UUID) async throws {
        try await dbWriter.write { db in
            guard let message = try Message.fetchOne(db, key: id) else { return }
            let now = Date()
            // Delete this message and everything after it (cascades to attachments
            // + fires the FTS triggers).
            try Self.messagesAfter(message, inclusive: true)
                .deleteAll(db)
            if var convo = try Conversation.fetchOne(db, key: message.conversationId) {
                convo.updatedAt = now
                try convo.update(db)
            }
        }
    }

    public func deleteMessagesAfter(id: UUID) async throws {
        try await dbWriter.write { db in
            guard let message = try Message.fetchOne(db, key: id) else { return }
            let now = Date()
            // Keep this message; delete everything after it (cascades to
            // attachments + fires the FTS triggers).
            try Self.messagesAfter(message, inclusive: false)
                .deleteAll(db)
            if var convo = try Conversation.fetchOne(db, key: message.conversationId) {
                convo.updatedAt = now
                try convo.update(db)
            }
        }
    }

    public func deleteConversation(id: UUID) async throws {
        try await dbWriter.write { db in
            // The conversation FK cascades to messages, attachments, and
            // embeddings; message delete triggers keep FTS in sync.
            try Conversation.deleteOne(db, key: id)
        }
    }

    public func deleteAllConversations() async throws {
        try await dbWriter.write { db in
            try Conversation.deleteAll(db)
        }
    }

    public func allConversationDetails(
        attachmentData: AttachmentDataScope
    ) async throws -> [ConversationDetail] {
        try await dbWriter.read { db in
            try Self.recentConversations(db).map { conversation in
                ConversationDetail(
                    conversation: conversation,
                    messages: try Self.messages(
                        db,
                        conversationId: conversation.id,
                        attachmentData: attachmentData
                    )
                )
            }
        }
    }

    public func conversationDetail(
        id: UUID,
        attachmentData: AttachmentDataScope
    ) async throws -> ConversationDetail? {
        try await dbWriter.read { db in
            try Self.conversationDetail(db, id: id, attachmentData: attachmentData)
        }
    }

    public func attachmentPayloads(ids: [UUID]) async throws -> [UUID: Data] {
        guard !ids.isEmpty else { return [:] }
        return try await dbWriter.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, data FROM attachment WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: UUID = row["id"]
                let data: Data = row["data"]
                return (id, data)
            })
        }
    }

    public func conversation(id: UUID) async throws -> Conversation? {
        try await dbWriter.read { db in try Self.conversation(db, id: id) }
    }

    /// Messages at or after `message` in its conversation, by `position`.
    private static func messagesAfter(
        _ message: Message, inclusive: Bool
    ) -> QueryInterfaceRequest<Message> {
        Message
            .filter(Col.conversationId == message.conversationId)
            .filter(inclusive ? Col.position >= message.position : Col.position > message.position)
    }

    /// The next per-conversation ordinal. Runs inside the write transaction,
    /// so two inserts can never claim the same position.
    private static func nextPosition(_ db: Database, conversationId: UUID) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM message WHERE conversationId = ?",
            arguments: [conversationId]
        ) ?? 1
    }

    /// Replace a message's content, re-extracting inline images: previously
    /// extracted rows for it are dropped (their links are gone from the new
    /// text) and any data-URI images in the new text become fresh rows. Callers
    /// still `update(db)` the message afterwards.
    private static func rewriteContent(
        _ db: Database, of message: inout Message, to content: String
    ) throws {
        try Attachment
            .filter(Column("messageId") == message.id)
            .filter(Column("kind") == AttachmentKind.inlineImage.rawValue)
            .deleteAll(db)
        let inline = InlineImageRef.extract(content)
        message.content = inline.text
        try insertInlineImages(db, inline.images, messageId: message.id)
    }

    private static func insertInlineImages(
        _ db: Database, _ images: [InlineImageRef.ExtractedImage], messageId: UUID
    ) throws {
        for image in images {
            try Attachment(
                messageId: messageId,
                kind: .inlineImage,
                name: image.name,
                data: image.data,
                mimeType: image.mime
            ).insert(db)
        }
    }

    public func searchConversations(matching query: String) async throws -> [ConversationSearchResult] {
        try await dbWriter.read { db in try Self.search(db, matching: query) }
    }
}

// MARK: - Semantic search index

/// A message the semantic index hasn't embedded yet.
public struct MessageEmbeddingCandidate: Equatable, Sendable {
    public let id: UUID
    /// The message content (clean text — inline images are extracted to
    /// attachment rows before content is persisted).
    public let text: String
}

/// Embedding storage + the hybrid (keyword ⊕ semantic) search entry point.
/// Deliberately *not* part of `ChatStore`: vectors are derived, rebuildable
/// data tied to this storage engine, like the FTS tables. The indexer and the
/// search UI talk to `AppDatabase` directly (the accepted read-path coupling).
public extension AppDatabase {
    /// Completed user/assistant messages with searchable text that have no
    /// stored vector for `model`, newest first (so a backfill makes recent
    /// chats semantically searchable soonest).
    func messagesNeedingEmbedding(model: String, limit: Int) async throws -> [MessageEmbeddingCandidate] {
        try await dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT m.id AS id, m.content AS text
                    FROM message m
                    LEFT JOIN message_embedding e
                        ON e.messageId = m.id AND e.model = :model
                    WHERE e.messageId IS NULL
                      AND m.isComplete
                      AND m.role IN ('user', 'assistant')
                      AND trim(m.content) <> ''
                    ORDER BY m.createdAt DESC
                    LIMIT :limit
                    """,
                arguments: ["model": model, "limit": limit]
            )
            return rows.map { MessageEmbeddingCandidate(id: $0["id"], text: $0["text"]) }
        }
    }

    /// Upsert one message's vector. An empty vector marks the message as
    /// unembeddable (never retried, skipped by search). A no-op if the message
    /// was deleted while the embedder ran.
    func storeMessageEmbedding(messageId: UUID, model: String, vector: [Float]) async throws {
        try await dbWriter.write { db in
            guard try Message.exists(db, key: messageId) else { return }
            try db.execute(
                sql: """
                    INSERT INTO message_embedding (messageId, model, vector, updatedAt)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(messageId, model) DO UPDATE SET
                        vector = excluded.vector,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [messageId, model, VectorCodec.encode(vector), Date()]
            )
        }
    }

    /// Drop vectors from embedder revisions other than `model`. Called once a
    /// full indexing pass has the current revision covering everything, so an
    /// old generation serves search during re-embedding but doesn't linger.
    func pruneEmbeddings(keepingModel model: String) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM message_embedding WHERE model <> ?",
                arguments: [model]
            )
        }
    }

    /// Hybrid search: FTS5 keyword results fused (reciprocal-rank) with
    /// semantic nearest-message results. `queryVector` must come from the
    /// embedder named by `model`; both lists are computed in one read so they
    /// see the same snapshot.
    func hybridSearchConversations(
        matching query: String, queryVector: [Float], model: String
    ) async throws -> [ConversationSearchResult] {
        try await dbWriter.read { db in
            HybridSearchRanker.fuse(
                keyword: try Self.search(db, matching: query),
                semantic: try Self.semanticSearch(db, queryVector: queryVector, model: model)
            )
        }
    }

    /// Drop a message's stored vector after its content is rewritten, so the
    /// next indexer pass re-embeds the new text.
    internal static func invalidateEmbedding(_ db: Database, messageId: UUID) throws {
        try db.execute(
            sql: "DELETE FROM message_embedding WHERE messageId = ?",
            arguments: [messageId]
        )
    }

    /// Conversations ranked by their best cosine hit against `queryVector`,
    /// best first, capped at `limit`. Brute-force scan: a personal history is
    /// thousands of vectors, well under a millisecond of dot products — no
    /// vector index needed. Snippets come from the best-matching message.
    internal static func semanticSearch(
        _ db: Database, queryVector: [Float], model: String, limit: Int = 10
    ) throws -> [ConversationSearchResult] {
        guard !queryVector.isEmpty else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT e.vector AS vector, m.conversationId AS cid, m.content AS text
                FROM message_embedding e
                JOIN message m ON m.id = e.messageId
                JOIN conversation c ON c.id = m.conversationId
                WHERE e.model = ? AND c.deletedAt IS NULL AND length(e.vector) > 0
                """,
            arguments: [model]
        )
        struct BestHit {
            var score: Float
            var text: String
        }
        var bestByConversation: [UUID: BestHit] = [:]
        for row in rows {
            let vector = VectorCodec.decode(row["vector"])
            guard vector.count == queryVector.count else { continue }
            let score = VectorCodec.dot(vector, queryVector)
            let cid: UUID = row["cid"]
            if let current = bestByConversation[cid], current.score >= score { continue }
            bestByConversation[cid] = BestHit(score: score, text: row["text"])
        }
        let top = bestByConversation.sorted { $0.value.score > $1.value.score }.prefix(limit)
        guard !top.isEmpty else { return [] }
        let conversations = try Conversation.filter(keys: top.map(\.key)).fetchAll(db)
        let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        return top.compactMap { entry in
            guard let conversation = byID[entry.key] else { return nil }
            return ConversationSearchResult(
                conversation: conversation,
                snippet: semanticSnippet(entry.value.text)
            )
        }
    }

    /// A compact one-line preview of the matched message: whitespace collapsed,
    /// clipped to roughly a list row.
    private static func semanticSnippet(_ text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > 100 else { return collapsed }
        return String(collapsed.prefix(100)) + "…"
    }
}

// MARK: - Synchronous read helpers

/// These run inside an existing database access. They back both the async
/// `ChatStore` methods above and the app-target GRDBQuery requests, so the query
/// logic lives in exactly one place.
public extension AppDatabase {
    /// Non-tombstoned conversations, most-recently-updated first.
    static func recentConversations(_ db: Database) throws -> [Conversation] {
        try Conversation
            .filter(Col.deletedAt == nil)
            .order(Column("updatedAt").desc)
            .fetchAll(db)
    }

    /// A conversation's messages in conversation order (`position`), each with
    /// its ordered attachments. Empty when the conversation is missing or
    /// tombstoned.
    static func messages(
        _ db: Database,
        conversationId: UUID,
        attachmentData: AttachmentDataScope = .full
    ) throws -> [ChatMessage] {
        let messages = try Message
            .filter(Col.conversationId == conversationId)
            .order(Col.position)
            .fetchAll(db)
        let messageIDs = messages.map(\.id)
        var attachmentRequest = Attachment
            .filter(messageIDs.contains(Column("messageId")))
            .order(Col.createdAt, Column.rowID)
        if attachmentData == .metadataOnly {
            // Supply the record's non-optional `data` property without reading
            // the BLOB column from SQLite. Everything needed to lay out the row
            // and decide what to load remains present.
            attachmentRequest = attachmentRequest.select(sql: """
                id, messageId, kind, name, zeroblob(0) AS data,
                mimeType, text, createdAt, updatedAt
                """)
        }
        let attachments = try attachmentRequest.fetchAll(db)
        let grouped = Dictionary(grouping: attachments, by: \.messageId)
        return messages.map { ChatMessage(message: $0, attachments: grouped[$0.id] ?? []) }
    }

    static func conversationDetail(
        _ db: Database,
        id: UUID,
        attachmentData: AttachmentDataScope = .full
    ) throws -> ConversationDetail? {
        guard let convo = try Conversation
            .filter(key: id)
            .filter(Col.deletedAt == nil)
            .fetchOne(db)
        else { return nil }
        return ConversationDetail(
            conversation: convo,
            messages: try messages(
                db,
                conversationId: id,
                attachmentData: attachmentData
            )
        )
    }

    /// Live conversation row (nil if missing or tombstoned) — for observing the title.
    static func conversation(_ db: Database, id: UUID) throws -> Conversation? {
        try Conversation.filter(key: id).filter(Col.deletedAt == nil).fetchOne(db)
    }

    /// Full-text search over titles + message content, ranked by relevance,
    /// excluding tombstoned conversations. Empty/whitespace query → no results.
    static func search(_ db: Database, matching query: String) throws -> [ConversationSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefix-match every token (search-as-you-type), all required.
        guard !trimmed.isEmpty, let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) else {
            return []
        }

        // Rank conversations by the best (lowest) bm25 across a title match or any
        // message match; carry a snippet from the best message hit.
        let sql = """
            WITH hits AS (
                SELECT m.conversationId AS cid,
                       bm25(message_ft) AS score,
                       snippet(message_ft, 0, '', '', '…', 12) AS snip
                FROM message_ft
                JOIN message m ON m.rowid = message_ft.rowid
                WHERE message_ft MATCH :pattern
                UNION ALL
                SELECT c.id AS cid, bm25(conversation_ft) AS score, NULL AS snip
                FROM conversation_ft
                JOIN conversation c ON c.rowid = conversation_ft.rowid
                WHERE conversation_ft MATCH :pattern
            )
            SELECT conversation.*,
                   (SELECT snip FROM hits
                    WHERE hits.cid = conversation.id AND snip IS NOT NULL
                    ORDER BY score LIMIT 1) AS snippet
            FROM conversation
            JOIN (SELECT cid, MIN(score) AS best FROM hits GROUP BY cid) ranked
                ON ranked.cid = conversation.id
            WHERE conversation.deletedAt IS NULL
            ORDER BY ranked.best
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: ["pattern": pattern])
        return try rows.map { row in
            ConversationSearchResult(
                conversation: try Conversation(row: row),
                snippet: row["snippet"]
            )
        }
    }
}
