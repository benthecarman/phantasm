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

    /// A name-only concrete server-tool selection.
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
        // tools ride as name-only concrete names; app-hosted tools ride as full
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

/// One streamed `chat.completion.chunk`. `xStatus` / `xProgress` map additive
/// `x_` fields; absence is normal (e.g. raw Ollama) and must not break decoding.
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
    public let xProgress: Double?
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
    public struct Model: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let capabilities: ModelCapabilities?
        public let contextLength: Int?

        public init(id: String, capabilities: ModelCapabilities? = nil, contextLength: Int? = nil) {
            self.id = id
            self.capabilities = capabilities
            self.contextLength = contextLength
        }
    }

    public struct ModelCapabilities: Decodable, Sendable, Equatable {
        public let completion: Bool
        public let vision: Bool
        public let audio: Bool
        public let tools: Bool
        public let insert: Bool
        public let thinking: Bool
        public let embedding: Bool

        public init(
            completion: Bool,
            vision: Bool,
            audio: Bool,
            tools: Bool,
            insert: Bool,
            thinking: Bool,
            embedding: Bool
        ) {
            self.completion = completion
            self.vision = vision
            self.audio = audio
            self.tools = tools
            self.insert = insert
            self.thinking = thinking
            self.embedding = embedding
        }
    }

    public struct ToolSelector: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        /// Concrete server tool schema names selected by this app-facing bucket.
        public let tools: [String]

        public init(id: String, label: String, tools: [String]) {
            self.id = id
            self.label = label
            self.tools = tools
        }
    }

    /// One advertised turn mode (spec §2.3 `modes`). The app composes
    /// `model + ":" + id` for a turn, gated on `requiredTools ⊆ toolSelectors`
    /// and a tool-capable base model. Modes are server-side data; the app only
    /// mirrors the manifest, never hardcodes the table.
    public struct Mode: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let requiredTools: [String]

        public init(id: String, label: String, requiredTools: [String]) {
            self.id = id
            self.label = label
            self.requiredTools = requiredTools
        }

        /// Modes the app recognizes for presentation (e.g. distinct icons).
        /// This is *not* the available-modes table — that stays server-driven;
        /// unknown ids simply have no `known` value and fall back to defaults.
        public enum Known: String, Sendable {
            case deepResearch = "deep-research"
            case quickResearch = "quick-research"
        }

        public var known: Known? { Known(rawValue: id) }
    }

    public let version: String
    public let modelEntries: [Model]
    public let toolSelectors: [ToolSelector]
    public let modes: [Mode]

    /// Model ids to offer in the chat picker. Unknown capabilities stay
    /// optimistic; known non-completion models are hidden.
    public var models: [String] {
        modelEntries
            .filter { $0.capabilities?.completion ?? true }
            .map(\.id)
    }

    /// `nil` means at least one model has unknown capabilities, so the UI should
    /// stay optimistic instead of treating missing support as false.
    public var visionModelIDs: Set<String>? {
        supportedModels(where: \.vision)
    }

    /// `nil` means tool support is unknown for this backend.
    public var toolModelIDs: Set<String>? {
        supportedModels(where: \.tools)
    }

    /// `nil` means reasoning support is unknown for this backend.
    public var thinkingModelIDs: Set<String>? {
        supportedModels(where: \.thinking)
    }

    /// Per-model context window sizes, for the models that report one. Models
    /// without a reported window are simply absent from the map.
    public var contextLengthByID: [String: Int] {
        var map: [String: Int] = [:]
        for model in modelEntries {
            if let length = model.contextLength { map[model.id] = length }
        }
        return map
    }

    public init(
        version: String,
        modelEntries: [Model],
        toolSelectors: [ToolSelector] = [],
        modes: [Mode] = []
    ) {
        self.version = version
        self.modelEntries = modelEntries
        self.toolSelectors = toolSelectors
        self.modes = modes
    }

    public func hasToolSelector(_ id: String) -> Bool {
        toolSelectors.contains { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case models
        case toolSelectors
        case modes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        modelEntries = try container.decode([Model].self, forKey: .models)
        toolSelectors = try container.decodeIfPresent([ToolSelector].self, forKey: .toolSelectors) ?? []
        modes = try container.decodeIfPresent([Mode].self, forKey: .modes) ?? []
    }

    private func supportedModels(where predicate: (ModelCapabilities) -> Bool) -> Set<String>? {
        guard modelEntries.allSatisfy({ $0.capabilities != nil }) else { return nil }
        return Set(modelEntries.compactMap { model in
            guard let capabilities = model.capabilities, predicate(capabilities) else { return nil }
            return model.id
        })
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
    /// App-hosted: the model reads the user's on-device Apple Health data. The app
    /// answers from HealthKit and continues the turn automatically (read-only).
    /// Off by default and toggled per chat. See `HealthTool`.
    public static let health = "get_health_data"
    /// App-hosted: the model reads the user's on-device Calendar events. The app
    /// answers from EventKit and continues the turn automatically. Off by default
    /// and toggled per chat. See `CalendarTool`.
    public static let calendar = "get_calendar_events"
    /// App-hosted: the model asks to create an on-device Calendar event. The app
    /// shows a confirmation prompt, then writes through EventKit only if the user
    /// approves. Off by default and toggled per chat. See `CalendarCreateEventTool`.
    public static let createCalendarEvent = "create_calendar_event"
    /// App-hosted: the model emits structured chart data the app renders natively
    /// with Swift Charts. Resolves on-device (the result just acknowledges the
    /// render); the chart is drawn from the call's arguments. See `RenderChartTool`.
    public static let renderChart = "render_chart"
}

/// App-facing capability bucket ids from `capabilities.tool_selectors`.
/// These are UI selectors, not server tool schema names.
public enum ToolSelectorName {
    /// Tools that reach the internet — gated by the per-chat web-access toggle.
    public static let webSearch = "web_search"
    /// Offline, on-box tools (calculator, unit convert, OCR). The app offers these
    /// unconditionally, so turning web access off never disables them.
    public static let utilities = "utilities"
    public static let imageGeneration = "image_generation"
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
        guard let capabilities else { return false }
        return capabilities.hasToolSelector(ToolSelectorName.webSearch)
            || capabilities.hasToolSelector(ToolSelectorName.imageGeneration)
    }

    public var connectionTestMessage: String {
        switch self {
        case .full(let caps):
            let hasServerTools = caps.hasToolSelector(ToolSelectorName.webSearch)
                || caps.hasToolSelector(ToolSelectorName.utilities)
                || caps.hasToolSelector(ToolSelectorName.imageGeneration)
            let toolNote = hasServerTools ? " Web access / image tools available." : " Chat only - no tools advertised."
            return "Connected. \(Self.modelCount(caps.models.count)).\(toolNote)"
        case .ollamaNative(let models):
            let suffix = models.isEmpty ? "" : " \(Self.modelCount(models.count))."
            return "Connected - native Ollama chat.\(suffix)"
        case .plainChatOnly(let models):
            let suffix = models.isEmpty ? "" : " \(Self.modelCount(models.count))."
            return "Connected - chat only (no web search or image tools).\(suffix)"
        }
    }

    /// Turn modes (e.g. Deep Research) advertised by the backend whose required
    /// tool selectors are available. Empty for non-orchestrator backends.
    public var availableModes: [Capabilities.Mode] {
        guard let caps = capabilities else { return [] }
        return caps.modes.filter { mode in
            mode.requiredTools.allSatisfy { caps.hasToolSelector($0) }
        }
    }

    private static func modelCount(_ count: Int) -> String {
        "\(count) model\(count == 1 ? "" : "s")"
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
