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
        XCTAssertEqual(result.artifacts.first?.kind, .video)
    }

    func testExtractsTrustedAudio() {
        let text = "Listen: [Audio: rain.flac](https://host.example/v1/files/sound/content?exp=9&sig=x)"
        let result = ServerArtifactRef.extractTrusted(
            in: text, backendBase: URL(string: "https://host.example")!)
        XCTAssertEqual(result.markdown, "Listen:")
        XCTAssertEqual(result.artifacts.map(\.id), ["sound"])
        XCTAssertEqual(result.artifacts.first?.label, "rain.flac")
        XCTAssertEqual(result.artifacts.first?.kind, .audio)
    }

    func testExtractsRelativeTrustedMedia() {
        let text = """
        Done
        [Video: clip.mp4](/v1/files/clip/content?exp=9&sig=x)
        [Audio: rain.flac](/v1/files/sound/content?exp=9&sig=x)
        """
        let result = ServerArtifactRef.extractTrusted(
            in: text, backendBase: URL(string: "https://host.example")!)
        XCTAssertEqual(result.markdown, "Done")
        XCTAssertEqual(result.artifacts.map(\.id), ["clip", "sound"])
        XCTAssertEqual(result.artifacts.map(\.url.absoluteString), [
            "https://host.example/v1/files/clip/content?exp=9&sig=x",
            "https://host.example/v1/files/sound/content?exp=9&sig=x",
        ])
        XCTAssertEqual(result.artifacts.map(\.kind), [.video, .audio])
    }

    func testLookalikeHostRemainsMarkdown() {
        let text = "[Video: clip.mp4](https://tracker.example/v1/files/abc/content?exp=9&sig=x)"
        let result = ServerArtifactRef.extractTrusted(
            in: text, backendBase: URL(string: "https://host.example")!)
        XCTAssertEqual(result.markdown, text)
        XCTAssertTrue(result.artifacts.isEmpty)
    }
}
