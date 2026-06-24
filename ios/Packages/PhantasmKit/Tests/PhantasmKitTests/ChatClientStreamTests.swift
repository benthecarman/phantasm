import XCTest
@testable import PhantasmKit

/// Drives `ChatClient` (the OpenAI SSE path used for the orchestrator) against a
/// URLProtocol that replays the *exact* bytes a real orchestrator emits,
/// including the leading `delta.role=assistant` open chunk and the `[DONE]`
/// sentinel. This is the path that has no other coverage.
final class ChatClientStreamTests: XCTestCase {
    final class SSEProtocol: URLProtocol {
        // Whole SSE body, captured from the live orchestrator.
        nonisolated(unsafe) static var body = ""
        nonisolated(unsafe) static var contentType = "text/event-stream"

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": Self.contentType]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SSEProtocol.self]
        return URLSession(configuration: config)
    }

    func testStreamsRealOrchestratorBytes() async throws {
        // Verbatim from `curl` against the orchestrator (CRLF per SSE spec).
        SSEProtocol.body = [
            #"data: {"id":"chatcmpl-x","object":"chat.completion.chunk","created":1,"model":"qwen3-14b-nothink","choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
            "",
            #"data: {"id":"chatcmpl-x","object":"chat.completion.chunk","created":1,"model":"qwen3-14b-nothink","choices":[{"index":0,"delta":{"content":"Hello"}}]}"#,
            "",
            #"data: {"id":"chatcmpl-x","object":"chat.completion.chunk","created":1,"model":"qwen3-14b-nothink","choices":[{"index":0,"delta":{"content":"!"}}]}"#,
            "",
            #"data: {"id":"chatcmpl-x","object":"chat.completion.chunk","created":1,"model":"qwen3-14b-nothink","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "",
            "data: [DONE]",
            "",
        ].joined(separator: "\n")

        let req = ChatRequest(model: "qwen3-14b-nothink", messages: [WireMessage(role: "user", content: "hi")])
        let stream = ChatClient(session: session())
            .stream(req, base: URL(string: "https://backend.example")!, token: "k")
        let events = try await collect(stream)

        let text = events.compactMap { if case .token(let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertEqual(text, "Hello!", "expected the content tokens to stream through; got events: \(events)")
    }
}
