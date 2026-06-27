import Foundation

/// OpenAI-compatible wire types shared by the chat + capabilities clients.
///
/// The app is a plain OpenAI client (spec §2.2): it sends full history each turn
/// and reads streamed `delta.content`. The only non-standard element is the
/// additive `x_status` field used for progress (§2.3).

public enum ReasoningEffort {
    public static let disabled = "none"
    public static let enabledDefault = "medium"
}

/// One entry of the standard OpenAI `tools` array. Two flavors:
///   * **server-tool selector** — name only; the orchestrator owns the schema and
///     executes the tool.
///   * **app-hosted tool** — a full schema (description + parameters); the
///     orchestrator forwards calls back to the app to execute. Its presence of
///     `parameters` is what marks it app-side (orchestrator §2.3).
public struct ToolSpec: Encodable, Sendable {
    public struct Function: Encodable, Sendable {
        public var name: String
        public var description: String?
        public var parameters: JSONValue?
    }
    public var type: String
    public var function: Function

    /// A name-only server-tool selector.
    public init(name: String) {
        self.type = "function"
        self.function = Function(name: name, description: nil, parameters: nil)
    }

    /// A full app-hosted tool definition the app will execute.
    public init(name: String, description: String, parameters: JSONValue) {
        self.type = "function"
        self.function = Function(name: name, description: description, parameters: parameters)
    }
}

/// A minimal JSON value, just enough to express an app tool's JSON-Schema
/// `parameters` inline. Encodes through the shared snake_case encoder; all schema
/// keys are already lowercase/underscored so they pass through unchanged.
public indirect enum JSONValue: Encodable, Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// One streamed/persisted tool call (OpenAI shape). `arguments` is a JSON-encoded
/// string. All fields optional so partial streaming fragments still decode.
public struct WireToolCall: Codable, Sendable, Equatable {
    public struct Function: Codable, Sendable, Equatable {
        public var name: String?
        public var arguments: String?
        public init(name: String?, arguments: String?) {
            self.name = name
            self.arguments = arguments
        }
    }
    public var index: Int?
    public var id: String?
    public var type: String?
    public var function: Function?

    public init(
        index: Int? = nil,
        id: String? = nil,
        type: String? = "function",
        function: Function?
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ChatRequest: Encodable, Sendable {
    public var model: String
    public var messages: [WireMessage]
    public var stream: Bool
    public var reasoningEffort: String?
    /// Per-request tool selection via the **standard** OpenAI `tools` array
    /// (spec §2.3): the names of the server tools to offer this turn. The server
    /// fills in the real schemas and intersects with what it has configured. `nil`
    /// omits the field (server offers all configured tools — and keeps plain-chat
    /// requests byte-for-byte standard).
    public var tools: [ToolSpec]?
    /// Standard OpenAI `tool_choice`. Set to `"none"` to force plain chat.
    public var toolChoice: String?

    public init(
        model: String,
        messages: [WireMessage],
        stream: Bool = true,
        reasoningEffort: String? = nil,
        enabledTools: [String]? = nil,
        appTools: [ToolSpec] = []
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.reasoningEffort = reasoningEffort
        // Translate the per-turn selection into standard OpenAI fields. Server
        // tools ride as name-only selectors; app-hosted tools ride as full
        // schemas the server forwards back to us. `tool_choice:"none"` only when
        // there are truly no tools (server selection [] AND no app tools).
        var specs: [ToolSpec] = []
        if let enabledTools, !enabledTools.isEmpty {
            specs += enabledTools.map(ToolSpec.init(name:))
        }
        specs += appTools
        if !specs.isEmpty {
            self.tools = specs
        } else if enabledTools?.isEmpty == true {
            self.toolChoice = "none"
        }
    }
}

public struct WireMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: WireContent
    /// Tool calls on an assistant message (forwarded app-tool calls re-sent in
    /// history). Omitted when nil, so plain messages stay byte-for-byte standard.
    public var toolCalls: [WireToolCall]?
    /// The call this message answers (a `tool`-role result).
    public var toolCallId: String?
    /// The tool name (a `tool`-role result).
    public var name: String?

    public init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }

    public init(role: String, content: WireContent) {
        self.role = role
        self.content = content
    }

    /// An assistant message carrying forwarded tool calls (empty text body).
    public init(assistantToolCalls: [WireToolCall]) {
        self.role = "assistant"
        self.content = .text("")
        self.toolCalls = assistantToolCalls
    }

    /// A `tool`-role result answering a specific tool call.
    public init(toolResult toolCallId: String, name: String, content: String) {
        self.role = "tool"
        self.content = .text(content)
        self.toolCallId = toolCallId
        self.name = name
    }
}

