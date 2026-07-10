import XCTest
@testable import PhantasmKit

/// Covers base-URL normalization: the networking layer appends `v1/...` paths
/// itself, so a pasted OpenAI-style `.../v1` must be stripped or requests
/// double up to `/v1/v1/chat/completions`.
final class BackendProfileTests: XCTestCase {
    private func norm(_ s: String) -> String {
        BackendProfile.normalizedBaseURLString(s)
    }

    func testStripsTrailingV1() {
        XCTAssertEqual(norm("https://inference.finite.computer/v1"),
                       "https://inference.finite.computer")
    }

    func testStripsTrailingV1WithSlash() {
        XCTAssertEqual(norm("https://host.example/v1/"),
                       "https://host.example")
    }

    func testStripsV1CaseInsensitively() {
        XCTAssertEqual(norm("https://host.example/V1"),
                       "https://host.example")
    }

    func testPreservesSubpathBeforeV1() {
        XCTAssertEqual(norm("https://host.example/proxy/v1"),
                       "https://host.example/proxy")
    }

    func testTrimsWhitespaceAndTrailingSlash() {
        XCTAssertEqual(norm("  https://host.example/  "),
                       "https://host.example")
    }

    func testLeavesPlainHostUntouched() {
        XCTAssertEqual(norm("https://ollama.example.ts.net"),
                       "https://ollama.example.ts.net")
    }

    func testDoesNotStripV1Midpath() {
        // Only a trailing /v1 is a path-version artifact; a host named v1 stays.
        XCTAssertEqual(norm("https://v1.example.com"),
                       "https://v1.example.com")
    }

    func testBaseURLUsesNormalizedString() {
        let profile = BackendProfile(name: "x", baseURLString: "https://host.example/v1/")
        XCTAssertEqual(profile.baseURL?.absoluteString, "https://host.example")
    }

    func testLegacyProfileDefaultsToStandardTransport() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Old","baseURLString":"https://host.example","autoWarm":false}
        """
        let profile = try JSONDecoder().decode(BackendProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.transport, .standard)
    }

    func testMapleTransportRoundTrips() throws {
        let original = BackendProfile(
            name: "Maple",
            baseURLString: "https://enclave.example",
            transport: .mapleEncrypted
        )
        let decoded = try JSONDecoder().decode(
            BackendProfile.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.transport, .mapleEncrypted)
    }
}
