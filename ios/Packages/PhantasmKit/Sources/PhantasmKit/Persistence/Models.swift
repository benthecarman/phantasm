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
    /// The selected research/turn mode for this chat (e.g. `"deep-research"`), or
    /// `nil` for an ordinary turn. It's the *UI preference*; at send time it
    /// reaches the wire only as a suffix on the `model` id (`<base>:<modeID>`),
    /// and only when the backend advertises that mode. The composer's research
    /// picker flips it.
    public var modeID: String?
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
        modeID: String? = nil
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
        self.modeID = modeID
    }

    public static let databaseTableName = "conversation"
}

public extension Conversation {
    /// Names of the tools this chat wants offered this turn, intersected against
    /// what the backend advertises (`capabilities.tools`). Returns `nil` when the
    /// backend exposes no tool manifest, so the caller omits the `tools` selection
    /// entirely and keeps the request standard; otherwise the (possibly empty)
    /// selection, which the caller encodes as standard `tools`/`tool_choice`.
    func requestedToolNames(supporting tools: Capabilities.Tools?) -> [String]? {
        guard let tools else { return nil }
        var names: [String] = []
        if tools.webSearch, webSearchEnabled { names.append(ToolName.webSearch) }
        if tools.imageGeneration, imageGenerationEnabled { names.append(ToolName.imageGeneration) }
        return names
    }

    /// Thinking is independent of the research mode (redesign §7): the preset
    /// (server) or the user (client) decides reasoning, never welded to the mode.
    func reasoningEffort(thinkingEnabled: Bool, disabledEffort: String?) -> String? {
        thinkingEnabled ? ReasoningEffort.enabledDefault : disabledEffort
    }

    /// The `model` string to send for this turn. When this chat has a research
    /// mode selected AND the backend advertises it (`availableModes`) AND the
    /// base model is tool-capable, the mode rides as a suffix (`<base>:<modeID>`,
    /// resolved server-side, spec §2.1). Otherwise the bare base model — the only
    /// place mode reaches the wire (redesign §7).
    func wireModel(
        base: String,
        availableModes: [Capabilities.Mode],
        baseModelIsToolCapable: Bool
    ) -> String {
        guard let modeID,
              baseModelIsToolCapable,
              availableModes.contains(where: { $0.id == modeID })
        else { return base }
        return "\(base):\(modeID)"
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
    /// JSON-encoded `[WireToolCall]` for an assistant message that forwarded
    /// app-hosted tool calls; nil otherwise. Re-sent in history so the model sees
    /// its own call paired with the tool result (client-executed tools, §2.3).
    public var toolCalls: String?
    /// The call this message answers (a `tool`-role result).
    public var toolCallId: String?
    /// The tool name (a `tool`-role result), e.g. `ask_user`.
    public var name: String?

    public init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: String,
        content: String,
        reasoning: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        isComplete: Bool = true,
        toolCalls: String? = nil,
        toolCallId: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.isComplete = isComplete
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
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
    /// completed messages are sent. Assistant messages that forwarded app-tool
    /// calls and their `tool`-role results round-trip so the model sees the
    /// call/result pair; every assistant tool_call is guaranteed to be followed
    /// by a matching tool result (a synthetic "(dismissed)" one is inserted for
    /// an unanswered call), keeping the history OpenAI-valid.
    func wireHistory() -> [WireMessage] {
        let completed = filter { $0.message.isComplete }
        var out: [WireMessage] = []
        for (index, item) in completed.enumerated() {
            let m = item.message
            if m.role == "tool", let toolCallId = m.toolCallId {
                out.append(WireMessage(
                    toolResult: toolCallId,
                    name: m.name ?? ToolName.askUser,
                    content: m.content
                ))
                continue
            }
            if let calls = decodeToolCalls(m.toolCalls), !calls.isEmpty {
                out.append(WireMessage(assistantToolCalls: calls))
                let nextIsResult = completed[safe: index + 1]?.message.role == "tool"
                if !nextIsResult {
                    for call in calls {
                        out.append(WireMessage(
                            toolResult: call.id ?? "",
                            name: call.function?.name ?? ToolName.askUser,
                            content: "(dismissed)"
                        ))
                    }
                }
                continue
            }
            guard !(m.content.isEmpty && item.attachments.isEmpty) else { continue }
            out.append(WireMessage(role: m.role, content: item.wireContent()))
        }
        return out
    }

    private func decodeToolCalls(_ json: String?) -> [WireToolCall]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? Wire.decoder().decode([WireToolCall].self, from: data)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