/// A message body that is either a plain string (the common case) or the OpenAI
/// multimodal content-parts array. We only emit parts when a message carries
/// attachments, so plain turns stay byte-for-byte compatible with raw Ollama.
public enum WireContent: Sendable, Equatable {
    case text(String)
    case parts([WirePart])
}

public extension WireContent {
    /// Concatenated text runs, ignoring images. For string content, the string.
    var plainText: String {
        switch self {
        case .text(let string):
            return string
        case .parts(let parts):
            return parts
                .compactMap { if case .text(let t) = $0 { return t } else { return nil } }
                .joined(separator: "\n")
        }
    }

    /// Decoded image payloads from any `image_url` data-URI parts (for the
    /// native Ollama client, which carries images as raw `Data`).
    var imageData: [Data] {
        guard case .parts(let parts) = self else { return [] }
        return parts.compactMap { part -> Data? in
            guard case .imageURL(let url) = part else { return nil }
            return WireContent.decodeDataURI(url)
        }
    }

    /// Decode the base64 payload of a `data:<mime>;base64,…` URI (or a bare
    /// base64 string). Returns nil for non-data URLs.
    static func decodeDataURI(_ url: String) -> Data? {
        guard let range = url.range(of: ";base64,") else {
            return url.hasPrefix("data:") ? nil : Data(base64Encoded: url)
        }
        return Data(base64Encoded: String(url[range.upperBound...]))
    }
}

extension WireContent: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = .parts(try container.decode([WirePart].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string): try container.encode(string)
        case .parts(let parts): try container.encode(parts)
        }
    }
}

/// One element of a multimodal message: a text run or an image (as a data URI).
public enum WirePart: Sendable, Equatable {
    case text(String)
    /// `image_url` part; `url` is a `data:<mime>;base64,…` data URI.
    case imageURL(String)
}

extension WirePart: Codable {
    // Raw values must round-trip through the shared encoder/decoder's
    // snake_case conversion: "imageUrl" → "image_url" on encode and back.
    private enum CodingKeys: String, CodingKey {
        case type, text, imageURL = "imageUrl"
    }
    private struct ImageURLBox: Codable, Equatable { var url: String }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "image_url":
            self = .imageURL(try container.decode(ImageURLBox.self, forKey: .imageURL).url)
        default:
            self = .text(try container.decode(String.self, forKey: .text))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLBox(url: url), forKey: .imageURL)
        }
    }
}

/// One streamed `chat.completion.chunk`. `xStatus` maps the additive `x_status`
/// field; absence is normal (e.g. raw Ollama) and must not break decoding.
public struct ChatChunk: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public struct Delta: Decodable, Sendable {
            public let content: String?
            public let reasoning: String?
            public let reasoningContent: String?
            public let thinking: String?
            /// Forwarded app-hosted tool calls (the chunk that hands a call back
            /// to the app). Absent on ordinary content/reasoning chunks.
            public let toolCalls: [WireToolCall]?
        }
        public let delta: Delta
        public let finishReason: String?
    }
    public let choices: [Choice]
    public let xStatus: String?
}

public extension ChatChunk.Choice.Delta {
    /// Different OpenAI-compatible backends use different names for streamed
    /// reasoning. Normalize them before the UI sees the event.
    var reasoningText: String? {
        reasoning ?? reasoningContent ?? thinking
    }
}

/// The capabilities manifest (spec §2.1).
public struct Capabilities: Decodable, Sendable, Equatable {
    public struct Tools: Decodable, Sendable, Equatable {
        public let webSearch: Bool
        public let imageGeneration: Bool

        public init(webSearch: Bool, imageGeneration: Bool) {
            self.webSearch = webSearch
            self.imageGeneration = imageGeneration
        }
    }
    /// One advertised turn mode (spec §2.3 `modes`). The app composes
    /// `model + ":" + id` for a turn, gated on `needs ⊆ available tools` and a
    /// tool-capable base model. Modes are server-side data; the app only mirrors
    /// the manifest, never hardcodes the table.
    public struct Mode: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let needs: [String]

        public init(id: String, label: String, needs: [String]) {
            self.id = id
            self.label = label
            self.needs = needs
        }
    }
    public let version: String
    public let chat: Bool
    public let models: [String]
    /// Subset of `models` that accept image input. `nil` when the manifest omits
    /// the field (older orchestrator) — vision is then treated as unknown.
    public let visionModels: [String]?
    /// Subset of `models` that support tool/function calling. The server tools
    /// can only be driven by a model in this list, so tool toggles gate on both.
    /// `nil` when the manifest omits the field — tool support is then unknown.
    public let toolModels: [String]?
    public let tools: Tools?
    /// Advertised turn modes (e.g. Deep Research), present only when their needed
    /// tools are usable. `nil` when the manifest omits the field (older
    /// orchestrator) — the app then shows no research UI (graceful, FR-A2).
    public let modes: [Mode]?
    public let streaming: String?

    public init(
        version: String,
        chat: Bool,
        models: [String],
        visionModels: [String]? = nil,
        toolModels: [String]? = nil,
        tools: Tools?,
        modes: [Mode]? = nil,
        streaming: String?
    ) {
        self.version = version
        self.chat = chat
        self.models = models
        self.visionModels = visionModels
        self.toolModels = toolModels
        self.tools = tools
        self.modes = modes
        self.streaming = streaming
    }
}

