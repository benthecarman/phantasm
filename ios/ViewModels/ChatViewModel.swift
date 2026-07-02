import Foundation
import Observation
import PhantasmKit
import UIKit

/// Drives one conversation: sends turns, accumulates streamed tokens in memory,
/// and commits a single complete assistant message when the turn ends
/// (buffer-then-commit, NFR-A4 — no per-token disk writes).
///
/// History lives in the SQLite store; the VM owns only the active conversation's
/// mutable metadata (id, title, modelID) and persists through the `ChatStore`
/// protocol. The message list + title in the UI update reactively via GRDBQuery,
/// so the VM never has to hold the rendered messages.
@MainActor
@Observable
final class ChatViewModel {
    private(set) var isStreaming = false
    /// Guards `recoverPendingTurnIfNeeded` against re-entrancy: it's set
    /// synchronously before the async recovery starts (which only flips
    /// `isStreaming` after an `await`), so concurrent foreground hooks can't each
    /// launch a recovery stream for the same turn.
    private var isRecovering = false
    private(set) var streamingText = ""
    private(set) var streamingReasoning = ""
    /// When the in-flight turn began. Seeds the loader's verb and the early
    /// pending-row `createdAt` for ordering; the preview shows no timestamp (that
    /// appears only once the turn completes, restamped to the completion time).
    /// VM-owned (not view `@State`) so it's reset every turn rather than reused by
    /// SwiftUI for the recycled bubble.
    private(set) var streamingStartedAt = Date.now
    private(set) var statusText: String?
    private(set) var statusProgress: Double?
    /// Whether the assistant-preview bubble has content to show. Stored — not
    /// computed from the per-token properties — so views that only need the
    /// coarse fact (the empty-state check) don't re-evaluate on every token.
    /// Maintained at turn transitions: true when a turn starts, false when the
    /// preview is cleared (prompt park, recovery keep, reconcile after commit).
    private(set) var hasAssistantPreview = false
    var errorMessage: String?
    /// A pending interactive app-tool prompt (e.g. `ask_user`'s multiple choice
    /// or a Calendar write confirmation) awaiting the user. Prompt views resolve
    /// it via the answer helpers below. Nil when there's nothing to answer.
    /// Auto-resolved tools (e.g. `current_time`) never set this — they continue
    /// the turn on their own (`resolveToolBatch`).
    private(set) var pendingPrompt: AppToolPrompt?

    private var env: (any ChatViewModelEnvironment)?
    private var store: ChatStore?
    /// The active conversation's metadata (a value, not the stored history). For a
    /// new chat this is an in-memory draft that isn't written until the first send.
    private var conversation: Conversation?
    private var task: Task<Void, Never>?
    private var pendingAssistantMessageID: UUID?
    private var pendingAssistantPreviewMessageID: UUID?
    private var isSceneActive = true
    private var isViewVisible = false
    private var suspendedByScene = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier
    private let backgroundTasks: any BackgroundTaskManaging
    private let notifications: any NotificationManaging
    private let imageFetcher: any ImageFetching

    private enum EmptyPendingDisposition {
        case delete
        case keepForRecovery
    }

    init() {
        self.backgroundTasks = UIApplicationBackgroundTaskManager()
        self.notifications = UserNotificationManager()
        self.imageFetcher = ImageClient()
        self.backgroundTaskID = backgroundTasks.invalidTaskID
    }

    init(
        backgroundTasks: any BackgroundTaskManaging,
        notifications: any NotificationManaging,
        imageFetcher: any ImageFetching
    ) {
        self.backgroundTasks = backgroundTasks
        self.notifications = notifications
        self.imageFetcher = imageFetcher
        self.backgroundTaskID = backgroundTasks.invalidTaskID
    }

    func configure(
        env: any ChatViewModelEnvironment,
        store: ChatStore,
        conversation: Conversation,
        sceneIsActive: Bool
    ) {
        self.env = env
        self.store = store
        self.conversation = conversation
        isSceneActive = sceneIsActive
        if sceneIsActive && isViewVisible {
            recoverPendingTurnIfNeeded()
        }
        healUncachedServerImages()
    }

