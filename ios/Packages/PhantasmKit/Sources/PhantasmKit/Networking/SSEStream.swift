import Foundation

/// A classified SSE line. The classifier is pure (no networking) so it can be
/// unit-tested directly.
public enum SSELine: Equatable, Sendable {
    /// A `data:` payload (the text after the prefix).
    case event(data: String)
    /// `data: [DONE]` — the OpenAI stream terminator.
    case done
    /// A `:` comment / keep-alive line.
    case comment
    /// A blank line (event boundary).
    case blank
}

/// Classify one raw SSE line.
public func classifySSELine(_ raw: String) -> SSELine {
    let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
    if line.isEmpty { return .blank }
    if line.hasPrefix(":") { return .comment }
    // A field line with no colon carries an empty value per the SSE spec.
    if line == "data" { return .event(data: "") }
    if let data = stripDataPrefix(line) {
        return data == "[DONE]" ? .done : .event(data: data)
    }
    // Unknown field lines (event:, id:, retry:) are treated as comments.
    return .comment
}

private func stripDataPrefix(_ line: String) -> String? {
    guard line.hasPrefix("data:") else { return nil }
    let afterColon = line.dropFirst("data:".count)
    // SSE allows an optional single leading space after the colon.
    return afterColon.hasPrefix(" ") ? String(afterColon.dropFirst()) : String(afterColon)
}

/// Merge a streamed tool-call fragment into the accumulator at `key`: keep the
/// first non-nil id/name/type, and append argument fragments. The orchestrator
/// sends each call whole in one chunk, but this also handles standard OpenAI
/// fragmented streaming.
func mergeToolCall(_ call: WireToolCall, into acc: inout [Int: WireToolCall], key: Int) {
    var merged = acc[key] ?? WireToolCall(index: key, id: nil, type: call.type, function: nil)
    if let id = call.id { merged.id = id }
    if let type = call.type { merged.type = type }
    let name = merged.function?.name ?? call.function?.name
    let args = (merged.function?.arguments ?? "") + (call.function?.arguments ?? "")
    merged.function = WireToolCall.Function(name: name, arguments: args.isEmpty ? nil : args)
    acc[key] = merged
}

/// The standard OpenAI mid-stream error event: `data: {"error":{"message":…}}`.
private struct StreamErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
    }
    let error: Payload
}

/// A domain event consumed by the chat UI.
public enum ChatStreamEvent: Sendable, Equatable {
    case token(String)      // append delta.content
    case reasoning(String)  // append model thinking/reasoning deltas
    case status(String)     // x_status -> progress UI (FR-A8)
    case progress(String, Double) // x_status + normalized x_progress
    case throughput(Double) // authoritative x_tokens_per_second
    case toolCalls([WireToolCall]) // forwarded app-hosted tool calls (finish_reason: tool_calls)
    case done
}

