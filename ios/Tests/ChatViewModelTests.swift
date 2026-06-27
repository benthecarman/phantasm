import PhantasmKit
@testable import Phantasm
import UIKit
import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testSendStreamsCommitsTitleSpeaksAndCachesServerImage() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let imageFetcher = FakeImageFetcher(
            image: .init(data: Data("png".utf8), mime: "image/png")
        )
        let env = FakeChatEnvironment(client: client)
        env.autoSpeakEnabled = true
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation, imageFetcher: imageFetcher)

        let imageURL = "https://backend.example/v1/files/img_1/content?exp=1&sig=s"
        client.enqueue(events: [
            .status("searching the web..."),
            .reasoning("plan"),
            .token("Answer ![generated](\(imageURL))"),
            .done,
        ])
        client.enqueue(events: [
            .token("Title: `Better Chat`"),
            .done,
        ])

        vm.send("  hello  ")

        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.conversation.title == "Better Chat"
                && detail.messages.count == 2
                && detail.messages.last?.message.isComplete == true
                && detail.messages.last?.attachments.count == 1
        }

        let detail = try await detail(store, conversation.id)
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(detail.messages.map(\.message.role), ["user", "assistant"])
        XCTAssertEqual(detail.messages[0].message.content, "hello")
        XCTAssertEqual(detail.messages[1].message.content, "Answer ![generated](\(imageURL))")
        XCTAssertEqual(detail.messages[1].message.reasoning, "plan")
        XCTAssertEqual(detail.messages[1].attachments.first?.kind, AttachmentKind.remoteImage.rawValue)
        XCTAssertEqual(detail.messages[1].attachments.first?.name, "img_1")
        XCTAssertEqual(env.spokenTexts, ["Answer ![generated](\(imageURL))"])
        XCTAssertEqual(client.requests.count, 2, "reply stream plus title-generation side query")
    }

    func testStopBeforeTokensDeletesPendingAssistantRow() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        client.enqueue(events: [.token("late"), .done], leadingDelayNanoseconds: 400_000_000)

        vm.send("stop me")
        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.messages.map(\.message.role) == ["user", "assistant"]
                && detail.messages.last?.message.isComplete == false
        }

        vm.stop()

        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.messages.map(\.message.role) == ["user"]
        }
        XCTAssertNil(vm.errorMessage)
    }

    func testStreamErrorDeletesPendingAssistantRowAndSurfacesMessage() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        client.enqueue(events: [], error: AppError.unreachable)

        vm.send("fail")

        try await waitUntil {
            vm.errorMessage == AppError.unreachable.userMessage
        }
        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.messages.map(\.message.role) == ["user"]
        }
    }

    func testRecoverPendingAssistantRowContinuesStreamingInPlace() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        var conversation = Conversation(modelID: "m")
        conversation.title = "Recovered"
        try await store.insertConversation(conversation)
        try await store.insertMessage(
            Message(conversationId: conversation.id, role: "user", content: "continue"),
            attachments: []
        )
        let pending = Message(
            conversationId: conversation.id,
            role: "assistant",
            content: "partial",
            reasoning: "thinking",
            isComplete: false
        )
        try await store.insertMessage(pending, attachments: [])
        client.enqueue(events: [.token(" answer"), .done])

        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        try await waitUntil {
            let detail = try await self.detail(store, conversation.id)
            return detail.messages.last?.message.content == "partial answer"
                && detail.messages.last?.message.reasoning == "thinking"
                && detail.messages.last?.message.isComplete == true
        }
        XCTAssertFalse(vm.isStreaming)
    }

    func testAppToolBatchParksForPromptThenContinuesAfterAnswer() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        let calls = [
            WireToolCall(
                index: 0,
                id: "time_call",
                function: .init(name: ToolName.currentTime, arguments: "{}")
            ),
            WireToolCall(
                index: 1,
                id: "ask_call",
                function: .init(
                    name: ToolName.askUser,
                    arguments: #"{"questions":[{"question":"Pick one","options":["A","B"],"type":"single_select"}]}"#
                )
            ),
        ]
        client.enqueue(events: [.toolCalls(calls), .done])
        client.enqueue(events: [.token("Final answer"), .done])

        vm.send("needs tool")

        try await waitUntil {
            vm.pendingPrompt?.toolCallId == "ask_call" && !vm.isStreaming
        }
        var detail = try await detail(store, conversation.id)
        XCTAssertEqual(detail.messages.map(\.message.role), ["user", "assistant", "tool"])
        XCTAssertEqual(detail.messages[1].message.toolCalls?.isEmpty, false)
        XCTAssertEqual(detail.messages[2].message.toolCallId, "time_call")
        XCTAssertEqual(detail.messages[2].message.name, ToolName.currentTime)

        vm.answerPendingPrompt("A")

        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.messages.map(\.message.role) == ["user", "assistant", "tool", "tool", "assistant"]
                && detail.messages.last?.message.content == "Final answer"
                && detail.messages.last?.message.isComplete == true
        }
        detail = try await self.detail(store, conversation.id)
        XCTAssertEqual(detail.messages[3].message.toolCallId, "ask_call")
        XCTAssertEqual(detail.messages[3].message.content, "A")
        XCTAssertNil(vm.pendingPrompt)
    }

    func testRecoverUnansweredPromptFromPersistedToolCallBatch() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        let conversation = Conversation(modelID: "m")
        try await store.insertConversation(conversation)
        let calls = [
            WireToolCall(
                index: 0,
                id: "ask_call",
                function: .init(
                    name: ToolName.askUser,
                    arguments: #"{"questions":[{"question":"Pick one","options":["A","B"]}]}"#
                )
            ),
        ]
        let json = try XCTUnwrap(String(data: Wire.encoder().encode(calls), encoding: .utf8))
        try await store.insertMessage(
            Message(
                conversationId: conversation.id,
                role: "assistant",
                content: "",
                isComplete: true,
                toolCalls: json
            ),
            attachments: []
        )

        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        try await waitUntil {
            vm.pendingPrompt?.toolCallId == "ask_call"
        }
        XCTAssertFalse(vm.isStreaming)
    }

    private func makeViewModel(
        env: FakeChatEnvironment,
        store: AppDatabase,
        conversation: Conversation,
        imageFetcher: any ImageFetching = FakeImageFetcher()
    ) -> ChatViewModel {
        let vm = ChatViewModel(
            backgroundTasks: FakeBackgroundTaskManager(),
            notifications: FakeNotificationManager(),
            imageFetcher: imageFetcher
        )
        vm.configure(env: env, store: store, conversation: conversation, sceneIsActive: true)
        return vm
    }

    private func detail(_ store: AppDatabase, _ id: UUID) async throws -> ConversationDetail {
        let detail = try await store.conversationDetail(id: id)
        return try XCTUnwrap(detail)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private static func fullCapabilities() -> Capabilities {
        Capabilities(
            version: "test",
            modelEntries: [
                .init(
                    id: "m",
                    capabilities: .init(
                        completion: true,
                        vision: false,
                        audio: false,
                        tools: true,
                        insert: false,
                        thinking: false,
                        embedding: false
                    )
                )
            ],
            toolSelectors: [
                .init(id: ToolSelectorName.webSearch, label: "Web search", tools: [ToolName.webSearch]),
                .init(
                    id: ToolSelectorName.imageGeneration,
                    label: "Images",
                    tools: [ToolName.imageGeneration]
                )
            ]
        )
    }
}

