import XCTest
@testable import PhantasmKit

/// The parse/generate matrix from docs/qr-pairing.md: round-trip, exotic-token
/// encoding, `/v1` normalization, missing/extra params, wrong `v`, non-http
/// schemes, and scheme/authority case-insensitivity.
final class PairingURITests: XCTestCase {
    private func parse(_ s: String) throws -> PairingPayload {
        try PairingURI.parse(XCTUnwrap(URL(string: s)))
    }

    // MARK: - Parsing

    func testParsesFullURI() throws {
        let p = try parse("phantasm://pair?v=1&url=https%3A%2F%2Fhost.example%3A8443&token=tok-123&name=Home")
        XCTAssertEqual(p.baseURLString, "https://host.example:8443")
        XCTAssertEqual(p.token, "tok-123")
        XCTAssertEqual(p.name, "Home")
        XCTAssertEqual(p.displayName, "Home")
    }

    func testTokenAndNameOptional() throws {
        let p = try parse("phantasm://pair?v=1&url=http%3A%2F%2F10.0.0.5%3A11434")
        XCTAssertNil(p.token)
        XCTAssertNil(p.name)
        XCTAssertEqual(p.displayName, "10.0.0.5", "name falls back to the host")
    }

    func testNormalizesTrailingV1AndSlashes() throws {
        let p = try parse("phantasm://pair?v=1&url=https%3A%2F%2Fhost.example%2Fv1%2F")
        XCTAssertEqual(p.baseURLString, "https://host.example")
    }

    func testOrchestratorEmittedURIParses() throws {
        // Byte-for-byte what `phantasm-orchestrator pair` prints (its URL
        // serialization appends a trailing slash; normalization strips it).
        let p = try parse(
            "phantasm://pair?v=1&url=https%3A%2F%2Fphantasm.example%3A8443%2F&token=dev-secret&name=phantasm.example"
        )
        XCTAssertEqual(p.baseURLString, "https://phantasm.example:8443")
        XCTAssertEqual(p.token, "dev-secret")
    }

    func testSchemeAndAuthorityCaseInsensitive() throws {
        let p = try parse("PHANTASM://Pair?v=1&url=https%3A%2F%2Fh.example")
        XCTAssertEqual(p.baseURLString, "https://h.example")
    }

    func testUnknownParamsIgnored() throws {
        let p = try parse("phantasm://pair?v=1&url=https%3A%2F%2Fh.example&future=x&more=y")
        XCTAssertEqual(p.baseURLString, "https://h.example")
    }

    func testPercentEncodedTokenDecodes() throws {
        let p = try parse("phantasm://pair?v=1&url=https%3A%2F%2Fh.example&token=a%20b%26c%3D%2B%2F%C3%BC")
        XCTAssertEqual(p.token, "a b&c=+/ü")
    }

    func testRawPlusInTokenStaysLiteral() throws {
        // RFC 3986 read: `+` in a query is a plus, not a space. Spec producers
        // always escape it, but a hand-built URI must not be corrupted.
        let p = try parse("phantasm://pair?v=1&url=https%3A%2F%2Fh.example&token=a+b")
        XCTAssertEqual(p.token, "a+b")
    }

    func testFirstDuplicateParamWins() throws {
        let p = try parse("phantasm://pair?v=1&url=https%3A%2F%2Fa.example&url=https%3A%2F%2Fevil.example")
        XCTAssertEqual(p.baseURLString, "https://a.example")
    }

    // MARK: - Rejection

    func testWrongSchemeOrAuthorityIsNotPairingURI() {
        for bad in ["https://pair?v=1&url=https%3A%2F%2Fh", "phantasm://settings?v=1"] {
            XCTAssertThrowsError(try parse(bad)) { error in
                XCTAssertEqual(error as? PairingURI.ParseError, .notPairingURI)
            }
        }
    }

    func testMissingOrWrongVersionRejected() {
        for bad in [
            "phantasm://pair?url=https%3A%2F%2Fh.example",
            "phantasm://pair?v=2&url=https%3A%2F%2Fh.example",
        ] {
            XCTAssertThrowsError(try parse(bad)) { error in
                XCTAssertEqual(error as? PairingURI.ParseError, .unsupportedVersion)
            }
        }
    }

    func testMissingOrNonHTTPBackendURLRejected() {
        for bad in [
            "phantasm://pair?v=1",
            "phantasm://pair?v=1&url=ftp%3A%2F%2Fh.example",
            "phantasm://pair?v=1&url=file%3A%2F%2F%2Fetc%2Fpasswd",
            "phantasm://pair?v=1&url=nonsense",
        ] {
            XCTAssertThrowsError(try parse(bad)) { error in
                XCTAssertEqual(error as? PairingURI.ParseError, .badBackendURL, "input: \(bad)")
            }
        }
    }

    // MARK: - Generation + round-trip

    func testGeneratedURIRoundTrips() throws {
        let original = PairingPayload(
            baseURLString: "https://host.example:8443",
            token: "a b&c=+/ü",
            name: "Home Server"
        )
        let parsed = try parse(original.uri)
        XCTAssertEqual(parsed, original)
    }

    func testGenerationNeverEmitsBarePlusOrAmpersandInValues() {
        let uri = PairingPayload(baseURLString: "https://h.example", token: "a+b&c", name: "x y").uri
        XCTAssertTrue(uri.contains("token=a%2Bb%26c"))
        XCTAssertTrue(uri.contains("name=x%20y"), "space is %20, never +")
    }

    // MARK: - Canonical matching + update merge

    func testMatchingProfileIgnoresHostCaseAndDefaultPort() {
        // The orchestrator's URL serializer lowercases hosts and drops :443;
        // a hand-typed profile may have both.
        let typed = BackendProfile(name: "Home", baseURLString: "https://Host.Example:443")
        let payload = PairingPayload(baseURLString: "https://host.example")
        XCTAssertEqual(payload.matchingProfile(in: [typed])?.id, typed.id)

        let other = PairingPayload(baseURLString: "https://other.example")
        XCTAssertNil(other.matchingProfile(in: [typed]))
        // A genuinely different (non-default) port is a different backend.
        let differentPort = PairingPayload(baseURLString: "https://host.example:8443")
        XCTAssertNil(differentPort.matchingProfile(in: [typed]))
    }

    func testParseErrorUserMessagesAreNonEmptyAndDistinct() {
        let all: [PairingURI.ParseError] = [.notPairingURI, .unsupportedVersion, .badBackendURL]
        let messages = all.map(\.userMessage)
        XCTAssertFalse(messages.contains(where: \.isEmpty))
        XCTAssertEqual(Set(messages).count, all.count)
    }

    func testGenerationMatchesOrchestratorForm() {
        let uri = PairingPayload(
            baseURLString: "https://phantasm.example:8443/",
            token: "dev-secret",
            name: "phantasm.example"
        ).uri
        XCTAssertEqual(
            uri,
            "phantasm://pair?v=1&url=https%3A%2F%2Fphantasm.example%3A8443%2F&token=dev-secret&name=phantasm.example"
        )
    }
}
