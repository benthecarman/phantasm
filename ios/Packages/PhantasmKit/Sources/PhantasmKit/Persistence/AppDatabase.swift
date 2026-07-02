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
        let pool = try DatabasePool(path: dir.appendingPathComponent("phantasm.sqlite").path)
        return try AppDatabase(pool)
    }

    /// In-memory database for tests and SwiftUI previews.
    public static func empty() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.column("modelID", .text)
                t.column("profileID", .blob)
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("conversationId", .blob).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isComplete", .boolean).notNull()
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

            // FTS5 external-content indexes, kept in sync by triggers that GRDB
            // installs via `synchronize(withTable:)`. unicode61 removes diacritics
            // by default; searches use prefix patterns for search-as-you-type.
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

        // Per-chat tool selection (web search / image generation). Existing chats
        // default on, matching the prior always-offered behavior on tool-enabled
        // backends; the composer's tool selector flips them per chat.
        migrator.registerMigration("v2_per_chat_tools") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "webSearchEnabled", .boolean).notNull().defaults(to: true)
                t.add(column: "imageGenerationEnabled", .boolean).notNull().defaults(to: true)
            }
        }

        // Per-chat Deep Research mode (x_research). Off by default — it's a
        // slower, deliberate mode the user opts into per chat.
        migrator.registerMigration("v3_deep_research") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "deepResearchEnabled", .boolean).notNull().defaults(to: false)
            }
        }

        // Per-assistant-message reasoning text. Existing rows migrate to no stored
        // reasoning; the Thinking toggle itself is stored per model in UserDefaults.
        migrator.registerMigration("v4_thinking") { db in
            try db.alter(table: "message") { t in
                t.add(column: "reasoning", .text).notNull().defaults(to: "")
            }
        }

        // Deep Research becomes a selected mode id rather than a bool: research is
        // now chosen via a mode-suffixed model id (redesign §2/§7), and the mode
        // table is server-side. Add `modeID` (nil = ordinary turn) and
        // migrate rows that had `deepResearchEnabled` on to "deep-research". The
        // old boolean column is left in place (unused) to keep the migration simple.
        migrator.registerMigration("v5_research_mode") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "modeID", .text)
            }
            try db.execute(
                sql: """
                    UPDATE conversation
                    SET modeID = 'deep-research'
                    WHERE deepResearchEnabled = 1
                    """
            )
        }

        // Client-executed (app-hosted) tools: an assistant message can carry
        // forwarded tool calls, and a `tool`-role message records the user's
        // answer. All nil for existing rows (ordinary chat/assistant messages).
        migrator.registerMigration("v6_client_tools") { db in
            try db.alter(table: "message") { t in
                t.add(column: "toolCalls", .text)
                t.add(column: "toolCallId", .text)
                t.add(column: "name", .text)
            }
        }

        // Per-chat opt-in for the app-hosted location tool. Off by default
        // (privacy-sensitive, triggers a permission prompt); the composer's tool
        // selector flips it per chat.
        migrator.registerMigration("v7_location_tool") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "locationEnabled", .boolean).notNull().defaults(to: false)
            }
        }

        // Per-chat opt-in for the app-hosted health tool. Off by default (same
        // privacy reasoning as location); the composer's tool selector flips it.
        migrator.registerMigration("v8_health_tool") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "healthEnabled", .boolean).notNull().defaults(to: false)
            }
        }

        // Per-chat opt-in for the app-hosted calendar tool. Off by default (same
        // privacy reasoning as location/health); the composer's tool selector
        // flips it.
        migrator.registerMigration("v9_calendar_tool") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "calendarEnabled", .boolean).notNull().defaults(to: false)
            }
        }

        // Full-text search moves to a sanitized projection: indexing raw
        // content tokenized megabytes of inline base64 image payload into FTS
        // (slow commits, permanent index bloat, garbage hits). `searchText` is
        // content with data-URI payloads stripped; the FTS index re-points at it.
        migrator.registerMigration("v10_search_projection") { db in
            try db.alter(table: "message") { t in
                t.add(column: "searchText", .text).notNull().defaults(to: "")
            }
            // Most rows carry no data URI: copy content wholesale.
            try db.execute(sql: """
                UPDATE message SET searchText = content
                WHERE content NOT LIKE '%](data:image/%'
                """)
            // Sanitize the (few) image-bearing rows in Swift.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, content FROM message WHERE content LIKE '%](data:image/%'
                """)
            for row in rows {
                let id: UUID = row["id"]
                let content: String = row["content"]
                try db.execute(
                    sql: "UPDATE message SET searchText = ? WHERE id = ?",
                    arguments: [Message.searchProjection(content), id]
                )
            }
            // Replace the FTS index (and the sync triggers GRDB installed for
            // it) with one over the sanitized column. Recreating it re-indexes
            // from the message table, shedding the base64 already in the index.
            let triggers = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'trigger' AND tbl_name = 'message' AND sql LIKE '%message_ft%'
                """)
            for trigger in triggers {
                try db.execute(sql: "DROP TRIGGER \"\(trigger)\"")
            }
            try db.execute(sql: "DROP TABLE message_ft")
            try db.create(virtualTable: "message_ft", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61()
                t.column("searchText")
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
