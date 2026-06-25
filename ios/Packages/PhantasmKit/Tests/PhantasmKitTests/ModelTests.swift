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

    // MARK: - Per-chat tool selection (x_tools)

    private func encodedKeys(_ request: ChatRequest) throws -> [String: Any] {
        let data = try Wire.encoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testChatRequestOmitsXToolsWhenNil() throws {
        let request = ChatRequest(model: "m", messages: [WireMessage(role: "user", content: "hi")])
        let json = try encodedKeys(request)
        XCTAssertNil(json["x_tools"], "nil selection must keep the request standard")
    }

    func testChatRequestEncodesXToolsAsSnakeCaseArray() throws {
        let request = ChatRequest(
            model: "m",
            messages: [WireMessage(role: "user", content: "hi")],
            xTools: [ToolName.webSearch]
        )
        let json = try encodedKeys(request)
        XCTAssertEqual(json["x_tools"] as? [String], ["web_search"])
    }

    func testChatRequestOmitsXResearchWhenNil() throws {
        let request = ChatRequest(model: "m", messages: [WireMessage(role: "user", content: "hi")])
        let json = try encodedKeys(request)
        XCTAssertNil(json["x_research"], "research off must keep the request standard")
    }

    func testChatRequestEncodesXResearchWhenOn() throws {
        let request = ChatRequest(
            model: "m",
            messages: [WireMessage(role: "user", content: "hi")],
            xResearch: true
        )
        let json = try encodedKeys(request)
        XCTAssertEqual(json["x_research"] as? Bool, true)
    }

    func testRequestedToolNamesNilWithoutManifest() {
        let convo = Conversation()
        XCTAssertNil(convo.requestedToolNames(supporting: nil))
    }

    func testRequestedToolNamesIntersectsBackendAndChatToggles() {
        // Backend offers both; chat disabled image gen -> only web search requested.
        let tools = Capabilities.Tools(webSearch: true, imageGeneration: true)
        let convo = Conversation(webSearchEnabled: true, imageGenerationEnabled: false)
        XCTAssertEqual(convo.requestedToolNames(supporting: tools), ["web_search"])
    }

    func testRequestedToolNamesDropsUnsupportedTool() {
        // Chat wants image gen but backend doesn't offer it -> excluded.
        let tools = Capabilities.Tools(webSearch: true, imageGeneration: false)
        let convo = Conversation(webSearchEnabled: true, imageGenerationEnabled: true)
        XCTAssertEqual(convo.requestedToolNames(supporting: tools), ["web_search"])
    }

    func testRequestedToolNamesEmptyWhenAllDisabled() {
        let tools = Capabilities.Tools(webSearch: true, imageGeneration: true)
        let convo = Conversation(webSearchEnabled: false, imageGenerationEnabled: false)
        XCTAssertEqual(convo.requestedToolNames(supporting: tools), [])
    }

    func testReasoningEffortUsesSavedThinkingPreference() {
        let convo = Conversation(deepResearchEnabled: false)

        XCTAssertEqual(
            convo.reasoningEffort(thinkingEnabled: true),
            ReasoningEffort.enabledDefault
        )
        XCTAssertEqual(
            convo.reasoningEffort(thinkingEnabled: false),
            ReasoningEffort.disabled
        )
    }

    func testDeepResearchForcesReasoningForThatTurn() {
        let convo = Conversation(deepResearchEnabled: true)

        XCTAssertEqual(
            convo.reasoningEffort(thinkingEnabled: false),
            ReasoningEffort.enabledDefault
        )
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

        XCTAssertEqual(json["reasoning_effort"] as? String, ReasoningEffort.disabled)
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testReasoningEffortCanEnableThinking() throws {
        let req = ChatRequest(
            model: "chat-model",
            messages: [WireMessage(role: "user", content: "hi")],
            reasoningEffort: ReasoningEffort.enabledDefault
        )
        let data = try Wire.encoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["reasoning_effort"] as? String, ReasoningEffort.enabledDefault)
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

    func testCachedMatchesUncachedAndRepeats() {
        let payload = Data("hello".utf8).base64EncodedString()
        let md = "Here: ![generated](data:image/png;base64,\(payload)) done"
        let direct = Base64ImageExtractor().extract(md)
        // First call populates the cache; second call hits it. Both must agree
        // with the uncached extraction.
        for _ in 0..<2 {
            let cached = Base64ImageExtractor().extractCached(md)
            XCTAssertEqual(cached.markdown, direct.markdown)
            XCTAssertEqual(cached.images, direct.images)
        }
    }
}

/// Persistence + full-text search over the GRDB-backed `ChatStore`. Each test
/// runs against a fresh in-memory database (`AppDatabase.empty()`).
final class PersistenceTests: XCTestCase {
    /// Distinct, increasing timestamps so message ordering is deterministic.
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testWireHistoryFiltersIncompleteAndEmpty() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "user", content: "hi", createdAt: t0),
            attachments: []
        )
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "hello",
                    createdAt: t0.addingTimeInterval(1), isComplete: true),
            attachments: []
        )
        // An empty, still-streaming message is excluded from wire history (XR-2).
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "",
                    createdAt: t0.addingTimeInterval(2), isComplete: false),
            attachments: []
        )

        let detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.wireHistory(), [
            WireMessage(role: "user", content: "hi"),
            WireMessage(role: "assistant", content: "hello"),
        ])
    }

    func testReasoningIsPersistedButExcludedFromWireHistory() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        try await store.insertMessage(
            Message(
                conversationId: convo.id,
                role: "assistant",
                content: "answer",
                reasoning: "hidden plan"
            ),
            attachments: []
        )

        let detail = try await store.conversationDetail(id: convo.id)

        XCTAssertEqual(detail?.messages.first?.message.reasoning, "hidden plan")
        XCTAssertEqual(detail?.wireHistory(), [WireMessage(role: "assistant", content: "answer")])
    }

    func testDeleteTombstonesConversationAndHardDeletesChildren() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let user = Message(conversationId: convo.id, role: "user", content: "hi")
        let image = Attachment(messageId: user.id, kind: .image, name: "p.jpg",
                               data: Data("bytes".utf8))
        try await store.insertMessage(user, attachments: [image])

        let before = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(before?.messages.count, 1)
        XCTAssertEqual(before?.messages.first?.attachments.count, 1)

        try await store.deleteConversation(id: convo.id)

        // Tombstoned: detail no longer returns the conversation.
        let after = try await store.conversationDetail(id: convo.id)
        XCTAssertNil(after)

        // Heavy data is physically gone; the conversation row remains as a tombstone.
        try await store.reader.read { db in
            XCTAssertEqual(try Message.fetchCount(db), 0)
            XCTAssertEqual(try Attachment.fetchCount(db), 0)
            let row = try Conversation.fetchOne(db, key: convo.id)
            XCTAssertNotNil(row)
            XCTAssertNotNil(row?.deletedAt)
        }
    }

    func testImageAttachmentBecomesContentParts() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation()
        try await store.insertConversation(convo)
        let user = Message(conversationId: convo.id, role: "user", content: "what is this?")
        let image = Attachment(messageId: user.id, kind: .image, name: "photo.jpg",
                               data: Data("png-bytes".utf8), mimeType: "image/jpeg")
        try await store.insertMessage(user, attachments: [image])

        let detail = try await store.conversationDetail(id: convo.id)
        guard case .parts(let parts) = detail?.messages.first?.wireContent() else {
            return XCTFail("expected content parts")
        }
        XCTAssertEqual(parts.first, .text("what is this?"))
        let b64 = Data("png-bytes".utf8).base64EncodedString()
        XCTAssertEqual(parts.last, .imageURL("data:image/jpeg;base64,\(b64)"))
    }

    func testTextFileAttachmentIsInlinedAsPlainText() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation()
        try await store.insertConversation(convo)
        let user = Message(conversationId: convo.id, role: "user", content: "summarize")
        let file = Attachment(messageId: user.id, kind: .text, name: "notes.txt", text: "line one")
        try await store.insertMessage(user, attachments: [file])

        // Text files stay a plain string so non-vision models still get them.
        let detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(
            detail?.messages.first?.wireContent(),
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

    func testBufferThenCommitInsertsSingleCompleteMessage() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation()
        try await store.insertConversation(convo)
        // The view model buffers streamed tokens in memory and commits exactly
        // one complete assistant message (NFR-A4).
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "final answer",
                    isComplete: true),
            attachments: []
        )
        let detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.count, 1)
        XCTAssertEqual(detail?.messages.first?.message.content, "final answer")
        XCTAssertEqual(detail?.messages.first?.message.isComplete, true)
    }

    func testEditUserMessageTruncatesAfterItAndKeepsAttachments() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let user = Message(conversationId: convo.id, role: "user", content: "old",
                           createdAt: t0)
        let image = Attachment(messageId: user.id, kind: .image, name: "p.jpg",
                               data: Data("bytes".utf8))
        try await store.insertMessage(user, attachments: [image])
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "reply",
                    createdAt: t0.addingTimeInterval(1)),
            attachments: []
        )

        try await store.editUserMessage(id: user.id, newContent: "new")

        let detail = try await store.conversationDetail(id: convo.id)
        // Only the edited message remains; the later assistant reply is gone.
        XCTAssertEqual(detail?.messages.count, 1)
        XCTAssertEqual(detail?.messages.first?.message.content, "new")
        // Its attachments ride along unchanged.
        XCTAssertEqual(detail?.messages.first?.attachments.count, 1)
        try await store.reader.read { db in
            XCTAssertEqual(try Attachment.fetchCount(db), 1)
        }
    }

    func testEditUserMessageKeepsFullTextSearchInSync() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let user = Message(conversationId: convo.id, role: "user", content: "kangaroo")
        try await store.insertMessage(user, attachments: [])

        try await store.editUserMessage(id: user.id, newContent: "platypus")

        // The old term no longer matches; the new one does (FTS triggers fired).
        let stale = try await store.searchConversations(matching: "kangaroo")
        XCTAssertTrue(stale.isEmpty)
        let fresh = try await store.searchConversations(matching: "platypus")
        XCTAssertEqual(fresh.map(\.conversation.id), [convo.id])
    }

    func testDeleteMessagesFromDropsItAndLaterMessages() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let user = Message(conversationId: convo.id, role: "user", content: "ask",
                           createdAt: t0)
        try await store.insertMessage(user, attachments: [])
        let reply = Message(conversationId: convo.id, role: "assistant", content: "answer",
                            createdAt: t0.addingTimeInterval(1))
        try await store.insertMessage(reply, attachments: [])

        // Regenerate: drop the assistant reply and re-stream from the user prompt.
        try await store.deleteMessagesFrom(id: reply.id)

        let detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.map(\.message.role), ["user"])
        XCTAssertEqual(detail?.messages.first?.message.content, "ask")
    }

    // MARK: Full-text search

    func testSearchMatchesMessageContent() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "Untitled")
        try await store.insertConversation(convo)
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "user", content: "the quick brown fox jumps"),
            attachments: []
        )
        let results = try await store.searchConversations(matching: "brown")
        XCTAssertEqual(results.map(\.conversation.id), [convo.id])
        XCTAssertNotNil(results.first?.snippet)
    }

    func testSearchMatchesTitle() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "Dinner recipes")
        try await store.insertConversation(convo)
        // A non-matching message ensures the hit comes from the title alone.
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "user", content: "unrelated"),
            attachments: []
        )
        let results = try await store.searchConversations(matching: "recipes")
        XCTAssertEqual(results.map(\.conversation.id), [convo.id])
    }

    func testSearchPrefixMatch() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "About Phantasm")
        try await store.insertConversation(convo)
        // Search-as-you-type: a token prefix matches the full term.
        let results = try await store.searchConversations(matching: "phan")
        XCTAssertEqual(results.first?.conversation.id, convo.id)
    }

    func testSearchRanksMessageMatchesAndExcludesNonMatches() async throws {
        let store = try AppDatabase.empty()
        let match = Conversation(title: "Match", createdAt: t0)
        let other = Conversation(title: "Other", createdAt: t0.addingTimeInterval(1))
        try await store.insertConversation(match)
        try await store.insertConversation(other)
        try await store.insertMessage(
            Message(conversationId: match.id, role: "user", content: "elephants are large"),
            attachments: []
        )
        try await store.insertMessage(
            Message(conversationId: other.id, role: "user", content: "nothing relevant here"),
            attachments: []
        )
        let results = try await store.searchConversations(matching: "elephants")
        XCTAssertEqual(results.map(\.conversation.id), [match.id])
    }

    func testDeletedConversationDropsFromSearch() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "Secret plans")
        try await store.insertConversation(convo)
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "user", content: "topsecret content"),
            attachments: []
        )
        let beforeDelete = try await store.searchConversations(matching: "topsecret")
        XCTAssertFalse(beforeDelete.isEmpty)

        try await store.deleteConversation(id: convo.id)
        // Both the message hit and the title hit must disappear.
        let byContent = try await store.searchConversations(matching: "topsecret")
        let byTitle = try await store.searchConversations(matching: "Secret")
        XCTAssertTrue(byContent.isEmpty)
        XCTAssertTrue(byTitle.isEmpty)
    }

    func testEmptyQueryReturnsNoResults() async throws {
        let store = try AppDatabase.empty()
        try await store.insertConversation(Conversation(title: "anything"))
        let results = try await store.searchConversations(matching: "   ")
        XCTAssertTrue(results.isEmpty)
    }
}
