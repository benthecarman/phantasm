import XCTest
@testable import PhantasmKit

final class AskUserParserTests: XCTestCase {
    private func call(
        name: String = ToolName.askUser,
        id: String? = "call_1",
        arguments: String
    ) -> WireToolCall {
        WireToolCall(
            index: 0,
            id: id,
            type: "function",
            function: WireToolCall.Function(name: name, arguments: arguments)
        )
    }

    func testParsesValidSingleChoice() {
        let c = call(arguments: #"{"question":"Pick one","options":["A","B","C"]}"#)
        let choice = AskUserParser.parse(c)
        XCTAssertEqual(choice?.toolCallId, "call_1")
        XCTAssertEqual(choice?.questions.count, 1)
        XCTAssertEqual(choice?.questions.first?.prompt, "Pick one")
        XCTAssertEqual(choice?.questions.first?.options, ["A", "B", "C"])
        XCTAssertEqual(choice?.questions.first?.type, .singleSelect)
    }

    func testParsesMultipleQuestionsWithTypes() {
        let c = call(arguments: #"""
        {"questions":[
          {"question":"Goal?","options":["Strength","Cardio"],"type":"single_select"},
          {"question":"Equipment?","options":["Dumbbells","Bands"],"type":"multi_select"},
          {"question":"Rank these","options":["Time","Results"],"type":"rank_priorities"}
        ]}
        """#)
        let choice = AskUserParser.parse(c)
        XCTAssertEqual(choice?.questions.count, 3)
        XCTAssertEqual(choice?.questions[0].type, .singleSelect)
        XCTAssertEqual(choice?.questions[1].type, .multiSelect)
        XCTAssertEqual(choice?.questions[2].type, .rankPriorities)
    }

    func testUnknownTypeDefaultsToSingleSelect() {
        let c = call(arguments: #"{"question":"Q","options":["A","B"],"type":"wat"}"#)
        XCTAssertEqual(AskUserParser.parse(c)?.questions.first?.type, .singleSelect)
    }

    func testDropsInvalidQuestionsButKeepsValidOnes() {
        // A questions array where one entry has too few options: drop just that one.
        let c = call(arguments: #"""
        {"questions":[
          {"question":"Good?","options":["A","B"],"type":"single_select"},
          {"question":"Bad?","options":["only"],"type":"single_select"}
        ]}
        """#)
        let choice = AskUserParser.parse(c)
        XCTAssertEqual(choice?.questions.count, 1)
        XCTAssertEqual(choice?.questions.first?.prompt, "Good?")
    }

    func testLegacyAllowMultipleMapsToMultiSelect() {
        let c = call(arguments: #"{"question":"Pick","options":["A","B"],"allow_multiple":true}"#)
        XCTAssertEqual(AskUserParser.parse(c)?.questions.first?.type, .multiSelect)
    }

    func testTrimsAndDropsEmptyOptions() {
        let c = call(arguments: #"{"question":" Pick ","options":["  A ","",  "B"]}"#)
        let choice = AskUserParser.parse(c)
        XCTAssertEqual(choice?.questions.first?.prompt, "Pick")
        XCTAssertEqual(choice?.questions.first?.options, ["A", "B"])
    }

    func testRejectsFewerThanTwoOptions() {
        XCTAssertNil(AskUserParser.parse(call(arguments: #"{"question":"Q","options":["only"]}"#)))
    }

    func testRejectsBadJSON() {
        XCTAssertNil(AskUserParser.parse(call(arguments: "not json")))
    }

    func testRejectsWrongToolName() {
        let c = call(name: "web_search", arguments: #"{"question":"Q","options":["A","B"]}"#)
        XCTAssertNil(AskUserParser.parse(c))
    }

    func testRejectsMissingId() {
        let c = call(id: nil, arguments: #"{"question":"Q","options":["A","B"]}"#)
        XCTAssertNil(AskUserParser.parse(c))
    }

    func testFirstChoiceSkipsNonAskUserCalls() {
        let other = call(name: "web_search", arguments: #"{"q":"x"}"#)
        let good = call(id: "call_2", arguments: #"{"question":"Q","options":["A","B"]}"#)
        XCTAssertEqual(AskUserParser.firstChoice(in: [other, good])?.toolCallId, "call_2")
        XCTAssertNil(AskUserParser.firstChoice(in: [other]))
    }
}