@MainActor
private final class FakeChatEnvironment: ChatViewModelEnvironment {
    var activeProfile: BackendProfile?
    var activeToken: String? = "test-token"
    var backendMode: BackendMode = .plainChatOnly(models: ["m"])
    var preferredModel: String? {
        backendMode.resolvedChatModel(
            conversationModel: nil,
            defaultModel: activeProfile?.defaultModel
        )
    }
    var chatStreamingClient: any ChatClienting { client }
    var ollamaStreamingClient: any ChatClienting { ollamaClient }
    var autoSpeakEnabled = false
    var defaultLocationEnabled = false
    var requestedLocationAuthorization = false
    var warmedModels: [String] = []
    var spokenTexts: [String] = []

    private let client: ScriptedChatClient
    private let ollamaClient = ScriptedChatClient()

    init(client: ScriptedChatClient) {
        self.client = client
        self.activeProfile = BackendProfile(
            name: "Test",
            baseURLString: "https://backend.example",
            defaultModel: "m"
        )
    }

    func supportsTools(_ model: String?) -> Bool {
        guard let model else { return false }
        return backendMode.capabilities?.toolModelIDs?.contains(model) ?? true
    }

    func thinkingEnabled(for model: String?) -> Bool { false }

    func disabledReasoningEffortForCurrentBackend() -> String? {
        switch backendMode {
        case .full, .ollamaNative: return ReasoningEffort.disabled
        case .plainChatOnly: return nil
        }
    }

