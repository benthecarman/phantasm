import XCTest
@testable import PhantasmKit

final class WarmupClientTests: XCTestCase {
    final class WarmProtocol: URLProtocol {
        nonisolated(unsafe) static var lastPath: String?
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastPath = request.url?.path
            Self.lastBody = request.httpBody ?? request.httpBodyStream?.readAllData()
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"warmed":true,"model":"native-model"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WarmProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        WarmProtocol.lastPath = nil
        WarmProtocol.lastBody = nil
    }

    func testNativeWarmSendsKeepAliveOnlyForPreload() async throws {
        await WarmupClient(session: session()).warm(
            model: "native-model",
            base: URL(string: "https://backend.example")!,
            token: "",
            mode: .ollamaNative(models: ["native-model"])
        )

        XCTAssertEqual(WarmProtocol.lastPath, "/api/chat")
        let data = try XCTUnwrap(WarmProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "native-model")
        XCTAssertEqual(json["keep_alive"] as? String, "30m")
        XCTAssertEqual((json["messages"] as? [Any])?.count, 0)
    }
}

private extension InputStream {
    func readAllData() -> Data {
        open()
        defer { close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
