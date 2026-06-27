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

    func testReferencesReturnIDAndFullURL() {
        let md = "![g](https://host.example/v1/files/abc/content?exp=1&sig=z)"
        let refs = ServerImageRef.references(in: md)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.id, "abc")
        XCTAssertEqual(refs.first?.url, "https://host.example/v1/files/abc/content?exp=1&sig=z")
    }

    func testInlineCachedRewritesOnlyCachedIDs() {
        let md = """
        ![a](https://h/v1/files/one/content?sig=x) ![b](https://h/v1/files/two/content?sig=y)
        """
        let bytes = Data([1, 2, 3])
        let out = ServerImageRef.inlineCached(
            md, cache: ["one": .init(data: bytes, mime: "image/png")])

        XCTAssertTrue(out.contains("data:image/png;base64,\(bytes.base64EncodedString())"))
        XCTAssertFalse(out.contains("/v1/files/one/content"), "cached ref replaced with bytes")
        XCTAssertTrue(out.contains("/v1/files/two/content"), "uncached ref left as a URL")
    }
}