    func setDefaultLocationEnabled(_ enabled: Bool) {
        defaultLocationEnabled = enabled
    }

    func requestLocationAuthorizationWhenInUse() {
        requestedLocationAuthorization = true
    }

    func warm(model: String) {
        warmedModels.append(model)
    }

    func speak(_ text: String, messageID: UUID) {
        spokenTexts.append(text)
    }
}

private final class ScriptedChatClient: ChatClienting, @unchecked Sendable {
    struct Script: Sendable {
        var events: [ChatStreamEvent]
        var leadingDelayNanoseconds: UInt64
        var pauseAfterEventNanoseconds: UInt64
        var error: (any Error)?
    }

    private let lock = NSLock()
    private var scripts: [Script] = []
    private var recordedRequests: [ChatRequest] = []

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func enqueue(
        events: [ChatStreamEvent],
        leadingDelayNanoseconds: UInt64 = 0,
        pauseAfterEventNanoseconds: UInt64 = 0,
        error: (any Error)? = nil
    ) {
        lock.lock()
        scripts.append(
            Script(
                events: events,
                leadingDelayNanoseconds: leadingDelayNanoseconds,
                pauseAfterEventNanoseconds: pauseAfterEventNanoseconds,
                error: error
            )
        )
        lock.unlock()
    }

    func stream(_ request: ChatRequest, base: URL, token: String)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        let script = nextScript(recording: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if script.leadingDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: script.leadingDelayNanoseconds)
                    }
                    for event in script.events {
                        try Task.checkCancellation()
                        continuation.yield(event)
                        if script.pauseAfterEventNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: script.pauseAfterEventNanoseconds)
                        }
                    }
                    if let error = script.error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func nextScript(recording request: ChatRequest) -> Script {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        if scripts.isEmpty {
            return Script(events: [.done], leadingDelayNanoseconds: 0, pauseAfterEventNanoseconds: 0, error: nil)
        }
        return scripts.removeFirst()
    }
}

@MainActor
private final class FakeBackgroundTaskManager: BackgroundTaskManaging {
    var invalidTaskID: UIBackgroundTaskIdentifier { .invalid }
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func beginBackgroundTask(
        named name: String,
        expirationHandler: @escaping @MainActor () -> Void
    ) -> UIBackgroundTaskIdentifier {
        beginCount += 1
        return .invalid
    }

    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        endCount += 1
    }
}

@MainActor
private final class FakeNotificationManager: NotificationManaging {
    private(set) var authorizationRequests = 0
    private(set) var scheduledConversationIDs: [UUID?] = []

    func requestAuthorizationIfNeeded() async {
        authorizationRequests += 1
    }

    func scheduleBackgroundCompletion(conversationID: UUID?) async {
        scheduledConversationIDs.append(conversationID)
    }
}

private final class FakeImageFetcher: ImageFetching, @unchecked Sendable {
    private let image: ServerImageRef.CachedImage?

    init(image: ServerImageRef.CachedImage? = nil) {
        self.image = image
    }

    func fetch(_ url: URL) async -> ServerImageRef.CachedImage? {
        return image
    }
}
