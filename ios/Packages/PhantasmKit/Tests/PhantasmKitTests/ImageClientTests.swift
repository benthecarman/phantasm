import XCTest

@testable import PhantasmKit

final class ImageClientTests: XCTestCase {
    final class RecordingProtocol: URLProtocol {
        struct Hit: Sendable {
            let method: String
            let url: String
            let auth: String?
        }
        nonisolated(unsafe) static var hits: [Hit] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            Self.hits.append(
                Hit(
                    method: request.httpMethod ?? "",
                    url: request.url?.absoluteString ?? "",
                    auth: request.value(forHTTPHeaderField: "Authorization")
                ))
            Self.lock.unlock()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        return URLSession(configuration: config)
    }

    func testDeletesEachIDWithBearer() async {
        RecordingProtocol.hits = []
        await ImageClient(session: session())
            .delete(
                ids: ["abc123", "DEF-_4"],
                base: URL(string: "https://host.example")!,
                token: "secret")

        let hits = RecordingProtocol.hits.sorted { $0.url < $1.url }
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.method == "DELETE" })
        XCTAssertTrue(hits.allSatisfy { $0.auth == "Bearer secret" })
        XCTAssertEqual(
            Set(hits.map(\.url)),
            [
                "https://host.example/v1/images/abc123",
                "https://host.example/v1/images/DEF-_4",
            ])
    }
}