/// Canonical server tool names, shared by the `x_tools` request field and the
/// per-conversation toggles. These MUST match the orchestrator's tool schema
/// names (`orchestrator/src/tools/*`).
public enum ToolName {
    public static let webSearch = "web_search"
    public static let imageGeneration = "image_generation"
    /// App-hosted: the model asks the user a multiple-choice question. The app
    /// owns this tool's schema and executes it (renders the prompt).
    public static let askUser = "ask_user_input"
    /// App-hosted: the model asks for the current date/time. The app answers from
    /// the device's own clock + timezone and continues the turn automatically (no
    /// UI, no user interaction). See `CurrentTimeTool`.
    public static let currentTime = "current_time"
    /// App-hosted: the model asks for the user's current location. The app answers
    /// from the device (CoreLocation + reverse geocoding) and continues the turn
    /// automatically. Off by default and toggled per chat. See `LocationTool`.
    public static let location = "get_current_location"
}

/// Tools the **app** hosts: it sends their full schemas each turn and executes
/// any call the orchestrator forwards back. The schemas live on the tool types in
/// `AppToolRegistry` (the single source of truth); this is the request-layer view
/// of that list. Adding a tool is one entry in `AppToolRegistry.tools`.
public enum AppTools {
    /// Every app-hosted tool schema to advertise this turn.
    public static var all: [ToolSpec] { AppToolRegistry.specs }
}

/// How the backend can be used after a capability probe (spec §2.1, FR-A2).
public enum BackendMode: Sendable, Equatable {
    /// Manifest present — full feature set advertised.
    case full(Capabilities)
    /// Raw Ollama detected via `/api/tags` — use native `/api/chat` streaming.
    case ollamaNative(models: [String])
    /// No manifest (404 / not an orchestrator) — plain chat only, no tool UI.
    /// Carries any models discovered from `/v1/models` so the picker still works.
    case plainChatOnly(models: [String])

    public var capabilities: Capabilities? {
        if case let .full(caps) = self { return caps }
        return nil
    }

    /// Models to offer in the picker (empty => free-text entry).
    public var models: [String] {
        switch self {
        case .full(let caps): return caps.models
        case .ollamaNative(let models): return models
        case .plainChatOnly(let models): return models
        }
    }

    public var showsTools: Bool {
        guard let tools = capabilities?.tools else { return false }
        return tools.webSearch || tools.imageGeneration
    }

    /// Turn modes (e.g. Deep Research) advertised by the backend whose needed
    /// tools are actually usable. Empty for non-orchestrator backends or when the
    /// manifest omits `modes` — the composer hides the research UI then.
    public var availableModes: [Capabilities.Mode] {
        guard let caps = capabilities, let modes = caps.modes else { return [] }
        let tools = caps.tools
        return modes.filter { mode in
            mode.needs.allSatisfy { need in
                switch need {
                case ToolName.webSearch: return tools?.webSearch == true
                case ToolName.imageGeneration: return tools?.imageGeneration == true
                default: return false
                }
            }
        }
    }

    public var usesOllamaNativeChat: Bool {
        if case .ollamaNative = self { return true }
        return false
    }

    public func resolvedChatModel(
        conversationModel: String?,
        defaultModel: String?
    ) -> String? {
        let conversationModel = conversationModel?.nonEmptyTrimmed
        let defaultModel = defaultModel?.nonEmptyTrimmed

        switch self {
        case .ollamaNative(let models):
            if models.isEmpty {
                return conversationModel ?? defaultModel
            }
            if let conversationModel,
               let validConversationModel = models.firstMatching(conversationModel) {
                return validConversationModel
            }
            if let defaultModel,
               let validDefaultModel = models.firstMatching(defaultModel) {
                return validDefaultModel
            }
            return models.first

        case .full, .plainChatOnly:
            return conversationModel ?? defaultModel ?? models.first
        }
    }
}

private extension Array where Element == String {
    func firstMatching(_ target: String) -> String? {
        first { $0.caseInsensitiveCompare(target) == .orderedSame }
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A shared JSON decoder configured for the OpenAI snake_case wire format.
public enum Wire {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}
