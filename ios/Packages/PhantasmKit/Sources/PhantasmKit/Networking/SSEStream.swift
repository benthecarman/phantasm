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

/// A domain event consumed by the chat UI.
public enum ChatStreamEvent: Sendable, Equatable {
    case token(String)      // append delta.content
    case reasoning(String)  // append model thinking/reasoning deltas
    case status(String)     // x_status -> progress UI (FR-A8)
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

            func flush() -> Bool {
                // Returns true if the stream should end (decoded a finish).
                guard !dataBuffer.isEmpty else { return false }
                let payload = dataBuffer.joined(separator: "\n")
                dataBuffer.removeAll(keepingCapacity: true)
                guard let chunk = try? decoder.decode(ChatChunk.self, from: Data(payload.utf8)) else {
                    return false // tolerate junk chunks (FR-A8)
                }
                if let status = chunk.xStatus {
                    continuation.yield(.status(status))
                }
                if let reasoning = chunk.choices.first?.delta.reasoningText,
                   !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }
                if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    continuation.yield(.token(content))
                }
                return chunk.choices.first?.finishReason != nil
            }

            do {
                for try await raw in lines {
                    try Task.checkCancellation()
                    switch classifySSELine(raw) {
                    case .event(let data):
                        dataBuffer.append(data)
                    case .blank:
                        if flush() {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    case .done:
                        _ = flush()
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    case .comment:
                        continue
                    }
                }
                _ = flush() // trailing frame without a closing blank line
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
/// coalesce into one undecodable blob and every token is lost. We split on `\n`
/// ourselves so the blank boundaries survive (a `\r` left on CRLF streams is
/// stripped downstream by `classifySSELine`). Byte-level iteration matches what
/// `AsyncLineSequence` already does internally, so there's no added cost.
public func sseLines<Bytes: AsyncSequence & Sendable>(
    _ bytes: Bytes
) -> AsyncThrowingStream<String, Error> where Bytes.Element == UInt8 {
    AsyncThrowingStream { continuation in
        let task = Task {
            var buffer: [UInt8] = []
            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if byte == 0x0A { // newline: emit the line (possibly empty)
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                        buffer.removeAll(keepingCapacity: true)
                    } else {
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
    func stream(_ request: ChatRequest, base: URL, token: String)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
}

public extension ChatClienting {
    /// Run a request to completion and return the concatenated assistant text,
    /// ignoring status/progress events. Drains the token stream so it reuses the
    /// same transport + auth as a normal turn (and works for every backend).
    /// Intended for short side-queries such as title generation.
    func complete(_ request: ChatRequest, base: URL, token: String) async throws -> String {
        var text = ""
        for try await event in stream(request, base: base, token: token) {
            if case .token(let t) = event { text += t }
        }
        return text
    }
}

/// OpenAI-compatible streaming client over `URLSession.bytes`.
public struct ChatClient: ChatClienting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(_ request: ChatRequest, base: URL, token: String)
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
                    urlReq.httpBody = try Wire.encoder().encode(request)

                    let (bytes, response) = try await session.bytes(for: urlReq)
                    if let http = response as? HTTPURLResponse,
                       let err = AppError.fromStatus(http.statusCode) {
                        throw err
                    }

                    for try await event in chatEventStream(lines: sseLines(bytes)) {
                        try Task.checkCancellation()
                        continuation.yield(event)
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
}