    func setViewVisible(_ visible: Bool) {
        guard isViewVisible != visible else {
            if visible { recoverPendingTurnIfNeeded() }
            return
        }
        isViewVisible = visible
        if visible {
            recoverPendingTurnIfNeeded()
        }
    }

    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else {
            if active { recoverPendingTurnIfNeeded() }
            return
        }
        isSceneActive = active
        if active {
            endBackgroundStreamingTask()
            recoverPendingTurnIfNeeded()
        } else if isStreaming {
            beginBackgroundStreamingTaskIfNeeded()
        }
    }

    private func beginBackgroundStreamingTaskIfNeeded() {
        guard backgroundTaskID == backgroundTasks.invalidTaskID else { return }
        backgroundTaskID = backgroundTasks.beginBackgroundTask(named: "Chat response") { [weak self] in
            self?.expireBackgroundStreamingTask()
        }
    }

    private func expireBackgroundStreamingTask() {
        guard backgroundTaskID != backgroundTasks.invalidTaskID else { return }
        suspendedByScene = true
        task?.cancel()
        endBackgroundStreamingTask()
    }

    private func endBackgroundStreamingTask() {
        guard backgroundTaskID != backgroundTasks.invalidTaskID else { return }
        let id = backgroundTaskID
        backgroundTaskID = backgroundTasks.invalidTaskID
        backgroundTasks.endBackgroundTask(id)
    }

    /// The model the composer should display / preselect for this conversation.
    var selectedModel: String? { conversation?.modelID }

    /// Per-chat tool selection for the composer's tool menu. Default to on so a
    /// fresh draft mirrors a tools-enabled backend's out-of-the-box behavior.
    var webSearchEnabled: Bool { conversation?.webSearchEnabled ?? true }
    var imageGenerationEnabled: Bool { conversation?.imageGenerationEnabled ?? true }
    /// Per-chat opt-in for the app-hosted location tool. Off by default — it's
    /// privacy-sensitive and triggers a system permission prompt.
    var locationEnabled: Bool { conversation?.locationEnabled ?? false }
    /// Per-chat opt-in for the app-hosted health tool. Off by default — it's
    /// privacy-sensitive and triggers a system permission prompt.
    var healthEnabled: Bool { conversation?.healthEnabled ?? false }
    /// Per-chat opt-in for the app-hosted calendar tool. Off by default — it's
    /// privacy-sensitive and triggers a system permission prompt.
    var calendarEnabled: Bool { conversation?.calendarEnabled ?? false }
    /// The selected research mode for this chat (e.g. `"deep-research"`), or `nil`
    /// for an ordinary turn. It only reaches the wire as a model-id suffix at send
    /// time (redesign §7), gated on the backend advertising it.
    var modeID: String? { conversation?.modeID }

    /// The research modes the active backend advertises whose needed tools are
    /// usable. Empty ⇒ no research UI. Drives the composer's mode picker.
    var availableModes: [Capabilities.Mode] { env?.backendMode.availableModes ?? [] }

    func setWebSearchEnabled(_ on: Bool) {
        setOptions(
            webSearch: on,
            imageGeneration: imageGenerationEnabled,
            location: locationEnabled,
            health: healthEnabled,
            calendar: calendarEnabled,
            modeID: modeID
        )
    }

    func setImageGenerationEnabled(_ on: Bool) {
        setOptions(
            webSearch: webSearchEnabled,
            imageGeneration: on,
            location: locationEnabled,
            health: healthEnabled,
            calendar: calendarEnabled,
            modeID: modeID
        )
    }

    func setLocationEnabled(_ on: Bool) {
        // Surface the iOS permission prompt the moment the user enables the tool,
        // not lazily on the model's first call. No-op once already decided.
        if on { env?.requestLocationAuthorizationWhenInUse() }
        // Remember the choice as the sticky default for future new chats.
        env?.setDefaultLocationEnabled(on)
        setOptions(
            webSearch: webSearchEnabled,
            imageGeneration: imageGenerationEnabled,
            location: on,
            health: healthEnabled,
            calendar: calendarEnabled,
            modeID: modeID
        )
    }

    func setHealthEnabled(_ on: Bool) {
        // Surface the HealthKit permission sheet the moment the user enables the
        // tool, not lazily on the model's first call. No-op once already decided.
        if on { env?.requestHealthAuthorization() }
        // Remember the choice as the sticky default for future new chats.
        env?.setDefaultHealthEnabled(on)
        setOptions(
            webSearch: webSearchEnabled,
            imageGeneration: imageGenerationEnabled,
            location: locationEnabled,
            health: on,
            calendar: calendarEnabled,
            modeID: modeID
        )
    }

    func setCalendarEnabled(_ on: Bool) {
        // Surface the Calendar permission sheet the moment the user enables the
        // tool, not lazily on the model's first call. No-op once already decided.
        if on { env?.requestCalendarAuthorization() }
        // Remember the choice as the sticky default for future new chats.
        env?.setDefaultCalendarEnabled(on)
        setOptions(
            webSearch: webSearchEnabled,
            imageGeneration: imageGenerationEnabled,
            location: locationEnabled,
            health: healthEnabled,
            calendar: on,
            modeID: modeID
        )
    }

    func setModeID(_ modeID: String?) {
        setOptions(
            webSearch: webSearchEnabled,
            imageGeneration: imageGenerationEnabled,
            location: locationEnabled,
            health: healthEnabled,
            calendar: calendarEnabled,
            modeID: modeID
        )
    }

    /// Update the conversation's tool/research selection and persist it. For an
    /// unsent draft the store write is a no-op and the selection rides along on
    /// the first send (the draft is inserted whole), mirroring `setModel`.
    private func setOptions(
        webSearch: Bool, imageGeneration: Bool, location: Bool, health: Bool,
        calendar: Bool, modeID: String?
    ) {
        guard var conversation else { return }
        conversation.webSearchEnabled = webSearch
        conversation.imageGenerationEnabled = imageGeneration
        conversation.locationEnabled = location
        conversation.healthEnabled = health
        conversation.calendarEnabled = calendar
        conversation.modeID = modeID
        self.conversation = conversation
        let id = conversation.id
        Task { [store] in
            try? await store?.setConversationOptions(
                id: id,
                webSearchEnabled: webSearch,
                imageGenerationEnabled: imageGeneration,
                locationEnabled: location,
                healthEnabled: health,
                calendarEnabled: calendar,
                modeID: modeID
            )
        }
    }

    var canSend: Bool {
        // The token is optional for direct no-auth backends such as local Ollama.
        guard let env, env.activeProfile?.baseURL != nil else { return false }
        return !isStreaming
    }

    func shouldShowAssistantPreview(alongside messages: [ChatMessage]) -> Bool {
        guard hasAssistantPreview else { return false }
        guard let pendingAssistantPreviewMessageID else { return true }
        return !messages.contains {
            $0.id == pendingAssistantPreviewMessageID && $0.message.isComplete
        }
    }

    func reconcileAssistantPreview(with messages: [ChatMessage]) {
        guard let pendingAssistantPreviewMessageID,
              messages.contains(where: {
                  $0.id == pendingAssistantPreviewMessageID && $0.message.isComplete
              })
        else { return }
        self.pendingAssistantPreviewMessageID = nil
        streamingText = ""
        streamingReasoning = ""
        statusText = nil
        statusProgress = nil
        hasAssistantPreview = false
    }

    /// Returns whether the text was consumed (a turn started, or it answered a
    /// pending prompt) — the composer clears its draft only then, so a rejected
    /// send (no model yet, backend missing) doesn't eat the typed message.
    @discardableResult
    func send(_ rawText: String, attachments: [PendingAttachment] = []) -> Bool {
        // A typed message while an `ask_user` prompt is pending IS the answer.
        // Prompts that require explicit buttons (Calendar writes) block ordinary
        // sends until the user confirms or cancels in the prompt UI.
        if let pendingPrompt {
            if pendingPrompt.acceptsFreeTextAnswer {
                let answer = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty {
                    answerPendingPrompt(answer)
                    return true
                }
            }
            return false
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), canSend,
              let env, let store, var conversation,
              let base = env.activeProfile?.baseURL else { return false }
        let token = env.activeToken ?? ""

        guard let model = env.backendMode.resolvedChatModel(
            conversationModel: conversation.modelID,
            defaultModel: env.preferredModel
        ) else {
            errorMessage = AppError.modelError(
                "No chat model is selected. Choose a model in Settings or wait for model discovery to finish."
            ).userMessage
            return false
        }

        // Update the conversation's metadata. A new chat's placeholder title is
        // replaced with a snippet of the first message (auto-naming refines it later).
        if conversation.title == "New Chat" {
            conversation.title = text.isEmpty
                ? (attachments.first?.name ?? "New Chat")
                : String(text.prefix(40))
        }
        conversation.modelID = model
        conversation.updatedAt = .now
        self.conversation = conversation

        // Build the user message + attachments (persisted inside the turn task).
        let userMessage = Message(
            conversationId: conversation.id, role: "user", content: text, isComplete: true
        )
        let messageAttachments = attachments.map { pending in
            Attachment(
                messageId: userMessage.id,
                kind: pending.kind,
                name: pending.name,
                data: pending.imageData,
                mimeType: pending.mimeType,
                text: pending.text
            )
        }

        isStreaming = true
        hasAssistantPreview = true
        streamingStartedAt = .now
        streamingText = ""
        streamingReasoning = ""
        statusText = nil
        statusProgress = nil
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        suspendedByScene = false
        errorMessage = nil
        Task { await notifications.requestAuthorizationIfNeeded() }

        let snapshot = conversation
        task = Task { [weak self] in
            await self?.runTurn(
                conversation: snapshot,
                userMessage: userMessage,
                attachments: messageAttachments,
                model: model,
                base: base,
                token: token,
                env: env,
                store: store
            )
        }
        return true
    }

    /// Persist the user turn (lazily creating the conversation), then stream the
    /// assistant reply. The message list updates reactively as rows are written.
    private func runTurn(
        conversation: Conversation,
        userMessage: Message,
        attachments: [Attachment],
        model: String,
        base: URL,
        token: String,
        env: any ChatViewModelEnvironment,
        store: ChatStore
    ) async {
        do {
            // Lazy create (idempotent) + refresh metadata + persist the user message.
            try await store.insertConversation(conversation)
            try await store.updateConversation(
                id: conversation.id, title: conversation.title,
                modelID: model, updatedAt: conversation.updatedAt
            )
            try await store.insertMessage(userMessage, attachments: attachments)
            guard await insertPendingAssistantMessage(
                conversationId: conversation.id,
                store: store
            ) != nil else { return }
            try Task.checkCancellation()
        } catch {
            finishAfterStreamFailure(error)
            return
        }

        await streamReply(
            conversationId: conversation.id, model: model,
            base: base, token: token, env: env, store: store
        )
    }

    /// Re-ask from an edited earlier message (FR-A: edit a previous message).
    /// Truncates the conversation after the edited message, then streams a fresh
    /// reply. The edited message keeps its attachments.
    func resend(afterEditing messageID: UUID, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let ctx = beginTurn() else { return }
        ctx.task { store in try await store.editUserMessage(id: messageID, newContent: text) }
    }

    /// Regenerate an assistant reply (FR-A): drop it and any later messages, then
    /// re-stream from the preceding history.
    func regenerate(messageID: UUID) {
        guard let ctx = beginTurn() else { return }
        ctx.task { store in try await store.deleteMessagesFrom(id: messageID) }
    }

    /// Resend a user message unchanged: keep it, drop everything after it, then
    /// re-stream from the kept history. The message keeps its attachments.
    func resend(messageID: UUID) {
        guard let ctx = beginTurn() else { return }
        ctx.task { store in try await store.deleteMessagesAfter(id: messageID) }
    }

    /// The resolved inputs for a streaming turn, plus a helper that runs a
    /// store mutation and then streams the reply. Shared by `resend`/`regenerate`.
    private struct TurnContext {
        let vm: ChatViewModel
        let convoID: UUID
        let model: String
        let base: URL
        let token: String
        let env: any ChatViewModelEnvironment
        let store: ChatStore

        /// Run `mutate` (truncate/edit the history), then stream a fresh reply.
        @MainActor
        func task(_ mutate: @escaping @Sendable (ChatStore) async throws -> Void) {
            vm.task = Task { [weak vm] in
                guard let vm else { return }
                do {
                    try await mutate(store)
                } catch {
                    vm.finish(error: AppError.from(error))
                    return
                }
                guard await vm.insertPendingAssistantMessage(
                    conversationId: convoID,
                    store: store
                ) != nil else { return }
                if Task.isCancelled {
                    vm.finishAfterStreamFailure(CancellationError())
                    return
                }
                await vm.streamReply(
                    conversationId: convoID, model: model,
                    base: base, token: token, env: env, store: store
                )
            }
        }
    }

    /// Resolve the model/base/token for a new turn and flip the VM into the
    /// streaming state. Surfaces a user-facing error and returns nil if no turn
    /// can start (no backend, already streaming, or no model selected).
    private func beginTurn() -> TurnContext? {
        guard canSend, let env, let store, let conversation,
              let base = env.activeProfile?.baseURL else { return nil }
        guard let model = env.backendMode.resolvedChatModel(
            conversationModel: conversation.modelID,
            defaultModel: env.preferredModel
        ) else {
            errorMessage = AppError.modelError(
                "No chat model is selected. Choose a model in Settings or wait for model discovery to finish."
            ).userMessage
            return nil
        }

        isStreaming = true
        hasAssistantPreview = true
        streamingStartedAt = .now
        streamingText = ""
        streamingReasoning = ""
        statusText = nil
        statusProgress = nil
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        // Resend/regenerate truncates the history, deleting the tool_calls row a
        // parked prompt would answer. A stale prompt answered later would insert
        // a tool row with no matching call — invalid history for strict backends.
        pendingPrompt = nil
        suspendedByScene = false
        errorMessage = nil
        Task { await notifications.requestAuthorizationIfNeeded() }

        return TurnContext(
            vm: self, convoID: conversation.id, model: model,
            base: base, token: env.activeToken ?? "", env: env, store: store
        )
    }

    /// Load the full history (stateless server, XR-2) and stream the assistant
    /// reply, committing it on completion via `finish`. Shared by a normal send
    /// and by re-asking after an edit.
    private func streamReply(
        conversationId: UUID,
        model: String,
        base: URL,
        token: String,
        env: any ChatViewModelEnvironment,
        store: ChatStore
    ) async {
        guard let detail = try? await store.conversationDetail(id: conversationId) else {
            finish(error: .modelError("Could not load the conversation history."))
            return
        }
        // Research is selected by the model id, not a request flag (redesign §2):
        // when this chat has a mode selected AND the backend advertises it AND the
        // base model is tool-capable, the mode rides as a `<base>:<mode>` suffix —
        // resolved server-side. Otherwise the bare base model. This is the only
        // place mode reaches the wire.
        let wireModel = detail.conversation.wireModel(
            base: model,
            availableModes: env.backendMode.availableModes,
            baseModelIsToolCapable: env.supportsTools(model)
        )
        // Scope which server tools this turn may use (spec §2.3). Omitted entirely
        // for backends with no tool manifest, keeping those requests standard.
        // App-hosted tools (e.g. ask_user) ride as full schemas the orchestrator
        // forwards back to us — only against an orchestrator with a tool-capable
        // model (a raw-Ollama backend has nothing to forward through).
        // App-hosted tools resolve entirely on-device, so they ride against any
        // backend that speaks OpenAI function-calling — orchestrator, native
        // Ollama, or a plain OpenAI endpoint — with a tool-capable model.
        // Location and health are gated further by this chat's per-conversation
        // opt-in (both off by default); the always-on app tools (ask_user,
        // current_time) ride unconditionally.
        let appTools = env.supportsTools(model)
            ? AppTools.all.filter { spec in
                switch spec.function.name {
                case ToolName.location: return detail.conversation.locationEnabled
                case ToolName.health: return detail.conversation.healthEnabled
                case ToolName.calendar, ToolName.createCalendarEvent:
                    return detail.conversation.calendarEnabled
                default: return true
                }
            }
            : []
        let request = ChatRequest(
            model: wireModel,
            messages: detail.wireHistory(),
            stream: true,
            reasoningEffort: detail.conversation.reasoningEffort(
                thinkingEnabled: env.thinkingEnabled(for: model),
                disabledEffort: env.disabledReasoningEffortForCurrentBackend()
            ),
            enabledTools: detail.conversation.requestedToolNames(
                supporting: env.backendMode.capabilities?.toolSelectors
            ),
            appTools: appTools
        )
        // The pending assistant message id keys this turn for resume: it's sent as
        // the orchestrator's `Idempotency-Key` and reused verbatim on the recovery
        // resend, so a turn interrupted by backgrounding reconnects to the same
        // server-side turn instead of starting over.
        let turnID = pendingAssistantMessageID?.uuidString
        let stream = env.backendMode.usesOllamaNativeChat
            ? env.ollamaStreamingClient.stream(request, base: base, token: token, turnID: turnID)
            : env.chatStreamingClient.stream(request, base: base, token: token, turnID: turnID)

        // App-hosted tool calls forwarded this turn, captured so the post-stream
        // step can resolve them (the turn ends once the model calls one).
        var batchedCalls: [WireToolCall]?
        // Whether the turn actually finished (a terminal `.done`) versus the
        // stream just ending because the connection dropped — e.g. the app was
        // backgrounded and the local task was cancelled. A cancelled
        // `URLSession.bytes` ends the stream *without throwing*, so this flag, not
        // the catch below, is what tells a real completion from an interruption.
        var sawDone = false
        do {
            for try await event in stream {
                switch event {
                case .token(let t):
                    statusText = nil
                    statusProgress = nil
                    streamingText += t
                case .reasoning(let r):
                    streamingReasoning += r
                case .status(let s):
                    statusText = s
                    statusProgress = nil
                case .progress(let s, let progress):
                    statusText = s
                    statusProgress = progress
                case .toolCalls(let calls):
                    statusText = nil
                    statusProgress = nil
                    batchedCalls = calls
                case .done:
                    sawDone = true
                }
            }
            // The model called app-hosted tools: resolve the batch (auto tools on
            // device, interactive ones via a prompt) and either continue the turn
            // or wait for the user.
            if let calls = batchedCalls, !calls.isEmpty {
                resolveToolBatch(
                    calls, conversationId: conversationId, model: model,
                    base: base, token: token, env: env, store: store
                )
                return
            }
            let backgrounded = !isSceneActive || suspendedByScene || !isViewVisible
            // Interrupted before the turn finished (no `.done`) while in the
            // background: keep the incomplete pending row and resume the turn on
            // foreground. Committing the partial here would drop the rest of the
            // answer (e.g. a still-generating image) AND race recovery, leaving a
            // duplicate. The resumable server turn replays in full on reconnect.
            let interruptedInBackground = !sawDone && backgrounded
            let emptyResponse = streamingText.isEmpty
            if interruptedInBackground || (emptyResponse && backgrounded) {
                suspendedByScene = false
                finish(error: nil, emptyPendingDisposition: .keepForRecovery)
            } else {
                finish(
                    error: emptyResponse
                        ? .modelError("The stream completed without any assistant text.")
                        : nil
                )
            }
        } catch {
            finishAfterStreamFailure(error)
        }
    }

    func recoverPendingTurnIfNeeded() {
        // `isRecovering` is set synchronously here (on the main actor) so the
        // several foreground hooks that all call this — `setSceneActive(true)` and
        // `setViewVisible(true)` fire together when the app returns — can't each
        // start a recovery. Without it, both pass the `!isStreaming` guard before
        // `recoverPendingTurn` flips it (after its `await`), so two streams attach
        // to the same turn and replay into one buffer: the duplicate image and
        // mangled message.
        guard !isStreaming, !isRecovering, isSceneActive, isViewVisible else { return }
        isRecovering = true
        Task { [weak self] in
            await self?.recoverPendingTurn()
            self?.isRecovering = false
        }
    }

    private func recoverPendingTurn() async {
        guard !isStreaming, isSceneActive, isViewVisible,
              let env, let store, let conversation,
              let base = env.activeProfile?.baseURL else { return }
        guard let detail = try? await store.conversationDetail(id: conversation.id) else { return }

        // Restore an unanswered interactive prompt from the active tool-call batch.
        // Its rows are *complete* (the assistant tool_call row + any auto-resolved
        // results already persisted), so the streaming-recovery path below won't
        // catch it. Works for a mixed batch too: the autos are in `answered`, the
        // interactive call isn't, so its prompt comes back up.
        if pendingPrompt == nil, let batch = detail.messages.activeToolCallBatch(),
           let prompt = AppToolRegistry.firstUnansweredPrompt(
               calls: batch.calls, answered: batch.answered
           ) {
            pendingPrompt = prompt
            return
        }

        guard let pending = detail.messages.last,
              pending.message.role == "assistant",
              !pending.message.isComplete else { return }
        // A resumable turn follows either the user's message (a plain turn) or a
        // completed tool-result row (the continuation after an app-tool batch).
        let previous = detail.messages.dropLast().last?.message
        guard let previous, previous.isComplete,
              previous.role == "user" || previous.role == "tool" else { return }
        guard let model = env.backendMode.resolvedChatModel(
            conversationModel: detail.conversation.modelID,
            defaultModel: env.preferredModel
        ) else { return }

        isStreaming = true
        hasAssistantPreview = true
        streamingStartedAt = pending.message.createdAt
        // Start empty: the orchestrator replays the resumed turn from the start
        // (we omit `Last-Event-ID`), so the replayed tokens rebuild the message —
        // preseeding the persisted partial here would double-count them.
        streamingText = ""
        streamingReasoning = ""
        statusText = nil
        statusProgress = nil
        pendingAssistantMessageID = pending.id
        pendingAssistantPreviewMessageID = nil
        errorMessage = nil

        task = Task { [weak self] in
            await self?.streamReply(
                conversationId: conversation.id,
                model: model,
                base: base,
                token: env.activeToken ?? "",
                env: env,
                store: store
            )
        }
    }

    private func finishAfterStreamFailure(_ error: Error) {
        guard isStreaming else { return }
        let appError = AppError.from(error)
        let shouldRecover = appError == .cancelled
            || !isSceneActive
            || suspendedByScene
            || !isViewVisible
        suspendedByScene = false
        finish(
            error: shouldRecover ? nil : appError,
            emptyPendingDisposition: shouldRecover ? .keepForRecovery : .delete
        )
        if shouldRecover, isSceneActive {
            recoverPendingTurnIfNeeded()
        }
    }

    private func insertPendingAssistantMessage(
        conversationId: UUID,
        store: ChatStore
    ) async -> UUID? {
        // stop() may have run while an earlier await was in flight (GRDB writes
        // don't observe Swift cancellation): the VM already finished, so a row
        // inserted now would be an orphan nobody owns — and the recovery path
        // would silently restart the turn the user explicitly stopped.
        guard isStreaming, !Task.isCancelled else { return nil }
        let assistant = Message(
            conversationId: conversationId,
            role: "assistant",
            content: "",
            createdAt: streamingStartedAt,
            isComplete: false
        )
        do {
            try await store.insertMessage(assistant, attachments: [])
            if !isStreaming || Task.isCancelled {
                // stop() raced the insert itself: remove the orphan.
                try? await store.deleteMessage(id: assistant.id)
                return nil
            }
            pendingAssistantMessageID = assistant.id
            return assistant.id
        } catch {
            finish(error: AppError.from(error))
            return nil
        }
    }

    /// Answer a pending `ask_user` prompt: persist the answer as a `tool`-role
    /// result for the forwarded call, then stream the model's continuation.
    func answerPendingPrompt(_ answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pendingPrompt?.acceptsFreeTextAnswer == true else { return }
        completePendingPrompt { text }
    }

    /// Answer a pending Calendar event confirmation. Confirming performs the
    /// EventKit write first and returns the save result to the model; canceling
    /// returns a non-fatal cancellation result.
    func answerPendingCalendarEvent(confirm: Bool) {
        guard case .calendarEvent(let confirmation) = pendingPrompt else { return }
        if confirm {
            completePendingPrompt(status: "adding calendar event…") {
                await AppToolRegistry.createCalendarEvent(confirmation)
            }
        } else {
            completePendingPrompt {
                CalendarCreateEventTool.cancelledResult()
            }
        }
    }

    private func completePendingPrompt(
        status: String? = nil,
        result: @escaping @Sendable () async -> String
    ) {
        guard let prompt = pendingPrompt, !isStreaming,
              let env, let store, let conversation,
              let base = env.activeProfile?.baseURL else { return }
        guard let model = env.backendMode.resolvedChatModel(
            conversationModel: conversation.modelID,
            defaultModel: env.preferredModel
        ) else { return }

        let toolCallId = prompt.toolCallId
        let toolName = prompt.toolName
        pendingPrompt = nil

        isStreaming = true
        hasAssistantPreview = true
        streamingStartedAt = .now
        streamingText = ""
        streamingReasoning = ""
        statusText = status
        statusProgress = nil
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        suspendedByScene = false
        errorMessage = nil
        let token = env.activeToken ?? ""

        task = Task { [weak self] in
            let text = await result()
            if Task.isCancelled {
                self?.finishAfterStreamFailure(CancellationError())
                return
            }
            let toolMessage = Message(
                conversationId: conversation.id,
                role: "tool",
                content: text,
                isComplete: true,
                toolCallId: toolCallId,
                name: toolName
            )
            do {
                try await store.insertMessage(toolMessage, attachments: [])
            } catch {
                self?.finish(error: AppError.from(error))
                return
            }
            // Restamp so the pending row sorts after the tool result just
            // inserted (the async tool work above ran past the turn start).
            self?.streamingStartedAt = .now
            guard await self?.insertPendingAssistantMessage(
                conversationId: conversation.id,
                store: store
            ) != nil else { return }
            if Task.isCancelled {
                self?.finishAfterStreamFailure(CancellationError())
                return
            }
            await self?.streamReply(
                conversationId: conversation.id, model: model,
                base: base, token: token, env: env, store: store
            )
        }
    }

    /// Resolve a forwarded batch of app-tool calls. Commits the calls onto the
    /// assistant row, then handles each in order: an `AutoResolvedTool` answers
    /// on-device and its `tool`-role result is persisted immediately; the first
    /// `InteractiveTool` call becomes the pending prompt (its result is persisted
    /// later, when the user answers). Any extra interactive calls or unknown tools
    /// in the same batch get a "(dismissed)" result so every call is answered
    /// (OpenAI-valid). With no prompt pending — a pure auto batch — the turn
    /// continues automatically; otherwise it parks until the user responds.
    private func resolveToolBatch(
        _ calls: [WireToolCall],
        conversationId: UUID,
        model: String,
        base: URL,
        token: String,
        env: any ChatViewModelEnvironment,
        store: ChatStore
    ) {
        let json = Self.encodeToolCalls(calls)
        let pendingID = pendingAssistantMessageID
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        streamingText = ""
        streamingReasoning = ""

        task = Task { [weak self] in
            // Commit the assistant tool_call row first, so every result that
            // follows is attributed to this batch.
            do {
                if let pendingID {
                    try await store.completeToolCallMessage(id: pendingID, toolCalls: json)
                }
            } catch {
                self?.finish(error: AppError.from(error))
                return
            }

            var prompt: AppToolPrompt?
            for call in calls {
                guard let id = call.id else { continue }
                let result: String?
                switch AppToolRegistry.match(call) {
                case .auto(let tool):
                    self?.statusText = tool.statusText
                    self?.statusProgress = nil
                    result = await tool.resolve(call)
                case .interactive(let tool):
                    if prompt == nil, let raised = tool.prompt(for: call) {
                        prompt = raised
                        continue // the user answers this one later
                    }
                    result = "(dismissed)" // a second interactive call, or unparseable
                case .unknown:
                    result = "(dismissed)"
                }
                if let result {
                    let message = Message(
                        conversationId: conversationId, role: "tool",
                        content: result, isComplete: true,
                        toolCallId: id, name: call.function?.name
                    )
                    do {
                        try await store.insertMessage(message, attachments: [])
                    } catch {
                        self?.finish(error: AppError.from(error))
                        return
                    }
                }
                if Task.isCancelled {
                    self?.finishAfterStreamFailure(CancellationError())
                    return
                }
            }

            // An interactive prompt remains: park the turn and wait for the user.
            if let prompt {
                self?.pendingPrompt = prompt
                self?.enterPromptWait(conversationId: conversationId, store: store)
                return
            }

            // Every call resolved on-device: continue the turn. Restamp the turn
            // clock first: the tool results above were inserted with a later
            // createdAt than the original turn start, and a pending row stamped
            // with the old start would sort before them — breaking ordering and
            // making the recovery guard unable to ever match an interrupted
            // continuation.
            self?.streamingStartedAt = .now
            guard await self?.insertPendingAssistantMessage(
                conversationId: conversationId, store: store
            ) != nil else { return }
            if Task.isCancelled {
                self?.finishAfterStreamFailure(CancellationError())
                return
            }
            await self?.streamReply(
                conversationId: conversationId, model: model,
                base: base, token: token, env: env, store: store
            )
        }
    }

    /// Stop streaming and wait for the user to answer a pending interactive
    /// prompt. The assistant tool_call row and any auto-resolved results are
    /// already committed, so this only parks the streaming state — it commits no
    /// row (unlike `finish`, which would try to flush empty streamed text).
    private func enterPromptWait(conversationId: UUID, store: ChatStore) {
        isStreaming = false
        hasAssistantPreview = false
        statusText = nil
        statusProgress = nil
        task = nil
        streamingText = ""
        streamingReasoning = ""
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        suspendedByScene = false
        Task {
            try? await store.updateConversation(
                id: conversationId, title: nil, modelID: nil, updatedAt: .now
            )
        }
        endBackgroundStreamingTask()
    }

    /// JSON-encode forwarded tool calls for durable storage on the assistant row.
    private static func encodeToolCalls(_ calls: [WireToolCall]) -> String {
        guard let data = try? Wire.encoder().encode(calls),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Stop button (FR-A9): abort the SSE connection; keep whatever streamed.
    func stop() {
        // A resumable turn no longer cancels on disconnect, so explicitly tell the
        // orchestrator to cancel it — freeing server resources and any running
        // image generation immediately rather than letting it finish unseen.
        if let env, let turnID = pendingAssistantMessageID?.uuidString,
           let base = env.activeProfile?.baseURL {
            let token = env.activeToken ?? ""
            let client: any ChatClienting = env.backendMode.usesOllamaNativeChat
                ? env.ollamaStreamingClient
                : env.chatStreamingClient
            Task { await client.cancel(turnID: turnID, base: base, token: token) }
        }
        task?.cancel()
        finish(error: nil, emptyPendingDisposition: .delete)
    }

    func setModel(_ model: String) {
        guard var conversation else { return }
        conversation.modelID = model
        self.conversation = conversation
        env?.warm(model: model)
        let id = conversation.id
        // Persist if the conversation already exists; for an unsent draft this is a
        // no-op and the model rides along on the first send instead.
        Task { [store] in
            try? await store?.updateConversation(id: id, title: nil, modelID: model, updatedAt: nil)
        }
    }

    private func finish(
        error: AppError?,
        emptyPendingDisposition: EmptyPendingDisposition = .delete
    ) {
        guard isStreaming else { return }
        isStreaming = false
        statusText = nil
        statusProgress = nil
        task = nil
        if emptyPendingDisposition != .keepForRecovery {
            suspendedByScene = false
        }

        // Note: app-hosted tool batches don't flow through here — `resolveToolBatch`
        // commits the tool_call row itself and either continues the turn or parks
        // via `enterPromptWait`.

        // Commit any streamed text as one complete assistant message.
        let committed = streamingText
        let committedReasoning = streamingReasoning
        let pendingID = pendingAssistantMessageID
        pendingAssistantMessageID = nil
        let shouldKeepPendingForRecovery = pendingID != nil
            && emptyPendingDisposition == .keepForRecovery
        let shouldNotifyWhenCommitted = !isSceneActive && error == nil
        // Read the reply aloud when the user opted into auto-speak — but only for
        // a clean, foreground completion (don't blast audio in the background).
        let shouldAutoSpeak = error == nil && isSceneActive
            && !committed.isEmpty && env?.autoSpeakEnabled == true

        if shouldKeepPendingForRecovery {
            streamingText = ""
            streamingReasoning = ""
            pendingAssistantPreviewMessageID = nil
            hasAssistantPreview = false
            endBackgroundStreamingTask()
        } else if let store, let conversation, !committed.isEmpty {
            // The preview stays visible (hasAssistantPreview remains true) until
            // the committed row lands and reconcileAssistantPreview clears it.
            if let pendingID {
                pendingAssistantPreviewMessageID = pendingID
                if shouldAutoSpeak { env?.speak(committed, messageID: pendingID) }
                Task { [weak self] in
                    do {
                        try await store.updateMessage(
                            id: pendingID,
                            content: committed,
                            reasoning: committedReasoning,
                            isComplete: true,
                            createdAt: .now
                        )
                        await self?.cacheServerImages(messageID: pendingID, content: committed)
                        try await store.updateConversation(
                            id: conversation.id, title: nil, modelID: nil, updatedAt: .now
                        )
                        if shouldNotifyWhenCommitted {
                            await self?.notifications.scheduleBackgroundCompletion(
                                conversationID: conversation.id
                            )
                        } else {
                            await self?.maybeGenerateTitle()
                        }
                        self?.endBackgroundStreamingTask()
                    } catch {
                        self?.handleAssistantCommitFailure(messageID: pendingID, error: error)
                        self?.endBackgroundStreamingTask()
                    }
                }
            } else {
                let assistant = Message(
                    conversationId: conversation.id, role: "assistant",
                    content: committed, reasoning: committedReasoning,
                    createdAt: .now, isComplete: true
                )
                pendingAssistantPreviewMessageID = assistant.id
                if shouldAutoSpeak { env?.speak(committed, messageID: assistant.id) }
                Task { [weak self] in
                    do {
                        try await store.insertMessage(assistant, attachments: [])
                        await self?.cacheServerImages(messageID: assistant.id, content: committed)
                        try await store.updateConversation(
                            id: conversation.id, title: nil, modelID: nil, updatedAt: .now
                        )
                        if shouldNotifyWhenCommitted {
                            await self?.notifications.scheduleBackgroundCompletion(
                                conversationID: conversation.id
                            )
                        } else {
                            await self?.maybeGenerateTitle()
                        }
                        self?.endBackgroundStreamingTask()
                    } catch {
                        self?.handleAssistantCommitFailure(messageID: assistant.id, error: error)
                        self?.endBackgroundStreamingTask()
                    }
                }
            }
        } else {
            if let store, let pendingID, emptyPendingDisposition == .delete {
                Task { try? await store.deleteMessage(id: pendingID) }
            }
            streamingText = ""
            streamingReasoning = ""
            pendingAssistantPreviewMessageID = nil
            hasAssistantPreview = false
            endBackgroundStreamingTask()
        }

        if let error, error != .cancelled {
            errorMessage = error.userMessage
        }
    }

    private func handleAssistantCommitFailure(messageID: UUID, error: Error) {
        guard pendingAssistantPreviewMessageID == messageID else { return }
        pendingAssistantPreviewMessageID = nil
        streamingText = ""
        streamingReasoning = ""
        hasAssistantPreview = false
        errorMessage = AppError.from(error).userMessage
    }

    /// Fetch and locally cache any server-hosted images the just-committed
    /// assistant message references, so they render offline and survive the
    /// signed URL's expiry (the message keeps the compact reference for re-sent
    /// history). `await`ed on the commit path so it runs under the same
    /// background-task assertion — otherwise a turn that completes as the app
    /// suspends (e.g. an interrupted image edit, recovered on reopen) would lose
    /// the caching to suspension, leaving the image to spin forever after restart.
    private func cacheServerImages(messageID: UUID, content: String) async {
        await cacheServerImages(messageID: messageID, refs: ServerImageRef.references(in: content))
    }

    /// Fetch + persist `refs` as local `remoteImage` attachments on `messageID`.
    /// Best-effort: unreachable refs are skipped. The caller owns the enclosing
    /// `Task` / background assertion.
    private func cacheServerImages(
        messageID: UUID, refs: [(id: String, url: String)]
    ) async {
        guard !refs.isEmpty, let store else { return }
        var attachments: [Attachment] = []
        for ref in refs {
            guard let url = URL(string: ref.url), let img = await imageFetcher.fetch(url) else {
                continue
            }
            attachments.append(
                Attachment(
                    messageId: messageID, kind: .remoteImage, name: ref.id,
                    data: img.data, mimeType: img.mime))
        }
        try? await store.addAttachments(messageID: messageID, attachments: attachments)
    }

    /// Cache any server-hosted images referenced in this conversation that aren't
    /// stored locally yet. Self-heals messages whose commit-time caching was lost
    /// — chiefly an image edit interrupted by backgrounding and recovered on a
    /// later open, where the live caching raced app suspension. Idempotent and
    /// best-effort; runs whenever the conversation is opened.
    private func healUncachedServerImages() {
        guard let store, let conversation else { return }
        let conversationID = conversation.id
        Task { [weak self] in
            guard let detail = try? await store.conversationDetail(id: conversationID) else {
                return
            }
            for cm in detail.messages where cm.message.role == "assistant" {
                let refs = ServerImageRef.references(in: cm.message.content)
                guard !refs.isEmpty else { continue }
                let cached = Set(
                    cm.attachments
                        .filter { $0.kind == AttachmentKind.remoteImage.rawValue }
                        .map(\.name)
                )
                let missing = refs.filter { !cached.contains($0.id) }
                guard !missing.isEmpty else { continue }
                await self?.cacheServerImages(messageID: cm.message.id, refs: missing)
            }
        }
    }

    /// After the very first assistant reply, replace the first-message placeholder
    /// title with a model-generated one (FR: auto-naming). Fire-and-forget.
    private func maybeGenerateTitle() async {
        guard let store, let conversation,
              let detail = try? await store.conversationDetail(id: conversation.id) else { return }
        let assistantReplies = detail.messages.filter { $0.message.role == "assistant" }.count
        guard assistantReplies == 1 else { return }
        await generateTitle(history: detail.wireHistory())
    }

    /// Side-query the model for a short conversation title. Failures leave the
    /// placeholder title in place and never surface to the user.
    private func generateTitle(history: [WireMessage]) async {
        guard let env, let store, let conversation,
              let base = env.activeProfile?.baseURL,
              let model = env.backendMode.resolvedChatModel(
                  conversationModel: conversation.modelID,
                  defaultModel: env.preferredModel
              ) else { return }
        let token = env.activeToken ?? ""
        let client: any ChatClienting = env.backendMode.usesOllamaNativeChat
            ? env.ollamaStreamingClient
            : env.chatStreamingClient
        let request = ChatRequest(
            model: model,
            messages: history + [WireMessage(role: "user", content: Self.titlePrompt)],
            stream: true,
            reasoningEffort: env.disabledReasoningEffortForCurrentBackend()
        )

        guard let raw = try? await client.complete(request, base: base, token: token) else { return }
        let title = Self.sanitizedTitle(raw)
        guard !title.isEmpty else { return }
        // Title only — don't bump updatedAt, so naming doesn't reorder the list.
        guard (try? await store.updateConversation(
            id: conversation.id, title: title, modelID: nil, updatedAt: nil
        )) != nil else { return }
        // Keep the in-memory draft in sync: the next send re-persists
        // conversation.title, and the stale first-message snippet would clobber
        // the generated title in the drawer.
        if self.conversation?.id == conversation.id {
            self.conversation?.title = title
        }
    }

    private static let titlePrompt =
        "Write a short, descriptive title (3-6 words) for this conversation. "
        + "Reply with only the title text — no quotes, no punctuation, no preamble."

    /// Clean up a raw model title: strip quotes/markdown, drop a "Title:" prefix,
    /// collapse to one line, and cap the length.
    static func sanitizedTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = t.split(whereSeparator: \.isNewline).first {
            t = String(firstLine).trimmingCharacters(in: .whitespaces)
        }
        if let range = t.range(of: "title:", options: [.caseInsensitive, .anchored]) {
            t = String(t[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*.# "))
        return String(t.prefix(60))
    }
}
