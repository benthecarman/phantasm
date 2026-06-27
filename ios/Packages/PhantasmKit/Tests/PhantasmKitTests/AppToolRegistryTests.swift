import XCTest
@testable import PhantasmKit

final class AppToolRegistryTests: XCTestCase {
    private func call(name: String, id: String, arguments: String = "{}") -> WireToolCall {
        WireToolCall(
            index: 0, id: id, type: "function",
            function: WireToolCall.Function(name: name, arguments: arguments)
        )
    }

    func testSpecsCoverEveryRegisteredTool() {
        XCTAssertEqual(AppToolRegistry.specs.count, AppToolRegistry.tools.count)
        let names = AppToolRegistry.specs.map(\.function.name)
        XCTAssertTrue(names.contains(ToolName.askUser))
        XCTAssertTrue(names.contains(ToolName.currentTime))
    }

    func testMatchClassifiesByKind() {
        if case .interactive = AppToolRegistry.match(call(name: ToolName.askUser, id: "a")) {
        } else { XCTFail("ask_user should be interactive") }

        if case .auto = AppToolRegistry.match(call(name: ToolName.currentTime, id: "b")) {
        } else { XCTFail("current_time should be auto-resolved") }

        if case .unknown = AppToolRegistry.match(call(name: "nope", id: "c")) {
        } else { XCTFail("unknown tool should classify as unknown") }
    }

    func testIsAutoResolvedOnlyForAutoTools() {
        XCTAssertTrue(AppToolRegistry.isAutoResolved(name: ToolName.currentTime))
        XCTAssertFalse(AppToolRegistry.isAutoResolved(name: ToolName.askUser))
        XCTAssertFalse(AppToolRegistry.isAutoResolved(name: nil))
        XCTAssertFalse(AppToolRegistry.isAutoResolved(name: "nope"))
    }

    func testFirstUnansweredPromptSkipsAnsweredAndAutoCalls() {
        let time = call(name: ToolName.currentTime, id: "t1")
        let ask = call(
            name: ToolName.askUser, id: "a1",
            arguments: #"{"questions":[{"question":"Pick","options":["A","B"]}]}"#
        )
        // A mixed batch where the auto call is already answered: the interactive
        // prompt should still come back.
        let prompt = AppToolRegistry.firstUnansweredPrompt(
            calls: [time, ask], answered: ["t1"]
        )
        XCTAssertEqual(prompt?.toolCallId, "a1")
        XCTAssertEqual(prompt?.toolName, ToolName.askUser)

        // Once the interactive call is also answered, nothing remains.
        XCTAssertNil(AppToolRegistry.firstUnansweredPrompt(
            calls: [time, ask], answered: ["t1", "a1"]
        ))
    }

    func testCurrentTimeToolResolvesViaProtocol() async {
        let result = await CurrentTimeTool().resolve(
            call(name: ToolName.currentTime, id: "t", arguments: #"{"timezone":"UTC"}"#)
        )
        XCTAssertTrue(result.hasPrefix("Current time:\ntimezone: UTC"))
    }
}
