import XCTest
@testable import PhantasmKit

final class SpeakableTextTests: XCTestCase {
    func testStripsEmphasisAndHeadings() {
        let md = "# Title\n\nThis is **bold** and _italic_ text."
        XCTAssertEqual(SpeakableText.plainText(from: md), "Title\nThis is bold and italic text.")
    }

    func testLinkKeepsTextDropsURL() {
        let md = "See [the docs](https://example.com/page) here."
        XCTAssertEqual(SpeakableText.plainText(from: md), "See the docs here.")
    }

    func testDropsImagesEntirely() {
        let md = "Here is a picture ![a cat](https://example.com/cat.png) of a cat."
        let out = SpeakableText.plainText(from: md)
        XCTAssertFalse(out.contains("http"))
        XCTAssertFalse(out.contains("cat.png"))
        XCTAssertTrue(out.contains("Here is a picture"))
        XCTAssertTrue(out.contains("of a cat."))
    }

    func testDropsBase64DataURIImage() {
        let md = "Result: ![generated](data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==) done."
        let out = SpeakableText.plainText(from: md)
        XCTAssertFalse(out.contains("base64"))
        XCTAssertFalse(out.contains("iVBOR"))
        XCTAssertTrue(out.contains("Result:"))
        XCTAssertTrue(out.contains("done."))
    }

    func testCodeFenceCollapsesToMarker() {
        let md = "Run this:\n```swift\nlet x = 1\nprint(x)\n```\nThanks."
        let out = SpeakableText.plainText(from: md)
        XCTAssertFalse(out.contains("let x = 1"))
        XCTAssertFalse(out.contains("```"))
        XCTAssertTrue(out.contains("code block"))
        XCTAssertTrue(out.contains("Thanks."))
    }

    func testInlineCodeUnwrapped() {
        let md = "Call the `send()` method."
        XCTAssertEqual(SpeakableText.plainText(from: md), "Call the send() method.")
    }

    func testListMarkersRemoved() {
        let md = "- first\n- second\n1. third"
        XCTAssertEqual(SpeakableText.plainText(from: md), "first\nsecond\nthird")
    }

    func testBlockquoteAndRuleRemoved() {
        let md = "> a quote\n\n---\n\nplain"
        XCTAssertEqual(SpeakableText.plainText(from: md), "a quote\nplain")
    }

    func testPlainTextUnchanged() {
        let md = "Just a normal sentence."
        XCTAssertEqual(SpeakableText.plainText(from: md), "Just a normal sentence.")
    }
}
