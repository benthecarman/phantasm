import Foundation

/// OpenAI-compatible wire types shared by the chat + capabilities clients.
///
/// The app is a plain OpenAI client (spec §2.2): it sends full history each turn
/// and reads streamed `delta.content`. The only non-standard element is the
/// additive `x_status` field used for progress (§2.3).

public struct ChatRequest: Encodable, Sendable {
    public var model: String
    public var messages: [WireMessage]
    public var stream: Bool
    public var reasoningEffort: String?
    /// Per-request tool selection (spec §2.3): the names of the server tools to
    /// offer this turn, encoded as the additive `x_tools` field. `nil` omits the
    /// field entirely (server offers all configured tools — and keeps plain-chat
    /// requests byte-for-byte standard); an empty array requests plain chat.
    public var xTools: [String]?
    /// Deep Research mode (spec §2.3): when `true`, encoded as the additive
    /// `x_research` field so the orchestrator runs its server-side research loop
    /// (decompose → search across several rounds → synthesize with citations).
    /// `nil` omits the field, keeping ordinary requests standard.
    public var xResearch: Bool?

    public init(
        model: String,
        messages: [WireMessage],
        stream: Bool = true,
        reasoningEffort: String? = "none",
        xTools: [String]? = nil,
        xResearch: Bool? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.reasoningEffort = reasoningEffort
        self.xTools = xTools
        self.xResearch = xResearch
    }
}

public struct WireMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: WireContent

    public init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }

    public init(role: String, content: WireContent) {
        self.role = role
        self.content = content
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
        }
        public let delta: Delta
        public let finishReason: String?
    }
    public let choices: [Choice]
    public let xStatus: String?
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
    public let streaming: String?

    public init(
        version: String,
        chat: Bool,
        models: [String],
        visionModels: [String]? = nil,
        toolModels: [String]? = nil,
        tools: Tools?,
        streaming: String?
    ) {
        self.version = version
        self.chat = chat
        self.models = models
        self.visionModels = visionModels
        self.toolModels = toolModels
        self.tools = tools
        self.streaming = streaming
    }
}

/// Canonical server tool names, shared by the `x_tools` request field and the
/// per-conversation toggles. These MUST match the orchestrator's tool schema
/// names (`orchestrator/src/tools/*`).
public enum ToolName {
    public static let webSearch = "web_search"
    public static let imageGeneration = "image_generation"
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
