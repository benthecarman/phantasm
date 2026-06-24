import SwiftData
import XCTest
@testable import PhantasmKit

final class CapabilityDecodeTests: XCTestCase {
    func testFullManifestDecodes() throws {
        let json = """
        {"version":"0.1.0","chat":true,"models":["llama3.1","qwen2.5:14b"],
         "tools":{"web_search":true,"image_generation":false},"streaming":"sse"}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.models, ["llama3.1", "qwen2.5:14b"])
        XCTAssertEqual(caps.tools?.webSearch, true)
        XCTAssertEqual(caps.tools?.imageGeneration, false)

        let mode = BackendMode.full(caps)
        XCTAssertTrue(mode.showsTools)
        XCTAssertEqual(mode.models.count, 2)
    }

    func testManifestDecodesVisionModels() throws {
        let json = """
        {"version":"0.1.0","chat":true,"models":["llava","qwen"],
         "vision_models":["llava"],"tools":{"web_search":false,"image_generation":false},
         "streaming":"sse"}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.visionModels, ["llava"])
    }

    func testManifestWithoutVisionModelsIsNil() throws {
        let json = #"{"version":"x","chat":true,"models":["m"],"streaming":"sse"}"#
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertNil(caps.visionModels)
    }

    func testPlainChatModeHasNoToolsButCarriesModels() {
        let mode = BackendMode.plainChatOnly(models: ["qwen2.5:7b", "bwen:8b"])
        XCTAssertFalse(mode.showsTools)
        XCTAssertEqual(mode.models, ["qwen2.5:7b", "bwen:8b"])
        XCTAssertNil(mode.capabilities)
        XCTAssertFalse(mode.usesOllamaNativeChat)
    }

    func testOllamaNativeModeHasNoToolsButUsesNativeChat() {
        let mode = BackendMode.ollamaNative(models: ["native-model"])
        XCTAssertFalse(mode.showsTools)
        XCTAssertEqual(mode.models, ["native-model"])
        XCTAssertNil(mode.capabilities)
        XCTAssertTrue(mode.usesOllamaNativeChat)
    }

    func testOllamaNativeResolverKeepsValidConversationModel() {
        let mode = BackendMode.ollamaNative(models: ["first-model", "selected-model"])

        XCTAssertEqual(
            mode.resolvedChatModel(
                conversationModel: "selected-model",
                defaultModel: "first-model"
            ),
            "selected-model"
        )
    }

    func testOllamaNativeResolverUsesValidDefaultWhenConversationModelIsStale() {
        let mode = BackendMode.ollamaNative(models: ["first-model", "default-model"])

        XCTAssertEqual(
            mode.resolvedChatModel(
                conversationModel: "missing-model",
                defaultModel: "default-model"
            ),
            "default-model"
        )
    }

    func testOllamaNativeResolverFallsBackToFirstDiscoveredModel() {
        let mode = BackendMode.ollamaNative(models: ["first-model", "second-model"])

        XCTAssertEqual(
            mode.resolvedChatModel(
                conversationModel: "missing-model",
                defaultModel: "also-missing"
            ),
            "first-model"
        )
    }

    func testPlainResolverKeepsSavedConversationModel() {
        let mode = BackendMode.plainChatOnly(models: ["advertised-model"])

        XCTAssertEqual(
            mode.resolvedChatModel(
                conversationModel: "custom-model",
                defaultModel: "advertised-model"
            ),
            "custom-model"
        )
    }

    func testManifestWithoutToolsBlock() throws {
        let json = #"{"version":"x","chat":true,"models":[],"streaming":"sse"}"#
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertFalse(BackendMode.full(caps).showsTools)
    }
}

final class ChatRequestEncodingTests: XCTestCase {
    func testReasoningEffortDefaultsToNone() throws {
        let req = ChatRequest(
            model: "chat-model",
            messages: [WireMessage(role: "user", content: "hi")]
        )
        let data = try Wire.encoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["reasoning_effort"] as? String, "none")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }
}

final class CapabilityProbeTests: XCTestCase {
    final class RoutingProtocol: URLProtocol {
        nonisolated(unsafe) static var responses: [String: (status: Int, body: String)] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let response = Self.responses[path] ?? (404, "not found")
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutingProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        RoutingProtocol.responses = [:]
    }

    func testProbeDetectsNativeOllamaAfterMissingCapabilities() async {
        RoutingProtocol.responses = [
            "/v1/capabilities": (404, "not found"),
            "/api/tags": (200, #"{"models":[{"name":"native-model"}]}"#),
        ]

        let mode = await CapabilitiesClient(session: session())
            .probe(base: URL(string: "https://backend.example")!, token: "")

        XCTAssertEqual(mode, .ollamaNative(models: ["native-model"]))
    }

    func testProbeFallsBackToOpenAIModelsWhenNotOllama() async {
        RoutingProtocol.responses = [
            "/v1/capabilities": (404, "not found"),
            "/api/tags": (404, "not found"),
            "/v1/models": (200, #"{"data":[{"id":"generic-model"}]}"#),
        ]

        let mode = await CapabilitiesClient(session: session())
            .probe(base: URL(string: "https://backend.example")!, token: "")

        XCTAssertEqual(mode, .plainChatOnly(models: ["generic-model"]))
    }
}

final class ErrorMappingTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertNil(AppError.fromStatus(200))
        XCTAssertEqual(AppError.fromStatus(401), .authFailed)
        XCTAssertEqual(AppError.fromStatus(403), .authFailed)
        XCTAssertEqual(AppError.fromStatus(404), .notFound)
        XCTAssertEqual(AppError.fromStatus(500), .modelError("HTTP 500"))
    }

