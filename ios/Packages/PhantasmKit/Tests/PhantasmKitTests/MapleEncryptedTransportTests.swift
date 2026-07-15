import CryptoKit
import XCTest
@testable import PhantasmKit

final class MapleEncryptedTransportTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x2a, count: 32))

    func testLiveMapleModelsWhenAPIKeyIsConfigured() async throws {
        guard let token = ProcessInfo.processInfo.environment["MAPLE_API_KEY"],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set MAPLE_API_KEY to run the live Maple model-loading test.")
        }
        let base = try XCTUnwrap(URL(string: "https://enclave.trymaple.ai"))
        let client = CapabilitiesClient(session: MapleEncryptedTransport.session())

        let mode = try await client.resolveOpenAICompatible(
            base: base,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        ).get()

        XCTAssertFalse(mode.models.isEmpty)
    }

    func testLiveMapleChatStreamWhenAPIKeyIsConfigured() async throws {
        guard let token = ProcessInfo.processInfo.environment["MAPLE_API_KEY"],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set MAPLE_API_KEY to run the live Maple chat test.")
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try XCTUnwrap(URL(string: "https://enclave.trymaple.ai"))
        let session = MapleEncryptedTransport.session()
        let mode = try await CapabilitiesClient(session: session)
            .resolveOpenAICompatible(base: base, token: trimmedToken)
            .get()
        let model = try XCTUnwrap(mode.models.first)
        let request = ChatRequest(
            model: model,
            messages: [
                WireMessage(role: "user", content: "Reply with only: pong")
            ],
            stream: true
        )

        var text = ""
        var didFinish = false
        do {
            for try await event in ChatClient(session: session).stream(
                request, base: base, token: trimmedToken
            ) {
                switch event {
                case .token(let token):
                    text += token
                case .done:
                    didFinish = true
                default:
                    break
                }
            }
        } catch {
            XCTFail("Maple chat failed with \(type(of: error)): \(String(reflecting: error))")
            return
        }

        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(didFinish)
    }

    func testLiveMapleAttestationParser() async throws {
        guard ProcessInfo.processInfo.environment["MAPLE_API_KEY"] != nil else {
            throw XCTSkip("Set MAPLE_API_KEY to run the live Maple attestation parser test.")
        }
        let nonce = UUID().uuidString.lowercased()
        let url = try XCTUnwrap(URL(string: "https://enclave.trymaple.ai/attestation/\(nonce)"))

        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        struct AttestationResponse: Decodable { let attestationDocument: String }
        let attestation = try Wire.decoder().decode(AttestationResponse.self, from: data)
        let document = try XCTUnwrap(Data(base64Encoded: attestation.attestationDocument))
        let fields = try MapleAttestationKeyExtractor.extract(from: document)

        XCTAssertEqual(fields.publicKey.count, 32)
        XCTAssertEqual(fields.nonce, Data(nonce.utf8))
    }

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

    func testRequestEnvelopeEncryptsBodyStreamFromURLProtocolRequest() throws {
        let clear = Data(#"{"model":"m","stream":true}"#.utf8)
        var request = URLRequest(url: URL(string: "https://enclave.example/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: clear)
        let material = MapleSessionMaterial(id: UUID().uuidString, key: key)

        let wrapped = try MapleRequestEnvelope.wrap(request, using: material)

        XCTAssertNil(wrapped.httpBodyStream)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(wrapped.httpBody)) as? [String: String]
        )
        let encrypted = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["encrypted"])))
        XCTAssertEqual(try MapleCrypto.open(encrypted, using: key), clear)
    }

    func testPreparedRequestReusesBodyStreamPayloadForSessionRetry() throws {
        let clear = Data(#"{"model":"m","stream":true}"#.utf8)
        var request = URLRequest(url: URL(string: "https://enclave.example/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: clear)
        let prepared = try MapleRequestEnvelope.prepare(request)
        let firstMaterial = MapleSessionMaterial(id: UUID().uuidString, key: key)
        let secondKey = SymmetricKey(data: Data(repeating: 0x5a, count: 32))
        let secondMaterial = MapleSessionMaterial(id: UUID().uuidString, key: secondKey)

        let first = try prepared.wrapped(using: firstMaterial)
        let second = try prepared.wrapped(using: secondMaterial)

        XCTAssertEqual(try decryptedRequestBody(first, using: key), clear)
        XCTAssertEqual(try decryptedRequestBody(second, using: secondKey), clear)
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

    func testAttestationParserAcceptsNitroDocumentMapShape() throws {
        let publicKey = Data((0..<32).map { UInt8(255 - $0) })
        let nonce = Data("nonce-456".utf8)

        var document = Data([0xa4]) // map(4)
        document.append(cborText("module_id"))
        document.append(cborText("test-module"))
        document.append(cborText("public_key"))
        document.append(cborBytes(publicKey))
        document.append(cborText("nonce"))
        document.append(cborBytes(nonce))
        document.append(cborText("user_data"))
        document.append(cborBytes(Data()))

        XCTAssertEqual(
            try MapleAttestationKeyExtractor.extract(from: document),
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

    func testAttestationParserRejectsOversizedDocument() {
        let document = Data(
            repeating: 0,
            count: MapleAttestationKeyExtractor.maximumDocumentBytes + 1
        )

        XCTAssertThrowsError(try MapleAttestationKeyExtractor.extract(from: document)) { error in
            XCTAssertEqual(error as? MapleTransportError, .responseTooLarge)
        }
    }

    func testBoundedResponseRejectsDeclaredLengthBeforeReading() async throws {
        let response = URLResponse(
            url: URL(string: "https://enclave.example/attestation")!,
            mimeType: "application/json",
            expectedContentLength: 5,
            textEncodingName: nil
        )
        let bytes = AsyncStream<UInt8> { continuation in
            continuation.yield(0x7b)
            continuation.finish()
        }

        do {
            _ = try await MapleBoundedResponse.collect(bytes, response: response, limit: 4)
            XCTFail("expected declared oversized response to fail")
        } catch {
            XCTAssertEqual(error as? MapleTransportError, .responseTooLarge)
        }
    }

    func testBoundedResponseRejectsChunkedBodyAtCap() async throws {
        let response = URLResponse(
            url: URL(string: "https://enclave.example/key_exchange")!,
            mimeType: "application/json",
            expectedContentLength: -1,
            textEncodingName: nil
        )
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in [UInt8](repeating: 0x61, count: 5) {
                continuation.yield(byte)
            }
            continuation.finish()
        }

        do {
            _ = try await MapleBoundedResponse.collect(bytes, response: response, limit: 4)
            XCTFail("expected chunked oversized response to fail")
        } catch {
            XCTAssertEqual(error as? MapleTransportError, .responseTooLarge)
        }
    }

    func testAttestationBase64IsBoundedBeforeDecode() {
        let oversized = String(
            repeating: "A",
            count: MapleAttestationDocumentDecoder.maximumEncodedBytes + 1
        )

        XCTAssertThrowsError(try MapleAttestationDocumentDecoder.decode(oversized)) { error in
            XCTAssertEqual(error as? MapleTransportError, .responseTooLarge)
        }
    }

    func testURLProtocolCallbackGateWaitsForDeliveryThenStopsFutureCallbacks() {
        let gate = MapleURLProtocolCallbackGate()
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let callbackReturned = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = gate.perform {
                callbackEntered.signal()
                releaseCallback.wait()
            }
            callbackReturned.signal()
        }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            gate.stop()
            stopReturned.signal()
        }
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + 0.05),
            .timedOut,
            "stop must not return while a client callback is still running"
        )

        releaseCallback.signal()
        XCTAssertEqual(callbackReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(gate.perform { XCTFail("callback ran after stop") })
    }

    func testAttestationParserRejectsExcessiveNesting() {
        // Tag 0 wrapped deeply around an otherwise valid empty map.
        var document = Data(repeating: 0xc0, count: 34)
        document.append(0xa0)

        XCTAssertThrowsError(try MapleAttestationKeyExtractor.extract(from: document)) { error in
            XCTAssertEqual(error as? MapleTransportError, .invalidCBOR)
        }
    }

    func testAttestationParserRejectsOversizedCollectionBeforeAllocating() {
        // array(4097), encoded as a 32-bit collection length with no payload.
        let document = Data([0x9a, 0x00, 0x00, 0x10, 0x01])

        XCTAssertThrowsError(try MapleAttestationKeyExtractor.extract(from: document)) { error in
            XCTAssertEqual(error as? MapleTransportError, .invalidCBOR)
        }
    }

    private func cborText(_ text: String) -> Data {
        cbor(major: 3, data: Data(text.utf8))
    }

    private func decryptedRequestBody(_ request: URLRequest, using key: SymmetricKey) throws
        -> Data
    {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        )
        let encrypted = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["encrypted"])))
        return try MapleCrypto.open(encrypted, using: key)
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
