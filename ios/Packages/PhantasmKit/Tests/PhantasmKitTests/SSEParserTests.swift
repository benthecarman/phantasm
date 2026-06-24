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

    func testDoneSentinelEndsStream() async throws {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}",
            "",
            "data: [DONE]",
        ]
        let events = try await collect(chatEventStream(lines: linesStream(lines)))
        XCTAssertEqual(events, [.token("hi"), .done])
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
        XCTAssertEqual(events, [.status("Thinking..."), .token("answer"), .done])
    }
}

final class OllamaNativeChatClientTests: XCTestCase {
    final class NativeProtocol: URLProtocol {
        nonisolated(unsafe) static var lastPath: String?
        nonisolated(unsafe) static var lastBody: Data?

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
            let body = """
            {"model":"native-model","created_at":"2026-06-24T07:17:27.100196506Z","message":{"role":"assistant","content":"hi"},"done":false}
            {"model":"native-model","created_at":"2026-06-24T07:17:27.112648860Z","message":{"role":"assistant","content":""},"done":true}

            """
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
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
    }

    func testNativeClientStreamsOllamaChatAndDisablesThinking() async throws {
        let request = ChatRequest(
            model: "native-model",
            messages: [WireMessage(role: "user", content: "hi")]
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
        XCTAssertEqual(json["keep_alive"] as? String, "30m")
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
