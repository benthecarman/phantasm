import XCTest
@testable import PhantasmKit

final class DisplayMathParserTests: XCTestCase {
    func testExtractsDisplayMathBetweenMarkdown() {
        let source = "Before\n\n$$\\frac{a}{b} = c$$\n\nAfter"
        XCTAssertEqual(
            DisplayMathParser.blocks(in: source),
            [
                .markdown("Before\n\n"),
                .math("\\frac{a}{b} = c"),
                .markdown("\n\nAfter"),
            ]
        )
    }

    func testExtractsMultipleAndMultilineExpressions() {
        let source = "$$x^2$$ then $$\n y^2 + z^2\n$$"
        XCTAssertEqual(
            DisplayMathParser.blocks(in: source),
            [.math("x^2"), .markdown(" then "), .math("y^2 + z^2")]
        )
    }

    func testExtractsWaterUsageFormula() {
        let expression = #"\frac{\text{Total Water Extracted}}{\text{Water needed per Data Center}} = \frac{150,000,000 \text{ liters}}{50,000,000 \text{ liters/DC}}"#
        XCTAssertEqual(
            DisplayMathParser.blocks(in: "$$\(expression)$$"),
            [.math(expression)]
        )
    }

    func testLeavesCodeEscapesAndUnmatchedDelimitersAsMarkdown() {
        let source = "`$$inline$$`\n```tex\n$$f(x)$$\n```\n\\$$escaped\\$$\n$$unclosed"
        XCTAssertEqual(DisplayMathParser.blocks(in: source), [.markdown(source)])
    }
}
