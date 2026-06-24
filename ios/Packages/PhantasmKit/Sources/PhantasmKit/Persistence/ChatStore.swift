import Foundation

/// A conversation with its full message history — each message paired with its
/// ordered attachments. Returned by one-shot fetches (building wire history, the
/// auto-title prompt) where the UI's reactive `@Query` isn't involved.
public struct ConversationDetail: Equatable, Sendable {
    public var conversation: Conversation
    public var messages: [ChatMessage]

    public init(conversation: Conversation, messages: [ChatMessage]) {
        self.conversation = conversation
        self.messages = messages
    }

    /// Wire history for this conversation (stateless server, XR-2).
    public func wireHistory() -> [WireMessage] { messages.wireHistory() }
}

/// One full-text search hit: the matching conversation plus an optional snippet
/// from the best-matching message (nil when only the title matched).
public struct ConversationSearchResult: Identifiable, Equatable, Sendable {
    public var conversation: Conversation
    public var snippet: String?

    public var id: UUID { conversation.id }

    public init(conversation: Conversation, snippet: String? = nil) {
        self.conversation = conversation
        self.snippet = snippet
    }
}

/// Storage-agnostic write / search / one-shot-fetch API for chat history.
///
/// Reactive list + message reads use GRDBQuery directly in the Views (an accepted
/// read-path coupling). Everything that *mutates* state or does a one-shot fetch
/// goes through this protocol, so the storage engine stays swappable — e.g. a
/// future cloud-synced implementation (SPEC §7). No GRDB types appear in the
/// signatures; the conforming type hides them.
public protocol ChatStore: Sendable {
    /// Persist a new conversation. Idempotent: re-inserting an existing id is a
    /// no-op (the conversation is created lazily on first send).
    func insertConversation(_ conversation: Conversation) async throws

    /// Persist one message and its attachments in a single transaction.
    func insertMessage(_ message: Message, attachments: [Attachment]) async throws

    /// Update a conversation's mutable fields. A `nil` argument leaves that field
    /// unchanged (including `updatedAt`, so a title-only edit need not reorder).
    func updateConversation(
        id: UUID, title: String?, modelID: String?, updatedAt: Date?
    ) async throws

    /// Tombstone the conversation (set `deletedAt`) and hard-delete its messages
    /// + attachments, reclaiming the heavy data while leaving a slim tombstone.
    func deleteConversation(id: UUID) async throws

    /// One-shot fetch of a conversation with its ordered message history. Returns
    /// nil if the conversation is missing or tombstoned.
    func conversationDetail(id: UUID) async throws -> ConversationDetail?

    /// Full-text search over conversation titles + message content, ranked by
    /// relevance. Tombstoned conversations are excluded. Empty query → no results.
    func searchConversations(matching query: String) async throws -> [ConversationSearchResult]
}
