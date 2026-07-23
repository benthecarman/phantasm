import ImageIO
import PhantasmKit
@testable import Phantasm
import UIKit
import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testProfileSwitchKeepsTurnAndFollowupsOnOwningBackend() async throws {
        let store = try AppDatabase.empty()
        let ownerClient = ScriptedChatClient()
        let otherClient = ScriptedChatClient()
        let imageFetcher = FakeImageFetcher(
            image: .init(data: Data("png".utf8), mime: "image/png")
        )
        let env = FakeChatEnvironment(client: ownerClient)
        let other = env.addProfile(
            name: "Other",
            baseURL: "https://other.example",
            token: "other-token",
            client: otherClient
        )
        let conversation = Conversation(profileID: env.primaryProfileID)
        let vm = makeViewModel(
            env: env,
            store: store,
            conversation: conversation,
            imageFetcher: imageFetcher
        )
        env.activeProfileID = other.id

        let imageURL = "https://backend.example/v1/files/img_1/content"
        ownerClient.enqueue(events: [.token("![image](\(imageURL))"), .done])
        ownerClient.enqueue(events: [.token("Owned Chat"), .done])

        XCTAssertTrue(vm.send("hello"))

        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.conversation.title == "Owned Chat"
                && detail?.messages.last?.attachments.count == 1
        }

        XCTAssertEqual(ownerClient.invocations.count, 2)
        XCTAssertTrue(ownerClient.invocations.allSatisfy {
            $0.base == URL(string: "https://backend.example")
                && $0.token == "test-token"
        })
        XCTAssertTrue(otherClient.invocations.isEmpty)
        XCTAssertEqual(
            imageFetcher.trustedBases,
            [URL(string: "https://backend.example")!]
        )
    }

    func testProfileSwitchKeepsCancellationOnOwningBackend() async throws {
        let store = try AppDatabase.empty()
        let ownerClient = ScriptedChatClient()
        let otherClient = ScriptedChatClient()
        let env = FakeChatEnvironment(client: ownerClient)
        let other = env.addProfile(
            name: "Other",
            baseURL: "https://other.example",
            token: "other-token",
            client: otherClient
        )
        let conversation = Conversation(profileID: env.primaryProfileID)
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        env.activeProfileID = other.id
        ownerClient.enqueue(
            events: [.token("late"), .done],
            leadingDelayNanoseconds: 400_000_000
        )

        XCTAssertTrue(vm.send("stop"))
        try await waitUntil { ownerClient.invocations.count == 1 }
        vm.stop()
        try await waitUntil { ownerClient.cancellations.count == 1 }

        XCTAssertEqual(
            ownerClient.cancellations.first?.base,
            URL(string: "https://backend.example")
        )
        XCTAssertEqual(ownerClient.cancellations.first?.token, "test-token")
        XCTAssertTrue(otherClient.cancellations.isEmpty)
    }

    func testPrepareForDeletionDrainsRescuedStartingTurnBeforeReturning() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation(profileID: env.primaryProfileID)
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        // prepareForDeletion runs before the newly-created turn task gets an
        // executor slice. stop() must therefore rescue the not-yet-persisted
        // user row and wait for that rescue before permitting the delete.
        XCTAssertTrue(vm.send("delete me"))
        await vm.prepareForDeletion()

        XCTAssertFalse(vm.canSend)
        let persisted = try await detail(store, conversation.id)
        XCTAssertEqual(persisted.messages.map(\.message.content), ["delete me"])

        try await store.deleteConversation(id: conversation.id)
        try await Task.sleep(nanoseconds: 500_000_000)
        let deleted = try await store.conversationDetail(id: conversation.id)
        XCTAssertNil(deleted)
    }

    func testFailedDeletionPreparationCanResumeConversation() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation(profileID: env.primaryProfileID)
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        XCTAssertTrue(vm.send("keep me"))
        await vm.prepareForDeletion()
        XCTAssertFalse(vm.canSend)

        // The root calls this when the destructive store write throws. The
        // stopped turn remains durable and the existing chat becomes usable.
        vm.resumeAfterFailedDeletion()
        XCTAssertTrue(vm.canSend)

        client.enqueue(events: [.token("still here"), .done])
        XCTAssertTrue(vm.send("continue"))
        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.messages.last?.message.content == "still here"
        }
    }

    func testMissingProfileFailsClosedUntilExplicitlyBound() async throws {
        let store = try AppDatabase.empty()
        let ownerClient = ScriptedChatClient()
        let replacementClient = ScriptedChatClient()
        let env = FakeChatEnvironment(client: ownerClient)
        let replacement = env.addProfile(
            name: "Replacement",
            baseURL: "https://replacement.example",
            token: "replacement-token",
            client: replacementClient
        )
        let conversation = Conversation(profileID: nil)
        try await store.insertConversation(conversation)
        try await store.insertMessage(
            Message(
                conversationId: conversation.id,
                role: "user",
                content: "existing private history",
                isComplete: true
            ),
            attachments: []
        )
        let vm = makeViewModel(
            env: env,
            store: store,
            conversation: conversation,
            bindDefaultProfile: false
        )

        XCTAssertFalse(vm.send("private history"))
        XCTAssertTrue(ownerClient.invocations.isEmpty)
        XCTAssertTrue(replacementClient.invocations.isEmpty)

        replacementClient.enqueue(events: [.token("safe"), .done])
        replacementClient.enqueue(events: [.token("Bound Chat"), .done])
        vm.bindConversation(to: replacement.id)
        try await waitUntil { vm.backendSession?.profileID == replacement.id }
        XCTAssertTrue(vm.send("private history"))

        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.conversation.title == "Bound Chat"
        }
        let detail = try await self.detail(store, conversation.id)
        XCTAssertEqual(detail.conversation.profileID, replacement.id)
        XCTAssertTrue(ownerClient.invocations.isEmpty)
        XCTAssertTrue(replacementClient.invocations.allSatisfy {
            $0.base == URL(string: "https://replacement.example")
                && $0.token == "replacement-token"
        })
        XCTAssertTrue(
            replacementClient.requests.first?.messages.contains {
                $0.content.plainText == "existing private history"
            } == true
        )
    }

    func testProfileSwitchKeepsPromptContinuationOnOwningBackend() async throws {
        let store = try AppDatabase.empty()
        let ownerClient = ScriptedChatClient()
        let otherClient = ScriptedChatClient()
        let env = FakeChatEnvironment(client: ownerClient)
        env.backendMode = .full(Self.fullCapabilities())
        let other = env.addProfile(
            name: "Other",
            baseURL: "https://other.example",
            token: "other-token",
            client: otherClient
        )
        let conversation = Conversation(profileID: env.primaryProfileID)
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        let calls = [WireToolCall(
            index: 0,
            id: "ask_call",
            function: .init(
                name: ToolName.askUser,
                arguments: #"{"questions":[{"question":"Pick","options":["A","B"]}]}"#
            )
        )]
        ownerClient.enqueue(events: [.toolCalls(calls), .done])
        ownerClient.enqueue(events: [.token("Final"), .done])

        XCTAssertTrue(vm.send("ask"))
        try await waitUntil { vm.pendingPrompt != nil && !vm.isStreaming }
        env.activeProfileID = other.id
        vm.answerPendingPrompt("A")
        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.messages.last?.message.content == "Final"
        }

        XCTAssertEqual(ownerClient.invocations.count, 2)
        XCTAssertTrue(ownerClient.invocations.allSatisfy {
            $0.base == URL(string: "https://backend.example")
        })
        XCTAssertTrue(otherClient.invocations.isEmpty)
    }

    func testCompletedResponseRecordsEstimatedTokensPerSecond() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        client.enqueue(
            events: [.token(String(repeating: "a", count: 20)), .token(String(repeating: "b", count: 20)), .done],
            pauseAfterEventNanoseconds: 100_000_000
        )
        client.enqueue(events: [.token("Speed test"), .done])

        vm.send("hello")

        try await waitUntil { !vm.isStreaming && vm.latestTokensPerSecond != nil }
        let rate = try XCTUnwrap(vm.latestTokensPerSecond)
        XCTAssertGreaterThan(rate, 35)
        XCTAssertLessThan(rate, 65)
    }

    func testCompletedResponsePrefersServerReportedTokensPerSecond() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        client.enqueue(events: [.token("answer"), .throughput(192.9), .done])
        client.enqueue(events: [.token("Speed test"), .done])

        vm.send("hello")

        try await waitUntil { !vm.isStreaming }
        XCTAssertEqual(vm.latestTokensPerSecond, 192.9)
    }

    func testRapidStreamCoalescesPublicationsWithoutLosingText() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        let tokenCount = 120
        let expected = String(repeating: "x", count: tokenCount)

        client.enqueue(
            events: Array(repeating: ChatStreamEvent.token("x"), count: tokenCount) + [.done],
            pauseAfterEventNanoseconds: 1_000_000
        )
        client.enqueue(events: [.token("Coalesced Stream"), .done])

        XCTAssertTrue(vm.send("hello"))
        try await waitUntil {
            guard !vm.isStreaming,
                  let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.messages.last?.message.content == expected
        }

        XCTAssertEqual(vm.streamingText, expected)
        XCTAssertGreaterThan(vm.streamingRevision, 0)
        XCTAssertLessThan(
            vm.streamingRevision,
            tokenCount / 2,
            "rapid network deltas should publish in frame-cadenced batches"
        )
    }

    func testTextAttachmentCapsReadWithoutCorruptingSplitUTF8Scalar() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        var data = Data(repeating: 0x61, count: AttachmentLoader.maxTextSourceBytes - 1)
        data.append(contentsOf: "€".utf8) // the bounded read sees only its first byte
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = await AttachmentLoader.file(at: url)

        XCTAssertEqual(attachment?.text.count, AttachmentLoader.maxFileCharacters)
        XCTAssertFalse(attachment?.text.contains("â") ?? true, "UTF-8 prefix became Latin-1 mojibake")
    }

    func testImagePreparationDownsamplesAndThumbnailCacheReusesDecodedImage() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let original = UIGraphicsImageRenderer(
            size: CGSize(width: 2_400, height: 1_200),
            format: format
        ).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_200))
        }

        let preparedAttachment = await AttachmentLoader.image(from: original)
        let attachment = try XCTUnwrap(preparedAttachment)
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertFalse(attachment.imageData.isEmpty)

        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(attachment.imageData as CFData, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        XCTAssertEqual(max(width, height), Int(AttachmentLoader.maxImageDimension))

        let cache = AttachmentThumbnailCache(totalCostLimit: 8 * 1024 * 1024, countLimit: 2)
        let id = UUID()
        let firstResult = await cache.image(for: id, data: attachment.imageData)
        let first = try XCTUnwrap(firstResult)
        let secondResult = await cache.image(for: id, data: attachment.imageData)
        let second = try XCTUnwrap(secondResult)
        XCTAssertTrue(first === second, "stable attachment IDs should reuse the decoded thumbnail")
        XCTAssertLessThanOrEqual(
            max(first.cgImage?.width ?? 0, first.cgImage?.height ?? 0),
            AttachmentThumbnailCache.maxPixelSize
        )
        XCTAssertGreaterThan(ImageProcessing.decodedByteCost(first), 0)

        let fullResult = await ImageProcessing.fullResolutionImage(data: attachment.imageData)
        let full = try XCTUnwrap(fullResult)
        XCTAssertEqual(full.cgImage?.width, width)
        XCTAssertEqual(full.cgImage?.height, height)
    }

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

    func testTitleGenerationRetriesWithoutReasoningEffortWhenReasoningRequestFails() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(.init(
            version: "0.1",
            modelEntries: [
                .init(
                    id: "m",
                    capabilities: .init(
                        completion: true,
                        vision: false,
                        audio: false,
                        tools: true,
                        insert: false,
                        embedding: false
                    ),
                    reasoningEfforts: [ReasoningEffort.disabled, ReasoningEffort.enabledDefault]
                )
            ]
        ))
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        client.enqueue(events: [.token("answer"), .done])
        client.enqueue(events: [], error: AppError.unreachable)
        client.enqueue(events: [.token("Fallback Title"), .done])

        vm.send("hello")

        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.conversation.title == "Fallback Title"
        }

        XCTAssertEqual(client.requests.count, 3)
        XCTAssertEqual(client.requests[1].reasoningEffort, ReasoningEffort.enabledDefault)
        XCTAssertNil(client.requests[2].reasoningEffort)
    }

    func testTitleGenerationIgnoresReasoningEventsAndThinkBlocks() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        client.enqueue(events: [.token("answer"), .done])
        client.enqueue(events: [
            .reasoning("hidden plan"),
            .token("<think>also hidden</think>\nTitle: Useful Chat"),
            .done,
        ])

        vm.send("hello")

        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.conversation.title == "Useful Chat"
        }
    }

    func testTitleGenerationStripsLeakedThinkBlocksFromHistory() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        client.enqueue(events: [.token("<think>secret plan</think>Visible answer"), .done])
        client.enqueue(events: [.token("Visible Title"), .done])

        vm.send("hello")

        try await waitUntil {
            client.requests.count == 2
        }

        let titleHistory = client.requests[1].messages.map(\.content.plainText).joined(separator: "\n")
        XCTAssertFalse(titleHistory.contains("secret plan"))
        XCTAssertTrue(titleHistory.contains("Visible answer"))
    }

    func testTitleGenerationUsesBoundedTextOnlyHistory() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        let imageBytes = Data(repeating: 0xAB, count: 32_000)
        let attachment = PendingAttachment(
            kind: .image,
            name: "Photo",
            imageData: imageBytes,
            mimeType: "image/jpeg"
        )

        client.enqueue(events: [.token(String(repeating: "answer ", count: 600)), .done])
        client.enqueue(events: [.token("Image Chat"), .done])

        XCTAssertTrue(vm.send(String(repeating: "question ", count: 400), attachments: [attachment]))
        try await waitUntil { client.requests.count == 2 }

        guard case .parts = client.requests[0].messages.first?.content else {
            return XCTFail("the main turn should still include the image")
        }
        let titleHistory = client.requests[1].messages.dropLast()
        XCTAssertFalse(titleHistory.isEmpty)
        XCTAssertTrue(titleHistory.allSatisfy {
            if case .text = $0.content { return true }
            return false
        })
        XCTAssertLessThanOrEqual(titleHistory.reduce(0) { $0 + $1.content.plainText.count }, 4_000)
        XCTAssertTrue(titleHistory.allSatisfy { $0.content.imageData.isEmpty })
    }

    func testSecondSendKeepsGeneratedTitle() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        client.enqueue(events: [.token("first reply"), .done])
        client.enqueue(events: [.token("Better Chat"), .done]) // title side-query
        vm.send("hello there")
        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.conversation.title == "Better Chat"
        }

        // A later send re-persists the VM's conversation metadata; it must not
        // revert the generated title to the first-message snippet.
        client.enqueue(events: [.token("second reply"), .done])
        vm.send("and another thing")
        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.messages.last?.message.content == "second reply"
                && detail?.messages.last?.message.isComplete == true
        }
        let detail = try await self.detail(store, conversation.id)
        XCTAssertEqual(detail.conversation.title, "Better Chat")
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

    func testStopImmediatelyAfterSendLeavesNoOrphanRow() async throws {
        // stop() right after send() cancels the task while the store writes are
        // still in flight. The pending assistant row must not be created (or
        // must be cleaned up) — an orphaned incomplete row used to auto-restart
        // the explicitly stopped turn on the next foreground.
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        client.enqueue(events: [.token("late"), .done], leadingDelayNanoseconds: 400_000_000)

        vm.send("stop me now")
        vm.stop()

        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.messages.map(\.message.role) == ["user"]
        }

        // Recovery hooks must not resurrect the stopped turn.
        vm.setViewVisible(false)
        vm.setViewVisible(true)
        try await Task.sleep(nanoseconds: 200_000_000)
        let detail = try await self.detail(store, conversation.id)
        XCTAssertEqual(detail.messages.map(\.message.role), ["user"])
        XCTAssertFalse(vm.isStreaming)
        XCTAssertTrue(client.requests.isEmpty, "the stopped turn must never reach the backend")
    }

    func testStoppedTurnCannotFinishReplacementTurn() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        client.enqueue(
            events: [.token("stale"), .done],
            leadingDelayNanoseconds: 800_000_000
        )
        client.enqueue(
            events: [.token("replacement"), .done],
            leadingDelayNanoseconds: 300_000_000
        )
        client.enqueue(events: [.token("Replacement Chat"), .done])

        XCTAssertTrue(vm.send("first"))
        try await waitUntil { client.invocations.count == 1 }

        vm.stop()
        XCTAssertTrue(vm.send("second"))

        // The stopped stream's cancellation resumes after the new send. It must
        // not clear the replacement turn while that turn is waiting for tokens.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertNil(vm.errorMessage)

        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.messages.last?.message.content == "replacement"
                && detail?.messages.last?.message.isComplete == true
        }
    }

    func testStoppedToolContinuationCannotFinishReplacementTurn() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)
        let calls = [WireToolCall(
            index: 0,
            id: "time_call",
            function: .init(name: ToolName.currentTime, arguments: "{}")
        )]

        client.enqueue(events: [.toolCalls(calls), .done])
        client.enqueue(
            events: [.token("stale continuation"), .done],
            leadingDelayNanoseconds: 800_000_000
        )
        client.enqueue(
            events: [.token("replacement"), .done],
            leadingDelayNanoseconds: 300_000_000
        )
        client.enqueue(events: [.token("Replacement Chat"), .done])

        XCTAssertTrue(vm.send("use a tool"))
        try await waitUntil { client.invocations.count == 2 }

        vm.stop()
        XCTAssertTrue(vm.send("new turn"))

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertNil(vm.errorMessage)

        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.messages.last?.message.content == "replacement"
                && detail?.messages.last?.message.isComplete == true
        }
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

    func testForegroundEOFCommitsPartialAnswerAndSurfacesError() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        // The sequence ends without the protocol's terminal `.done` event.
        client.enqueue(events: [.token("partial answer")])
        vm.send("hello")

        let expected = AppError.modelError(
            "The connection closed before the response finished."
        ).userMessage
        try await waitUntil { vm.errorMessage == expected }
        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id),
                  detail.messages.count == 2 else { return false }
            return detail.messages.last?.message.content == "partial answer"
                && detail.messages.last?.message.isComplete == true
        }
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(client.requests.count, 1, "an incomplete response must not generate a title")
    }

    func testReasoningOnlyCompletionCommitsReasoningAndSurfacesSpecificError() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        client.enqueue(events: [.reasoning("thinking trace"), .done])

        vm.send("think but do not answer")

        try await waitUntil {
            vm.errorMessage == AppError.modelError("The model produced thinking but no answer.").userMessage
        }
        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id),
                  detail.messages.count == 2 else {
                return false
            }
            let assistant = detail.messages[1].message
            return assistant.role == "assistant"
                && assistant.content.isEmpty
                && assistant.reasoning == "thinking trace"
                && assistant.isComplete
        }
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(client.requests.count, 1)
    }

    func testCompletedThinkingDurationIsPersisted() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation()
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        client.enqueue(
            events: [.reasoning("first"), .reasoning(" second"), .token("answer"), .done],
            pauseAfterEventNanoseconds: 100_000_000
        )
        client.enqueue(events: [.token("Timed thought"), .done])

        vm.send("hello")

        try await waitUntil {
            let detail = try await store.conversationDetail(id: conversation.id)
            return detail?.messages.last?.message.reasoningDuration != nil
        }
        let stored = try await detail(store, conversation.id)
        let duration = try XCTUnwrap(stored.messages.last?.message.reasoningDuration)
        XCTAssertGreaterThan(duration, 0.15)
        XCTAssertLessThan(duration, 0.4)
    }

    func testRecoverPendingAssistantRowReplaysStreamingInPlace() async throws {
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let otherClient = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let other = env.addProfile(
            name: "Other",
            baseURL: "https://other.example",
            token: "other-token",
            client: otherClient
        )
        env.activeProfileID = other.id
        var conversation = Conversation(
            modelID: "m",
            profileID: env.primaryProfileID
        )
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
        client.enqueue(events: [.reasoning("thinking"), .token("partial answer"), .done])

        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        try await waitUntil {
            let detail = try await self.detail(store, conversation.id)
            return detail.messages.last?.message.content == "partial answer"
                && detail.messages.last?.message.reasoning == "thinking"
                && detail.messages.last?.message.reasoningDuration == nil
                && detail.messages.last?.message.isComplete == true
        }
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(
            client.invocations.first?.base,
            URL(string: "https://backend.example")
        )
        XCTAssertTrue(otherClient.invocations.isEmpty)
    }

    func testRecoverContinuationInterruptedAfterToolBatch() async throws {
        // A turn that continued past an app-tool batch and was interrupted
        // (backgrounded, killed) leaves: user, assistant tool_calls, tool
        // result, incomplete assistant. Recovery must resume it — the guard
        // used to require the row before the pending one to be a user message,
        // so these turns were orphaned and their answers silently lost.
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        let conversation = Conversation(modelID: "m")
        try await store.insertConversation(conversation)
        let t0 = Date(timeIntervalSinceNow: -10)
        try await store.insertMessage(
            Message(conversationId: conversation.id, role: "user", content: "what time?",
                    createdAt: t0, isComplete: true),
            attachments: []
        )
        let calls = [WireToolCall(
            index: 0, id: "time_call",
            function: .init(name: ToolName.currentTime, arguments: "{}")
        )]
        let json = try XCTUnwrap(String(data: Wire.encoder().encode(calls), encoding: .utf8))
        try await store.insertMessage(
            Message(conversationId: conversation.id, role: "assistant", content: "",
                    createdAt: t0.addingTimeInterval(1), isComplete: true, toolCalls: json),
            attachments: []
        )
        try await store.insertMessage(
            Message(conversationId: conversation.id, role: "tool", content: "12:00",
                    createdAt: t0.addingTimeInterval(2), isComplete: true,
                    toolCallId: "time_call", name: ToolName.currentTime),
            attachments: []
        )
        try await store.insertMessage(
            Message(conversationId: conversation.id, role: "assistant", content: "",
                    createdAt: t0.addingTimeInterval(3), isComplete: false),
            attachments: []
        )
        client.enqueue(events: [.token("It is noon."), .done])

        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        vm.setViewVisible(true)

        try await waitUntil {
            let detail = try await self.detail(store, conversation.id)
            return detail.messages.last?.message.content == "It is noon."
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
        // The orchestrator flushes answer content queued by earlier server tools
        // (e.g. a generated image) as a token ahead of the tool_calls chunk; it
        // must survive onto the committed tool-call row, not just the preview.
        client.enqueue(events: [.token("![img](data:image/png;base64,AA==)"), .toolCalls(calls), .done])
        client.enqueue(events: [.token("Final answer"), .done])

        vm.send("needs tool")

        try await waitUntil {
            vm.pendingPrompt?.toolCallId == "ask_call" && !vm.isStreaming
        }
        var detail = try await detail(store, conversation.id)
        XCTAssertEqual(detail.messages.map(\.message.role), ["user", "assistant", "tool"])
        XCTAssertEqual(detail.messages[1].message.toolCalls?.isEmpty, false)
        // The store extracts the image payload to an attachment row; the wire
        // restores the exact data-URI markdown so the model re-sees it.
        XCTAssertTrue(detail.messages[1].message.content.hasPrefix("![img](phantasm-file://"))
        if case .text(let wire) = detail.messages[1].wireContent() {
            XCTAssertEqual(wire, "![img](data:image/png;base64,AA==)")
        } else {
            XCTFail("expected plain text wire content")
        }
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

    func testCalendarCreatePromptCancelsAndContinues() async throws {
        AppToolRegistry.configureCalendar(provider: TestCalendarProvider())
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        var conversation = Conversation()
        conversation.calendarEnabled = true
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        let calls = [
            WireToolCall(
                index: 0,
                id: "create_cal",
                function: .init(
                    name: ToolName.createCalendarEvent,
                    arguments: #"{"title":"Lunch","start_date":"2026-06-29T12:00:00"}"#
                )
            ),
        ]
        client.enqueue(events: [.toolCalls(calls), .done])
        client.enqueue(events: [.token("I won't add it."), .done])

        vm.send("add lunch")

        try await waitUntil {
            if case .calendarEvent = vm.pendingPrompt {
                return !vm.isStreaming
            }
            return false
        }

        vm.answerPendingCalendarEvent(confirm: false)

        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.messages.map(\.message.role) == ["user", "assistant", "tool", "assistant"]
                && detail.messages[2].message.name == ToolName.createCalendarEvent
                && detail.messages[2].message.content.contains("cancelled")
                && detail.messages.last?.message.content == "I won't add it."
        }
        XCTAssertNil(vm.pendingPrompt)
    }

    func testCalendarCreatePromptConfirmsAndContinues() async throws {
        let created = CalendarEvent(
            title: "Lunch",
            start: Self.date(2026, 6, 29, hour: 12),
            end: Self.date(2026, 6, 29, hour: 13),
            calendarTitle: "Work"
        )
        AppToolRegistry.configureCalendar(provider: TestCalendarProvider(createResult: .success(created)))
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        var conversation = Conversation()
        conversation.calendarEnabled = true
        let vm = makeViewModel(env: env, store: store, conversation: conversation)

        let calls = [
            WireToolCall(
                index: 0,
                id: "create_cal",
                function: .init(
                    name: ToolName.createCalendarEvent,
                    arguments: #"{"title":"Lunch","start_date":"2026-06-29T12:00:00"}"#
                )
            ),
        ]
        client.enqueue(events: [.toolCalls(calls), .done])
        client.enqueue(events: [.token("Added."), .done])

        vm.send("add lunch")

        try await waitUntil {
            if case .calendarEvent = vm.pendingPrompt {
                return !vm.isStreaming
            }
            return false
        }

        vm.answerPendingCalendarEvent(confirm: true)

        try await waitUntil {
            guard let detail = try await store.conversationDetail(id: conversation.id) else {
                return false
            }
            return detail.messages.map(\.message.role) == ["user", "assistant", "tool", "assistant"]
                && detail.messages[2].message.name == ToolName.createCalendarEvent
                && detail.messages[2].message.content.hasPrefix("create_calendar_event succeeded:")
                && detail.messages.last?.message.content == "Added."
        }
        XCTAssertNil(vm.pendingPrompt)
    }

    func testCalendarOutcomeCommitsAfterStopAndDeletionPreparationWaits() async throws {
        let created = CalendarEvent(
            title: "Lunch",
            start: Self.date(2026, 6, 29, hour: 12),
            end: Self.date(2026, 6, 29, hour: 13),
            calendarTitle: "Work"
        )
        let provider = DelayedCalendarProvider()
        AppToolRegistry.configureCalendar(provider: provider)
        let store = try AppDatabase.empty()
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        var conversation = Conversation()
        conversation.calendarEnabled = true
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        let calls = [WireToolCall(
            index: 0,
            id: "create_cal_stop",
            function: .init(
                name: ToolName.createCalendarEvent,
                arguments: #"{"title":"Lunch","start_date":"2026-06-29T12:00:00"}"#
            )
        )]
        client.enqueue(events: [.toolCalls(calls), .done])

        XCTAssertTrue(vm.send("add lunch"))
        try await waitUntil {
            if case .calendarEvent = vm.pendingPrompt { return !vm.isStreaming }
            return false
        }

        vm.answerPendingCalendarEvent(confirm: true)
        await provider.waitUntilCreateStarted()
        vm.stop()

        let deletionFinished = TestAsyncFlag()
        let deletionPreparation = Task {
            await vm.prepareForDeletion()
            await deletionFinished.set()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let returnedEarly = await deletionFinished.value
        XCTAssertFalse(
            returnedEarly,
            "deletion preparation returned before the durable outcome commit"
        )
        await provider.completeCreate(with: .success(created))
        await deletionPreparation.value
        let didFinish = await deletionFinished.value
        XCTAssertTrue(didFinish)

        let persisted = try await detail(store, conversation.id)
        let result = try XCTUnwrap(persisted.messages.last?.message)
        XCTAssertEqual(result.role, "tool")
        XCTAssertTrue(result.content.hasPrefix("create_calendar_event succeeded:"))
        XCTAssertFalse(result.content.contains("outcome pending"))
    }

    func testCalendarOutcomeMarkerNeverReachesModelAfterCommitFailure() async throws {
        let created = CalendarEvent(
            title: "Lunch",
            start: Self.date(2026, 6, 29, hour: 12),
            end: Self.date(2026, 6, 29, hour: 13),
            calendarTitle: "Work"
        )
        AppToolRegistry.configureCalendar(
            provider: TestCalendarProvider(createResult: .success(created))
        )
        let database = try AppDatabase.empty()
        let gate = TestAsyncGate()
        await gate.open()
        let store = BlockingOptionsStore(
            base: database,
            gate: gate,
            failToolOutcomeUpdate: true
        )
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        var conversation = Conversation()
        conversation.calendarEnabled = true
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        let calls = [WireToolCall(
            index: 0,
            id: "create_cal_failed_commit",
            function: .init(
                name: ToolName.createCalendarEvent,
                arguments: #"{"title":"Lunch","start_date":"2026-06-29T12:00:00"}"#
            )
        )]
        client.enqueue(events: [.toolCalls(calls), .done])

        XCTAssertTrue(vm.send("add lunch"))
        try await waitUntil {
            if case .calendarEvent = vm.pendingPrompt { return !vm.isStreaming }
            return false
        }
        vm.answerPendingCalendarEvent(confirm: true)
        try await waitUntil { !vm.isStreaming && vm.errorMessage != nil }

        let persisted = try await detail(database, conversation.id)
        XCTAssertEqual(
            persisted.messages.last?.message.content,
            "(confirmed — outcome pending; do not retry automatically)"
        )

        client.enqueue(events: [.token("must not be used"), .done])
        XCTAssertTrue(vm.send("what happened?"))
        try await waitUntil { !vm.isStreaming }
        XCTAssertEqual(
            client.invocations.count,
            1,
            "a durable uncertainty marker must never be forwarded as a tool result"
        )
    }

    func testSendWaitsForLatestToolSettingsPersistence() async throws {
        let database = try AppDatabase.empty()
        let gate = TestAsyncGate()
        let store = BlockingOptionsStore(base: database, gate: gate)
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        var conversation = Conversation(profileID: env.primaryProfileID)
        conversation.webSearchEnabled = true
        try await database.insertConversation(conversation)
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        client.enqueue(events: [.token("done"), .done])

        vm.setWebSearchEnabled(false)
        XCTAssertTrue(vm.send("private request"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(
            client.invocations.isEmpty,
            "the request must wait for the just-disabled tool to reach storage"
        )

        await gate.open()
        try await waitUntil { client.invocations.count == 1 }
        XCTAssertFalse(client.requests[0].tools?.contains {
            $0.function.name == ToolName.webSearch
        } ?? false)
    }

    func testSendFailsClosedWhenToolSettingsPersistenceFails() async throws {
        let database = try AppDatabase.empty()
        let gate = TestAsyncGate()
        await gate.open()
        let store = BlockingOptionsStore(
            base: database,
            gate: gate,
            failOptionsWrite: true
        )
        let client = ScriptedChatClient()
        let env = FakeChatEnvironment(client: client)
        env.backendMode = .full(Self.fullCapabilities())
        var conversation = Conversation(profileID: env.primaryProfileID)
        conversation.webSearchEnabled = true
        try await database.insertConversation(conversation)
        let vm = makeViewModel(env: env, store: store, conversation: conversation)
        client.enqueue(events: [.token("must not be used"), .done])

        vm.setWebSearchEnabled(false)
        XCTAssertTrue(vm.send("private request"))
        try await waitUntil { !vm.isStreaming && vm.errorMessage != nil }

        XCTAssertTrue(
            client.invocations.isEmpty,
            "the request must not use stale persisted tool settings"
        )
    }

    private func makeViewModel(
        env: FakeChatEnvironment,
        store: any ChatStore,
        conversation: Conversation,
        imageFetcher: any ImageFetching = FakeImageFetcher(),
        bindDefaultProfile: Bool = true
    ) -> ChatViewModel {
        var configuredConversation = conversation
        if bindDefaultProfile && configuredConversation.profileID == nil {
            configuredConversation.profileID = env.primaryProfileID
        }
        let vm = ChatViewModel(
            backgroundTasks: FakeBackgroundTaskManager(),
            notifications: FakeNotificationManager(),
            imageFetcher: imageFetcher
        )
        vm.configure(
            env: env,
            store: store,
            conversation: configuredConversation,
            sceneIsActive: true
        )
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

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }
}

private actor DelayedCalendarProvider: CalendarProviding {
    private var createContinuation:
        CheckedContinuation<Result<CalendarEvent, CalendarLookupError>, Never>?
    private var didStartCreate = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func events(
        matching query: CalendarEventQuery
    ) async -> Result<[CalendarEvent], CalendarLookupError> {
        .success([])
    }

    func createEvent(
        _ draft: CalendarEventDraft
    ) async -> Result<CalendarEvent, CalendarLookupError> {
        didStartCreate = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            createContinuation = continuation
        }
    }

    func waitUntilCreateStarted() async {
        if didStartCreate { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func completeCreate(
        with result: Result<CalendarEvent, CalendarLookupError>
    ) {
        createContinuation?.resume(returning: result)
        createContinuation = nil
    }
}

private actor TestAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor TestAsyncFlag {
    private(set) var value = false

    func set() { value = true }
}

private struct BlockingOptionsStore: ChatStore {
    let base: AppDatabase
    let gate: TestAsyncGate
    var failOptionsWrite = false
    var failToolOutcomeUpdate = false

    func insertConversation(_ conversation: Conversation) async throws {
        try await base.insertConversation(conversation)
    }

    func insertMessage(_ message: Message, attachments: [Attachment]) async throws {
        try await base.insertMessage(message, attachments: attachments)
    }

    func updateMessage(
        id: UUID,
        content: String,
        reasoning: String,
        reasoningDuration: TimeInterval?,
        isComplete: Bool,
        createdAt: Date?
    ) async throws {
        if failToolOutcomeUpdate {
            throw AppError.modelError("simulated tool outcome persistence failure")
        }
        try await base.updateMessage(
            id: id,
            content: content,
            reasoning: reasoning,
            reasoningDuration: reasoningDuration,
            isComplete: isComplete,
            createdAt: createdAt
        )
    }

    func addAttachments(messageID: UUID, attachments: [Attachment]) async throws {
        try await base.addAttachments(messageID: messageID, attachments: attachments)
    }

    func completeToolCallMessage(id: UUID, toolCalls: String, content: String) async throws {
        try await base.completeToolCallMessage(id: id, toolCalls: toolCalls, content: content)
    }

    func deleteMessage(id: UUID) async throws { try await base.deleteMessage(id: id) }

    func updateConversation(
        id: UUID,
        title: String?,
        modelID: String?,
        updatedAt: Date?
    ) async throws {
        try await base.updateConversation(
            id: id, title: title, modelID: modelID, updatedAt: updatedAt
        )
    }

    func bindConversation(id: UUID, toProfileID profileID: UUID) async throws {
        try await base.bindConversation(id: id, toProfileID: profileID)
    }

    func setConversationOptions(
        id: UUID,
        toolSettings: ToolSettings,
        turnModeID: String?
    ) async throws {
        await gate.wait()
        if failOptionsWrite {
            throw AppError.modelError("simulated settings persistence failure")
        }
        try await base.setConversationOptions(
            id: id, toolSettings: toolSettings, turnModeID: turnModeID
        )
    }

    func editUserMessage(id: UUID, newContent: String) async throws {
        try await base.editUserMessage(id: id, newContent: newContent)
    }

    func deleteMessagesFrom(id: UUID) async throws {
        try await base.deleteMessagesFrom(id: id)
    }

    func deleteMessagesAfter(id: UUID) async throws {
        try await base.deleteMessagesAfter(id: id)
    }

    func deleteConversation(id: UUID) async throws {
        try await base.deleteConversation(id: id)
    }

    func deleteAllConversations() async throws { try await base.deleteAllConversations() }

    func allConversationDetails(
        attachmentData: AttachmentDataScope
    ) async throws -> [ConversationDetail] {
        try await base.allConversationDetails(attachmentData: attachmentData)
    }

    func conversationDetail(
        id: UUID,
        attachmentData: AttachmentDataScope
    ) async throws -> ConversationDetail? {
        try await base.conversationDetail(id: id, attachmentData: attachmentData)
    }

    func attachmentPayloads(ids: [UUID]) async throws -> [UUID: Data] {
        try await base.attachmentPayloads(ids: ids)
    }

    func conversation(id: UUID) async throws -> Conversation? {
        try await base.conversation(id: id)
    }

    func searchConversations(
        matching query: String
    ) async throws -> [ConversationSearchResult] {
        try await base.searchConversations(matching: query)
    }
}

private struct TestCalendarProvider: CalendarProviding {
    var eventsResult: Result<[CalendarEvent], CalendarLookupError> = .success([])
    var createResult: Result<CalendarEvent, CalendarLookupError> = .failure(.unavailable("not configured"))

    func events(matching query: CalendarEventQuery) async -> Result<[CalendarEvent], CalendarLookupError> {
        eventsResult
    }

    func createEvent(_ draft: CalendarEventDraft) async -> Result<CalendarEvent, CalendarLookupError> {
        createResult
    }
}

@MainActor
private final class FakeChatEnvironment: ChatViewModelEnvironment {
    var backendMode: BackendMode = .plainChatOnly(models: ["m"])
    var activeProfileID: UUID?
    var autoSpeakEnabled = false
    var defaultLocationEnabled = false
    var defaultHealthEnabled = false
    var defaultCalendarEnabled = false
    var requestedLocationAuthorization = false
    var requestedHealthAuthorization = false
    var requestedCalendarAuthorization = false
    var warmedModels: [String] = []
    var spokenTexts: [String] = []
    var searchIndexRequests = 0
    var primaryProfileID: UUID { primaryProfile.id }

    private let client: ScriptedChatClient
    private let primaryProfile: BackendProfile
    private var additionalProfiles: [UUID: SessionConfiguration] = [:]

    private struct SessionConfiguration {
        let profile: BackendProfile
        let token: String
        let mode: BackendMode
        let client: ScriptedChatClient
    }

    init(client: ScriptedChatClient) {
        self.client = client
        self.primaryProfile = BackendProfile(
            name: "Test",
            baseURLString: "https://backend.example",
            defaultModel: "m"
        )
        self.activeProfileID = primaryProfile.id
    }

    @discardableResult
    func addProfile(
        name: String,
        baseURL: String,
        token: String,
        mode: BackendMode = .plainChatOnly(models: ["m"]),
        client: ScriptedChatClient
    ) -> BackendProfile {
        let profile = BackendProfile(
            name: name,
            baseURLString: baseURL,
            defaultModel: "m"
        )
        additionalProfiles[profile.id] = SessionConfiguration(
            profile: profile,
            token: token,
            mode: mode,
            client: client
        )
        return profile
    }

    func backendSession(for profileID: UUID?) -> BackendSession? {
        guard let profileID else { return nil }
        let configuration: SessionConfiguration
        if profileID == primaryProfile.id {
            configuration = SessionConfiguration(
                profile: primaryProfile,
                token: "test-token",
                mode: backendMode,
                client: client
            )
        } else if let additional = additionalProfiles[profileID] {
            configuration = additional
        } else {
            return nil
        }
        guard let baseURL = configuration.profile.baseURL else { return nil }
        let capabilities = configuration.mode.capabilities
        return BackendSession(
            profile: configuration.profile,
            baseURL: baseURL,
            token: configuration.token,
            mode: configuration.mode,
            visionModels: capabilities?.visionModelIDs,
            toolModels: capabilities?.toolModelIDs,
            reasoningEffortsByModel: capabilities?.reasoningEffortsByID,
            contextLengths: capabilities?.contextLengthByID,
            client: configuration.client,
            thinkingPreferences: [:],
            reasoningEffortPreferences: [:]
        )
    }

    func setDefaultLocationEnabled(_ enabled: Bool) {
        defaultLocationEnabled = enabled
    }

    func requestLocationAuthorizationWhenInUse() {
        requestedLocationAuthorization = true
    }

    func setDefaultHealthEnabled(_ enabled: Bool) {
        defaultHealthEnabled = enabled
    }

    func requestHealthAuthorization() {
        requestedHealthAuthorization = true
    }

    func setDefaultCalendarEnabled(_ enabled: Bool) {
        defaultCalendarEnabled = enabled
    }

    func requestCalendarAuthorization() {
        requestedCalendarAuthorization = true
    }

    func warm(model: String, profileID: UUID) {
        warmedModels.append(model)
    }

    func speak(_ text: String, messageID: UUID) {
        spokenTexts.append(text)
    }

    func indexSearchEmbeddings() {
        searchIndexRequests += 1
    }
}

private final class ScriptedChatClient: ChatClienting, @unchecked Sendable {
    struct Invocation: Sendable {
        var request: ChatRequest
        var base: URL
        var token: String
        var turnID: String?
    }

    struct Cancellation: Sendable {
        var turnID: String
        var base: URL
        var token: String
    }

    struct Script: Sendable {
        var events: [ChatStreamEvent]
        var leadingDelayNanoseconds: UInt64
        var pauseAfterEventNanoseconds: UInt64
        var error: (any Error)?
    }

    private let lock = NSLock()
    private var scripts: [Script] = []
    private var recordedInvocations: [Invocation] = []
    private var recordedCancellations: [Cancellation] = []

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations.map(\.request)
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    var cancellations: [Cancellation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCancellations
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

    func stream(_ request: ChatRequest, base: URL, token: String, turnID: String?)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
    {
        let script = nextScript(
            recording: Invocation(
                request: request,
                base: base,
                token: token,
                turnID: turnID
            )
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if script.leadingDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: script.leadingDelayNanoseconds)
                    }
                    for event in script.events {
                        try Task.checkCancellation()
                        continuation.yield(event)
                        // `.done` is terminal; model generation has already
                        // finished, so do not make consumers wait through an
                        // artificial post-completion delay.
                        if script.pauseAfterEventNanoseconds > 0,
                           event != .done {
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

    func cancel(turnID: String, base: URL, token: String) async {
        lock.lock()
        recordedCancellations.append(
            Cancellation(turnID: turnID, base: base, token: token)
        )
        lock.unlock()
    }

    private func nextScript(recording invocation: Invocation) -> Script {
        lock.lock()
        defer { lock.unlock() }
        recordedInvocations.append(invocation)
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
    private let lock = NSLock()
    private var recordedTrustedBases: [URL] = []

    var trustedBases: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTrustedBases
    }

    init(image: ServerImageRef.CachedImage? = nil) {
        self.image = image
    }

    func fetch(_ url: URL, trustedBase: URL) async -> ServerImageRef.CachedImage? {
        lock.lock()
        recordedTrustedBases.append(trustedBase)
        lock.unlock()
        return image
    }
}
