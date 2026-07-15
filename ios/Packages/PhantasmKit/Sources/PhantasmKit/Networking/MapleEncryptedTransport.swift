import CryptoKit
import Foundation

/// An OpenAI-compatible transport for Maple/OpenSecret endpoints.
///
/// Callers still use `ChatClient` / `CapabilitiesClient` and ordinary OpenAI
/// request and response bodies. This transport changes only the HTTP envelope:
/// it establishes an OpenSecret session, encrypts outgoing JSON, and decrypts
/// successful JSON/SSE responses before the existing clients see them.
///
/// - Important: This first implementation extracts the enclave's X25519 key
///   from its attestation document but deliberately does **not** verify the
///   document's certificate chain, signature, or PCR measurements. Traffic is
///   encrypted, but the server's identity is not yet authenticated. Keep that
///   distinction explicit until full attestation verification is added.
public enum MapleEncryptedTransport {
    /// A URLSession that transparently adapts normal OpenAI requests to Maple's
    /// encrypted wire protocol. The supplied configuration is copied.
    public static func session(
        configuration: URLSessionConfiguration = .default
    ) -> URLSession {
        let copy = configuration.copy() as? URLSessionConfiguration
            ?? URLSessionConfiguration.default
        copy.protocolClasses = [MapleEncryptedURLProtocol.self]
        return URLSession(configuration: copy)
    }

    /// Establish and cache an encrypted session. Backend resolution uses this
    /// as the Maple probe after ordinary OpenAI/Ollama detection fails.
    public static func prepare(base: URL) async throws {
        _ = try await MapleSessionCache.shared.session(for: base)
    }
}

/// Thin `ChatClienting` facade over the normal OpenAI client. All OpenAI SSE
/// interpretation remains in `ChatClient`; only the URL loading transport is
/// different.
public struct MapleChatClient: ChatClienting {
    private let openAI: ChatClient

    public init(session: URLSession? = nil) {
        if let session {
            self.openAI = ChatClient(session: session)
        } else {
            // Match ChatClient's cold-model tolerance; supplying a custom
            // URLSession must not accidentally restore URLSession's 60s idle
            // timeout for the encrypted path.
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 60 * 60
            self.openAI = ChatClient(
                session: MapleEncryptedTransport.session(configuration: config)
            )
        }
    }

    public func stream(_ request: ChatRequest, base: URL, token: String, turnID: String?)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        openAI.stream(request, base: base, token: token, turnID: turnID)
    }

    public func cancel(turnID: String, base: URL, token: String) async {
        await openAI.cancel(turnID: turnID, base: base, token: token)
    }
}

// MARK: - URL loading adapter

/// Serializes URLProtocol client delivery with `stopLoading()`. A recursive lock
/// permits a client callback to stop the protocol reentrantly; a stop from any
/// other thread waits for an already-started callback, then prevents all later
/// callbacks before returning.
final class MapleURLProtocolCallbackGate: @unchecked Sendable {
    private enum State { case active, stopped, finished }

    private let lock = NSRecursiveLock()
    private var state = State.active

    @discardableResult
    func perform(terminal: Bool = false, _ callback: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return false }
        if terminal { state = .finished }
        callback()
        return true
    }

    func stop() {
        lock.lock()
        state = .stopped
        lock.unlock()
    }
}

