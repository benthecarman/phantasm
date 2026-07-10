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

    func testOnlyCompleteSignedContentURLsAreTrustedForAutomaticLoading() {
        XCTAssertTrue(ServerImageRef.isSignedContentURL(URL(
            string: "https://host.example/v1/files/abc-_1/content?exp=99&sig=xyz"
        )!))
        XCTAssertFalse(ServerImageRef.isSignedContentURL(URL(
            string: "https://host.example/v1/files/abc/content?sig=xyz"
        )!))
        XCTAssertFalse(ServerImageRef.isSignedContentURL(URL(
            string: "https://tracker.example/pixel.png?exp=99&sig=xyz"
        )!))
        XCTAssertFalse(ServerImageRef.isTrustedContentURL(
            URL(string: "https://tracker.example/v1/files/abc/content?exp=99&sig=xyz")!,
            backendBase: URL(string: "https://host.example")!
        ))
        XCTAssertTrue(ServerImageRef.isTrustedContentURL(
            URL(string: "https://host.example/v1/files/abc/content?exp=99&sig=xyz")!,
            backendBase: URL(string: "https://host.example")!
        ))
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

    func testCachedPlaceholderAvoidsBase64RoundTrip() {
        let bytes = Data([1, 2, 3])
        let result = ServerImageRef.cachedPlaceholders(
            in: "![a](https://h/v1/files/one/content?exp=1&sig=x)",
            cache: ["one": .init(data: bytes, mime: "image/png")],
            startingAt: 4
        )
        XCTAssertEqual(result.markdown, "![a](phantasm-img://4)")
        XCTAssertEqual(result.images, [4: bytes])
        XCTAssertFalse(result.markdown.contains("base64"))
    }
}