    func testURLErrorMapping() {
        XCTAssertEqual(AppError.from(URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(AppError.from(URLError(.timedOut)), .unreachable)
        XCTAssertEqual(AppError.from(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(AppError.from(CancellationError()), .cancelled)
    }
}

final class Base64ImageExtractorTests: XCTestCase {
    func testExtractsAndReplacesDataURI() {
        let payload = Data("hello".utf8).base64EncodedString()
        let md = "Here: ![generated](data:image/png;base64,\(payload)) done"
        let result = Base64ImageExtractor().extract(md)
        XCTAssertTrue(result.markdown.contains("phantasm-img://0"))
        XCTAssertFalse(result.markdown.contains("base64"))
        XCTAssertEqual(result.images[0], Data("hello".utf8))
    }

    func testLeavesHttpImagesUntouched() {
        let md = "![x](https://example.com/a.png)"
        let result = Base64ImageExtractor().extract(md)
        XCTAssertEqual(result.markdown, md)
        XCTAssertTrue(result.images.isEmpty)
    }

    func testNoImagesIsNoOp() {
        let md = "just **text** and `code`"
        let result = Base64ImageExtractor().extract(md)
        XCTAssertEqual(result.markdown, md)
        XCTAssertTrue(result.images.isEmpty)
    }
}

@MainActor
final class PersistenceTests: XCTestCase {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Conversation.self, Message.self, Attachment.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testCascadeDeleteAndWireHistory() throws {
        let ctx = try inMemoryContext()
        let convo = Conversation(title: "T")
        ctx.insert(convo)
        let user = Message(role: "user", content: "hi")
        let assistant = Message(role: "assistant", content: "hello", isComplete: true)
        let streaming = Message(role: "assistant", content: "", isComplete: false)
        user.conversation = convo
        assistant.conversation = convo
        streaming.conversation = convo
        ctx.insert(user)
        ctx.insert(assistant)
        ctx.insert(streaming)
        try ctx.save()

        // wireHistory only includes complete, non-empty messages (XR-2).
        let history = convo.wireHistory()
        XCTAssertEqual(history, [
            WireMessage(role: "user", content: "hi"),
            WireMessage(role: "assistant", content: "hello"),
        ])

        // Deleting the conversation cascades to its messages.
        ctx.delete(convo)
        try ctx.save()
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        XCTAssertTrue(remaining.isEmpty)
    }

    func testImageAttachmentBecomesContentParts() throws {
        let ctx = try inMemoryContext()
        let convo = Conversation(title: "T")
        ctx.insert(convo)
        let user = Message(role: "user", content: "what is this?")
        user.conversation = convo
        ctx.insert(user)
        let image = Attachment(
            kind: .image, name: "photo.jpg",
            data: Data("png-bytes".utf8), mimeType: "image/jpeg"
        )
        image.message = user
        ctx.insert(image)
        try ctx.save()

        guard case .parts(let parts) = user.wireContent() else {
            return XCTFail("expected content parts")
        }
        XCTAssertEqual(parts.first, .text("what is this?"))
        let b64 = Data("png-bytes".utf8).base64EncodedString()
        XCTAssertEqual(parts.last, .imageURL("data:image/jpeg;base64,\(b64)"))
    }

    func testTextFileAttachmentIsInlinedAsPlainText() throws {
        let ctx = try inMemoryContext()
        let convo = Conversation(title: "T")
        ctx.insert(convo)
        let user = Message(role: "user", content: "summarize")
        user.conversation = convo
        ctx.insert(user)
        let file = Attachment(kind: .text, name: "notes.txt", text: "line one")
        file.message = user
        ctx.insert(file)
        try ctx.save()

        // Text files stay a plain string so non-vision models still get them.
        XCTAssertEqual(
            user.wireContent(),
            .text("summarize\n\nAttached file \"notes.txt\":\nline one")
        )
    }

    func testContentPartsRoundTripThroughWireEncoding() throws {
        let original = WireMessage(role: "user", content: .parts([
            .text("hello"),
            .imageURL("data:image/png;base64,QUJD"),
        ]))
        let data = try Wire.encoder().encode(original)
        // image_url part nests the URL under an object, OpenAI-style.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parts = try XCTUnwrap(json["content"] as? [[String: Any]])
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String,
                       "data:image/png;base64,QUJD")

        let decoded = try Wire.decoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testBufferThenCommitProducesOneCompleteMessage() throws {
        let ctx = try inMemoryContext()
        let convo = Conversation(title: "T")
        ctx.insert(convo)
        // Simulate streaming: insert empty incomplete, then commit once.
        let msg = Message(role: "assistant", content: "", isComplete: false)
        msg.conversation = convo
        ctx.insert(msg)
        try ctx.save()
        msg.content = "final answer"
        msg.isComplete = true
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.content, "final answer")
        XCTAssertEqual(all.first?.isComplete, true)
    }
}