private final class MapleEncryptedURLProtocol: URLProtocol, @unchecked Sendable {
    private let taskLock = NSLock()
    private let callbackGate = MapleURLProtocolCallbackGate()
    private var loadingTask: Task<Void, Never>?
    private var loadingStopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        // This protocol is installed only in Maple-specific URL sessions. The
        // handshake uses a separate URLSession, so it cannot recurse here.
        request.url?.scheme == "https" || request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.load()
        }
        let shouldCancel = taskLock.withLock {
            guard !loadingStopped, loadingTask == nil else { return true }
            loadingTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    override func stopLoading() {
        // Close callback delivery first. When this returns, no callback can
        // subsequently begin, even if cancellation races the final byte.
        callbackGate.stop()
        let task = taskLock.withLock {
            loadingStopped = true
            let task = loadingTask
            loadingTask = nil
            return task
        }
        task?.cancel()
    }

    private func load() async {
        do {
            guard let url = request.url else { throw MapleTransportError.missingURL }
            let base = try MapleAPIBase.baseURL(for: url)
            // URLProtocol exposes Foundation's one-shot body stream rather than
            // the original Data in some requests. Read it exactly once so a
            // stale-session retry can encrypt the same payload again.
            let preparedRequest = try MapleRequestEnvelope.prepare(request)

            var attempt = 0
            while true {
                try Task.checkCancellation()
                let material = try await MapleSessionCache.shared.session(for: base)
                let upstreamRequest = try preparedRequest.wrapped(using: material)
                let (bytes, response) = try await MapleNetwork.streaming.bytes(for: upstreamRequest)

                // OpenSecret treats a 400 as a possibly expired encrypted
                // session and retries one fresh handshake. Drain the small error
                // body before retrying so the connection remains reusable.
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 400, attempt == 0 {
                    for try await _ in bytes { try Task.checkCancellation() }
                    await MapleSessionCache.shared.invalidate(base: base, sessionID: material.id)
                    attempt += 1
                    continue
                }

                do {
                    try await relay(bytes: bytes, response: response, material: material)
                } catch {
                    // A failed authenticated decryption makes this session
                    // unusable. Do not poison the next request with it.
                    await MapleSessionCache.shared.invalidate(
                        base: base, sessionID: material.id
                    )
                    throw error
                }
                return
            }
        } catch is CancellationError {
            // URLProtocol cancellation is expected when the user stops a turn.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession commonly surfaces task cancellation as URLError rather
            // than Swift's CancellationError.
        } catch {
            fail(with: error)
        }
    }

    private func deliver(
        terminal: Bool = false,
        _ callback: (URLProtocolClient) -> Void
    ) throws {
        guard let client,
              callbackGate.perform(terminal: terminal, { callback(client) })
        else { throw CancellationError() }
    }

    private func fail(with error: Error) {
        guard let client else { return }
        callbackGate.perform(terminal: true) {
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    private func relay(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        material: MapleSessionMaterial
    ) async throws {
        guard let http = response as? HTTPURLResponse else {
            try deliver {
                $0.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            try await relayRaw(bytes)
            try deliver(terminal: true) { $0.urlProtocolDidFinishLoading(self) }
            return
        }

        let successful = (200..<300).contains(http.statusCode)
        let isSSE = http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream") == true

        if !successful {
            try deliver {
                $0.urlProtocol(
                    self,
                    didReceive: MapleResponseHeaders.sanitized(http, contentType: nil),
                    cacheStoragePolicy: .notAllowed
                )
            }
            try await relayRaw(bytes)
            try deliver(terminal: true) { $0.urlProtocolDidFinishLoading(self) }
            return
        }

        if isSSE {
            try deliver {
                $0.urlProtocol(
                    self,
                    didReceive: MapleResponseHeaders.sanitized(
                        http, contentType: "text/event-stream; charset=utf-8"
                    ),
                    cacheStoragePolicy: .notAllowed
                )
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let clearEvent = try MapleSSEEnvelope.unwrap(line, using: material.key) {
                    try deliver { $0.urlProtocol(self, didLoad: clearEvent) }
                }
            }
            try deliver(terminal: true) { $0.urlProtocolDidFinishLoading(self) }
            return
        }

        if http.statusCode == 204 {
            try deliver {
                $0.urlProtocol(
                    self,
                    didReceive: MapleResponseHeaders.sanitized(http, contentType: nil),
                    cacheStoragePolicy: .notAllowed
                )
            }
            for try await _ in bytes { try Task.checkCancellation() }
            try deliver(terminal: true) { $0.urlProtocolDidFinishLoading(self) }
            return
        }

        var encryptedResponse = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            encryptedResponse.append(byte)
            guard encryptedResponse.count <= MapleTransportLimits.maximumJSONResponseBytes else {
                throw MapleTransportError.responseTooLarge
            }
        }
        let clearResponse = try MapleJSONEnvelope.unwrap(encryptedResponse, using: material.key)
        try deliver {
            $0.urlProtocol(
                self,
                didReceive: MapleResponseHeaders.sanitized(
                    http, contentType: "application/json"
                ),
                cacheStoragePolicy: .notAllowed
            )
        }
        try deliver { $0.urlProtocol(self, didLoad: clearResponse) }
        try deliver(terminal: true) { $0.urlProtocolDidFinishLoading(self) }
    }

    private func relayRaw(_ bytes: URLSession.AsyncBytes) async throws {
        var buffer = Data()
        buffer.reserveCapacity(16 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 16 * 1024 {
                try deliver { $0.urlProtocol(self, didLoad: buffer) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try deliver { $0.urlProtocol(self, didLoad: buffer) } }
    }
}

private enum MapleTransportLimits {
    static let maximumJSONResponseBytes = 16 * 1_024 * 1_024
}

/// Collects a response without ever allowing Foundation-facing code to retain
/// more than the configured cap. Content-Length is rejected before iteration;
/// chunked/missing-length responses are bounded byte by byte.
enum MapleBoundedResponse {
    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        response: URLResponse,
        limit: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard limit >= 0 else { throw MapleTransportError.responseTooLarge }
        try validateExpectedLength(response, limit: limit)
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), limit))
        }
        for try await byte in bytes {
            guard data.count < limit else {
                throw MapleTransportError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }

    static func validateExpectedLength(_ response: URLResponse, limit: Int) throws {
        let expected = response.expectedContentLength
        guard expected < 0 || expected <= Int64(limit) else {
            throw MapleTransportError.responseTooLarge
        }
    }
}

private enum MapleResponseHeaders {
    static func sanitized(_ response: HTTPURLResponse, contentType: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName)
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame
                || name.caseInsensitiveCompare("Content-Encoding") == .orderedSame
                || name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame
            {
                continue
            }
            headers[name] = String(describing: rawValue)
        }
        if let contentType { headers["Content-Type"] = contentType }
        guard let url = response.url else { return response }
        return HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? response
    }
}

