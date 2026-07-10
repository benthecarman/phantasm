import Foundation
import GRDB

/// On-device conversation history (NFR-A3). No cloud dependency in MVP.
///
/// These are GRDB value-type records (SQLite-backed) rather than reference types:
/// relationships are foreign-key columns, not stored object graphs, and the
/// chronological/wire-format helpers live on the `ChatMessage` aggregate and the
/// `[ChatMessage]` array (see below) instead of on the records themselves.
///
/// Every row carries `updatedAt`. `Conversation` retains the nullable `deletedAt`
/// field from the original schema so existing databases remain readable, though
/// current local-only deletes remove the row. Column names match the properties.

/// A conversation's per-chat tool selection, persisted as one JSON column so a
/// new tool is a new field with a default — not a schema migration. Server
/// tools default on (matching a tools-enabled backend out of the box); the
/// device tools default off — each is privacy-sensitive and triggers a system
/// permission prompt. The composer's tool selector flips them per chat.
///
/// Field names are the persisted JSON keys — renaming one requires a data
/// migration; only additions (with decode defaults) are free.
public struct ToolSettings: Codable, Equatable, Sendable {
    public var webSearch: Bool
    public var imageGeneration: Bool
    public var location: Bool
    public var health: Bool
    public var calendar: Bool

    public init(
        webSearch: Bool = true,
        imageGeneration: Bool = true,
        location: Bool = false,
        health: Bool = false,
        calendar: Bool = false
    ) {
        self.webSearch = webSearch
        self.imageGeneration = imageGeneration
        self.location = location
        self.health = health
        self.calendar = calendar
    }

    /// Absent keys decode to their defaults, so adding a field never breaks
    /// rows persisted before it existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? true
        imageGeneration = try c.decodeIfPresent(Bool.self, forKey: .imageGeneration) ?? true
        location = try c.decodeIfPresent(Bool.self, forKey: .location) ?? false
        health = try c.decodeIfPresent(Bool.self, forKey: .health) ?? false
        calendar = try c.decodeIfPresent(Bool.self, forKey: .calendar) ?? false
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable,
    FetchableRecord, PersistableRecord
{
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Legacy tombstone field retained for on-disk compatibility.
    public var deletedAt: Date?
    public var modelID: String?
    public var profileID: UUID?
    /// Per-chat tool selection (one JSON column; see `ToolSettings`).
    public var toolSettings: ToolSettings
    /// The selected research/turn mode for this chat (e.g. `"deep-research"`),
    /// or `nil` for an ordinary turn. It's the *UI preference*; at send time it
    /// reaches the wire only as a suffix on the `model` id (`<base>:<mode>`),
    /// and only when the backend advertises that mode. The composer's research
    /// picker flips it. (Named to stay visually distinct from `modelID`.)
    public var turnModeID: String?
    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        modelID: String? = nil,
        profileID: UUID? = nil,
        toolSettings: ToolSettings = ToolSettings(),
        turnModeID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
        self.modelID = modelID
        self.profileID = profileID
        self.toolSettings = toolSettings
        self.turnModeID = turnModeID
    }

    public static let databaseTableName = "conversation"
}

public extension Conversation {
    // Flat accessors for the composer/tool-menu call sites.
    var webSearchEnabled: Bool {
        get { toolSettings.webSearch }
        set { toolSettings.webSearch = newValue }
    }
    var imageGenerationEnabled: Bool {
        get { toolSettings.imageGeneration }
        set { toolSettings.imageGeneration = newValue }
    }
    var locationEnabled: Bool {
        get { toolSettings.location }
        set { toolSettings.location = newValue }
    }
    var healthEnabled: Bool {
        get { toolSettings.health }
        set { toolSettings.health = newValue }
    }
    var calendarEnabled: Bool {
        get { toolSettings.calendar }
        set { toolSettings.calendar = newValue }
    }
}

public extension Conversation {
    /// Names of the tools this chat wants offered this turn, intersected against
    /// what the backend advertises (`capabilities.toolSelectors`). Returns `nil`
    /// when the backend exposes no orchestrator manifest, so the caller omits the
    /// `tools` selection entirely and keeps the request standard; otherwise the
    /// possibly empty selection encodes as standard `tools`/`tool_choice`.
    func requestedToolNames(supporting toolSelectors: [Capabilities.ToolSelector]?) -> [String]? {
        guard let toolSelectors else { return nil }
        func tools(for id: String) -> [String] {
            toolSelectors.first { $0.id == id }?.tools ?? []
        }
        var names: [String] = []
        // Offline utility tools (calculator, unit convert, OCR) never touch the
        // network, so they're always offered — independent of the web-access and
        // image toggles.
        names.append(contentsOf: tools(for: ToolSelectorName.utilities))
        if webSearchEnabled { names.append(contentsOf: tools(for: ToolSelectorName.webSearch)) }
        if imageGenerationEnabled { names.append(contentsOf: tools(for: ToolSelectorName.imageGeneration)) }
        return names
    }

