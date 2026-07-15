import Foundation
import GRDB
import GRDBQuery
import PhantasmKit

/// Reactive reads for the chat UI (GRDBQuery). These are the one place the app's
/// read path touches GRDB directly; the query logic itself lives in PhantasmKit
/// (the synchronous `AppDatabase` helpers), so it stays storage-engine-owned and
/// host-testable. Writes never go through here — they use `env.store`.

/// The history list. With an empty `searchText` it streams all non-tombstoned
/// conversations, most-recently-updated first. With text it streams ranked
/// full-text results across titles + message content, each with an optional
/// snippet. The field is bound to the search box; mutating it re-runs the query.
struct ConversationsRequest: ValueObservationQueryable {
    static var defaultValue: [ConversationSearchResult] { [] }

    var searchText = ""

    func fetch(_ db: Database) throws -> [ConversationSearchResult] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try AppDatabase.recentConversations(db)
                .map { ConversationSearchResult(conversation: $0, snippet: nil) }
        }
        return try AppDatabase.search(db, matching: searchText)
    }
}

/// One conversation's messages (each with its ordered attachments), chronological.
struct MessagesRequest: ValueObservationQueryable {
    static var defaultValue: [ChatMessage] { [] }

    var conversationId: UUID

    func fetch(_ db: Database) throws -> [ChatMessage] {
        try AppDatabase.messages(
            db,
            conversationId: conversationId,
            attachmentData: .metadataOnly
        )
    }
}

/// A single conversation row, for observing live title changes (nil if tombstoned).
struct ConversationRequest: ValueObservationQueryable {
    static var defaultValue: Conversation? { nil }

    var id: UUID

    func fetch(_ db: Database) throws -> Conversation? {
        try AppDatabase.conversation(db, id: id)
    }
}