// MARK: - Encrypted OpenAI envelopes

struct MapleSessionMaterial: @unchecked Sendable {
    let id: String
    let key: SymmetricKey
}

enum MapleRequestEnvelope {
    private struct Body: Encodable { let encrypted: String }

    struct Prepared {
        fileprivate let request: URLRequest
        fileprivate let clearBody: Data?

        func wrapped(using material: MapleSessionMaterial) throws -> URLRequest {
            var wrapped = request
            wrapped.httpBodyStream = nil
            if let clearBody, !clearBody.isEmpty {
                let encrypted = try MapleCrypto.seal(clearBody, using: material.key)
                wrapped.httpBody = try JSONEncoder().encode(
                    Body(encrypted: encrypted.base64EncodedString())
                )
            }
            wrapped.setValue("application/json", forHTTPHeaderField: "Content-Type")
            wrapped.setValue(material.id, forHTTPHeaderField: "x-session-id")
            wrapped.setValue(nil, forHTTPHeaderField: "Content-Length")
            return wrapped
        }
    }

    static func prepare(_ request: URLRequest) throws -> Prepared {
        Prepared(request: request, clearBody: try request.mapleHTTPBody)
    }

    static func wrap(_ request: URLRequest, using material: MapleSessionMaterial) throws
        -> URLRequest
    {
        try prepare(request).wrapped(using: material)
    }
}

private extension URLRequest {
    var mapleHTTPBody: Data? {
        get throws {
            if let httpBody { return httpBody }
            guard let stream = httpBodyStream else { return nil }

            stream.open()
            defer { stream.close() }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                } else if count == 0 {
                    return data
                } else {
                    throw stream.streamError ?? MapleTransportError.requestBodyStreamUnreadable
                }
            }
        }
    }
}

enum MapleJSONEnvelope {
    private struct Body: Decodable { let encrypted: String }

    static func unwrap(_ data: Data, using key: SymmetricKey) throws -> Data {
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let encrypted = Data(base64Encoded: body.encrypted) else {
            throw MapleTransportError.invalidBase64
        }
        return try MapleCrypto.open(encrypted, using: key)
    }
}

