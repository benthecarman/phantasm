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

    /// Open (or create) the on-disk store at `url`. Internal so tests can
    /// exercise the pre-release reset below against a scratch file.
    static func open(at url: URL) throws -> AppDatabase {
        let pool = try DatabasePool(path: url.path)
        // Pre-release schema reset: the incremental migration lineage was
        // collapsed into the single migration below before the first release.
        // A store written by an older dev build carries applied identifiers
        // this migrator has never heard of, and GRDB (correctly) refuses to
        // migrate such a database. No released build ever produced one, so a
        // superseded store is dev data: start fresh instead of dooming every
        // session to the in-memory fallback.
        if try pool.read({ try migrator.hasBeenSuperseded($0) }) {
            let fm = FileManager.default
            try pool.close()
            try fm.removeItem(at: url)
            // SQLite side files; usually gone after a clean close.
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
            return try AppDatabase(DatabasePool(path: url.path))
        }
        return try AppDatabase(pool)
    }

    /// In-memory database for tests and SwiftUI previews.
    public static func empty() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // The full schema in one migration. The incremental lineage this
        // replaced (v1–v11) predates the first release; no shipped build ever
        // ran it, and `makeShared` resets any leftover dev store that did
        // (`hasBeenSuperseded`). Post-release schema changes append new
        // migrations below this one.
        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                // Tombstone: deletes keep this slim row (messages are
                // hard-deleted) so a future cloud-sync layer can propagate
                // the deletion (SPEC §7).
                t.column("deletedAt", .datetime)
                t.column("modelID", .text)
                t.column("profileID", .blob)
                // Per-chat tool selection. Server tools default on, matching
                // a tools-enabled backend out of the box; the device tools
                // default off — each is privacy-sensitive and triggers a
                // system permission prompt.
                t.column("webSearchEnabled", .boolean).notNull().defaults(to: true)
                t.column("imageGenerationEnabled", .boolean).notNull().defaults(to: true)
                t.column("locationEnabled", .boolean).notNull().defaults(to: false)
                t.column("healthEnabled", .boolean).notNull().defaults(to: false)
                t.column("calendarEnabled", .boolean).notNull().defaults(to: false)
                // Selected research/turn mode (nil = ordinary turn). Reaches
                // the wire only as a `<base>:<modeID>` model-id suffix
                // (redesign §7).
                t.column("modeID", .text)
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
                // What FTS indexes: `content` with inline base64 image
                // payloads stripped. Indexing raw content would tokenize
                // megabytes of base64 into FTS — slow commits, index bloat,
                // garbage hits. Maintained by the store whenever `content`
                // changes.
                t.column("searchText", .text).notNull()
            }
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

            // Semantic search index: one vector per message, produced by the
            // on-device embedder. `model` names the embedder revision —
            // vectors from different revisions are never comparable, so a
            // revision bump makes every row a re-embed candidate. An *empty*
            // vector marks a message that failed to embed, so the indexer
            // doesn't retry it forever. Rows cascade-delete with their
            // message; content rewrites delete the row explicitly so the
            // indexer re-embeds.
            try db.create(table: "message_embedding") { t in
                t.primaryKey("messageId", .blob).notNull()
                    .references("message", onDelete: .cascade)
                t.column("model", .text).notNull()
                t.column("vector", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // FTS5 external-content indexes, kept in sync by triggers that GRDB
            // installs via `synchronize(withTable:)`. unicode61 removes diacritics
            // by default; searches use prefix patterns for search-as-you-type.
            try db.create(virtualTable: "message_ft", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61()
                t.column("searchText")
            }
            try db.create(virtualTable: "conversation_ft", using: FTS5()) { t in
                t.synchronize(withTable: "conversation")
                t.tokenizer = .unicode61()
                t.column("title")
            }
        }
        return migrator
    }
}

// MARK: - Column names

