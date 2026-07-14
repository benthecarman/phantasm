import XCTest
@testable import PhantasmKit

final class InlineMathParserTests: XCTestCase {
    func testReplacesInlineMathWithImagePlaceholder() {
        let boundary = "\u{200B}"
        XCTAssertEqual(
            InlineMathParser.prepare("Move $\\rightarrow$ next"),
            PreparedInlineMath(
                markdown: "Move \(boundary)![Equation](phantasm-math://0)\(boundary) next",
                expressions: [0: "\\rightarrow"]
            )
        )
    }

    func testPreservesBoldAroundInlineMath() {
        let boundary = "\u{200B}"
        XCTAssertEqual(
            InlineMathParser.prepare("**Move $\\rightarrow$ next**"),
            PreparedInlineMath(
                markdown: "**Move \(boundary)**![Equation](phantasm-math://0)**\(boundary) next**",
                expressions: [0: "\\rightarrow"]
            )
        )
    }

    func testPreservesBoldWhenMathIsOnlyContent() {
        let boundary = "\u{200B}"
        XCTAssertEqual(
            InlineMathParser.prepare("**$\\rightarrow$**"),
            PreparedInlineMath(
                markdown: "**\(boundary)**![Equation](phantasm-math://0)**\(boundary)**",
                expressions: [0: "\\rightarrow"]
            )
        )
    }

    func testExtractsMultipleInlineExpressions() {
        let boundary = "\u{200B}"
        let first = "\(boundary)![Equation](phantasm-math://0)\(boundary)"
        let second = "\(boundary)![Equation](phantasm-math://1)\(boundary)"
        XCTAssertEqual(
            InlineMathParser.prepare("$x$ and $y^2$"),
            PreparedInlineMath(
                markdown: "\(first) and \(second)",
                expressions: [0: "x", 1: "y^2"]
            )
        )
    }

    func testLeavesCurrencyCodeEscapesAndDisplayMathUntouched() {
        let source = "Pay $5 or $10, use `$x$`, escape \\$y\\$, or show $$z$$"
        XCTAssertEqual(
            InlineMathParser.prepare(source),
            PreparedInlineMath(markdown: source, expressions: [:])
        )
    }

    func testLeavesFencedAndUnmatchedMathUntouched() {
        let source = "```md\n$x$\n```\n$unclosed"
        XCTAssertEqual(
            InlineMathParser.prepare(source),
            PreparedInlineMath(markdown: source, expressions: [:])
        )
    }
}