enum MapleSSEEnvelope {
    /// Converts one encrypted Maple SSE field into an ordinary OpenAI SSE
    /// event. It intentionally does not inspect the decrypted JSON.
    static func unwrap(_ rawLine: String, using key: SymmetricKey) throws -> Data? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.hasPrefix(":") {
            // Preserve heartbeats as standard SSE comments.
            return Data("\(line)\n\n".utf8)
        }
        guard line.hasPrefix("data:") else { return nil }
        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if payload == "[DONE]" { return Data("data: [DONE]\n\n".utf8) }
        guard let encrypted = Data(base64Encoded: payload) else {
            // Match the OpenSecret SDK: non-base64 retry/heartbeat events are
            // transport metadata, not model output.
            return nil
        }
        let clear = try MapleCrypto.open(encrypted, using: key)
        guard String(data: clear, encoding: .utf8) != nil else {
            throw MapleTransportError.invalidUTF8
        }
        var event = Data("data: ".utf8)
        event.append(clear)
        event.append(Data("\n\n".utf8))
        return event
    }
}

enum MapleCrypto {
    /// CryptoKit's ChaChaPoly combined representation is the OpenSecret wire
    /// representation: 12-byte nonce || ciphertext || 16-byte tag.
    static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    static func open(_ encrypted: Data, using key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: encrypted)
        return try ChaChaPoly.open(box, using: key)
    }
}

// MARK: - Session establishment

private actor MapleSessionCache {
    static let shared = MapleSessionCache()

    private var sessions: [String: MapleSessionMaterial] = [:]
    private var pending: [String: Task<MapleSessionMaterial, Error>] = [:]

    func session(for base: URL) async throws -> MapleSessionMaterial {
        let cacheKey = MapleAPIBase.normalized(base).absoluteString
        if let session = sessions[cacheKey] { return session }
        if let task = pending[cacheKey] { return try await task.value }

        let normalized = MapleAPIBase.normalized(base)
        let task = Task { try await MapleHandshake.establish(base: normalized) }
        pending[cacheKey] = task
        do {
            let session = try await task.value
            sessions[cacheKey] = session
            pending[cacheKey] = nil
            return session
        } catch {
            pending[cacheKey] = nil
            throw error
        }
    }

    func invalidate(base: URL, sessionID: String) {
        let cacheKey = MapleAPIBase.normalized(base).absoluteString
        guard sessions[cacheKey]?.id == sessionID else { return }
        sessions[cacheKey] = nil
    }
}

private enum MapleHandshake {
    private struct AttestationResponse: Decodable { let attestationDocument: String }
    private struct KeyExchangeRequest: Encodable {
        let clientPublicKey: String
        let nonce: String
    }
    private struct KeyExchangeResponse: Decodable {
        let encryptedSessionKey: String
        let sessionId: String
    }

    static func establish(base: URL) async throws -> MapleSessionMaterial {
        let nonce = UUID().uuidString.lowercased()
        let attestationURL = base
            .appendingPathComponent("attestation")
            .appendingPathComponent(nonce)
        let (attestationBytes, attestationResponse) = try await MapleNetwork.json.bytes(
            from: attestationURL
        )
        let attestationData = try await MapleBoundedResponse.collect(
            attestationBytes,
            response: attestationResponse,
            limit: MapleTransportLimits.maximumJSONResponseBytes
        )
        try requireSuccess(attestationResponse, data: attestationData)
        let attestation = try Wire.decoder().decode(
            AttestationResponse.self, from: attestationData
        )
        let document = try MapleAttestationDocumentDecoder.decode(
            attestation.attestationDocument
        )
        let fields = try MapleAttestationKeyExtractor.extract(from: document)
        guard fields.nonce == Data(nonce.utf8) else {
            throw MapleTransportError.attestationNonceMismatch
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: fields.publicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: serverKey)
        let sharedKey = sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }

