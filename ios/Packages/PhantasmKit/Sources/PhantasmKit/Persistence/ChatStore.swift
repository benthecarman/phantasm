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

    /// Replace a message's streamed body and completion flag. Used to create a
    /// durable pending assistant row at turn start, then complete that same row
    /// once the buffered stream finishes. `createdAt`, when supplied, restamps
    /// the row to its completion time (the pending row is inserted at turn start,
    /// but the displayed timestamp should reflect when the whole message arrived).
    func updateMessage(
        id: UUID,
        content: String,
        reasoning: String,
        isComplete: Bool,
        createdAt: Date?
    ) async throws

    /// Attach rows to an already-persisted message (post-commit). Used to cache
    /// server-hosted generated images locally once they've been fetched, after
    /// the assistant message itself is committed. A no-op if the message is gone.
    func addAttachments(messageID: UUID, attachments: [Attachment]) async throws

    /// Finalize a pending assistant row as one that forwarded app-hosted tool
    /// calls: store the JSON-encoded `[WireToolCall]`, keep any answer text the
    /// turn streamed before the batch (e.g. an image a server tool produced in
    /// an earlier iteration), and mark it complete. Used when a turn ends with
    /// the model calling an app tool (e.g. `ask_user`).
    func completeToolCallMessage(id: UUID, toolCalls: String, content: String) async throws

    /// Remove one message and its attachments. A no-op if the message no longer
    /// exists.
    func deleteMessage(id: UUID) async throws

    /// Update a conversation's mutable fields. A `nil` argument leaves that field
    /// unchanged (including `updatedAt`, so a title-only edit need not reorder).
    func updateConversation(
        id: UUID, title: String?, modelID: String?, updatedAt: Date?
    ) async throws

    /// Persist a conversation's per-chat tool selection (web search / image
    /// generation / location) and selected research mode (`modeID`, nil =
    /// ordinary). Does not bump `updatedAt`, so toggling doesn't reorder the
    /// history. A no-op if the conversation doesn't exist yet (an unsent draft
    /// carries its selection into the first send instead).
    func setConversationOptions(
        id: UUID,
        webSearchEnabled: Bool,
        imageGenerationEnabled: Bool,
        locationEnabled: Bool,
        healthEnabled: Bool,
        calendarEnabled: Bool,
        modeID: String?
    ) async throws

    /// Edit a previously sent message in place and truncate the conversation
    /// after it: replaces the message's content (FTS stays in sync via triggers),
    /// keeps its attachments, and hard-deletes every later message + its
    /// attachments. Bumps the conversation's `updatedAt`. Used to re-ask from an
    /// edited prompt — the caller then re-streams the truncated history. A no-op
    /// if the message no longer exists.
    func editUserMessage(id: UUID, newContent: String) async throws

    /// Delete a message and every message after it in the same conversation
    /// (cascades to attachments, fires the FTS triggers), bumping the
    /// conversation's `updatedAt`. Used to regenerate an assistant reply: drop it
    /// (and anything later), then re-stream from the remaining history. A no-op
    /// if the message no longer exists.
    func deleteMessagesFrom(id: UUID) async throws

    /// Delete every message *after* the given one in the same conversation,
    /// keeping the message itself (cascades to attachments, fires the FTS
    /// triggers), bumping the conversation's `updatedAt`. Used to resend a user
    /// message: drop anything after it, then re-stream from the kept history.
    /// A no-op if the message no longer exists.
    func deleteMessagesAfter(id: UUID) async throws

    /// Tombstone the conversation (set `deletedAt`) and hard-delete its messages
    /// + attachments, reclaiming the heavy data while leaving a slim tombstone.
    func deleteConversation(id: UUID) async throws

    /// Tombstone every conversation and hard-delete all messages + attachments —
    /// the bulk equivalent of `deleteConversation` across the whole history.
    func deleteAllConversations() async throws

    /// One-shot fetch of a conversation with its ordered message history. Returns
    /// nil if the conversation is missing or tombstoned.
    func conversationDetail(id: UUID) async throws -> ConversationDetail?

    /// Full-text search over conversation titles + message content, ranked by
    /// relevance. Tombstoned conversations are excluded. Empty query → no results.
    func searchConversations(matching query: String) async throws -> [ConversationSearchResult]
}
