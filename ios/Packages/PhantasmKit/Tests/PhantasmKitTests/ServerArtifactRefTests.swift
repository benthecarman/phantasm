import XCTest
@testable import PhantasmKit

final class ServerArtifactRefTests: XCTestCase {
    func testExtractsTrustedVideoAndLeavesText() {
        let base = URL(string: "https://host.example")!
        let text = "Done\n\n[Video: clip.mp4](https://host.example/v1/files/abc/content?exp=9&sig=x)"
        let result = ServerArtifactRef.extractTrusted(in: text, backendBase: base)
        XCTAssertEqual(result.markdown, "Done")
        XCTAssertEqual(result.artifacts.map(\.id), ["abc"])
        XCTAssertEqual(result.artifacts.first?.label, "clip.mp4")
    }

    func testLookalikeHostRemainsMarkdown() {
        let text = "[Video: clip.mp4](https://tracker.example/v1/files/abc/content?exp=9&sig=x)"
        let result = ServerArtifactRef.extractTrusted(
            in: text, backendBase: URL(string: "https://host.example")!)
        XCTAssertEqual(result.markdown, text)
        XCTAssertTrue(result.artifacts.isEmpty)
    }
}
