import XCTest
@testable import PhantasmKit

/// A direct no-auth backend such as local Ollama is a valid config: the token is
/// optional. These tests lock in that an empty token sends NO `Authorization`
/// header (rather than a malformed
/// `Bearer `), while a real token still does — the regression that left the
/// send button permanently disabled when no token was entered.
final class AuthHeaderTests: XCTestCase {
    /// Captures the outgoing request's Authorization header, then fails the
    /// load so the clients fall back without needing a real server.
    final class CapturingProtocol: URLProtocol {
        nonisolated(unsafe) static var lastAuthorization: String??

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: config)
    }

    private let base = URL(string: "https://backend.example")!

    override func setUp() {
        super.setUp()
        CapturingProtocol.lastAuthorization = nil
    }

    func testCapabilitiesOmitsHeaderWhenTokenEmpty() async {
        _ = await CapabilitiesClient(session: session()).resolve(base: base, token: "")
        // Outer optional: a request was made. Inner: no Authorization header set.
        XCTAssertEqual(CapturingProtocol.lastAuthorization, .some(.none))
    }

    func testCapabilitiesSendsBearerWhenTokenPresent() async {
        _ = await CapabilitiesClient(session: session()).resolve(base: base, token: "secret")
        XCTAssertEqual(CapturingProtocol.lastAuthorization, "Bearer secret")
    }

    func testChatStreamOmitsHeaderWhenTokenEmpty() async {
        let req = ChatRequest(model: "m", messages: [], stream: true)
        let stream = ChatClient(session: session()).stream(req, base: base, token: "")
        // Drain (the request fails by design); we only care about the header.
        do { for try await _ in stream {} } catch {}
        XCTAssertEqual(CapturingProtocol.lastAuthorization, .some(.none))
    }

    func testChatStreamSendsBearerWhenTokenPresent() async {
        let req = ChatRequest(model: "m", messages: [], stream: true)
        let stream = ChatClient(session: session()).stream(req, base: base, token: "secret")
        do { for try await _ in stream {} } catch {}
        XCTAssertEqual(CapturingProtocol.lastAuthorization, "Bearer secret")
    }
}