        var keyRequest = URLRequest(url: base.appendingPathComponent("key_exchange"))
        keyRequest.httpMethod = "POST"
        keyRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        keyRequest.httpBody = try Wire.encoder().encode(KeyExchangeRequest(
            clientPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            nonce: nonce
        ))
        let (keyBytes, keyResponse) = try await MapleNetwork.json.bytes(for: keyRequest)
        let keyData = try await MapleBoundedResponse.collect(
            keyBytes,
            response: keyResponse,
            limit: MapleTransportLimits.maximumJSONResponseBytes
        )
        try requireSuccess(keyResponse, data: keyData)
        let exchange = try Wire.decoder().decode(KeyExchangeResponse.self, from: keyData)
        guard UUID(uuidString: exchange.sessionId) != nil,
              let encryptedSessionKey = Data(base64Encoded: exchange.encryptedSessionKey)
        else {
            throw MapleTransportError.invalidKeyExchange
        }
        let sessionKey = try MapleCrypto.open(encryptedSessionKey, using: sharedKey)
        guard sessionKey.count == 32 else { throw MapleTransportError.invalidSessionKey }
        return MapleSessionMaterial(id: exchange.sessionId, key: SymmetricKey(data: sessionKey))
    }

    private static func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MapleTransportError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(2_048), encoding: .utf8) ?? ""
            throw MapleTransportError.httpStatus(http.statusCode, detail)
        }
    }
}

enum MapleAttestationDocumentDecoder {
    static let maximumEncodedBytes =
        ((MapleAttestationKeyExtractor.maximumDocumentBytes + 2) / 3) * 4

    static func decode(_ encoded: String) throws -> Data {
        guard encoded.utf8.count <= maximumEncodedBytes else {
            throw MapleTransportError.responseTooLarge
        }
        guard let document = Data(base64Encoded: encoded) else {
            throw MapleTransportError.invalidBase64
        }
        guard document.count <= MapleAttestationKeyExtractor.maximumDocumentBytes else {
            throw MapleTransportError.responseTooLarge
        }
        return document
    }
}

private enum MapleNetwork {
    static let json: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    static let streaming: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()
}

enum MapleAPIBase {
    static func normalized(_ base: URL) -> URL {
        var value = base
        while value.path.hasSuffix("/") && value.path != "/" {
            value.deleteLastPathComponent()
        }
        return value
    }

    /// Recovers the configured API base from paths appended by the existing
    /// OpenAI/Ollama clients, preserving deployments mounted under a subpath.
    static func baseURL(for endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { throw MapleTransportError.missingURL }
        let path = components.percentEncodedPath
        let markers = ["/v1/", "/api/"]
        guard let marker = markers.compactMap({ path.range(of: $0, options: .backwards) }).max(
            by: { $0.lowerBound < $1.lowerBound }
        ) else {
            throw MapleTransportError.unrecognizedEndpoint(path)
        }
        components.percentEncodedPath = String(path[..<marker.lowerBound])
        components.query = nil
        components.fragment = nil
        guard let base = components.url else { throw MapleTransportError.missingURL }
        return normalized(base)
    }
}

// MARK: - Minimal attestation-document CBOR extraction

struct MapleAttestationFields: Equatable {
    let publicKey: Data
    let nonce: Data
}

enum MapleAttestationKeyExtractor {
    static let maximumDocumentBytes = 1_024 * 1_024

    /// Extracts only the key-exchange fields from the Nitro attestation document.
    /// This is parsing, not attestation verification; see
    /// `MapleEncryptedTransport` above.
    static func extract(from document: Data) throws -> MapleAttestationFields {
        guard document.count <= maximumDocumentBytes else {
            throw MapleTransportError.responseTooLarge
        }
        var outerParser = MinimalCBORParser(data: document)
        let outer = try outerParser.parseComplete().untagged
        switch outer {
        case .map(let fields):
            return try extract(fromFields: fields)

        case .array(let cose):
            guard cose.count == 4, case .bytes(let payload) = cose[2] else {
                throw MapleTransportError.invalidAttestationDocument
            }
            var payloadParser = MinimalCBORParser(data: payload)
            guard case .map(let fields) = try payloadParser.parseComplete().untagged else {
                throw MapleTransportError.invalidAttestationDocument
            }
            return try extract(fromFields: fields)

        default:
            throw MapleTransportError.invalidAttestationDocument
        }
    }

