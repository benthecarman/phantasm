import CryptoKit
import XCTest
@testable import PhantasmKit

final class MapleEncryptedTransportTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x2a, count: 32))

    func testChaChaCombinedRepresentationRoundTrips() throws {
        let clear = Data("private message".utf8)
        let encrypted = try MapleCrypto.seal(clear, using: key)

        XCTAssertEqual(encrypted.count, 12 + clear.count + 16, "nonce + ciphertext + tag")
        XCTAssertNotEqual(encrypted, clear)
        XCTAssertEqual(try MapleCrypto.open(encrypted, using: key), clear)
    }

    func testRequestEnvelopeEncryptsBodyAndPreservesAuthorization() throws {
        var request = URLRequest(url: URL(string: "https://enclave.example/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"m","stream":true}"#.utf8)
        request.setValue("Bearer maple-key", forHTTPHeaderField: "Authorization")
        let material = MapleSessionMaterial(id: UUID().uuidString, key: key)

        let wrapped = try MapleRequestEnvelope.wrap(request, using: material)
        XCTAssertEqual(wrapped.value(forHTTPHeaderField: "x-session-id"), material.id)
        XCTAssertEqual(wrapped.value(forHTTPHeaderField: "Authorization"), "Bearer maple-key")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(wrapped.httpBody)) as? [String: String]
        )
        let encrypted = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["encrypted"])))
        XCTAssertEqual(
            try MapleCrypto.open(encrypted, using: key),
            try XCTUnwrap(request.httpBody)
        )
    }

    func testJSONEnvelopeDecryptsToOriginalOpenAIResponse() throws {
        let clear = Data(#"{"object":"list","data":[{"id":"maple-model"}]}"#.utf8)
        let encrypted = try MapleCrypto.seal(clear, using: key).base64EncodedString()
        let envelope = try JSONSerialization.data(withJSONObject: ["encrypted": encrypted])

        XCTAssertEqual(try MapleJSONEnvelope.unwrap(envelope, using: key), clear)
    }

    func testSSEEnvelopeProducesOrdinaryOpenAIEventWithoutParsingJSON() throws {
        let json = #"{"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}"#
        let encrypted = try MapleCrypto.seal(Data(json.utf8), using: key).base64EncodedString()

        let event = try XCTUnwrap(MapleSSEEnvelope.unwrap("data: \(encrypted)", using: key))
        XCTAssertEqual(String(decoding: event, as: UTF8.self), "data: \(json)\n\n")
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(
                MapleSSEEnvelope.unwrap("data: [DONE]", using: key)
            ), as: UTF8.self),
            "data: [DONE]\n\n"
        )
    }

    func testDecryptedSSEUsesExistingOpenAIEventParser() async throws {
        let json = #"{"choices":[{"delta":{"content":"hello"},"finish_reason":"stop"}]}"#
        let encrypted = try MapleCrypto.seal(Data(json.utf8), using: key).base64EncodedString()
        let event = try XCTUnwrap(MapleSSEEnvelope.unwrap("data: \(encrypted)", using: key))
        let rawLines = String(decoding: event, as: UTF8.self).components(separatedBy: "\n")
        let lines = AsyncStream<String> { continuation in
            for line in rawLines { continuation.yield(line) }
            continuation.finish()
        }

        var parsed: [ChatStreamEvent] = []
        for try await item in chatEventStream(lines: lines) { parsed.append(item) }
        XCTAssertEqual(parsed, [.token("hello"), .done])
    }

    func testAttestationParserExtractsKeyAndNonceWithoutVerifyingDocument() throws {
        let publicKey = Data((0..<32).map(UInt8.init))
        let nonce = Data("nonce-123".utf8)

        var payload = Data([0xa2]) // map(2)
        payload.append(cborText("public_key"))
        payload.append(cborBytes(publicKey))
        payload.append(cborText("nonce"))
        payload.append(cborBytes(nonce))

        var cose = Data([0x84, 0x40, 0xa0]) // array(4), protected bstr, unprotected map
        cose.append(cborBytes(payload))
        cose.append(0x40) // signature bstr (ignored by this first implementation)

        XCTAssertEqual(
            try MapleAttestationKeyExtractor.extract(from: cose),
            MapleAttestationFields(publicKey: publicKey, nonce: nonce)
        )
    }

    func testAPIBaseRecoveryPreservesMountedSubpath() throws {
        XCTAssertEqual(
            try MapleAPIBase.baseURL(
                for: URL(string: "https://host.example/private/v1/chat/completions")!
            ).absoluteString,
            "https://host.example/private"
        )
        XCTAssertEqual(
            try MapleAPIBase.baseURL(
                for: URL(string: "https://host.example/private/api/tags")!
            ).absoluteString,
            "https://host.example/private"
        )
    }

    func testAttestationParserRejectsWrongKeyLength() {
        var payload = Data([0xa2])
        payload.append(cborText("public_key"))
        payload.append(cborBytes(Data(repeating: 1, count: 31)))
        payload.append(cborText("nonce"))
        payload.append(cborBytes(Data("n".utf8)))
        var cose = Data([0x84, 0x40, 0xa0])
        cose.append(cborBytes(payload))
        cose.append(0x40)

        XCTAssertThrowsError(try MapleAttestationKeyExtractor.extract(from: cose))
    }

    private func cborText(_ text: String) -> Data {
        cbor(major: 3, data: Data(text.utf8))
    }

    private func cborBytes(_ data: Data) -> Data {
        cbor(major: 2, data: data)
    }

    private func cbor(major: UInt8, data: Data) -> Data {
        var encoded = Data()
        if data.count < 24 {
            encoded.append((major << 5) | UInt8(data.count))
        } else if data.count <= Int(UInt8.max) {
            encoded.append((major << 5) | 24)
            encoded.append(UInt8(data.count))
        } else {
            XCTFail("test fixture is unexpectedly large")
        }
        encoded.append(data)
        return encoded
    }
}
