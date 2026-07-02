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
        nonisolated(unsafe) static var status = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.status,
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

    override func setUp() {
        super.setUp()
        SSEProtocol.body = ""
        SSEProtocol.contentType = "text/event-stream"
        SSEProtocol.status = 200
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

    func testErrorBodyDetailSurfacesOnBadStatus() async throws {
        // A 400's OpenAI error body must reach the user, not just "HTTP 400".
        SSEProtocol.status = 400
        SSEProtocol.contentType = "application/json"
        SSEProtocol.body = #"{"error":{"message":"context length exceeded","type":"invalid_request_error"}}"#

        let req = ChatRequest(model: "m", messages: [WireMessage(role: "user", content: "hi")])
        let stream = ChatClient(session: session())
            .stream(req, base: URL(string: "https://backend.example")!, token: "k")
        do {
            _ = try await collect(stream)
            XCTFail("expected the 400 to throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .modelError("HTTP 400: context length exceeded"))
        }
    }

    func testZeroEventOkResponseIsAnError() async throws {
        // A backend that ignores stream:true and returns plain JSON must fail
        // the turn, not complete "successfully" with an empty message.
        SSEProtocol.contentType = "application/json"
        SSEProtocol.body = #"{"choices":[{"message":{"content":"hi"}}]}"#

        let req = ChatRequest(model: "m", messages: [WireMessage(role: "user", content: "hi")])
        let stream = ChatClient(session: session())
            .stream(req, base: URL(string: "https://backend.example")!, token: "k")
        do {
            _ = try await collect(stream)
            XCTFail("expected the empty stream to throw")
        } catch let error as AppError {
            guard case .modelError = error else {
                return XCTFail("expected modelError, got \(error)")
            }
        }
    }
}
