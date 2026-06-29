import XCTest
@testable import PhantasmKit

final class OrchestratorContractFixtureTests: XCTestCase {
    func testStatusReasoningAndServerImageFixtureParses() async throws {
        let events = try await events(from: "status-reasoning-image")

        XCTAssertTrue(events.contains(.status("searching the web...")))
        XCTAssertTrue(events.contains(.reasoning("checking sources")))
        let text = events.tokens
        XCTAssertTrue(text.contains("/v1/files/img_1/content"))
        XCTAssertEqual(events.last, .done)
    }

    func testAppToolCallFixtureParses() async throws {
        let events = try await events(from: "app-tool-call")

        guard case .toolCalls(let calls) = events.first(where: {
            if case .toolCalls = $0 { return true }
            return false
        }) else {
            return XCTFail("expected forwarded app tool calls, got \(events)")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_ask")
        XCTAssertEqual(calls[0].function?.name, ToolName.askUser)
        let arguments = try XCTUnwrap(calls[0].function?.arguments)
        XCTAssertEqual(
            try Wire.decoder().decode(AskUserArguments.self, from: Data(arguments.utf8)),
            AskUserArguments(
                questions: [
                    .init(question: "Pick one", options: ["A", "B"], type: "single_select")
                ]
            )
        )
        XCTAssertEqual(events.last, .done)
    }

    func testStreamErrorFixtureParsesAsStatusTokenAndDone() async throws {
        let events = try await events(from: "stream-error")

        XCTAssertTrue(events.contains(.status("error: upstream boom")))
        XCTAssertTrue(events.tokens.contains("WARNING: upstream boom"))
        XCTAssertEqual(events.last, .done)
    }

    private func events(from fixture: String) async throws -> [ChatStreamEvent] {
        let lines = try fixtureLines(named: fixture)
        return try await collect(chatEventStream(lines: linesStream(lines)))
    }

    private func fixtureLines(named fixture: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PhantasmKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PhantasmKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
        let url = root
            .appendingPathComponent("docs/contract-fixtures/orchestrator-sse")
            .appendingPathComponent("\(fixture).sse")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

private struct AskUserArguments: Decodable, Equatable {
    struct Question: Decodable, Equatable {
        let question: String
        let options: [String]
        let type: String
    }

    let questions: [Question]
}

private extension [ChatStreamEvent] {
    var tokens: String {
        compactMap {
            if case .token(let token) = $0 { return token }
            return nil
        }.joined()
    }
}
