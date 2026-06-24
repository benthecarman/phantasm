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

    public init(
        model: String,
        messages: [WireMessage],
        stream: Bool = true,
        reasoningEffort: String? = "none"
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.reasoningEffort = reasoningEffort
    }
}

public struct WireMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
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
    public let tools: Tools?
    public let streaming: String?

    public init(version: String, chat: Bool, models: [String], tools: Tools?, streaming: String?) {
        self.version = version
        self.chat = chat
        self.models = models
        self.tools = tools
        self.streaming = streaming
    }
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