    /// Thinking is independent of the research mode (redesign §7): the preset
    /// (server) or the user (client) decides reasoning, never welded to the mode.
    func reasoningEffort(thinkingEnabled: Bool, disabledEffort: String?) -> String? {
        thinkingEnabled ? ReasoningEffort.enabledDefault : disabledEffort
    }

    /// The `model` string to send for this turn. When this chat has a research
    /// mode selected AND the backend advertises it (`availableModes`) AND the
    /// base model is tool-capable, the mode rides as a suffix (`<base>:<mode>`,
    /// resolved server-side, spec §2.1). Otherwise the bare base model — the only
    /// place mode reaches the wire (redesign §7).
    func wireModel(
        base: String,
        availableModes: [Capabilities.Mode],
        baseModelIsToolCapable: Bool
    ) -> String {
        guard let turnModeID,
              baseModelIsToolCapable,
              availableModes.contains(where: { $0.id == turnModeID })
        else { return base }
        return "\(base):\(turnModeID)"
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
    /// Explicit per-conversation ordinal, assigned by the store on insert.
    /// This — not `createdAt` — is the message order: burst inserts from the
    /// tool flow land in the same millisecond, and strict OpenAI backends
    /// reject a history whose tool result precedes its `tool_calls` row.
    public var position: Int

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
        name: String? = nil,
        position: Int = 0
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
        self.position = position
    }

    public static let databaseTableName = "message"
}

/// Kinds of message attachment. Images ride along as vision input; text files
/// are extracted to plain text on-device and inlined into the prompt.
public enum AttachmentKind: String, Sendable {
    case image
    case text
    /// A locally-cached copy of a server-hosted generated image. The message
    /// content keeps the compact `/v1/files/<id>/content` reference (so re-sent
    /// history stays small); these bytes back its display once the signed URL
    /// expires and offline. `name` holds the server `<id>`. Deliberately *not*
    /// re-serialized to the wire by `wireContent()` — the reference already is.
    case remoteImage = "remote_image"
    /// A generated image the store extracted from inline base64 markdown at
    /// persist time (see `InlineImageRef`): the content keeps a compact
    /// `phantasm-file://<name>` link, these bytes back it. Restored into the
    /// content — not serialized as image parts — by `wireContent()`, so history
    /// round-trips the exact markdown the model produced.
    case inlineImage = "inline_image"
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

    /// Bytes of the message's extracted inline images, keyed by their
    /// `phantasm-file://<name>` link name — the restore input for both the
    /// wire (`wireContent`) and the renderer.
    public var inlineImages: [String: ServerImageRef.CachedImage] {
        var out: [String: ServerImageRef.CachedImage] = [:]
        for a in attachments where a.kind == AttachmentKind.inlineImage.rawValue {
            out[a.name] = ServerImageRef.CachedImage(data: a.data, mime: a.mimeType)
        }
        return out
    }