/// Turn an async sequence of raw lines into typed chat events. Pure of
/// networking so it can be driven from fixtures in tests.
///
/// Accumulates consecutive `data:` lines until an event boundary (blank line),
/// per the SSE spec, before decoding — robust to multi-line `data:` frames.
public func chatEventStream<Lines: AsyncSequence & Sendable>(
    lines: Lines,
    decoder: JSONDecoder = Wire.decoder()
) -> AsyncThrowingStream<ChatStreamEvent, Error> where Lines.Element == String {
    AsyncThrowingStream { continuation in
        let task = Task {
            var dataBuffer: [String] = []
            // Forwarded tool calls accumulate across chunks (merged by index, so
            // standard fragmented streaming works); flushed on the terminating
            // frame before `.done`.
            var toolCalls: [Int: WireToolCall] = [:]

            func flush() throws -> Bool {
                // Returns true if the stream should end (decoded a finish).
                guard !dataBuffer.isEmpty else { return false }
                let payload = dataBuffer.joined(separator: "\n")
                dataBuffer.removeAll(keepingCapacity: true)
                let data = Data(payload.utf8)
                guard let chunk = try? decoder.decode(ChatChunk.self, from: data) else {
                    // OpenAI-compatible servers report mid-stream failures (rate
                    // limit, context overflow, upstream crash) as a terminal
                    // `data: {"error":{…}}` event. Surfacing it as a thrown error
                    // keeps the truncated text from being committed as a normal
                    // complete message.
                    if let envelope = try? decoder.decode(StreamErrorEnvelope.self, from: data) {
                        throw AppError.modelError(envelope.error.message ?? "stream error")
                    }
                    return false // tolerate junk chunks (FR-A8)
                }
                // x_status and x_progress are additive and independent (§2.3):
                // progress without a status still surfaces (with an empty label)
                // instead of being dropped.
                if let progress = chunk.xProgress {
                    continuation.yield(.progress(chunk.xStatus ?? "", min(max(progress, 0), 1)))
                } else if let status = chunk.xStatus {
                    continuation.yield(.status(status))
                }
                if let tokensPerSecond = chunk.xTokensPerSecond,
                   tokensPerSecond.isFinite, tokensPerSecond > 0 {
                    continuation.yield(.throughput(tokensPerSecond))
                }
                if let reasoning = chunk.choices.first?.delta?.reasoningText,
                   !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }
                if let content = chunk.choices.first?.delta?.content, !content.isEmpty {
                    continuation.yield(.token(content))
                }
                for (offset, call) in (chunk.choices.first?.delta?.toolCalls ?? []).enumerated() {
                    let key = call.index ?? offset
                    mergeToolCall(call, into: &toolCalls, key: key)
                }
                return chunk.choices.first?.finishReason?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }

            // Emit accumulated tool calls (ordered by index) before `.done`.
            func emitToolCallsIfAny() {
                guard !toolCalls.isEmpty else { return }
                let ordered = toolCalls.keys.sorted().compactMap { toolCalls[$0] }
                continuation.yield(.toolCalls(ordered))
            }

            do {
                for try await raw in lines {
                    try Task.checkCancellation()
                    switch classifySSELine(raw) {
                    case .event(let data):
                        dataBuffer.append(data)
                    case .blank:
                        if try flush() {
                            emitToolCallsIfAny()
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    case .done:
                        _ = try flush()
                        emitToolCallsIfAny()
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    case .comment:
                        continue
                    }
                }
                _ = try flush() // trailing frame without a closing blank line
                emitToolCallsIfAny()
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: AppError.from(error))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Split a byte stream into lines, **preserving empty lines**.
///
/// `URLSession.AsyncBytes.lines` silently drops blank lines, but SSE uses the
/// blank line as its event boundary — without it, consecutive `data:` frames
/// coalesce into one undecodable blob and every token is lost. We split on the
/// spec's three terminators (LF, CRLF, bare CR) ourselves so the blank
/// boundaries survive. Byte-level iteration matches what `AsyncLineSequence`
/// already does internally, so there's no added cost.
public func sseLines<Bytes: AsyncSequence & Sendable>(
    _ bytes: Bytes
) -> AsyncThrowingStream<String, Error> where Bytes.Element == UInt8 {
    AsyncThrowingStream { continuation in
        let task = Task {
            var buffer: [UInt8] = []
            var lastWasCR = false
            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    switch byte {
                    case 0x0D: // bare CR terminates a line (CRLF handled below)
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                        buffer.removeAll(keepingCapacity: true)
                        lastWasCR = true
                    case 0x0A where lastWasCR: // the LF of a CRLF: already emitted
                        lastWasCR = false
                    case 0x0A:
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                        buffer.removeAll(keepingCapacity: true)
                    default:
                        lastWasCR = false
                        buffer.append(byte)
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Chat client

public protocol ChatClienting: Sendable {
    /// Stream a turn. `turnID`, when set, is sent as the `Idempotency-Key` header
    /// so the orchestrator buffers the turn and replays it on reconnect — letting
    /// a long generation survive the app backgrounding (see `docs/resilient-turns.md`).
    /// Backends without a turn registry (native Ollama) ignore it.
    func stream(_ request: ChatRequest, base: URL, token: String, turnID: String?)
        -> AsyncThrowingStream<ChatStreamEvent, Error>

    /// Cancel a resumable turn server-side by its `turnID`. Best-effort and
    /// fire-and-forget; the default is a no-op for backends that don't support it.
    func cancel(turnID: String, base: URL, token: String) async
}

public extension ChatClienting {
    /// Convenience overload for callers with no turn id — side queries (title
    /// generation) and the native backend, which aren't resumable.
    func stream(_ request: ChatRequest, base: URL, token: String)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        stream(request, base: base, token: token, turnID: nil)
    }

    /// Default: nothing to cancel (e.g. native Ollama has no turn registry).
    func cancel(turnID: String, base: URL, token: String) async {}

    /// Run a request to completion and return the concatenated assistant text,
    /// ignoring status/progress events. Drains the token stream so it reuses the
    /// same transport + auth as a normal turn (and works for every backend).
    /// Intended for short side-queries such as title generation.
    func complete(_ request: ChatRequest, base: URL, token: String) async throws -> String {
        var text = ""
        var sawDone = false
        for try await event in stream(request, base: base, token: token) {
            switch event {
            case .token(let token):
                text += token
            case .done:
                sawDone = true
            default:
                break
            }
        }
        // Some stream producers translate cancellation into an ordinary EOF.
        // Preserve cancellation semantics instead of misclassifying that EOF as
        // a truncated backend response.
        try Task.checkCancellation()
        guard sawDone else {
            throw AppError.modelError("The connection closed before the response finished.")
        }
        return text
    }
}

/// OpenAI-compatible streaming client over `URLSession.bytes`.
public struct ChatClient: ChatClienting {
    private let session: URLSession

    /// Streaming-tuned session. `URLSession.shared`'s 60 s idle timeout kills
    /// the first turn against a cold backend that is still loading a model
    /// (auto-warm is off by default), surfacing "backend unreachable" for a
    /// healthy server. Allow long idle gaps; bound the total turn instead.
    private static let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    public init(session: URLSession? = nil) {
        self.session = session ?? ChatClient.streamingSession
    }

    public func stream(_ request: ChatRequest, base: URL, token: String, turnID: String?)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlReq = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
                    urlReq.httpMethod = "POST"
                    if !token.isEmpty {
                        urlReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Resumable-turn key (transport-only; body stays standard OpenAI).
                    if let turnID, !turnID.isEmpty {
                        urlReq.setValue(turnID, forHTTPHeaderField: "Idempotency-Key")
                    }
                    urlReq.httpBody = try Wire.encoder().encode(request)

                    let (bytes, response) = try await session.bytes(for: urlReq)
                    if let http = response as? HTTPURLResponse,
                       let err = AppError.fromStatus(http.statusCode) {
                        throw await Self.enriched(err, status: http.statusCode, body: bytes)
                    }

                    var sawEvent = false
                    for try await event in chatEventStream(lines: sseLines(bytes)) {
                        try Task.checkCancellation()
                        sawEvent = true
                        continuation.yield(event)
                    }
                    // A 200 whose body parses to zero events (a backend that
                    // ignored stream:true and returned plain JSON) is a failure,
                    // not an empty success.
                    guard sawEvent else {
                        throw AppError.modelError("the backend sent no stream events")
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppError.from(error))
                }
            }
            // Aborting the SSE connection on cancel (FR-A9).
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pull the OpenAI `error.message` out of a non-2xx body so e.g. a 400
    /// "context length exceeded" surfaces its detail, not just "HTTP 400".
    /// Auth/not-found keep their taxonomy (they drive distinct UI).
    private static func enriched(
        _ appError: AppError, status: Int, body: URLSession.AsyncBytes
    ) async -> AppError {
        guard case .modelError = appError else { return appError }
        var data = Data()
        do {
            for try await byte in body {
                data.append(byte)
                if data.count > 64 * 1024 { break }
            }
        } catch {
            return appError
        }
        guard let envelope = try? Wire.decoder().decode(StreamErrorEnvelope.self, from: data),
              let message = envelope.error.message
        else { return appError }
        return .modelError("HTTP \(status): \(message)")
    }

    /// Tell the orchestrator to cancel a resumable turn (the Stop button). The
    /// turn no longer cancels on disconnect, so this frees server resources (and
    /// any running ComfyUI generation) immediately. Best-effort: failures are
    /// ignored since Stop already finished the turn locally.
    public func cancel(turnID: String, base: URL, token: String) async {
        var req = URLRequest(url: base.appendingPathComponent("v1/chat/cancel"))
        req.httpMethod = "POST"
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["turn_id": turnID])
        _ = try? await session.data(for: req)
    }
}
