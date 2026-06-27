import XCTest

@testable import PhantasmKit

final class ServerImageRefTests: XCTestCase {
    func testExtractsRelativeAndAbsoluteIDs() {
        let md = """
        Here you go ![generated](/v1/files/abc123/content?exp=9&sig=zz)
        and another ![edited](https://host.example/v1/files/DEF-_4/content?exp=1&sig=q)
        """
        XCTAssertEqual(ServerImageRef.ids(in: md), ["abc123", "DEF-_4"])
    }

    func testDeduplicatesAndPreservesOrder() {
        let md =
            "![a](/v1/files/one/content?sig=x) ![b](/v1/files/two/content) ![c](/v1/files/one/content)"
        XCTAssertEqual(ServerImageRef.ids(in: md), ["one", "two"])
    }

    func testIgnoresInlineDataURIsAndPlainText() {
        let md = "![inline](data:image/png;base64,AAAA) no refs here"
        XCTAssertTrue(ServerImageRef.ids(in: md).isEmpty)
    }
}