    /// The wire body for this message. Plain text unless the message carries
    /// attachments; image attachments become `image_url` parts and text files
    /// are inlined as additional text (so non-vision models still get them).
    /// Extracted inline images are restored into the text as the data-URI
    /// markdown the model originally produced.
    public func wireContent() -> WireContent {
        let content = InlineImageRef.restore(message.content, images: inlineImages)
        let images = attachments.filter { $0.kind == AttachmentKind.image.rawValue }
        let files = attachments.filter { $0.kind == AttachmentKind.text.rawValue }
        guard !images.isEmpty || !files.isEmpty else { return .text(content) }

        var textBlocks: [String] = []
        if !content.isEmpty { textBlocks.append(content) }
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

public extension ChatMessage {
    /// The chart(s) this assistant row asked to render, decoded from its forwarded
    /// `render_chart` tool calls — each either a drawable `ChartSpec` or a
    /// validation error the view shows as a plain-text fallback. Empty unless the
    /// row carries at least one `render_chart` call. Pure/host-testable so the view
    /// stays dumb (just renders or shows the fallback).
    var chartRenders: [Result<ChartSpec, ChartSpec.ValidationError>] {
        renderChartCalls.map { ChartSpec.decode(fromArguments: $0.function?.arguments) }
    }

    /// Whether this row carries a `render_chart` call — keeps the otherwise-empty
    /// tool-call row visible in the transcript so the chart can be drawn.
    var hasChartRender: Bool { !renderChartCalls.isEmpty }

    private var renderChartCalls: [WireToolCall] {
        guard message.role == "assistant", let json = message.toolCalls,
              let data = json.data(using: .utf8),
              let calls = try? Wire.decoder().decode([WireToolCall].self, from: data)
        else { return [] }
        return calls.filter { $0.function?.name == ToolName.renderChart }
    }
}

public extension Array where Element == ChatMessage {
    /// Full history mapped to the wire format (stateless server, XR-2). Only
    /// completed messages are sent. Assistant messages that forwarded app-tool
    /// calls and their `tool`-role results round-trip so the model sees the
    /// call/result pair. Every call in a forwarded batch is guaranteed a matching
    /// result: the stored `tool` rows that follow are emitted, and any call still
    /// without one (a dismissed prompt, or an unanswered call in a partially
    /// resolved mixed batch) gets a synthetic "(dismissed)" result — keeping the
    /// history OpenAI-valid per-call, not just per-message.
    func wireHistory() -> [WireMessage] {
        let completed = filter { $0.message.isComplete }
        var out: [WireMessage] = []
        var index = 0
        while index < completed.count {
            let item = completed[index]
            let m = item.message

            if m.role == "tool", let toolCallId = m.toolCallId {
                out.append(WireMessage(
                    toolResult: toolCallId,
                    name: m.name ?? ToolName.askUser,
                    content: m.content
                ))
                index += 1
                continue
            }

            if let calls = decodeToolCalls(m.toolCalls), !calls.isEmpty {
                // Keep any preamble text the model wrote with the calls — it is
                // part of the model's own context, and dropping it desyncs what
                // the model believes it already told the user.
                out.append(WireMessage(assistantToolCalls: calls, content: m.content))
                // Emit every stored `tool` result that follows this batch, tracking
                // which call ids got answered.
                var answered = Set<String>()
                var next = index + 1
                while next < completed.count,
                      completed[next].message.role == "tool",
                      let id = completed[next].message.toolCallId {
                    let result = completed[next].message
                    out.append(WireMessage(
                        toolResult: id,
                        name: result.name ?? ToolName.askUser,
                        content: result.content
                    ))
                    answered.insert(id)
                    next += 1
                }
                // Fill in any call the model made that never got a result.
                for call in calls where !(call.id.map(answered.contains) ?? false) {
                    out.append(WireMessage(
                        toolResult: call.id ?? "",
                        name: call.function?.name ?? ToolName.askUser,
                        content: "(dismissed)"
                    ))
                }
                index = next
                continue
            }

            if !(m.content.isEmpty && item.attachments.isEmpty) {
                out.append(WireMessage(role: m.role, content: item.wireContent()))
            }
            index += 1
        }
        return out
    }

    /// The trailing app-tool-call batch still awaiting results, if the most recent
    /// activity is an assistant `tool_calls` message followed *only* by `tool`
    /// results (i.e. the turn hasn't continued past it). Returns the forwarded
    /// calls plus the set of call ids already answered — used after a relaunch to
    /// restore a pending interactive prompt (including one in a mixed batch whose
    /// auto-resolved results were already persisted). Nil if there's no such batch
    /// or the turn already moved on.
    func activeToolCallBatch() -> (calls: [WireToolCall], answered: Set<String>)? {
        let completed = filter { $0.message.isComplete }
        guard let k = completed.lastIndex(where: {
            $0.message.role == "assistant" && $0.message.toolCalls != nil
        }) else { return nil }
        let after = completed[(k + 1)...]
        guard after.allSatisfy({ $0.message.role == "tool" }) else { return nil }
        guard let calls = decodeToolCalls(completed[k].message.toolCalls), !calls.isEmpty else {
            return nil
        }
        let answered = Set(after.compactMap { $0.message.toolCallId })
        return (calls, answered)
    }

    private func decodeToolCalls(_ json: String?) -> [WireToolCall]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? Wire.decoder().decode([WireToolCall].self, from: data)
    }
}