    private static func extract(
        fromFields fields: [(MinimalCBORValue, MinimalCBORValue)]
    ) throws -> MapleAttestationFields {
        var publicKey: Data?
        var nonce: Data?
        for (key, value) in fields {
            guard case .text(let name) = key.untagged else { continue }
            switch (name, value.untagged) {
            case ("public_key", .bytes(let bytes)): publicKey = bytes
            case ("nonce", .bytes(let bytes)): nonce = bytes
            case ("nonce", .text(let text)): nonce = Data(text.utf8)
            default: break
            }
        }
        guard let publicKey, publicKey.count == 32, let nonce else {
            throw MapleTransportError.invalidAttestationDocument
        }
        return MapleAttestationFields(publicKey: publicKey, nonce: nonce)
    }
}

private indirect enum MinimalCBORValue {
    case unsigned(UInt64)
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([MinimalCBORValue])
    case map([(MinimalCBORValue, MinimalCBORValue)])
    case tagged(UInt64, MinimalCBORValue)
    case simple(UInt8)

    var untagged: MinimalCBORValue {
        if case .tagged(_, let value) = self { return value.untagged }
        return self
    }
}

private struct MinimalCBORParser {
    private static let maximumNestingDepth = 32
    private static let maximumCollectionCount = 4_096

    let data: Data
    var offset = 0

    mutating func parseComplete() throws -> MinimalCBORValue {
        let value = try parse(depth: 0)
        guard offset == data.count else { throw MapleTransportError.invalidCBOR }
        return value
    }

