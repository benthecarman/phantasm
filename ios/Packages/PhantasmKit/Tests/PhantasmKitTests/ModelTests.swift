import XCTest
@testable import PhantasmKit

final class CapabilityDecodeTests: XCTestCase {
    func testFullManifestDecodes() throws {
        let json = """
        {"version":"0.3.0",
         "models":[
           {"id":"llama3.1","context_length":8192,
            "capabilities":{"completion":true,"vision":false,"audio":false,"tools":false,"insert":false,"embedding":false}},
           {"id":"qwen2.5:14b","context_length":32768,
            "reasoning_efforts":["none","low","medium","high"],
            "capabilities":{"completion":true,"vision":false,"audio":false,"tools":true,"insert":false,"embedding":false}},
           {"id":"nomic-embed-text:latest",
            "capabilities":{"completion":false,"vision":false,"audio":false,"tools":false,"insert":false,"embedding":true}}
         ],
         "tool_selectors":[
           {"id":"web_search","label":"Web search","tools":["web_search","weather"]},
           {"id":"utilities","label":"Utilities","tools":["calculator"]}
         ]}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.models, ["llama3.1", "qwen2.5:14b"])
        XCTAssertEqual(caps.modelEntries.first?.contextLength, 8192)
        XCTAssertEqual(caps.modelEntries[0].reasoningEffortAvailability, .unknown)
        XCTAssertEqual(
            caps.modelEntries[1].reasoningEffortAvailability,
            .known(["none", "low", "medium", "high"])
        )
        XCTAssertEqual(caps.reasoningEffortsByID["llama3.1"], .unknown)
        XCTAssertEqual(
            caps.reasoningEffortsByID["qwen2.5:14b"],
            .known(["none", "low", "medium", "high"])
        )
        XCTAssertTrue(caps.hasToolSelector(ToolSelectorName.webSearch))
        XCTAssertTrue(caps.hasToolSelector(ToolSelectorName.utilities))
        XCTAssertFalse(caps.hasToolSelector(ToolSelectorName.imageGeneration))
        XCTAssertEqual(caps.toolModelIDs, ["qwen2.5:14b"])

        let mode = BackendMode.full(caps)
        XCTAssertTrue(mode.showsTools)
        XCTAssertEqual(mode.models.count, 2)
    }

    func testManifestDecodesModelCapabilities() throws {
        let json = """
        {"version":"0.3.0",
         "models":[
           {"id":"llava","capabilities":{"completion":true,"vision":true,"audio":true,"tools":false,"insert":false,"embedding":false}},
           {"id":"qwen","capabilities":{"completion":true,"vision":false,"audio":false,"tools":true,"insert":true,"embedding":false}}
         ],
         "tool_selectors":[]}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.visionModelIDs, ["llava"])
        XCTAssertEqual(caps.toolModelIDs, ["qwen"])
        XCTAssertEqual(caps.modelEntries.first?.capabilities?.audio, true)
        XCTAssertEqual(caps.modelEntries.last?.capabilities?.insert, true)
    }

    func testReasoningEffortsDistinguishUnknownFromKnownEmpty() throws {
        let json = """
        {"version":"0.3.0",
         "models":[
           {"id":"unknown"},
           {"id":"known-empty","reasoning_efforts":[]},
           {"id":"known-levels","reasoning_efforts":["low","medium"]}
         ],
         "tool_selectors":[]}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.reasoningEffortsByID["unknown"], .unknown)
        XCTAssertEqual(caps.reasoningEffortsByID["known-empty"], .known([]))
        XCTAssertEqual(caps.reasoningEffortsByID["known-levels"], .known(["low", "medium"]))
    }

    func testConnectionTestMessageCoversBackendModes() throws {
        let json = """
        {"version":"0.3.0",
         "models":[{"id":"qwen","capabilities":{"completion":true,"vision":false,"audio":false,"tools":true,"insert":false,"embedding":false}}],
         "tool_selectors":[{"id":"web_search","label":"Web search","tools":["web_search"]}]}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))

        XCTAssertEqual(
            BackendMode.full(caps).connectionTestMessage,
            "Connected. 1 model. Web access / image tools available."
        )
        XCTAssertEqual(
            BackendMode.ollamaNative(models: ["llama"]).connectionTestMessage,
            "Connected - native Ollama chat. 1 model."
        )
        XCTAssertEqual(
            BackendMode.mapleEncrypted(models: ["private-model"]).connectionTestMessage,
            "Connected - Maple encrypted chat. 1 model."
        )
        XCTAssertEqual(
            BackendMode.plainChatOnly(models: ["gpt-oss", "local"]).connectionTestMessage,
            "Connected - chat only (no web search or image tools). 2 models."
        )
    }

    func testManifestWithPartialModelCapabilitiesStaysOptimistic() throws {
        // An orchestrator that omits individual capability fields (older build,
        // future rename) must not fail the manifest decode — that used to
        // silently degrade the whole backend to plain chat. Missing capability
        // fields stay optimistic (spec §2.1).
        let json = """
        {"version":"0.3.0",
         "models":[{"id":"m","capabilities":{"completion":true,"vision":false,"tools":true}}],
         "tool_selectors":[]}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.models, ["m"])
        XCTAssertEqual(caps.visionModelIDs, [])
        XCTAssertEqual(caps.toolModelIDs, ["m"])
        XCTAssertNil(caps.reasoningEffortModelIDs)
    }

    func testManifestWithoutModelCapabilitiesIsUnknown() throws {
        let json = #"{"version":"x","models":[{"id":"m"}],"tool_selectors":[]}"#
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertNil(caps.visionModelIDs)
        XCTAssertNil(caps.toolModelIDs)
        XCTAssertNil(caps.reasoningEffortModelIDs)
    }

    func testBackendModePreservesBackendModelOrder() throws {
        let json = """
        {"version":"x",
         "models":[
           {"id":"zeta","capabilities":{"completion":true}},
           {"id":"alpha","capabilities":{"completion":true}},
           {"id":"embed","capabilities":{"completion":false}}
         ],
         "tool_selectors":[]}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))

        XCTAssertEqual(caps.models, ["zeta", "alpha"])
        XCTAssertEqual(BackendMode.full(caps).models, ["zeta", "alpha"])
        XCTAssertEqual(BackendMode.ollamaNative(models: ["zeta", "alpha"]).models, ["zeta", "alpha"])
        XCTAssertEqual(BackendMode.mapleEncrypted(models: ["zeta", "alpha"]).models, ["zeta", "alpha"])
        XCTAssertEqual(BackendMode.plainChatOnly(models: ["zeta", "alpha"]).models, ["zeta", "alpha"])
    }

    // MARK: - Per-chat tool selection (standard OpenAI tools/tool_choice)

    private func encodedKeys(_ request: ChatRequest) throws -> [String: Any] {
        let data = try Wire.encoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func toolSelectors(_ ids: String...) -> [Capabilities.ToolSelector] {
        ids.map { Capabilities.ToolSelector(id: $0, label: $0, tools: [$0]) }
    }

    func testChatRequestOmitsToolFieldsWhenNil() throws {
        let request = ChatRequest(model: "m", messages: [WireMessage(role: "user", content: "hi")])
        let json = try encodedKeys(request)
        XCTAssertNil(json["tools"], "nil selection must keep the request standard")
        XCTAssertNil(json["tool_choice"], "nil selection must keep the request standard")
    }

    func testChatRequestEncodesSelectedToolsAsStandardArray() throws {
        let request = ChatRequest(
            model: "m",
            messages: [WireMessage(role: "user", content: "hi")],
            enabledTools: [ToolName.webSearch]
        )
        let json = try encodedKeys(request)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "web_search")
        XCTAssertNil(json["tool_choice"], "naming tools must not force tool_choice")
    }

    func testChatRequestEncodesEmptySelectionAsToolChoiceNone() throws {
        let request = ChatRequest(
            model: "m",
            messages: [WireMessage(role: "user", content: "hi")],
            enabledTools: []
        )
        let json = try encodedKeys(request)
        XCTAssertEqual(json["tool_choice"] as? String, "none")
        XCTAssertNil(json["tools"], "plain-chat selection sends only tool_choice:none")
    }

    func testChatRequestStaysStandardWithNoCustomFields() throws {
        // Image URL delivery is a server-side choice — the request carries no
        // bespoke field for it, staying byte-for-byte standard.
        let request = ChatRequest(model: "m", messages: [WireMessage(role: "user", content: "hi")])
        let json = try encodedKeys(request)
        XCTAssertNil(json["x_image_urls"])
        XCTAssertEqual(Set(json.keys), ["model", "messages", "stream"])
    }

    func testChatRequestNeverEmitsResearchFlag() throws {
        // Research is now selected by the model id, never a request field.
        let request = ChatRequest(
            model: "qwen2.5:14b:deep-research",
            messages: [WireMessage(role: "user", content: "hi")]
        )
        let json = try encodedKeys(request)
        XCTAssertNil(json["x_research"], "the research flag is deleted from the wire")
        XCTAssertNil(json["research"], "the research flag is deleted from the wire")
        XCTAssertEqual(json["model"] as? String, "qwen2.5:14b:deep-research")
    }

    // MARK: - Modes (capabilities + wire model id)

    func testManifestDecodesModes() throws {
        let json = """
        {"version":"0.3.0",
         "models":[{"id":"qwen2.5:14b","capabilities":{"completion":true,"vision":false,"audio":false,"tools":true,"insert":false,"embedding":false}}],
         "tool_selectors":[
           {"id":"web_search","label":"Web search","tools":["web_search"]},
           {"id":"image_generation","label":"Images","tools":["image_generation"]}
         ],
         "modes":[
           {"id":"deep-research","label":"Deep Research","required_tools":["web_search"]},
           {"id":"quick-research","label":"Quick Research","required_tools":["web_search"]}
         ]}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.modes.count, 2)
        XCTAssertEqual(caps.modes.first?.id, "deep-research")
        XCTAssertEqual(caps.modes.first?.label, "Deep Research")
        XCTAssertEqual(caps.modes.first?.requiredTools, ["web_search"])
    }

    func testManifestWithoutModesIsEmpty() throws {
        let json = #"{"version":"x","models":[{"id":"m"}],"tool_selectors":[]}"#
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertTrue(caps.modes.isEmpty)
    }

    func testAvailableModesGateOnNeededTools() throws {
        // web_search available, image_generation not.
        let json = """
        {"version":"0.3.0",
         "models":[{"id":"m","capabilities":{"completion":true,"vision":false,"audio":false,"tools":true,"insert":false,"embedding":false}}],
         "tool_selectors":[{"id":"web_search","label":"Web search","tools":["web_search"]}],
         "modes":[
           {"id":"deep-research","label":"Deep Research","required_tools":["web_search"]},
           {"id":"image-mode","label":"Image","required_tools":["image_generation"]}
         ]}
        """
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        let modes = BackendMode.full(caps).availableModes
        XCTAssertEqual(modes.map(\.id), ["deep-research"])
    }

    func testAvailableModesEmptyForNonOrchestrator() {
        XCTAssertTrue(BackendMode.plainChatOnly(models: ["m"]).availableModes.isEmpty)
        XCTAssertTrue(BackendMode.ollamaNative(models: ["m"]).availableModes.isEmpty)
    }

    func testWireModelAppendsModeSuffixWhenAdvertisedAndToolCapable() {
        let convo = Conversation(turnModeID: "deep-research")
        let modes = [
            Capabilities.Mode(
                id: "deep-research",
                label: "Deep Research",
                requiredTools: ["web_search"]
            )
        ]
        XCTAssertEqual(
            convo.wireModel(base: "qwen2.5:14b", availableModes: modes, baseModelIsToolCapable: true),
            "qwen2.5:14b:deep-research"
        )
    }

    func testWireModelStaysBareWhenModeUnselected() {
        let convo = Conversation(turnModeID: nil)
        let modes = [
            Capabilities.Mode(
                id: "deep-research",
                label: "Deep Research",
                requiredTools: ["web_search"]
            )
        ]
        XCTAssertEqual(
            convo.wireModel(base: "qwen2.5:14b", availableModes: modes, baseModelIsToolCapable: true),
            "qwen2.5:14b"
        )
    }

    func testWireModelStaysBareWhenBackendDoesNotAdvertiseMode() {
        let convo = Conversation(turnModeID: "deep-research")
        XCTAssertEqual(
            convo.wireModel(base: "qwen2.5:14b", availableModes: [], baseModelIsToolCapable: true),
            "qwen2.5:14b"
        )
    }

    func testWireModelStaysBareWhenBaseModelNotToolCapable() {
        let convo = Conversation(turnModeID: "deep-research")
        let modes = [
            Capabilities.Mode(
                id: "deep-research",
                label: "Deep Research",
                requiredTools: ["web_search"]
            )
        ]
        XCTAssertEqual(
            convo.wireModel(base: "qwen2.5:14b", availableModes: modes, baseModelIsToolCapable: false),
            "qwen2.5:14b"
        )
    }

    func testRequestedToolNamesNilWithoutManifest() {
        let convo = Conversation()
        XCTAssertNil(convo.requestedToolNames(supporting: nil))
    }

    private func standardSelectors() -> [Capabilities.ToolSelector] {
        [
            Capabilities.ToolSelector(
                id: ToolSelectorName.webSearch,
                label: "Web search",
                tools: [ToolName.webSearch, "weather"]
            ),
            Capabilities.ToolSelector(
                id: ToolSelectorName.utilities,
                label: "Utilities",
                tools: ["calculator", "unit_convert", "ocr"]
            ),
            Capabilities.ToolSelector(
                id: ToolSelectorName.imageGeneration,
                label: "Images",
                tools: [ToolName.imageGeneration, "image_edit"]
            ),
        ]
    }

    func testRequestedToolNamesIntersectsBackendAndChatToggles() {
        // Web access on, image gen off -> network tools + always-on utilities, no images.
        let convo = Conversation(toolSettings: ToolSettings(webSearch: true, imageGeneration: false))
        XCTAssertEqual(
            convo.requestedToolNames(supporting: standardSelectors()),
            ["calculator", "unit_convert", "ocr", ToolName.webSearch, "weather"]
        )
    }

    func testRequestedToolNamesKeepsUtilitiesWhenWebAccessDisabled() {
        // The bug fix: disabling web access must NOT disable the offline tools.
        let convo = Conversation(toolSettings: ToolSettings(webSearch: false, imageGeneration: false))
        XCTAssertEqual(
            convo.requestedToolNames(supporting: standardSelectors()),
            ["calculator", "unit_convert", "ocr"]
        )
    }

    func testRequestedToolNamesDropsUnsupportedTool() {
        // Chat wants image gen but backend offers only web search -> images excluded.
        let tools = [
            Capabilities.ToolSelector(
                id: ToolSelectorName.webSearch,
                label: "Web search",
                tools: [ToolName.webSearch]
            )
        ]
        let convo = Conversation(toolSettings: ToolSettings(webSearch: true, imageGeneration: true))
        XCTAssertEqual(convo.requestedToolNames(supporting: tools), [ToolName.webSearch])
    }

    func testRequestedToolNamesEmptyWhenNoUtilitiesAndTogglesOff() {
        // No offline bucket advertised; both toggles off -> nothing requested.
        let tools = toolSelectors(ToolSelectorName.webSearch, ToolSelectorName.imageGeneration)
        let convo = Conversation(toolSettings: ToolSettings(webSearch: false, imageGeneration: false))
        XCTAssertEqual(convo.requestedToolNames(supporting: tools), [])
    }

    func testReasoningEffortUsesSavedThinkingPreference() {
        let convo = Conversation(turnModeID: nil)

        XCTAssertEqual(
            convo.reasoningEffort(thinkingEnabled: true, disabledEffort: ReasoningEffort.disabled),
            ReasoningEffort.enabledDefault
        )
        XCTAssertEqual(
            convo.reasoningEffort(thinkingEnabled: false, disabledEffort: ReasoningEffort.disabled),
            ReasoningEffort.disabled
        )
        XCTAssertNil(
            convo.reasoningEffort(thinkingEnabled: false, disabledEffort: nil)
        )
    }

    func testResearchModeDoesNotForceThinking() {
        // Thinking is independent of the research mode (redesign §7): selecting a
        // mode must not flip reasoning on.
        let convo = Conversation(turnModeID: "deep-research")

        XCTAssertNil(
            convo.reasoningEffort(thinkingEnabled: false, disabledEffort: nil)
        )
        XCTAssertEqual(
            convo.reasoningEffort(thinkingEnabled: false, disabledEffort: ReasoningEffort.disabled),
            ReasoningEffort.disabled
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

    func testMapleModeUsesEncryptedOpenAITransport() {
        let mode = BackendMode.mapleEncrypted(models: ["private-model"])
        XCTAssertFalse(mode.showsTools)
        XCTAssertEqual(mode.models, ["private-model"])
        XCTAssertNil(mode.capabilities)
        XCTAssertFalse(mode.usesOllamaNativeChat)
        XCTAssertTrue(mode.usesMapleEncryptedChat)
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
        let json = #"{"version":"x","models":[]}"#
        let caps = try Wire.decoder().decode(Capabilities.self, from: Data(json.utf8))
        XCTAssertFalse(BackendMode.full(caps).showsTools)
    }
}

final class ChatRequestEncodingTests: XCTestCase {
    func testReasoningEffortIsOmittedByDefault() throws {
        let req = ChatRequest(
            model: "chat-model",
            messages: [WireMessage(role: "user", content: "hi")]
        )
        let data = try Wire.encoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["reasoning_effort"])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testReasoningEffortCanDisableThinking() throws {
        let req = ChatRequest(
            model: "chat-model",
            messages: [WireMessage(role: "user", content: "hi")],
            reasoningEffort: ReasoningEffort.disabled
        )
        let data = try Wire.encoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["reasoning_effort"] as? String, ReasoningEffort.disabled)
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

    func testAppToolsRideInToolsArrayWithFullSchema() throws {
        // An app-hosted tool sends a full schema (parameters), which is what marks
            // it app-side to the orchestrator. Server tool selections stay name-only.
        let req = ChatRequest(
            model: "m",
            messages: [WireMessage(role: "user", content: "hi")],
            enabledTools: [ToolName.webSearch],
            appTools: AppTools.all
        )
        let data = try Wire.encoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let functions = tools.compactMap { $0["function"] as? [String: Any] }

        // The server tool selection is name-only.
        let webSearch = try XCTUnwrap(functions.first { $0["name"] as? String == ToolName.webSearch })
        XCTAssertNil(webSearch["parameters"])

        // The app tool carries a full parameters schema.
        let askUser = try XCTUnwrap(functions.first { $0["name"] as? String == ToolName.askUser })
        let params = try XCTUnwrap(askUser["parameters"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "object")
        let properties = try XCTUnwrap(params["properties"] as? [String: Any])
        // The form carries a `questions` array; each item has question + options.
        let questions = try XCTUnwrap(properties["questions"] as? [String: Any])
        XCTAssertEqual(questions["type"] as? String, "array")
        let item = try XCTUnwrap(questions["items"] as? [String: Any])
        let itemProps = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertNotNil(itemProps["question"])
        XCTAssertNotNil(itemProps["options"])
        XCTAssertNil(json["tool_choice"])
    }

    func testAppToolsOfferedEvenWhenServerToolsDisabled() throws {
        // Disabling server tools ([] => would be tool_choice:none) must NOT
        // suppress app tools when present.
        let req = ChatRequest(
            model: "m",
            messages: [WireMessage(role: "user", content: "hi")],
            enabledTools: [],
            appTools: AppTools.all
        )
        let data = try Wire.encoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["tool_choice"], "app tools present => not plain chat")
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AppTools.all.count)
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains(ToolName.askUser))
        XCTAssertTrue(names.contains(ToolName.currentTime))
    }
}

final class CapabilityResolveTests: XCTestCase {
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

    func testResolveDetectsNativeOllamaAfterMissingCapabilities() async {
        RoutingProtocol.responses = [
            "/v1/capabilities": (404, "not found"),
            "/api/tags": (200, #"{"models":[{"name":"native-model"}]}"#),
        ]

        let result = await CapabilitiesClient(session: session())
            .resolve(base: URL(string: "https://backend.example")!, token: "")

        XCTAssertEqual(try? result.get(), .ollamaNative(models: ["native-model"]))
    }

    func testResolveDetectsNativeOllamaAfterNonOrchestratorCapabilitiesResponse() async {
        RoutingProtocol.responses = [
            "/v1/capabilities": (405, "method not allowed"),
            "/api/tags": (200, #"{"models":[{"name":"native-model"}]}"#),
        ]

        let result = await CapabilitiesClient(session: session())
            .resolve(base: URL(string: "https://backend.example")!, token: "")

        XCTAssertEqual(try? result.get(), .ollamaNative(models: ["native-model"]))
    }

    func testResolveFallsBackToOpenAIModelsWhenNotOllama() async {
        RoutingProtocol.responses = [
            "/v1/capabilities": (404, "not found"),
            "/api/tags": (404, "not found"),
            "/v1/models": (200, #"{"data":[{"id":"generic-model"}]}"#),
        ]

        let result = await CapabilitiesClient(session: session())
            .resolve(base: URL(string: "https://backend.example")!, token: "")

        XCTAssertEqual(try? result.get(), .plainChatOnly(models: ["generic-model"]))
    }

    func testNativeOllamaShowDiscoversVisionToolsAndContextLength() async {
        RoutingProtocol.responses = [
            "/api/show": (
                200,
                #"{"capabilities":["completion","vision","tools"],"model_info":{"family.context_length":32768}}"#
            ),
        ]

        let capabilities = await CapabilitiesClient(session: session())
            .fetchOllamaModelCapabilities(
                base: URL(string: "https://backend.example")!,
                token: "",
                models: ["native-model"]
            )

        XCTAssertEqual(capabilities.visionModels, Set(["native-model"]))
        XCTAssertEqual(capabilities.toolModels, Optional(Set(["native-model"])))
        XCTAssertEqual(capabilities.contextLengths, ["native-model": 32_768])
    }

    func testFailedNativeOllamaShowKeepsToolSupportUnknown() async {
        RoutingProtocol.responses = ["/api/show": (500, "error")]

        let capabilities = await CapabilitiesClient(session: session())
            .fetchOllamaModelCapabilities(
                base: URL(string: "https://backend.example")!,
                token: "",
                models: ["native-model"]
            )

        XCTAssertNil(capabilities.toolModels)
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

    func testStreamingSanitizerStripsWithoutDecoding() {
        let payload = Data("hello".utf8).base64EncodedString()
        // A complete image is replaced by the placeholder.
        let complete = "Before ![generated](data:image/png;base64,\(payload)) after"
        XCTAssertEqual(
            Base64ImageExtractor.streamingSanitized(complete),
            "Before *(image)* after"
        )
        // A still-open trailing data-URI truncates from its opening "![" so
        // partial base64 never reaches the markdown parser.
        let open = "Text ![generated](data:image/png;base64,AAAA"
        XCTAssertEqual(
            Base64ImageExtractor.streamingSanitized(open),
            "Text *(image)*"
        )
        // Plain text is untouched.
        XCTAssertEqual(Base64ImageExtractor.streamingSanitized("plain"), "plain")
    }

    func testDecodesWhitespaceWrappedBase64() {
        // The regex admits whitespace in the payload (wrapped base64); the
        // decoder must tolerate it instead of degrading the image to *(image)*.
        let raw = Data("hello".utf8).base64EncodedString()
        let wrapped = raw.enumerated()
            .map { $0.offset == 4 ? "\n\($0.element)" : String($0.element) }
            .joined()
        let md = "![generated](data:image/png;base64,\(wrapped))"
        let result = Base64ImageExtractor().extract(md)
        XCTAssertEqual(result.images[0], Data("hello".utf8))
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

    func testSameTimestampMessagesKeepInsertionOrder() async throws {
        // The auto-resolved tool flow inserts sibling rows back-to-back and Date
        // storage is millisecond-precision, so createdAt ties are realistic.
        // rowid must break the tie: a tool result emitted before its tool_calls
        // row would make strict backends reject the whole conversation.
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let contents = ["one", "two", "three", "four"]
        for content in contents {
            try await store.insertMessage(
                Message(conversationId: convo.id, role: "assistant", content: content,
                        createdAt: t0, isComplete: true),
                attachments: []
            )
        }

        let detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.map(\.message.content), contents)
    }

    func testTruncationAtTimestampTieUsesInsertionOrder() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let a = Message(conversationId: convo.id, role: "assistant", content: "a",
                        createdAt: t0, isComplete: true)
        let b = Message(conversationId: convo.id, role: "tool", content: "b",
                        createdAt: t0, isComplete: true)
        let c = Message(conversationId: convo.id, role: "assistant", content: "c",
                        createdAt: t0, isComplete: true)
        for message in [a, b, c] {
            try await store.insertMessage(message, attachments: [])
        }

        // Keep `b` and its same-timestamp predecessor; drop only what followed.
        try await store.deleteMessagesAfter(id: b.id)
        var detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.map(\.message.content), ["a", "b"])

        // Delete `b` and everything after it, keeping the earlier sibling.
        try await store.deleteMessagesFrom(id: b.id)
        detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.map(\.message.content), ["a"])
    }

    func testPendingAssistantMessageCompletesInPlace() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let turnStart = Date(timeIntervalSince1970: 1_000)
        let pending = Message(
            conversationId: convo.id,
            role: "assistant",
            content: "",
            createdAt: turnStart,
            isComplete: false
        )
        try await store.insertMessage(pending, attachments: [])

        var detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.count, 1)
        XCTAssertEqual(detail?.wireHistory(), [])

        let completedAt = Date(timeIntervalSince1970: 2_000)
        try await store.updateMessage(
            id: pending.id,
            content: "final answer",
            reasoning: "hidden plan",
            isComplete: true,
            createdAt: completedAt
        )

        detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.count, 1)
        XCTAssertEqual(detail?.messages.first?.message.content, "final answer")
        XCTAssertEqual(detail?.messages.first?.message.reasoning, "hidden plan")
        XCTAssertEqual(detail?.messages.first?.message.isComplete, true)
        // The pending row is restamped to its completion time, not the turn start.
        XCTAssertEqual(detail?.messages.first?.message.createdAt, completedAt)
        XCTAssertEqual(detail?.wireHistory(), [WireMessage(role: "assistant", content: "final answer")])
    }

    /// Build a JSON-encoded `[WireToolCall]` as the stream/persistence layer does.
    private func encodedCalls(id: String, name: String, arguments: String) throws -> String {
        let calls = [WireToolCall(
            index: 0, id: id, type: "function",
            function: WireToolCall.Function(name: name, arguments: arguments)
        )]
        return try XCTUnwrap(String(data: Wire.encoder().encode(calls), encoding: .utf8))
    }

    func testWireHistoryRoundTripsToolCallAndResult() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "user", content: "help me pick",
                    createdAt: t0),
            attachments: []
        )
        let json = try encodedCalls(
            id: "call_1", name: ToolName.askUser,
            arguments: #"{"question":"Which?","options":["A","B"]}"#
        )
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "",
                    createdAt: t0.addingTimeInterval(1), isComplete: true, toolCalls: json),
            attachments: []
        )
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "tool", content: "A",
                    createdAt: t0.addingTimeInterval(2), isComplete: true,
                    toolCallId: "call_1", name: ToolName.askUser),
            attachments: []
        )

        let detail = try await store.conversationDetail(id: convo.id)
        let wire = try XCTUnwrap(detail?.wireHistory())
        XCTAssertEqual(wire.count, 3)
        XCTAssertEqual(wire[0], WireMessage(role: "user", content: "help me pick"))
        XCTAssertEqual(wire[1].role, "assistant")
        XCTAssertEqual(wire[1].toolCalls?.first?.id, "call_1")
        XCTAssertEqual(wire[1].toolCalls?.first?.function?.name, ToolName.askUser)
        XCTAssertEqual(wire[2], WireMessage(toolResult: "call_1", name: ToolName.askUser, content: "A"))
    }

    func testWireHistorySynthesizesDismissedResultForUnansweredCall() async throws {
        // An assistant tool_call with no following tool result must still be
        // followed by a (synthetic) result so the history stays OpenAI-valid.
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let json = try encodedCalls(
            id: "call_7", name: ToolName.askUser,
            arguments: #"{"question":"Which?","options":["A","B"]}"#
        )
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "",
                    createdAt: t0, isComplete: true, toolCalls: json),
            attachments: []
        )
        // The user moved on with a normal message instead of answering.
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "user", content: "never mind",
                    createdAt: t0.addingTimeInterval(1)),
            attachments: []
        )

        let detail = try await store.conversationDetail(id: convo.id)
        let wire = try XCTUnwrap(detail?.wireHistory())
        XCTAssertEqual(wire.count, 3)
        XCTAssertEqual(wire[0].role, "assistant")
        XCTAssertEqual(wire[1], WireMessage(toolResult: "call_7", name: ToolName.askUser, content: "(dismissed)"))
        XCTAssertEqual(wire[2], WireMessage(role: "user", content: "never mind"))
    }

    func testWireHistoryMixedBatchEmitsResultPerCall() async throws {
        // One assistant message calling two app tools (current_time auto-resolved +
        // ask_user interactive). The auto result is persisted; the interactive one
        // is left unanswered and the user moves on. Each call must get a result:
        // the stored time result, plus a synthesized dismissed for the prompt.
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)

        let batch = [
            WireToolCall(index: 0, id: "ct", type: "function",
                         function: .init(name: ToolName.currentTime, arguments: "{}")),
            WireToolCall(index: 1, id: "au", type: "function",
                         function: .init(name: ToolName.askUser,
                                         arguments: #"{"questions":[{"question":"Q","options":["A","B"]}]}"#)),
        ]
        let json = try XCTUnwrap(String(data: Wire.encoder().encode(batch), encoding: .utf8))
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "",
                    createdAt: t0, isComplete: true, toolCalls: json),
            attachments: []
        )
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "tool", content: "Current time: …",
                    createdAt: t0.addingTimeInterval(1), isComplete: true,
                    toolCallId: "ct", name: ToolName.currentTime),
            attachments: []
        )
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "user", content: "never mind",
                    createdAt: t0.addingTimeInterval(2)),
            attachments: []
        )

        let detail = try await store.conversationDetail(id: convo.id)
        let wire = try XCTUnwrap(detail?.wireHistory())
        XCTAssertEqual(wire.count, 4)
        XCTAssertEqual(wire[0].toolCalls?.count, 2)
        XCTAssertEqual(wire[1], WireMessage(toolResult: "ct", name: ToolName.currentTime, content: "Current time: …"))
        XCTAssertEqual(wire[2], WireMessage(toolResult: "au", name: ToolName.askUser, content: "(dismissed)"))
        XCTAssertEqual(wire[3], WireMessage(role: "user", content: "never mind"))
    }

    func testActiveToolCallBatchTracksAnsweredCalls() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let batch = [
            WireToolCall(index: 0, id: "ct", type: "function",
                         function: .init(name: ToolName.currentTime, arguments: "{}")),
            WireToolCall(index: 1, id: "au", type: "function",
                         function: .init(name: ToolName.askUser,
                                         arguments: #"{"questions":[{"question":"Q","options":["A","B"]}]}"#)),
        ]
        let json = try XCTUnwrap(String(data: Wire.encoder().encode(batch), encoding: .utf8))
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "assistant", content: "",
                    createdAt: t0, isComplete: true, toolCalls: json),
            attachments: []
        )
        try await store.insertMessage(
            Message(conversationId: convo.id, role: "tool", content: "time",
                    createdAt: t0.addingTimeInterval(1), isComplete: true,
                    toolCallId: "ct", name: ToolName.currentTime),
            attachments: []
        )

        let detail = try await store.conversationDetail(id: convo.id)
        let active = try XCTUnwrap(detail?.messages.activeToolCallBatch())
        XCTAssertEqual(active.calls.count, 2)
        XCTAssertEqual(active.answered, ["ct"])
        // The interactive call is the one still needing the user.
        let prompt = AppToolRegistry.firstUnansweredPrompt(
            calls: active.calls, answered: active.answered
        )
        XCTAssertEqual(prompt?.toolCallId, "au")
    }

    func testCompleteToolCallMessageStoresCallsAndCompletes() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "T")
        try await store.insertConversation(convo)
        let pending = Message(conversationId: convo.id, role: "assistant", content: "",
                              isComplete: false)
        try await store.insertMessage(pending, attachments: [])

        let json = try encodedCalls(
            id: "call_1", name: ToolName.askUser,
            arguments: #"{"question":"Q","options":["A","B"]}"#
        )
        try await store.completeToolCallMessage(
            id: pending.id, toolCalls: json, content: "already-streamed image"
        )

        let detail = try await store.conversationDetail(id: convo.id)
        XCTAssertEqual(detail?.messages.first?.message.isComplete, true)
        XCTAssertEqual(detail?.messages.first?.message.toolCalls, json)
        // Answer text streamed ahead of the batch is kept on the row.
        XCTAssertEqual(detail?.messages.first?.message.content, "already-streamed image")
        // It round-trips into wire history as an assistant tool_call (+ synthetic
        // dismissed result, since nothing answered it) with its content intact.
        XCTAssertEqual(detail?.wireHistory().first?.toolCalls?.first?.id, "call_1")
        XCTAssertEqual(detail?.wireHistory().first?.content.plainText, "already-streamed image")
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

    func testDeleteHardDeletesConversationAndChildren() async throws {
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

        // Detail no longer returns the conversation.
        let after = try await store.conversationDetail(id: convo.id)
        XCTAssertNil(after)

        // The conversation and all child data are physically gone.
        try await store.reader.read { db in
            XCTAssertEqual(try Message.fetchCount(db), 0)
            XCTAssertEqual(try Attachment.fetchCount(db), 0)
            let row = try Conversation.fetchOne(db, key: convo.id)
            XCTAssertNil(row)
        }
    }

    func testDeleteAllHardDeletesConversationsAndChildren() async throws {
        let store = try AppDatabase.empty()
        for title in ["One", "Two"] {
            let conversation = Conversation(title: title)
            try await store.insertConversation(conversation)
            let message = Message(conversationId: conversation.id, role: "user", content: title)
            try await store.insertMessage(
                message,
                attachments: [Attachment(messageId: message.id, kind: .image, name: "p.jpg")]
            )
        }

        try await store.deleteAllConversations()

        try await store.reader.read { db in
            XCTAssertEqual(try Conversation.fetchCount(db), 0)
            XCTAssertEqual(try Message.fetchCount(db), 0)
            XCTAssertEqual(try Attachment.fetchCount(db), 0)
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

    func testSearchIgnoresInlineImagePayloadsButFindsSurroundingText() async throws {
        let store = try AppDatabase.empty()
        let convo = Conversation(title: "Untitled")
        try await store.insertConversation(convo)
        // A distinctive fake payload: raw content keeps it, but the FTS
        // projection must not index it.
        let payload = "zebrafish" + String(repeating: "A", count: 64)
        try await store.insertMessage(
            Message(
                conversationId: convo.id, role: "assistant",
                content: "Here is your sunset ![generated](data:image/png;base64,\(payload)) enjoy"
            ),
            attachments: []
        )
        let byText = try await store.searchConversations(matching: "sunset")
        XCTAssertEqual(byText.map(\.conversation.id), [convo.id])
        let byPayload = try await store.searchConversations(matching: "zebrafish")
        XCTAssertTrue(byPayload.isEmpty, "base64 payloads must not be searchable")
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
