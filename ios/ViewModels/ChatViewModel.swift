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
    /// Advances once per published stream snapshot. The transcript follows this
    /// cadence instead of separately scrolling for every token/reasoning delta.
    private(set) var streamingRevision = 0
    /// Lossless accumulators are deliberately unobserved: network deltas append
    /// here immediately, while the rendered properties above update at most once
    /// per display frame. `finish` commits these buffers, never the throttled UI.
    @ObservationIgnored private var bufferedStreamingText = ""
    @ObservationIgnored private var bufferedStreamingReasoning = ""
    @ObservationIgnored private var streamPublicationTask: Task<Void, Never>?
    /// Finalized once answer text starts (or the reasoning-only stream ends), so
    /// the collapsed pill can settle before the whole response is committed.
    private(set) var streamingReasoningDuration: TimeInterval?
    /// When the in-flight turn began. Seeds the loader's verb and the early
    /// pending-row `createdAt` for ordering; the preview shows no timestamp (that
    /// appears only once the turn completes, restamped to the completion time).
    /// VM-owned (not view `@State`) so it's reset every turn rather than reused by
    /// SwiftUI for the recycled bubble.
    private(set) var streamingStartedAt = Date.now
    /// Generation speed for the latest clean response: authoritative backend
    /// timing when available, otherwise a local estimate. Updated once at
    /// completion so the full chat view does not re-render for every token.
    private(set) var latestTokensPerSecond: Double?
    private(set) var statusText: String?
    private(set) var statusProgress: Double?
    /// Whether the assistant-preview bubble has content to show. Stored — not
    /// computed from the per-token properties — so views that only need the
    /// coarse fact (the empty-state check) don't re-evaluate on every token.
    /// Maintained at turn transitions: true when a turn starts, false when the
    /// preview is cleared (prompt park, recovery keep, reconcile after commit).
    private(set) var hasAssistantPreview = false
    var errorMessage: String?
    private(set) var isBindingBackend = false
    /// A pending interactive app-tool prompt (e.g. `ask_user`'s multiple choice
    /// or a Calendar write confirmation) awaiting the user. Prompt views resolve
    /// it via the answer helpers below. Nil when there's nothing to answer.
    /// Auto-resolved tools (e.g. `current_time`) never set this — they continue
    /// the turn on their own (`resolveToolBatch`).
    private(set) var pendingPrompt: AppToolPrompt?

    private var env: (any ChatViewModelEnvironment)?
    private var store: ChatStore?
    /// The in-flight assistant row commit from the previous turn's finish. The
    /// next turn's history read awaits it so a fast follow-up send can't load
    /// a history that is missing the last reply.
    private var commitTask: Task<Void, Never>?
    /// Conversation-option/model writes are chained so rapid picker changes
    /// reach storage in the same order as the in-memory selections.
    private var settingsPersistenceTask: Task<Result<Void, AppError>, Never>?
    /// A confirmed interactive-tool result is committed independently from the
    /// cancellable model turn. In particular, stopping while EventKit is saving
    /// must not leave the durable row stuck at an outcome-pending placeholder.
    private var pendingPromptCommitTask: Task<PendingPromptCommitResult, Never>?
    private var pendingPromptCommitID: UUID?
    /// The active conversation's metadata (a value, not the stored history). For a
    /// new chat this is an in-memory draft that isn't written until the first send.
    private var conversation: Conversation?
    private var task: Task<Void, Never>?
    /// Identifies the logical turn allowed to mutate streaming state. A stopped
    /// task can resume from cancellation after a replacement turn starts; every
    /// async continuation carries its generation and must still own the VM.
    private var activeTurnGeneration: UUID?
    /// Retained after a turn finishes so its asynchronous row commit may report
    /// an error, but only until a newer turn supersedes it.
    private var currentTurnGeneration: UUID?
    /// Immutable backend snapshot captured for the active turn (and retained
    /// while an interactive tool prompt is parked). Profile selection changes
    /// elsewhere in the app cannot retarget this work.
    private var turnSession: BackendSession?
    private var startingTurn: StartingTurn?
    private var pendingAssistantMessageID: UUID?
    private var pendingAssistantPreviewMessageID: UUID?
    /// Set while the owner is coordinating a destructive history operation.
    /// It blocks new sends and recovery while the active turn is stopped and
    /// its final row commit drains. If the database delete fails, the owner
    /// clears this state so the existing conversation remains usable.
    private var isPreparingForDeletion = false
    private var isSceneActive = true
    private var isViewVisible = false
    private var suspendedByScene = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier
    private var backgroundTaskGeneration: UUID?
    private let backgroundTasks: any BackgroundTaskManaging
    private let notifications: any NotificationManaging
    private let imageFetcher: any ImageFetching

    private enum EmptyPendingDisposition {
        case delete
        case keepForRecovery
    }

    private enum PendingPromptCommitResult {
        case success
        case failure(AppError)
    }

    private static let pendingPromptOutcomeMarker =
        "(confirmed — outcome pending; do not retry automatically)"

    /// The first writes of a turn (conversation + user message), held until
    /// `runTurn` lands them. GRDB honors Task cancellation, so cancelling the
    /// turn task (stop, background expiry) can kill those writes before the
    /// user's message persists — `finish` re-runs them from an uncancelled
    /// task while this is still set.
    private struct StartingTurn {
        var conversation: Conversation
        var userMessage: Message
        var attachments: [Attachment]
        var model: String
        var store: ChatStore
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
        guard backgroundTaskID == backgroundTasks.invalidTaskID,
              let generation = activeTurnGeneration else { return }
        backgroundTaskGeneration = generation
        backgroundTaskID = backgroundTasks.beginBackgroundTask(named: "Chat response") { [weak self] in
            self?.expireBackgroundStreamingTask()
        }
    }

    private func expireBackgroundStreamingTask() {
        guard backgroundTaskID != backgroundTasks.invalidTaskID,
              let generation = backgroundTaskGeneration,
              ownsTurn(generation) else { return }
        suspendedByScene = true
        task?.cancel()
        endBackgroundStreamingTask(for: generation)
    }

    private func endBackgroundStreamingTask(for generation: UUID? = nil) {
        guard backgroundTaskID != backgroundTasks.invalidTaskID else { return }
        if let generation, backgroundTaskGeneration != generation { return }
        let id = backgroundTaskID
        backgroundTaskID = backgroundTasks.invalidTaskID
        backgroundTaskGeneration = nil
        backgroundTasks.endBackgroundTask(id)
    }

    @discardableResult
    private func activateTurn(session: BackendSession) -> UUID {
        let generation = UUID()
        activeTurnGeneration = generation
        currentTurnGeneration = generation
        turnSession = session
        return generation
    }

    private func ownsTurn(_ generation: UUID) -> Bool {
        activeTurnGeneration == generation
    }

    /// Reset both the lossless accumulator and its rendered snapshot at a turn
    /// boundary. Cancelling the delayed publisher prevents a prior generation
    /// from painting over a replacement turn.
    private func resetStreamingBuffers(status: String? = nil) {
        streamPublicationTask?.cancel()
        streamPublicationTask = nil
        bufferedStreamingText = ""
        bufferedStreamingReasoning = ""
        streamingText = ""
        streamingReasoning = ""
        streamingReasoningDuration = nil
        statusText = status
        statusProgress = nil
        streamingRevision = 0
    }

    /// Schedule one UI publication at roughly 60 Hz. Repeated deltas reuse the
    /// same task, so Markdown parsing and tail scrolling happen once per frame.
    private func scheduleStreamingPublication(generation: UUID) {
        guard streamPublicationTask == nil else { return }
        streamPublicationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 16_666_667)
            } catch {
                return
            }
            guard let self else { return }
            self.streamPublicationTask = nil
            self.publishStreamingBuffers(generation: generation)
        }
    }

    private func publishStreamingBuffers(generation: UUID) {
        guard ownsTurn(generation) else { return }
        guard streamingText != bufferedStreamingText
                || streamingReasoning != bufferedStreamingReasoning else { return }
        streamingText = bufferedStreamingText
        streamingReasoning = bufferedStreamingReasoning
        streamingRevision &+= 1
    }

    /// Terminal events, stop, and failures bypass the cadence delay so the last
    /// buffered characters are visible and committed immediately.
    private func flushStreamingBuffers(generation: UUID) {
        streamPublicationTask?.cancel()
        streamPublicationTask = nil
        publishStreamingBuffers(generation: generation)
    }

    /// The model the composer should display / preselect for this conversation.
    var selectedModel: String? { conversation?.modelID }
    /// The current conversation's backend. Resolution is exact and fails closed
    /// for legacy chats or chats whose profile has been deleted.
    var backendSession: BackendSession? {
        guard let profileID = conversation?.profileID else { return nil }
        return env?.backendSession(for: profileID)
    }

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
    var modeID: String? { conversation?.turnModeID }

    /// The research modes the active backend advertises whose needed tools are
    /// usable. Empty ⇒ no research UI. Drives the composer's mode picker.
    var availableModes: [Capabilities.Mode] {
        backendSession?.mode.availableModes ?? []
    }

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
        let settings = ToolSettings(
            webSearch: webSearch,
            imageGeneration: imageGeneration,
            location: location,
            health: health,
            calendar: calendar
        )
        conversation.toolSettings = settings
        conversation.turnModeID = modeID
        self.conversation = conversation
        let id = conversation.id
        let priorWrite = settingsPersistenceTask
        settingsPersistenceTask = Task { [store] in
            _ = await priorWrite?.value
            guard let store else { return .success(()) }
            do {
                try await store.setConversationOptions(
                    id: id, toolSettings: settings, turnModeID: modeID
                )
                return .success(())
            } catch {
                return .failure(AppError.from(error))
            }
        }
    }

    var canSend: Bool {
        // The token is optional for direct no-auth backends such as local Ollama.
        guard backendSession != nil, !isPreparingForDeletion else { return false }
        return !isStreaming
    }

    /// Bind a legacy/deleted-profile conversation after the user explicitly
    /// chooses where its full history may be sent.
    func bindConversation(to profileID: UUID) {
        guard !isStreaming, !isPreparingForDeletion, !isBindingBackend, let env, let store,
              let conversation,
              env.backendSession(for: profileID) != nil else { return }
        isBindingBackend = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBindingBackend = false }
            do {
                try await store.bindConversation(
                    id: conversation.id,
                    toProfileID: profileID
                )
                guard var current = self.conversation,
                      current.id == conversation.id,
                      env.backendSession(for: profileID) != nil else { return }
                current.profileID = profileID
                current.modelID = nil
                current.turnModeID = nil
                self.conversation = current
            } catch {
                self.errorMessage = AppError.from(error).userMessage
            }
        }
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
        resetStreamingBuffers()
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
              let store, var conversation,
              let session = backendSession else {
            if self.conversation?.profileID == nil || backendSession == nil {
                errorMessage = "Choose a backend before continuing this chat."
            }
            return false
        }

        guard let model = session.resolvedModel(
            conversationModel: conversation.modelID
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
        latestTokensPerSecond = nil
        resetStreamingBuffers()
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        suspendedByScene = false
        errorMessage = nil
        let generation = activateTurn(session: session)
        startingTurn = StartingTurn(
            conversation: conversation,
            userMessage: userMessage,
            attachments: messageAttachments,
            model: model,
            store: store
        )
        Task { await notifications.requestAuthorizationIfNeeded() }

        let snapshot = conversation
        task = Task { [weak self] in
            await self?.runTurn(
                conversation: snapshot,
                userMessage: userMessage,
                attachments: messageAttachments,
                model: model,
                session: session,
                store: store,
                generation: generation
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
        session: BackendSession,
        store: ChatStore,
        generation: UUID
    ) async {
        do {
            // Lazy create (idempotent) + refresh metadata + persist the user
            // message. Idempotent because `finish`'s rescue re-runs it when a
            // cancellation kills these writes mid-flight.
            try await Self.persistStartingTurn(
                conversation: conversation,
                userMessage: userMessage,
                attachments: attachments,
                model: model,
                store: store
            )
            // ID-checked so a stale turn resuming after stop → send can't clear
            // the new turn's snapshot.
            if startingTurn?.userMessage.id == userMessage.id {
                startingTurn = nil
            }
            guard ownsTurn(generation) else { return }
            guard await insertPendingAssistantMessage(
                conversationId: conversation.id,
                store: store,
                generation: generation
            ) != nil else { return }
            try Task.checkCancellation()
        } catch {
            finishAfterStreamFailure(error, generation: generation)
            return
        }

        await streamReply(
            conversationId: conversation.id, model: model,
            session: session, store: store, generation: generation
        )
    }

    private static func persistStartingTurn(
        conversation: Conversation,
        userMessage: Message,
        attachments: [Attachment],
        model: String,
        store: ChatStore
    ) async throws {
        try await store.insertConversation(conversation)
        try await store.updateConversation(
            id: conversation.id, title: conversation.title,
            modelID: model, updatedAt: conversation.updatedAt
        )
        do {
            try await store.insertMessage(userMessage, attachments: attachments)
        } catch {
            // The turn task and `finish`'s rescue can both attempt this
            // insert; the loser hits the unique constraint. Swallow only when
            // the row actually landed — anything else is a real write error.
            guard try await store.hasMessage(id: userMessage.id, in: conversation.id) else {
                throw error
            }
        }
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
        let session: BackendSession
        let store: ChatStore
        let generation: UUID

        /// Run `mutate` (truncate/edit the history), then stream a fresh reply.
        @MainActor
        func task(_ mutate: @escaping @Sendable (ChatStore) async throws -> Void) {
            vm.task = Task { [weak vm] in
                guard let vm else { return }
                do {
                    try await mutate(store)
                } catch {
                    vm.finish(generation: generation, error: AppError.from(error))
                    return
                }
                guard vm.ownsTurn(generation) else { return }
                guard await vm.insertPendingAssistantMessage(
                    conversationId: convoID,
                    store: store,
                    generation: generation
                ) != nil else { return }
                if Task.isCancelled {
                    vm.finishAfterStreamFailure(
                        CancellationError(), generation: generation
                    )
                    return
                }
                await vm.streamReply(
                    conversationId: convoID, model: model,
                    session: session, store: store, generation: generation
                )
            }
        }
    }

    /// Resolve the model/base/token for a new turn and flip the VM into the
    /// streaming state. Surfaces a user-facing error and returns nil if no turn
    /// can start (no backend, already streaming, or no model selected).
    private func beginTurn() -> TurnContext? {
        guard canSend, let store, let conversation,
              let session = backendSession else { return nil }
        guard let model = session.resolvedModel(
            conversationModel: conversation.modelID
        ) else {
            errorMessage = AppError.modelError(
                "No chat model is selected. Choose a model in Settings or wait for model discovery to finish."
            ).userMessage
            return nil
        }

        isStreaming = true
        hasAssistantPreview = true
        streamingStartedAt = .now
        resetStreamingBuffers()
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        // Resend/regenerate truncates the history, deleting the tool_calls row a
        // parked prompt would answer. A stale prompt answered later would insert
        // a tool row with no matching call — invalid history for strict backends.
        pendingPrompt = nil
        suspendedByScene = false
        errorMessage = nil
        let generation = activateTurn(session: session)
        Task { await notifications.requestAuthorizationIfNeeded() }

        return TurnContext(
            vm: self, convoID: conversation.id, model: model,
            session: session, store: store, generation: generation
        )
    }

    /// Load the full history (stateless server, XR-2) and stream the assistant
    /// reply, committing it on completion via `finish`. Shared by a normal send
    /// and by re-asking after an edit.
    private func streamReply(
        conversationId: UUID,
        model: String,
        session: BackendSession,
        store: ChatStore,
        generation: UUID,
        measuresThroughput: Bool = true,
        measuresReasoningDuration: Bool = true
    ) async {
        // Wait for the previous turn's row commit (not its follow-up work) so
        // a fast follow-up send can't read a history missing the last reply.
        await commitTask?.value
        // Tool/mode writes are asynchronous. A send immediately following a
        // picker change must not build its request from the previous persisted
        // selection, especially when the user just disabled a sensitive tool.
        if let settingsResult = await settingsPersistenceTask?.value,
           case .failure(let error) = settingsResult {
            finish(generation: generation, error: error)
            return
        }
        // A stopped Calendar confirmation continues committing independently;
        // never send its temporary idempotency marker to the model.
        if let promptResult = await pendingPromptCommitTask?.value,
           case .failure(let error) = promptResult {
            finish(generation: generation, error: error)
            return
        }
        guard ownsTurn(generation) else { return }
        guard let detail = try? await store.conversationDetail(id: conversationId) else {
            finish(
                generation: generation,
                error: .modelError("Could not load the conversation history.")
            )
            return
        }
        guard ownsTurn(generation) else { return }
        guard !detail.messages.contains(where: {
            $0.message.role == "tool"
                && $0.message.content == Self.pendingPromptOutcomeMarker
        }) else {
            finish(
                generation: generation,
                error: .modelError(
                    "A previously confirmed action has an uncertain outcome. Check the destination before trying it again."
                )
            )
            return
        }
        // Research is selected by the model id, not a request flag (redesign §2):
        // when this chat has a mode selected AND the backend advertises it AND the
        // base model is tool-capable, the mode rides as a `<base>:<mode>` suffix —
        // resolved server-side. Otherwise the bare base model. This is the only
        // place mode reaches the wire.
        let wireModel = detail.conversation.wireModel(
            base: model,
            availableModes: session.mode.availableModes,
            baseModelIsToolCapable: session.supportsTools(model)
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
        let appTools = session.supportsTools(model)
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
            reasoningEffort: session.reasoningEffort(for: model),
            enabledTools: detail.conversation.requestedToolNames(
                supporting: session.mode.capabilities?.toolSelectors
            ),
            appTools: appTools
        )
        // The pending assistant message id keys this turn for resume: it's sent as
        // the orchestrator's `Idempotency-Key` and reused verbatim on the recovery
        // resend, so a turn interrupted by backgrounding reconnects to the same
        // server-side turn instead of starting over.
        let turnID = pendingAssistantMessageID?.uuidString
        let stream = session.client.stream(
            request,
            base: session.baseURL,
            token: session.token,
            turnID: turnID
        )

        // App-hosted tool calls forwarded this turn, captured so the post-stream
        // step can resolve them (the turn ends once the model calls one).
        var batchedCalls: [WireToolCall]?
        var firstAnswerTokenAt: Date?
        var generatedCharacterCount = 0
        var reportedTokensPerSecond: Double?
        var firstReasoningTokenAt: Date?
        // Whether the turn actually finished (a terminal `.done`) versus the
        // stream just ending because the connection dropped — e.g. the app was
        // backgrounded and the local task was cancelled. A cancelled
        // `URLSession.bytes` ends the stream *without throwing*, so this flag, not
        // the catch below, is what tells a real completion from an interruption.
        var sawDone = false
        do {
            for try await event in stream {
                guard ownsTurn(generation) else { return }
                switch event {
                case .token(let t):
                    if statusText != nil { statusText = nil }
                    if statusProgress != nil { statusProgress = nil }
                    if measuresReasoningDuration,
                       streamingReasoningDuration == nil,
                       let firstReasoningTokenAt {
                        streamingReasoningDuration = Date.now.timeIntervalSince(firstReasoningTokenAt)
                    }
                    if firstAnswerTokenAt == nil { firstAnswerTokenAt = .now }
                    generatedCharacterCount += t.count
                    bufferedStreamingText += t
                    scheduleStreamingPublication(generation: generation)
                case .reasoning(let r):
                    if firstReasoningTokenAt == nil { firstReasoningTokenAt = .now }
                    bufferedStreamingReasoning += r
                    scheduleStreamingPublication(generation: generation)
                case .status(let s):
                    statusText = s
                    statusProgress = nil
                case .progress(let s, let progress):
                    statusText = s
                    statusProgress = progress
                case .throughput(let tokensPerSecond):
                    reportedTokensPerSecond = tokensPerSecond
                case .toolCalls(let calls):
                    if statusText != nil { statusText = nil }
                    if statusProgress != nil { statusProgress = nil }
                    batchedCalls = calls
                case .done:
                    sawDone = true
                }
            }
            flushStreamingBuffers(generation: generation)
            // The model called app-hosted tools: resolve the batch (auto tools on
            // device, interactive ones via a prompt) and either continue the turn
            // or wait for the user.
            if sawDone, let calls = batchedCalls, !calls.isEmpty {
                resolveToolBatch(
                    calls, conversationId: conversationId, model: model,
                    session: session, store: store, generation: generation
                )
                return
            }
            guard ownsTurn(generation) else { return }
            let backgrounded = !isSceneActive || suspendedByScene || !isViewVisible
            if sawDone, measuresReasoningDuration,
               streamingReasoningDuration == nil,
               let firstReasoningTokenAt {
                streamingReasoningDuration = Date.now.timeIntervalSince(firstReasoningTokenAt)
            }
            // Interrupted before the turn finished (no `.done`) while in the
            // background: keep the incomplete pending row and resume the turn on
            // foreground. Committing the partial here would drop the rest of the
            // answer (e.g. a still-generating image) AND race recovery, leaving a
            // duplicate. The resumable server turn replays in full on reconnect.
            let interruptedInBackground = !sawDone && backgrounded
            let emptyResponse = bufferedStreamingText.isEmpty
            let reasoningOnlyResponse = sawDone
                && emptyResponse
                && !bufferedStreamingReasoning.isEmpty
            if interruptedInBackground || (emptyResponse && !reasoningOnlyResponse && backgrounded) {
                suspendedByScene = false
                finish(
                    generation: generation,
                    error: nil,
                    emptyPendingDisposition: .keepForRecovery
                )
            } else {
                let completionError: AppError?
                if !sawDone {
                    completionError = .modelError("The connection closed before the response finished.")
                } else if reasoningOnlyResponse {
                    completionError = .modelError("The model produced thinking but no answer.")
                } else if emptyResponse {
                    completionError = .modelError("The stream completed without any assistant text.")
                } else {
                    completionError = nil
                }
                if completionError == nil, measuresThroughput {
                    latestTokensPerSecond = reportedTokensPerSecond
                        ?? firstAnswerTokenAt.flatMap {
                            ContextWindow.estimatedTokensPerSecond(
                                characterCount: generatedCharacterCount,
                                duration: Date.now.timeIntervalSince($0)
                            )
                        }
                }
                finish(generation: generation, error: completionError)
            }
        } catch {
            finishAfterStreamFailure(error, generation: generation)
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
        guard !isStreaming, !isRecovering, !isPreparingForDeletion,
              isSceneActive, isViewVisible else { return }
        isRecovering = true
        Task { [weak self] in
            await self?.recoverPendingTurn()
            self?.isRecovering = false
        }
    }

    private func recoverPendingTurn() async {
        guard !isStreaming, !isPreparingForDeletion, isSceneActive, isViewVisible,
              let store, let conversation,
              let session = backendSession else { return }
        // A commit from the just-finished turn may still be landing; reading
        // before it does would mistake the not-yet-completed row for a
        // resumable turn and stream it a second time.
        await commitTask?.value
        guard !isStreaming, !isPreparingForDeletion else { return }
        guard let detail = try? await store.conversationDetail(
            id: conversation.id,
            attachmentData: .metadataOnly
        ) else { return }
        // A send may have started while either awaited read was in flight. Its
        // generation owns the VM now, so abandon this stale recovery attempt.
        guard !isStreaming, !isPreparingForDeletion else { return }

        // Restore an unanswered interactive prompt from the active tool-call batch.
        // Its rows are *complete* (the assistant tool_call row + any auto-resolved
        // results already persisted), so the streaming-recovery path below won't
        // catch it. Works for a mixed batch too: the autos are in `answered`, the
        // interactive call isn't, so its prompt comes back up.
        if pendingPrompt == nil, let batch = detail.messages.activeToolCallBatch(),
           let prompt = AppToolRegistry.firstUnansweredPrompt(
               calls: batch.calls, answered: batch.answered
           ) {
            _ = activateTurn(session: session)
            pendingPrompt = prompt
            return
        }

        // The app may have been suspended or stopped after a confirmed prompt's
        // result row committed but before its continuation row was inserted.
        // Resume a fully answered batch explicitly. A surviving outcome marker
        // is intentionally *not* resumed: after process death its side effect is
        // uncertain and must never be retried automatically.
        if let batch = detail.messages.activeToolCallBatch(),
           batch.calls.allSatisfy({ call in
               guard let id = call.id else { return false }
               return batch.answered.contains(id)
           }),
           let last = detail.messages.last?.message,
           last.role == "tool" {
            if last.content == Self.pendingPromptOutcomeMarker {
                errorMessage = pendingPromptCommitTask == nil
                    ? "A previously confirmed action has an uncertain outcome. Check the destination before trying it again."
                    : "The confirmed action is still being finalized."
                return
            }
            guard let model = session.resolvedModel(
                conversationModel: detail.conversation.modelID
            ) else { return }
            isStreaming = true
            hasAssistantPreview = true
            streamingStartedAt = .now
            resetStreamingBuffers()
            pendingAssistantMessageID = nil
            pendingAssistantPreviewMessageID = nil
            errorMessage = nil
            let generation = activateTurn(session: session)
            task = Task { [weak self] in
                guard let self else { return }
                guard await self.insertPendingAssistantMessage(
                    conversationId: conversation.id,
                    store: store,
                    generation: generation
                ) != nil else { return }
                await self.streamReply(
                    conversationId: conversation.id,
                    model: model,
                    session: session,
                    store: store,
                    generation: generation
                )
            }
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
        guard let model = session.resolvedModel(
            conversationModel: detail.conversation.modelID
        ) else { return }

        isStreaming = true
        hasAssistantPreview = true
        streamingStartedAt = pending.message.createdAt
        // Start empty: the orchestrator replays the resumed turn from the start
        // (we omit `Last-Event-ID`), so the replayed tokens rebuild the message —
        // preseeding the persisted partial here would double-count them.
        resetStreamingBuffers()
        pendingAssistantMessageID = pending.id
        pendingAssistantPreviewMessageID = nil
        errorMessage = nil
        let generation = activateTurn(session: session)
        task = Task { [weak self] in
            await self?.streamReply(
                conversationId: conversation.id,
                model: model,
                session: session,
                store: store,
                generation: generation,
                measuresThroughput: false,
                measuresReasoningDuration: false
            )
        }
    }

    private func finishAfterStreamFailure(_ error: Error, generation: UUID) {
        guard isStreaming, ownsTurn(generation) else { return }
        let appError = AppError.from(error)
        let shouldRecover = appError == .cancelled
            || !isSceneActive
            || suspendedByScene
            || !isViewVisible
        suspendedByScene = false
        finish(
            generation: generation,
            error: shouldRecover ? nil : appError,
            emptyPendingDisposition: shouldRecover ? .keepForRecovery : .delete
        )
        if shouldRecover, isSceneActive {
            recoverPendingTurnIfNeeded()
        }
    }

    private func insertPendingAssistantMessage(
        conversationId: UUID,
        store: ChatStore,
        generation: UUID
    ) async -> UUID? {
        // stop() may have run while an earlier await was in flight: the VM
        // already finished, so a row inserted now would be an orphan nobody
        // owns — and the recovery path would silently restart the turn the
        // user explicitly stopped.
        guard isStreaming, ownsTurn(generation), !Task.isCancelled else { return nil }
        let assistant = Message(
            conversationId: conversationId,
            role: "assistant",
            content: "",
            createdAt: streamingStartedAt,
            isComplete: false
        )
        do {
            try await store.insertMessage(assistant, attachments: [])
            if !isStreaming || !ownsTurn(generation) || Task.isCancelled {
                // stop() raced the insert itself: remove the orphan.
                try? await store.deleteMessage(id: assistant.id)
                return nil
            }
            pendingAssistantMessageID = assistant.id
            return assistant.id
        } catch {
            finish(generation: generation, error: AppError.from(error))
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
        guard let prompt = pendingPrompt, !isStreaming, !isPreparingForDeletion,
              let store, let conversation,
              let session = turnSession ?? backendSession else { return }
        let generation = activeTurnGeneration ?? activateTurn(session: session)
        guard ownsTurn(generation) else { return }
        guard let model = session.resolvedModel(
            conversationModel: conversation.modelID
        ) else { return }

        let toolCallId = prompt.toolCallId
        let toolName = prompt.toolName
        pendingPrompt = nil

        isStreaming = true
        hasAssistantPreview = true
        streamingStartedAt = .now
        resetStreamingBuffers(status: status)
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        suspendedByScene = false
        errorMessage = nil
        turnSession = session

        // This task is deliberately separate from `task`: stop/background
        // cancellation revokes model-turn ownership but must not cancel a
        // Calendar write after the user confirmed it. It owns the full durable
        // sequence — marker first, side effect second, actual outcome last.
        let commitID = UUID()
        let outcomeCommit = Task { () -> PendingPromptCommitResult in
            let toolMessage = Message(
                conversationId: conversation.id,
                role: "tool",
                content: Self.pendingPromptOutcomeMarker,
                isComplete: true,
                toolCallId: toolCallId,
                name: toolName
            )
            do {
                try await store.insertMessage(toolMessage, attachments: [])
            } catch {
                return .failure(AppError.from(error))
            }
            let text = await result()
            do {
                try await store.updateMessage(
                    id: toolMessage.id, content: text, reasoning: "",
                    isComplete: true, createdAt: nil
                )
            } catch {
                // The pre-effect placeholder is the durable idempotency marker:
                // recovery treats the call as answered and never repeats the
                // potentially non-idempotent Calendar write. Do not let the
                // model continue with that placeholder as though it were the
                // actual outcome.
                return .failure(AppError.from(error))
            }
            return .success
        }
        pendingPromptCommitTask = outcomeCommit
        pendingPromptCommitID = commitID

        task = Task { [weak self] in
            let outcome = await outcomeCommit.value
            guard let self else { return }
            if self.pendingPromptCommitID == commitID {
                self.pendingPromptCommitTask = nil
                self.pendingPromptCommitID = nil
            }
            guard self.ownsTurn(generation) else { return }
            if case .failure(let error) = outcome {
                self.finish(generation: generation, error: error)
                return
            }
            if Task.isCancelled {
                self.finishAfterStreamFailure(
                    CancellationError(), generation: generation
                )
                return
            }
            // Restamp so the pending row sorts after the tool result just
            // inserted (the async tool work above ran past the turn start).
            self.streamingStartedAt = .now
            guard await self.insertPendingAssistantMessage(
                conversationId: conversation.id,
                store: store,
                generation: generation
            ) != nil else { return }
            if Task.isCancelled {
                self.finishAfterStreamFailure(
                    CancellationError(), generation: generation
                )
                return
            }
            await self.streamReply(
                conversationId: conversation.id, model: model,
                session: session, store: store, generation: generation
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
        session: BackendSession,
        store: ChatStore,
        generation: UUID
    ) {
        guard ownsTurn(generation) else { return }
        let json = Self.encodeToolCalls(calls)
        let pendingID = pendingAssistantMessageID
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        // Any text already streamed this turn (e.g. an image a server tool
        // generated in an earlier iteration, flushed ahead of the batch) belongs
        // to this row — commit it, or it vanishes from history and the model's
        // context on resume.
        let streamedContent = bufferedStreamingText
        resetStreamingBuffers()

        task = Task { [weak self] in
            // Commit the assistant tool_call row first, so every result that
            // follows is attributed to this batch.
            do {
                if let pendingID {
                    try await store.completeToolCallMessage(
                        id: pendingID, toolCalls: json, content: streamedContent
                    )
                }
            } catch {
                self?.finish(generation: generation, error: AppError.from(error))
                return
            }
            guard self?.ownsTurn(generation) == true else { return }

            var prompt: AppToolPrompt?
            for call in calls {
                guard self?.ownsTurn(generation) == true else { return }
                guard let id = call.id else { continue }
                let result: String?
                switch AppToolRegistry.match(call) {
                case .auto(let tool):
                    self?.statusText = tool.statusText
                    self?.statusProgress = nil
                    result = await tool.resolve(call)
                    guard self?.ownsTurn(generation) == true else { return }
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
                        self?.finish(generation: generation, error: AppError.from(error))
                        return
                    }
                    guard self?.ownsTurn(generation) == true else { return }
                }
                if Task.isCancelled {
                    self?.finishAfterStreamFailure(
                        CancellationError(), generation: generation
                    )
                    return
                }
            }

            // An interactive prompt remains: park the turn and wait for the user.
            if let prompt {
                guard self?.ownsTurn(generation) == true else { return }
                self?.pendingPrompt = prompt
                self?.enterPromptWait(
                    conversationId: conversationId,
                    store: store,
                    generation: generation
                )
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
                conversationId: conversationId,
                store: store,
                generation: generation
            ) != nil else { return }
            if Task.isCancelled {
                self?.finishAfterStreamFailure(
                    CancellationError(), generation: generation
                )
                return
            }
            await self?.streamReply(
                conversationId: conversationId, model: model,
                session: session, store: store, generation: generation
            )
        }
    }

    /// Stop streaming and wait for the user to answer a pending interactive
    /// prompt. The assistant tool_call row and any auto-resolved results are
    /// already committed, so this only parks the streaming state — it commits no
    /// row (unlike `finish`, which would try to flush empty streamed text).
    private func enterPromptWait(
        conversationId: UUID,
        store: ChatStore,
        generation: UUID
    ) {
        guard ownsTurn(generation) else { return }
        isStreaming = false
        hasAssistantPreview = false
        statusText = nil
        statusProgress = nil
        task = nil
        resetStreamingBuffers()
        pendingAssistantMessageID = nil
        pendingAssistantPreviewMessageID = nil
        suspendedByScene = false
        Task {
            try? await store.updateConversation(
                id: conversationId, title: nil, modelID: nil, updatedAt: .now
            )
        }
        endBackgroundStreamingTask(for: generation)
    }

    /// JSON-encode forwarded tool calls for durable storage on the assistant row.
    private static func encodeToolCalls(_ calls: [WireToolCall]) -> String {
        guard let data = try? Wire.encoder().encode(calls),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Stop button (FR-A9): abort the SSE connection; keep whatever streamed.
    func stop() {
        guard let generation = activeTurnGeneration, isStreaming else { return }
        // A resumable turn no longer cancels on disconnect, so explicitly tell the
        // orchestrator to cancel it — freeing server resources and any running
        // image generation immediately rather than letting it finish unseen.
        if let session = turnSession,
           let turnID = pendingAssistantMessageID?.uuidString {
            Task {
                await session.client.cancel(
                    turnID: turnID,
                    base: session.baseURL,
                    token: session.token
                )
            }
        }
        let stoppedTask = task
        // Revoke ownership before delivering cancellation. The cancelled task
        // may resume after another send starts, but it can no longer finish or
        // mutate that replacement turn.
        finish(
            generation: generation,
            error: nil,
            emptyPendingDisposition: .delete
        )
        stoppedTask?.cancel()
    }

    /// Stop work that could write this conversation, then wait for both the
    /// turn task and the commit it schedules. The database row must not be
    /// deleted until this returns: `stop()` deliberately rescues a user message
    /// or commits buffered assistant text from an uncancelled task.
    func prepareForDeletion() async {
        beginPreparingForDeletion()

        // Capture before stop(), which clears `task` synchronously in finish().
        let runningTask = task
        if isStreaming {
            stop()
        } else {
            // A task can be finishing the transition into a parked prompt even
            // after `isStreaming` was cleared. Revoking its generation prevents
            // any continuation from starting more work.
            activeTurnGeneration = nil
            runningTask?.cancel()
            task = nil
        }

        runningTask?.cancel()
        await runningTask?.value
        // A confirmed Calendar side effect is cancellation-independent. Keep
        // the conversation alive until its actual outcome is durably recorded.
        _ = await pendingPromptCommitTask?.value
        // stop() may have replaced the prior commit with a chained rescue, so
        // read the property only after the turn task has fully unwound.
        await commitTask?.value
    }

    /// Synchronous half of deletion preparation. The cache calls this when a
    /// model is created while a delete is already pending, before configure()
    /// can launch recovery work for it.
    func beginPreparingForDeletion() {
        isPreparingForDeletion = true
    }

    /// Restore normal interaction when the coordinated database deletion
    /// failed. A stopped turn stays stopped, but the preserved conversation can
    /// be sent to again and any durable pending turn can recover normally.
    func resumeAfterFailedDeletion() {
        guard isPreparingForDeletion else { return }
        isPreparingForDeletion = false
        recoverPendingTurnIfNeeded()
    }

    func setModel(_ model: String) {
        guard var conversation else { return }
        conversation.modelID = model
        self.conversation = conversation
        if let profileID = conversation.profileID {
            env?.warm(model: model, profileID: profileID)
        }
        let id = conversation.id
        // Persist if the conversation already exists; for an unsent draft this is a
        // no-op and the model rides along on the first send instead.
        let priorWrite = settingsPersistenceTask
        settingsPersistenceTask = Task { [store] in
            _ = await priorWrite?.value
            guard let store else { return .success(()) }
            do {
                try await store.updateConversation(
                    id: id, title: nil, modelID: model, updatedAt: nil
                )
                return .success(())
            } catch {
                return .failure(AppError.from(error))
            }
        }
    }

    private func finish(
        generation: UUID,
        error: AppError?,
        emptyPendingDisposition: EmptyPendingDisposition = .delete
    ) {
        guard isStreaming, ownsTurn(generation) else { return }
        flushStreamingBuffers(generation: generation)
        isStreaming = false
        activeTurnGeneration = nil
        let completedSession = turnSession
        turnSession = nil
        statusText = nil
        statusProgress = nil
        task = nil
        // Rescue an unpersisted user turn: cancelling the turn task (stop, or
        // the background task expiring) makes its in-flight GRDB writes throw
        // before the user's message lands. Re-run the idempotent persist from
        // an uncancelled task, chained onto `commitTask` so a fast follow-up
        // send (and recovery) reads a history that includes the message.
        if let startingTurn {
            self.startingTurn = nil
            let priorCommit = commitTask
            commitTask = Task { [weak self] in
                await priorCommit?.value
                do {
                    try await Self.persistStartingTurn(
                        conversation: startingTurn.conversation,
                        userMessage: startingTurn.userMessage,
                        attachments: startingTurn.attachments,
                        model: startingTurn.model,
                        store: startingTurn.store
                    )
                } catch {
                    guard self?.currentTurnGeneration == generation else { return }
                    self?.errorMessage = AppError.from(error).userMessage
                }
            }
        }
        if emptyPendingDisposition != .keepForRecovery {
            suspendedByScene = false
        }

        // Note: app-hosted tool batches don't flow through here — `resolveToolBatch`
        // commits the tool_call row itself and either continues the turn or parks
        // via `enterPromptWait`.

        // Commit any streamed text as one complete assistant message.
        let committed = bufferedStreamingText
        let committedReasoning = bufferedStreamingReasoning
        let committedReasoningDuration = streamingReasoningDuration
        let hasAssistantPayload = !committed.isEmpty || !committedReasoning.isEmpty
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
            resetStreamingBuffers()
            pendingAssistantPreviewMessageID = nil
            hasAssistantPreview = false
            endBackgroundStreamingTask(for: generation)
        } else if let store, let conversation, hasAssistantPayload {
            // The preview stays visible (hasAssistantPreview remains true) until
            // the committed row lands and reconcileAssistantPreview clears it.
            if let pendingID {
                pendingAssistantPreviewMessageID = pendingID
                if shouldAutoSpeak { env?.speak(committed, messageID: pendingID) }
                commitAssistantMessage(
                    store: store,
                    conversationID: conversation.id,
                    messageID: pendingID,
                    content: committed,
                    notifyInBackground: shouldNotifyWhenCommitted,
                    isCleanCompletion: error == nil,
                    session: completedSession,
                    generation: generation
                ) {
                    try await store.updateMessage(
                        id: pendingID,
                        content: committed,
                        reasoning: committedReasoning,
                        reasoningDuration: committedReasoningDuration,
                        isComplete: true,
                        createdAt: .now
                    )
                }
            } else {
                let assistant = Message(
                    conversationId: conversation.id, role: "assistant",
                    content: committed, reasoning: committedReasoning,
                    reasoningDuration: committedReasoningDuration,
                    createdAt: .now, isComplete: true
                )
                pendingAssistantPreviewMessageID = assistant.id
                if shouldAutoSpeak { env?.speak(committed, messageID: assistant.id) }
                commitAssistantMessage(
                    store: store,
                    conversationID: conversation.id,
                    messageID: assistant.id,
                    content: committed,
                    notifyInBackground: shouldNotifyWhenCommitted,
                    isCleanCompletion: error == nil,
                    session: completedSession,
                    generation: generation
                ) {
                    try await store.insertMessage(assistant, attachments: [])
                }
            }
        } else {
            if let store, let pendingID, emptyPendingDisposition == .delete {
                Task { try? await store.deleteMessage(id: pendingID) }
            }
            resetStreamingBuffers()
            pendingAssistantPreviewMessageID = nil
            hasAssistantPreview = false
            endBackgroundStreamingTask(for: generation)
        }

        if let error, error != .cancelled {
            errorMessage = error.userMessage
        }
    }

    /// Commit the finished assistant message. The row write itself is tracked
    /// as `commitTask` so the next turn's history read can await it — without
    /// also waiting on the network-bound follow-ups (image caching, title
    /// generation), which run after the row lands.
    private func commitAssistantMessage(
        store: ChatStore,
        conversationID: UUID,
        messageID: UUID,
        content: String,
        notifyInBackground: Bool,
        isCleanCompletion: Bool,
        session: BackendSession?,
        generation: UUID,
        write: @escaping @Sendable () async throws -> Void
    ) {
        let rowCommit = Task { [weak self] () -> Bool in
            do {
                try await write()
                return true
            } catch {
                self?.handleAssistantCommitFailure(
                    messageID: messageID,
                    generation: generation,
                    error: error
                )
                self?.endBackgroundStreamingTask(for: generation)
                return false
            }
        }
        commitTask = Task { _ = await rowCommit.value }
        Task { [weak self] in
            guard await rowCommit.value else { return }
            // New rows for the semantic search index (fire-and-forget).
            self?.env?.indexSearchEmbeddings()
            if let session {
                await self?.cacheServerImages(
                    messageID: messageID,
                    content: content,
                    session: session
                )
            }
            try? await store.updateConversation(
                id: conversationID, title: nil, modelID: nil, updatedAt: .now
            )
            if notifyInBackground {
                await self?.notifications.scheduleBackgroundCompletion(
                    conversationID: conversationID
                )
            } else if isCleanCompletion && !content.isEmpty {
                await self?.maybeGenerateTitle(session: session)
            }
            self?.endBackgroundStreamingTask(for: generation)
        }
    }

    private func handleAssistantCommitFailure(
        messageID: UUID,
        generation: UUID,
        error: Error
    ) {
        guard currentTurnGeneration == generation,
              pendingAssistantPreviewMessageID == messageID else { return }
        pendingAssistantPreviewMessageID = nil
        resetStreamingBuffers()
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
    private func cacheServerImages(
        messageID: UUID,
        content: String,
        session: BackendSession
    ) async {
        await cacheServerImages(
            messageID: messageID,
            refs: ServerImageRef.references(in: content),
            session: session
        )
    }

    /// Fetch + persist `refs` as local `remoteImage` attachments on `messageID`.
    /// Best-effort: unreachable refs are skipped. The caller owns the enclosing
    /// `Task` / background assertion.
    private func cacheServerImages(
        messageID: UUID,
        refs: [(id: String, url: String)],
        session: BackendSession
    ) async {
        guard !refs.isEmpty, let store else { return }
        var attachments: [Attachment] = []
        for ref in refs {
            guard let url = URL(string: ref.url),
                  let img = await imageFetcher.fetch(
                      url,
                      trustedBase: session.trustedMediaBaseURL
                  ) else {
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
        guard let store, let conversation,
              let session = backendSession else { return }
        let conversationID = conversation.id
        Task { [weak self] in
            guard let detail = try? await store.conversationDetail(
                id: conversationID,
                attachmentData: .metadataOnly
            ) else {
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
                await self?.cacheServerImages(
                    messageID: cm.message.id,
                    refs: missing,
                    session: session
                )
            }
        }
    }

    /// After the very first assistant reply, replace the first-message placeholder
    /// title with a model-generated one (FR: auto-naming). Fire-and-forget.
    private func maybeGenerateTitle(session: BackendSession?) async {
        guard let session else { return }
        guard let store, let conversation,
              let detail = try? await store.conversationDetail(
                  id: conversation.id,
                  attachmentData: .metadataOnly
              ) else { return }
        let assistantReplies = detail.messages.filter { $0.message.role == "assistant" }.count
        guard assistantReplies == 1 else { return }
        await generateTitle(
            history: Self.titleHistory(from: detail.messages),
            session: session
        )
    }

    /// Side-query the model for a short conversation title. Failures leave the
    /// placeholder title in place and never surface to the user.
    private func generateTitle(
        history: [WireMessage],
        session: BackendSession
    ) async {
        guard let store, let conversation,
              let model = session.resolvedModel(
                  conversationModel: conversation.modelID
              ) else { return }
        let reasoningEffort = session.reasoningEffort(for: model)
        let titleMessages = history + [WireMessage(role: "user", content: Self.titlePrompt)]

        func complete(reasoningEffort: String?) async throws -> String {
            let request = ChatRequest(
                model: model,
                messages: titleMessages,
                stream: true,
                reasoningEffort: reasoningEffort
            )
            return try await session.client.complete(
                request,
                base: session.baseURL,
                token: session.token
            )
        }

        let raw: String
        do {
            raw = try await complete(reasoningEffort: reasoningEffort)
        } catch {
            guard reasoningEffort != nil,
                  let retried = try? await complete(reasoningEffort: nil)
            else { return }
            raw = retried
        }
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

    /// A deliberately small, text-only synopsis for the title side-query.
    /// Building this from persisted content (rather than `wireHistory`) avoids
    /// restoring inline images or encoding photo attachments to base64 only to
    /// discard them before the model names the chat.
    private static func titleHistory(from history: [ChatMessage]) -> [WireMessage] {
        let perMessageLimit = 2_000
        var remaining = 4_000
        var result: [WireMessage] = []

        for item in history where item.message.isComplete && remaining > 0 {
            let message = item.message
            guard message.role == "user" || message.role == "assistant" else { continue }
            let plain = SpeakableText.plainText(
                from: message.content.strippingThinkingBlocks()
            )
            guard !plain.isEmpty else { continue }
            let text = String(plain.prefix(min(perMessageLimit, remaining)))
            result.append(WireMessage(role: message.role, content: text))
            remaining -= text.count
        }
        return result
    }

    /// Clean up a raw model title: strip quotes/markdown, drop a "Title:" prefix,
    /// collapse to one line, and cap the length.
    static func sanitizedTitle(_ raw: String) -> String {
        var t = raw.strippingThinkingBlocks().trimmingCharacters(in: .whitespacesAndNewlines)
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

private extension String {
    func strippingThinkingBlocks() -> String {
        var stripped = replacingOccurrences(
            of: #"(?is)<think\b[^>]*>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
        if let range = stripped.range(of: "<think", options: .caseInsensitive) {
            stripped = String(stripped[..<range.lowerBound])
        }
        return stripped
    }
}

private extension ChatStore {
    /// Membership check used only when `insertMessage` fails, to tell a benign
    /// duplicate-key race from a real write error. Metadata is sufficient; no
    /// attachment payloads are materialized for this recovery check.
    func hasMessage(id: UUID, in conversationID: UUID) async throws -> Bool {
        let detail = try await conversationDetail(
            id: conversationID,
            attachmentData: .metadataOnly
        )
        return detail?.messages.contains { $0.message.id == id } == true
    }
}
