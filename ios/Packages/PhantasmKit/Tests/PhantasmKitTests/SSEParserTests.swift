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
}
