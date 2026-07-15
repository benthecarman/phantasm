import Foundation
import Ollama

/// Native Ollama `/api/chat` client. This is used only when capability probing
/// has identified a raw Ollama backend via `/api/tags`; orchestrator and generic
/// OpenAI-compatible backends continue through `ChatClient`.
public struct OllamaNativeChatClient: ChatClienting {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.streamingSession
    }

    /// Match the OpenAI client's cold-model tolerance: native Ollama can also
    /// sit idle while loading weights before emitting its first NDJSON chunk.
    private static let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    // `turnID` is ignored: a raw Ollama backend has no turn registry, so there's
    // nothing to resume — the connection-bound stream is the only mode.
    public func stream(_ request: ChatRequest, base: URL, token: String, turnID: String?)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            // Deliberately not main-actor-isolated: mapping the full history to
            // Ollama messages base64-decodes every image attachment, and chunk
            // decoding runs per token — both would contend with UI work (NFR-A4).
            // The Ollama client is created and consumed entirely inside this task.
            let task = Task {
                do {
                    guard let model = Ollama.Model.ID(rawValue: request.model) else {
                        throw AppError.modelError("Invalid Ollama model id: \(request.model)")
                    }

                    let client = await Ollama.Client(
                        session: session(for: token),
                        host: base,
                        userAgent: "Phantasm"
                    )
                    let stream = try await client.chatStream(
                        model: model,
                        messages: request.messages.map(\.ollamaMessage),
                        tools: ollamaTools(from: request.tools),
                        think: request.ollamaThink
                    )

                    // App-hosted tool calls accumulate across chunks; Ollama
                    // returns them whole (not fragmented), so each call maps
                    // straight to a `WireToolCall`. The native API gives calls no
                    // id, but the downstream resolver keys every call by `id`
                    // (skipping any without one), so we synthesize a stable one.
                    var toolCalls: [WireToolCall] = []
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        if let thinking = chunk.message.thinking,
                           !thinking.isEmpty {
                            continuation.yield(.reasoning(thinking))
                        }
                        if !chunk.message.content.isEmpty {
                            continuation.yield(.token(chunk.message.content))
                        }
                        for call in chunk.message.toolCalls ?? [] {
                            let index = toolCalls.count
                            toolCalls.append(WireToolCall(
                                index: index,
                                id: "call_\(index)",
                                function: .init(
                                    name: call.function.name,
                                    arguments: encodeArguments(call.function.arguments)
                                )
                            ))
                        }
                        if chunk.done {
                            if !toolCalls.isEmpty {
                                continuation.yield(.toolCalls(toolCalls))
                            }
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    }
                    throw AppError.modelError(
                        "The connection closed before the response finished."
                    )
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapOllamaError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maps the request's app-hosted tool specs to Ollama tools. Only full
    /// schemas (app tools carry `parameters`) are forwarded — name-only server
    /// selectors have no schema to send, and a raw Ollama backend has no server
    /// tools anyway. Each spec is re-encoded through the same wire encoder used
    /// for OpenAI backends, so the model sees an identical schema.
    private func ollamaTools(from specs: [ToolSpec]?) -> [any ToolProtocol]? {
        guard let specs else { return nil }
        let encoder = Wire.encoder()
        let tools: [any ToolProtocol] = specs.compactMap { spec in
            guard spec.function.parameters != nil,
                  let data = try? encoder.encode(spec),
                  let value = try? JSONDecoder().decode(Value.self, from: data)
            else { return nil }
            return RawTool(schema: value)
        }
        return tools.isEmpty ? nil : tools
    }

    /// Serializes Ollama's structured tool-call arguments back into the
    /// JSON-encoded string that `WireToolCall` (and the OpenAI shape) expects.
    private func encodeArguments(_ args: [String: Value]) -> String {
        guard let data = try? JSONEncoder().encode(args),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private func session(for token: String) -> URLSession {
        guard !token.isEmpty else { return session }
        return Self.tokenedSessions.session(for: token)
    }

    /// One session per bearer token, reused across turns. Building a fresh
    /// URLSession per streamed turn (and never invalidating it) accumulates
    /// resources; Apple recommends session reuse.
    private static let tokenedSessions = TokenedSessionCache()

    private final class TokenedSessionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [String: URLSession] = [:]

        func session(for token: String) -> URLSession {
            lock.lock()
            defer { lock.unlock() }
            if let cached = sessions[token] { return cached }
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 60 * 60
            config.httpAdditionalHeaders = ["Authorization": "Bearer \(token)"]
            let session = URLSession(configuration: config)
            // Profiles change tokens rarely; drop stale sessions instead of
            // growing without bound.
            if sessions.count >= 4 {
                sessions.values.forEach { $0.finishTasksAndInvalidate() }
                sessions.removeAll()
            }
            sessions[token] = session
            return session
        }
    }

    private func mapOllamaError(_ error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let clientError = error as? Ollama.Client.Error {
            switch clientError {
            case .responseError(let response, let detail):
                return AppError.fromStatus(response.statusCode) ?? .modelError(detail)
            case .decodingError(_, let detail), .requestError(let detail), .unexpectedError(let detail):
                return .modelError(detail)
            }
        }
        return AppError.from(error)
    }
}

/// Minimal `ToolProtocol` conformer that carries a pre-built tool schema value
/// straight through to Ollama (the app already holds full OpenAI-style schemas).
private struct RawTool: ToolProtocol {
    let schema: any (Codable & Sendable)
}

private extension WireMessage {
    var ollamaMessage: Ollama.Chat.Message {
        let text = content.plainText
        let images = content.imageData
        let attachedImages = images.isEmpty ? nil : images
        switch role {
        case "system":
            return .system(text, images: attachedImages)
        case "assistant":
            if let toolCalls, !toolCalls.isEmpty {
                return .assistant(
                    text, images: attachedImages,
                    toolCalls: toolCalls.compactMap(\.ollamaToolCall)
                )
            }
            return .assistant(text, images: attachedImages)
        case "tool":
            return .tool(text)
        default:
            return .user(text, images: attachedImages)
        }
    }
}

private extension WireToolCall {
    /// Converts a persisted OpenAI-shape tool call back into Ollama's structured
    /// form so the assistant's tool_call turn is echoed when continuing a turn.
    var ollamaToolCall: Ollama.Chat.Message.ToolCall? {
        guard let name = function?.name else { return nil }
        var arguments: [String: Value] = [:]
        if let raw = function?.arguments,
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Value].self, from: data) {
            arguments = decoded
        }
        return .init(function: .init(name: name, arguments: arguments))
    }
}

private extension ChatRequest {
    var ollamaThink: Bool? {
        guard let reasoningEffort else { return nil }
        return reasoningEffort.caseInsensitiveCompare(ReasoningEffort.disabled) == .orderedSame ? false : true
    }
}
