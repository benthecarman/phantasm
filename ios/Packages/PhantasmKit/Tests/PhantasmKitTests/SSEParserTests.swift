import XCTest
@testable import PhantasmKit

func linesStream(_ lines: [String]) -> AsyncStream<String> {
    AsyncStream { continuation in
        for line in lines { continuation.yield(line) }
        continuation.finish()
    }
}

func collect(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [ChatStreamEvent] {
    var out: [ChatStreamEvent] = []
    for try await event in stream { out.append(event) }
    return out
}

final class SSEParserTests: XCTestCase {
    func testClassifyLines() {
        XCTAssertEqual(classifySSELine("data: {\"a\":1}"), .event(data: "{\"a\":1}"))
        XCTAssertEqual(classifySSELine("data:{\"a\":1}"), .event(data: "{\"a\":1}"))
        XCTAssertEqual(classifySSELine("data: [DONE]"), .done)
        XCTAssertEqual(classifySSELine(": keep-alive"), .comment)
        XCTAssertEqual(classifySSELine(""), .blank)
        XCTAssertEqual(classifySSELine("event: message"), .comment)
        // Trailing CR is stripped.
        XCTAssertEqual(classifySSELine("data: x\r"), .event(data: "x"))
    }

    private func lines(of text: String) async throws -> [String] {
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in Data(text.utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        var out: [String] = []
        for try await line in sseLines(bytes) { out.append(line) }
        return out
    }

    func testSSELinesSplitsOnAllSpecTerminators() async throws {
        // The SSE spec allows LF, CRLF, and bare CR as line terminators.
        let lf = try await lines(of: "a\nb\n\nc")
        XCTAssertEqual(lf, ["a", "b", "", "c"])

        let crlf = try await lines(of: "a\r\nb\r\n\r\nc")
        XCTAssertEqual(crlf, ["a", "b", "", "c"])

        let cr = try await lines(of: "a\rb\r\rc")
        XCTAssertEqual(cr, ["a", "b", "", "c"])
    }

    func testClassifyFieldLineWithoutColon() {
        // A field line with no colon carries an empty value per the spec.
        XCTAssertEqual(classifySSELine("data"), .event(data: ""))
    }

    func testStreamYieldsTokensStatusAndDone() async throws {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{}}],\"x_status\":\"searching…\"}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
            "",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.token("Hel"), .status("searching…"), .token("lo"), .done])
    }

    func testStreamYieldsStructuredProgress() async throws {
        let lines = [
            "data: {\"choices\":[{\"delta\":{}}],\"x_status\":\"generating image…\",\"x_progress\":0.42}",
            "",
            "data: [DONE]",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.progress("generating image…", 0.42), .done])
    }

    func testProgressWithoutStatusStillSurfaces() async throws {
        let lines = [
            "data: {\"choices\":[{\"delta\":{}}],\"x_progress\":0.5}",
            "",
            "data: [DONE]",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.progress("", 0.5), .done])
    }

    func testDoneSentinelEndsStream() async throws {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}",
            "",
            "data: [DONE]",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.token("hi"), .done])
    }

    func testFinishChunkWithoutDeltaEndsStream() async throws {
        // Some compat servers emit the finish chunk with no delta key at all.
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}",
            "",
            "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\"}]}",
            "",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.token("hi"), .done])
    }

    func testEmptyFinishReasonDoesNotEndStream() async throws {
        // Some compatibility servers encode an absent finish reason as an
        // empty string. It is not terminal; later content must not be dropped.
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"one \"},\"finish_reason\":\"\"}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}",
            "",
            "data: [DONE]",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.token("one "), .token("two"), .done])
    }

    func testJunkChunkIsTolerated() async throws {
        // A malformed data line must not break the stream (FR-A8 robustness).
        let lines = [
            "data: not-json",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}",
            "",
            "data: [DONE]",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.token("ok"), .done])
    }

    func testMidStreamErrorEventThrowsModelError() async throws {
        // OpenAI-compatible servers report mid-stream failures as a terminal
        // `data: {"error":{…}}` event; it must surface as an error, not be
        // swallowed as junk (which would commit a truncated message).
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"par\"}}]}",
            "",
            "data: {\"error\":{\"message\":\"context length exceeded\",\"type\":\"invalid_request_error\"}}",
            "",
        ]
        do {
            _ = try await collect(chatEventStream(lines: linesStream(lines)))
            XCTFail("expected the error event to throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .modelError("context length exceeded"))
        }
    }

    func testAbsentXStatusDoesNotBreakDecoding() async throws {
        let lines = ["data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}", "", "data: [DONE]"]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.token("a"), .done])
    }

    func testReasoningDeltasSurfaceActivity() async throws {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"\",\"reasoning\":\"Thinking\"}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}",
            "",
            "data: [DONE]",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.reasoning("Thinking"), .token("answer"), .done])
    }

    func testReasoningContentAliasSurfacesReasoning() async throws {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Plan\"}}]}",
            "",
            "data: [DONE]",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.reasoning("Plan"), .done])
    }

    func testWholeToolCallChunkSurfacesBeforeDone() async throws {
        // The orchestrator sends the tool call whole in one chunk, then a finish
        // chunk with finish_reason: tool_calls.
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"ask_user\",\"arguments\":\"{\\\"question\\\":\\\"Pick\\\",\\\"options\\\":[\\\"a\\\",\\\"b\\\"]}\"}}]}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
            "",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        guard case .toolCalls(let calls) = events.first else {
            return XCTFail("expected toolCalls first, got \(events)")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].type, "function")
        XCTAssertEqual(calls[0].function?.name, "ask_user")
        // arguments is a JSON-encoded string, decodable on its own.
        XCTAssertEqual(
            calls[0].function?.arguments,
            "{\"question\":\"Pick\",\"options\":[\"a\",\"b\"]}"
        )
        XCTAssertEqual(events.last, .done)
    }

    func testFragmentedToolCallArgumentsAreConcatenated() async throws {
        // Standard OpenAI streams arguments in fragments sharing one index.
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_9\",\"type\":\"function\",\"function\":{\"name\":\"ask_user\",\"arguments\":\"{\\\"question\\\":\"}}]}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"Hi\\\"}\"}}]}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
            "",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        guard case .toolCalls(let calls) = events.first else {
            return XCTFail("expected toolCalls first, got \(events)")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_9")
        XCTAssertEqual(calls[0].function?.arguments, "{\"question\":\"Hi\"}")
    }
}

