import Foundation
import GRDB

/// On-device conversation history (NFR-A3). No cloud dependency in MVP.
///
/// These are GRDB value-type records (SQLite-backed) rather than reference types:
/// relationships are foreign-key columns, not stored object graphs, and the
/// chronological/wire-format helpers live on the `ChatMessage` aggregate and the
/// `[ChatMessage]` array (see below) instead of on the records themselves.
///
/// Every row carries `updatedAt`; `Conversation` additionally carries a nullable
/// `deletedAt` tombstone. Deleting a conversation hard-removes its messages +
/// attachments (reclaiming the heavy data) but leaves the conversation row as a
/// lightweight tombstone, so a future cloud-sync layer can still propagate the
/// deletion (SPEC §7). Column names match the property names.

public struct Conversation: Identifiable, Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord
{
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Tombstone: non-nil once the conversation has been deleted.
    public var deletedAt: Date?
    public var modelID: String?
    public var profileID: UUID?
    /// Whether this chat wants the server's web-search tool offered (when the
    /// backend supports it). Defaults on, so behavior matches a tools-enabled
    /// backend out of the box; the composer's tool selector flips it per chat.
    public var webSearchEnabled: Bool
    /// Whether this chat wants the server's image-generation tool offered.
    public var imageGenerationEnabled: Bool
    /// Whether this chat runs in Deep Research mode (`x_research`). Off by
    /// default — it's a slower, deliberate mode the user opts into per chat; the
    /// composer's research toggle flips it.
    public var deepResearchEnabled: Bool
    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        modelID: String? = nil,
        profileID: UUID? = nil,
        webSearchEnabled: Bool = true,
        imageGenerationEnabled: Bool = true,
        deepResearchEnabled: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
        self.modelID = modelID
        self.profileID = profileID
        self.webSearchEnabled = webSearchEnabled
        self.imageGenerationEnabled = imageGenerationEnabled
        self.deepResearchEnabled = deepResearchEnabled
    }

    public static let databaseTableName = "conversation"
}

public extension Conversation {
    /// Names of the tools this chat wants offered this turn, intersected against
    /// what the backend advertises (`capabilities.tools`). Returns `nil` when the
    /// backend exposes no tool manifest, so the caller omits `x_tools` entirely
    /// and keeps the request standard; otherwise the (possibly empty) selection.
    func requestedToolNames(supporting tools: Capabilities.Tools?) -> [String]? {
        guard let tools else { return nil }
        var names: [String] = []
        if tools.webSearch, webSearchEnabled { names.append(ToolName.webSearch) }
        if tools.imageGeneration, imageGenerationEnabled { names.append(ToolName.imageGeneration) }
        return names
    }

    /// Deep Research is an explicit slow/thorough turn mode, so it opts the
    /// request into thinking for that turn without changing the saved preference.
    func reasoningEffort(thinkingEnabled: Bool) -> String {
        deepResearchEnabled || thinkingEnabled
            ? ReasoningEffort.enabledDefault
            : ReasoningEffort.disabled
    }
}

public struct Message: Identifiable, Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord
{
    public var id: UUID
    public var conversationId: UUID
    public var role: String
    public var content: String
    /// Optional model thinking/reasoning associated with an assistant response.
    /// Kept separate from `content` so it is hidden by default and excluded from
    /// future prompts.
    public var reasoning: String
    public var createdAt: Date
    public var updatedAt: Date
    /// `false` while streaming; flipped to `true` once the turn finishes.
    public var isComplete: Bool

    public init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: String,
        content: String,
        reasoning: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        isComplete: Bool = true
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.isComplete = isComplete
    }

    public static let databaseTableName = "message"
}

/// Kinds of message attachment. Images ride along as vision input; text files
/// are extracted to plain text on-device and inlined into the prompt.
public enum AttachmentKind: String, Sendable {
    case image
    case text
}

public struct Attachment: Identifiable, Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord
{
    public var id: UUID
    public var messageId: UUID
    /// `AttachmentKind` raw value.
    public var kind: String
    /// Display label — the source filename, or a synthesized name for photos.
    public var name: String
    /// Image bytes (for `.image`); empty for text files.
    public var data: Data
    /// MIME type of `data` (for `.image`), e.g. `image/jpeg`.
    public var mimeType: String
    /// Extracted text (for `.text`); empty for images.
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        messageId: UUID,
        kind: AttachmentKind,
        name: String,
        data: Data = Data(),
        mimeType: String = "image/jpeg",
        text: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.kind = kind.rawValue
        self.name = name
        self.data = data
        self.mimeType = mimeType
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public static let databaseTableName = "attachment"
}

// MARK: - Aggregate + wire format

/// A message paired with its attachments (pre-ordered). This is the in-memory
/// shape the UI renders and the wire format is derived from — the records
/// themselves no longer carry their children.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public var message: Message
    /// Attachments in stable chronological order.
    public var attachments: [Attachment]

    public var id: UUID { message.id }

    public init(message: Message, attachments: [Attachment] = []) {
        self.message = message
        self.attachments = attachments
    }

    /// The wire body for this message. Plain text unless the message carries
    /// attachments; image attachments become `image_url` parts and text files
    /// are inlined as additional text (so non-vision models still get them).
    public func wireContent() -> WireContent {
        let images = attachments.filter { $0.kind == AttachmentKind.image.rawValue }
        let files = attachments.filter { $0.kind == AttachmentKind.text.rawValue }
        guard !images.isEmpty || !files.isEmpty else { return .text(message.content) }

        var textBlocks: [String] = []
        if !message.content.isEmpty { textBlocks.append(message.content) }
        for file in files {
            textBlocks.append("Attached file \"\(file.name)\":\n\(file.text)")
        }
        let combinedText = textBlocks.joined(separator: "\n\n")

        guard !images.isEmpty else { return .text(combinedText) }

        var parts: [WirePart] = []
        if !combinedText.isEmpty { parts.append(.text(combinedText)) }
        for image in images {
            let base64 = image.data.base64EncodedString()
            parts.append(.imageURL("data:\(image.mimeType);base64,\(base64)"))
        }
        return .parts(parts)
    }
}

public extension Array where Element == ChatMessage {
    /// Full history mapped to the wire format (stateless server, XR-2). Only
    /// completed messages with text or attachments are sent.
    func wireHistory() -> [WireMessage] {
        filter { $0.message.isComplete && !($0.message.content.isEmpty && $0.attachments.isEmpty) }
            .map { WireMessage(role: $0.message.role, content: $0.wireContent()) }
    }
}