private enum Col {
    static let conversationId = Column("conversationId")
    static let deletedAt = Column("deletedAt")
    static let createdAt = Column("createdAt")
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
            try message.insert(db)
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
        isComplete: Bool,
        createdAt: Date?
    ) async throws {
        try await dbWriter.write { db in
            guard var message = try Message.fetchOne(db, key: id) else { return }
            message.content = content
            message.searchText = Message.searchProjection(content)
            message.reasoning = reasoning
            message.isComplete = isComplete
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
            message.content = content
            message.searchText = Message.searchProjection(content)
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

    public func setConversationOptions(
        id: UUID,
        webSearchEnabled: Bool,
        imageGenerationEnabled: Bool,
        locationEnabled: Bool,
        healthEnabled: Bool,
        calendarEnabled: Bool,
        modeID: String?
    ) async throws {
        try await dbWriter.write { db in
            guard var convo = try Conversation.fetchOne(db, key: id) else { return }
            convo.webSearchEnabled = webSearchEnabled
            convo.imageGenerationEnabled = imageGenerationEnabled
            convo.locationEnabled = locationEnabled
            convo.healthEnabled = healthEnabled
            convo.calendarEnabled = calendarEnabled
            convo.modeID = modeID
            try convo.update(db)
        }
    }

    public func editUserMessage(id: UUID, newContent: String) async throws {
        try await dbWriter.write { db in
            guard var message = try Message.fetchOne(db, key: id) else { return }
            let now = Date()
            // Truncate everything after the edited message (cascades to
            // attachments + fires the FTS triggers), then update it in place.
            try Self.messagesAfter(db, message, inclusive: false)
                .deleteAll(db)
            message.content = newContent
            message.searchText = Message.searchProjection(newContent)
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
            try Self.messagesAfter(db, message, inclusive: true)
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
            try Self.messagesAfter(db, message, inclusive: false)
                .deleteAll(db)
            if var convo = try Conversation.fetchOne(db, key: message.conversationId) {
                convo.updatedAt = now
                try convo.update(db)
            }
        }
    }

    public func deleteConversation(id: UUID) async throws {
        try await dbWriter.write { db in
            // Hard-delete the heavy data: removing messages cascades to
            // attachments (FK) and fires the FTS triggers that clean message_ft.
            try Message.filter(Col.conversationId == id).deleteAll(db)
            // Leave a lightweight tombstone so a future sync can propagate the delete.
            guard var convo = try Conversation.fetchOne(db, key: id) else { return }
            let now = Date()
            convo.deletedAt = now
            convo.updatedAt = now
            try convo.update(db)
        }
    }

    public func deleteAllConversations() async throws {
        try await dbWriter.write { db in
            // Hard-delete all messages (cascades to attachments + fires FTS
            // triggers), then tombstone every live conversation — same shape as
            // deleteConversation, applied across the whole history.
            try Message.deleteAll(db)
            let now = Date()
            try Conversation
                .filter(Col.deletedAt == nil)
                .updateAll(db, Col.deletedAt.set(to: now), Column("updatedAt").set(to: now))
        }
    }

    public func conversationDetail(id: UUID) async throws -> ConversationDetail? {
        try await dbWriter.read { db in try Self.conversationDetail(db, id: id) }
    }

    /// Messages at or after `message` in its conversation, in (createdAt, rowid)
    /// order. rowid breaks same-millisecond ties (burst inserts from the tool
    /// flow), so truncation never deletes/keeps the wrong sibling.
    private static func messagesAfter(
        _ db: Database, _ message: Message, inclusive: Bool
    ) throws -> QueryInterfaceRequest<Message> {
        let anchorRowid = try Message
            .filter(key: message.id)
            .select(Column.rowID, as: Int64.self)
            .fetchOne(db) ?? Int64.max
        let tiebreaker = inclusive ? Column.rowID >= anchorRowid : Column.rowID > anchorRowid
        return Message
            .filter(Col.conversationId == message.conversationId)
            .filter(
                Col.createdAt > message.createdAt
                    || (Col.createdAt == message.createdAt && tiebreaker)
            )
    }

    public func searchConversations(matching query: String) async throws -> [ConversationSearchResult] {
        try await dbWriter.read { db in try Self.search(db, matching: query) }
    }
}

// MARK: - Semantic search index

/// A message the semantic index hasn't embedded yet.
public struct MessageEmbeddingCandidate: Equatable, Sendable {
    public let id: UUID
    /// The message's sanitized search projection (same text FTS indexes).
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
                    SELECT m.id AS id, m.searchText AS text
                    FROM message m
                    LEFT JOIN message_embedding e
                        ON e.messageId = m.id AND e.model = :model
                    WHERE e.messageId IS NULL
                      AND m.isComplete
                      AND m.role IN ('user', 'assistant')
                      AND trim(m.searchText) <> ''
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
                    ON CONFLICT(messageId) DO UPDATE SET
                        model = excluded.model,
                        vector = excluded.vector,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [messageId, model, VectorCodec.encode(vector), Date()]
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
                SELECT e.vector AS vector, m.conversationId AS cid, m.searchText AS text
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

    /// A conversation's messages in chronological order, each with its ordered
    /// attachments. Empty when the conversation is missing or tombstoned.
    static func messages(_ db: Database, conversationId: UUID) throws -> [ChatMessage] {
        // rowid breaks createdAt ties: the auto-resolved tool flow inserts an
        // assistant tool_calls row and its tool result back-to-back, and Date
        // storage is millisecond-precision — an unspecified tie order could emit
        // the tool result before its tool_calls row in the wire history, which
        // strict OpenAI backends reject.
        let messages = try Message
            .filter(Col.conversationId == conversationId)
            .order(Col.createdAt, Column.rowID)
            .fetchAll(db)
        let messageIDs = messages.map(\.id)
        let attachments = try Attachment
            .filter(messageIDs.contains(Column("messageId")))
            .order(Col.createdAt, Column.rowID)
            .fetchAll(db)
        let grouped = Dictionary(grouping: attachments, by: \.messageId)
        return messages.map { ChatMessage(message: $0, attachments: grouped[$0.id] ?? []) }
    }

    static func conversationDetail(_ db: Database, id: UUID) throws -> ConversationDetail? {
        guard let convo = try Conversation
            .filter(key: id)
            .filter(Col.deletedAt == nil)
            .fetchOne(db)
        else { return nil }
        return ConversationDetail(conversation: convo, messages: try messages(db, conversationId: id))
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