    private mutating func parse(depth: Int) throws -> MinimalCBORValue {
        guard depth <= Self.maximumNestingDepth else {
            throw MapleTransportError.invalidCBOR
        }
        let initial = try readByte()
        let major = initial >> 5
        let additional = initial & 0x1f
        switch major {
        case 0:
            return .unsigned(try length(additional))
        case 1:
            let raw = try length(additional)
            guard raw <= UInt64(Int64.max) else { throw MapleTransportError.invalidCBOR }
            return .negative(-1 - Int64(raw))
        case 2:
            if additional == 31 { return .bytes(try parseIndefiniteBytes(depth: depth)) }
            let rawCount = try length(additional)
            let count = try integerCount(rawCount)
            return .bytes(try readData(count: count))
        case 3:
            if additional == 31 { return .text(try parseIndefiniteText(depth: depth)) }
            let rawCount = try length(additional)
            let count = try integerCount(rawCount)
            let bytes = try readData(count: count)
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw MapleTransportError.invalidUTF8
            }
            return .text(text)
        case 4:
            if additional == 31 { return .array(try parseIndefiniteArray(depth: depth)) }
            let rawCount = try length(additional)
            let count = try integerCount(rawCount)
            guard count <= Self.maximumCollectionCount else {
                throw MapleTransportError.invalidCBOR
            }
            var values: [MinimalCBORValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try parse(depth: depth + 1)) }
            return .array(values)
        case 5:
            if additional == 31 { return .map(try parseIndefiniteMap(depth: depth)) }
            let rawCount = try length(additional)
            let count = try integerCount(rawCount)
            guard count <= Self.maximumCollectionCount else {
                throw MapleTransportError.invalidCBOR
            }
            var values: [(MinimalCBORValue, MinimalCBORValue)] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                values.append((
                    try parse(depth: depth + 1),
                    try parse(depth: depth + 1)
                ))
            }
            return .map(values)
        case 6:
            return .tagged(try length(additional), try parse(depth: depth + 1))
        case 7:
            switch additional {
            case 0...23: return .simple(additional)
            case 24: return .simple(try readByte())
            case 25: _ = try readData(count: 2); return .simple(additional)
            case 26: _ = try readData(count: 4); return .simple(additional)
            case 27: _ = try readData(count: 8); return .simple(additional)
            default: throw MapleTransportError.invalidCBOR
            }
        default:
            throw MapleTransportError.invalidCBOR
        }
    }

    private mutating func length(_ additional: UInt8) throws -> UInt64 {
        switch additional {
        case 0...23: return UInt64(additional)
        case 24: return UInt64(try readByte())
        case 25: return try readUInt(byteCount: 2)
        case 26: return try readUInt(byteCount: 4)
        case 27: return try readUInt(byteCount: 8)
        default: throw MapleTransportError.invalidCBOR
        }
    }

    private func integerCount(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw MapleTransportError.invalidCBOR }
        return Int(value)
    }

    private mutating func parseIndefiniteBytes(depth: Int) throws -> Data {
        var result = Data()
        var chunkCount = 0
        while !consumeBreakIfPresent() {
            guard chunkCount < Self.maximumCollectionCount,
                  case .bytes(let chunk) = try parse(depth: depth + 1),
                  chunk.count <= data.count - result.count else {
                throw MapleTransportError.invalidCBOR
            }
            result.append(chunk)
            chunkCount += 1
        }
        return result
    }

    private mutating func parseIndefiniteText(depth: Int) throws -> String {
        var result = ""
        var chunkCount = 0
        while !consumeBreakIfPresent() {
            guard chunkCount < Self.maximumCollectionCount,
                  case .text(let chunk) = try parse(depth: depth + 1) else {
                throw MapleTransportError.invalidCBOR
            }
            result.append(chunk)
            chunkCount += 1
            guard result.utf8.count <= data.count else {
                throw MapleTransportError.invalidCBOR
            }
        }
        return result
    }

    private mutating func parseIndefiniteArray(depth: Int) throws -> [MinimalCBORValue] {
        var values: [MinimalCBORValue] = []
        while !consumeBreakIfPresent() {
            guard values.count < Self.maximumCollectionCount else {
                throw MapleTransportError.invalidCBOR
            }
            values.append(try parse(depth: depth + 1))
        }
        return values
    }

    private mutating func parseIndefiniteMap(
        depth: Int
    ) throws -> [(MinimalCBORValue, MinimalCBORValue)] {
        var values: [(MinimalCBORValue, MinimalCBORValue)] = []
        while !consumeBreakIfPresent() {
            guard values.count < Self.maximumCollectionCount else {
                throw MapleTransportError.invalidCBOR
            }
            values.append((
                try parse(depth: depth + 1),
                try parse(depth: depth + 1)
            ))
        }
        return values
    }

    private mutating func readUInt(byteCount: Int) throws -> UInt64 {
        let bytes = try readData(count: byteCount)
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private mutating func consumeBreakIfPresent() -> Bool {
        guard offset < data.count, data[offset] == 0xff else { return false }
        offset += 1
        return true
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw MapleTransportError.invalidCBOR }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw MapleTransportError.invalidCBOR
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}

enum MapleTransportError: Error, LocalizedError, Equatable {
    case missingURL
    case unrecognizedEndpoint(String)
    case requestBodyStreamUnreadable
    case invalidBase64
    case invalidUTF8
    case invalidCBOR
    case responseTooLarge
    case invalidAttestationDocument
    case attestationNonceMismatch
    case invalidKeyExchange
    case invalidSessionKey
    case nonHTTPResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingURL: return "Maple request is missing its URL."
        case .unrecognizedEndpoint(let path): return "Maple cannot adapt endpoint path \(path)."
        case .requestBodyStreamUnreadable: return "Maple could not read the request body stream."
        case .invalidBase64: return "Maple returned invalid encrypted data."
        case .invalidUTF8: return "Maple returned invalid text data."
        case .invalidCBOR: return "Maple returned malformed CBOR."
        case .responseTooLarge: return "Maple returned a response that was too large."
        case .invalidAttestationDocument: return "Maple returned an unusable attestation document."
        case .attestationNonceMismatch: return "Maple returned an attestation for a different handshake."
        case .invalidKeyExchange: return "Maple returned an invalid key exchange response."
        case .invalidSessionKey: return "Maple returned an invalid encrypted session key."
        case .nonHTTPResponse: return "Maple returned a non-HTTP response."
        case .httpStatus(let status, let detail):
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return "Maple handshake failed with HTTP \(status)\(suffix)"
        }
    }
}
