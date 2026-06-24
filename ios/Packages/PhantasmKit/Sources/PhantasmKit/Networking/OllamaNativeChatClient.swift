import Foundation
import Ollama

/// Native Ollama `/api/chat` client. This is used only when capability probing
/// has identified a raw Ollama backend via `/api/tags`; orchestrator and generic
/// OpenAI-compatible backends continue through `ChatClient`.
public struct OllamaNativeChatClient: ChatClienting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(_ request: ChatRequest, base: URL, token: String)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    guard let model = Ollama.Model.ID(rawValue: request.model) else {
                        throw AppError.modelError("Invalid Ollama model id: \(request.model)")
                    }

                    let client = Ollama.Client(
                        session: session(for: token),
                        host: base,
                        userAgent: "Phantasm"
                    )
                    let stream = try client.chatStream(
                        model: model,
                        messages: request.messages.map(\.ollamaMessage),
                        think: request.reasoningEffort?.caseInsensitiveCompare("none") == .orderedSame ? false : nil,
                        keepAlive: .minutes(30)
                    )

                    var didYieldThinkingStatus = false
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        if let thinking = chunk.message.thinking,
                           !thinking.isEmpty,
                           !didYieldThinkingStatus {
                            didYieldThinkingStatus = true
                            continuation.yield(.status("Thinking..."))
                        }
                        if !chunk.message.content.isEmpty {
                            continuation.yield(.token(chunk.message.content))
                        }
                        if chunk.done {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapOllamaError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func session(for token: String) -> URLSession {
        guard !token.isEmpty else { return session }
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Authorization": "Bearer \(token)"]
        return URLSession(configuration: config)
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

private extension WireMessage {
    var ollamaMessage: Ollama.Chat.Message {
        switch role {
        case "system":
            return .system(content)
        case "assistant":
            return .assistant(content)
        case "tool":
            return .tool(content)
        default:
            return .user(content)
        }
    }
}