final class OllamaNativeChatClientTests: XCTestCase {
        final class NativeProtocol: URLProtocol {
            nonisolated(unsafe) static var lastPath: String?
            nonisolated(unsafe) static var lastBody: Data?
            nonisolated(unsafe) static var responseBody = """
            {"model":"native-model","created_at":"2026-06-24T07:17:27.100196506Z","message":{"role":"assistant","content":"hi"},"done":false}
            {"model":"native-model","created_at":"2026-06-24T07:17:27.112648860Z","message":{"role":"assistant","content":""},"done":true}

            """

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastPath = request.url?.path
            Self.lastBody = request.httpBody ?? request.httpBodyStream?.readAllData()
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/x-ndjson"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NativeProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        NativeProtocol.lastPath = nil
        NativeProtocol.lastBody = nil
        NativeProtocol.responseBody = """
        {"model":"native-model","created_at":"2026-06-24T07:17:27.100196506Z","message":{"role":"assistant","content":"hi"},"done":false}
        {"model":"native-model","created_at":"2026-06-24T07:17:27.112648860Z","message":{"role":"assistant","content":""},"done":true}

        """
    }

    func testNativeClientStreamsOllamaChatAndDisablesThinking() async throws {
        let request = ChatRequest(
            model: "native-model",
            messages: [WireMessage(role: "user", content: "hi")],
            reasoningEffort: ReasoningEffort.disabled
        )
        let stream = OllamaNativeChatClient(session: session())
            .stream(request, base: URL(string: "https://backend.example")!, token: "")

        let events = try await collect(stream)

        XCTAssertEqual(events, [.token("hi"), .done])
        XCTAssertEqual(NativeProtocol.lastPath, "/api/chat")

        let data = try XCTUnwrap(NativeProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["think"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNil(json["keep_alive"])
    }

    func testNativeClientStreamsThinkingWhenEnabled() async throws {
        NativeProtocol.responseBody = """
        {"model":"native-model","created_at":"2026-06-24T07:17:27.100196506Z","message":{"role":"assistant","content":"","thinking":"plan"},"done":false}
        {"model":"native-model","created_at":"2026-06-24T07:17:27.112648860Z","message":{"role":"assistant","content":"hi"},"done":true}

        """
        let request = ChatRequest(
            model: "native-model",
            messages: [WireMessage(role: "user", content: "hi")],
            reasoningEffort: ReasoningEffort.enabledDefault
        )
        let stream = OllamaNativeChatClient(session: session())
            .stream(request, base: URL(string: "https://backend.example")!, token: "")

        let events = try await collect(stream)

        XCTAssertEqual(events, [.reasoning("plan"), .token("hi"), .done])
        let data = try XCTUnwrap(NativeProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["think"] as? Bool, true)
    }

    func testNativeClientRejectsPrematureEOF() async throws {
        NativeProtocol.responseBody = """
        {"model":"native-model","created_at":"2026-06-24T07:17:27Z","message":{"role":"assistant","content":"partial"},"done":false}

        """
        let request = ChatRequest(
            model: "native-model",
            messages: [WireMessage(role: "user", content: "hi")]
        )

        do {
            _ = try await collect(
                OllamaNativeChatClient(session: session()).stream(
                    request,
                    base: URL(string: "https://backend.example")!,
                    token: ""
                )
            )
            XCTFail("expected premature EOF to throw")
        } catch let error as AppError {
            XCTAssertEqual(
                error,
                .modelError("The connection closed before the response finished.")
            )
        }
    }
}

private extension InputStream {
    func readAllData() -> Data {
        open()
        defer { close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
