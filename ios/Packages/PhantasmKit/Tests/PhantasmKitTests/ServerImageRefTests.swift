import XCTest

@testable import PhantasmKit

final class ServerImageRefTests: XCTestCase {
    func testExtractsRelativeAndAbsoluteIDs() {
        let md = """
        Here you go ![generated](/v1/images/abc123?exp=9&sig=zz)
        and another ![edited](https://host.example/v1/images/DEF-_4?exp=1&sig=q)
        """
        XCTAssertEqual(ServerImageRef.ids(in: md), ["abc123", "DEF-_4"])
    }

    func testDeduplicatesAndPreservesOrder() {
        let md = "![a](/v1/images/one?sig=x) ![b](/v1/images/two?sig=y) ![c](/v1/images/one?sig=z)"
        XCTAssertEqual(ServerImageRef.ids(in: md), ["one", "two"])
    }

    func testIgnoresInlineDataURIsAndPlainText() {
        let md = "![inline](data:image/png;base64,AAAA) no refs here"
        XCTAssertTrue(ServerImageRef.ids(in: md).isEmpty)
    }
}
