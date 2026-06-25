import Foundation
import Observation
import PhantasmKit

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
    private(set) var streamingText = ""
    private(set) var streamingReasoning = ""
    private(set) var statusText: String?
    var errorMessage: String?

    private var env: AppEnvironment?
    private var store: ChatStore?
    /// The active conversation's metadata (a value, not the stored history). For a
    /// new chat this is an in-memory draft that isn't written until the first send.
    private var conversation: Conversation?
    private var task: Task<Void, Never>?
    private var pendingAssistantPreviewMessageID: UUID?

    func configure(env: AppEnvironment, store: ChatStore, conversation: Conversation) {
        self.env = env
        self.store = store
        self.conversation = conversation
    }

    /// The model the composer should display / preselect for this conversation.
    var selectedModel: String? { conversation?.modelID }

    /// Per-chat tool selection for the composer's tool menu. Default to on so a
    /// fresh draft mirrors a tools-enabled backend's out-of-the-box behavior.
    var webSearchEnabled: Bool { conversation?.webSearchEnabled ?? true }
    var imageGenerationEnabled: Bool { conversation?.imageGenerationEnabled ?? true }
    /// Deep Research is off by default — a deliberate, slower mode.
    var deepResearchEnabled: Bool { conversation?.deepResearchEnabled ?? false }

    func setWebSearchEnabled(_ on: Bool) {
        setTools(
            webSearch: on,
            imageGeneration: imageGenerationEnabled,
            deepResearch: deepResearchEnabled
        )
    }

    func setImageGenerationEnabled(_ on: Bool) {
        setTools(
            webSearch: webSearchEnabled,
            imageGeneration: on,
            deepResearch: deepResearchEnabled
        )
    }

    func setDeepResearchEnabled(_ on: Bool) {
        setTools(
            webSearch: webSearchEnabled,
            imageGeneration: imageGenerationEnabled,
            deepResearch: on
        )
    }

    /// Update the conversation's tool/research selection and persist it. For an
    /// unsent draft the store write is a no-op and the selection rides along on
    /// the first send (the draft is inserted whole), mirroring `setModel`.
    private func setTools(webSearch: Bool, imageGeneration: Bool, deepResearch: Bool) {
        guard var conversation else { return }
        conversation.webSearchEnabled = webSearch
        conversation.imageGenerationEnabled = imageGeneration
        conversation.deepResearchEnabled = deepResearch
        self.conversation = conversation
        let id = conversation.id
        Task { [store] in
            try? await store?.setConversationOptions(
                id: id,
                webSearchEnabled: webSearch,
                imageGenerationEnabled: imageGeneration,
                deepResearchEnabled: deepResearch
            )
        }
    }

    var canSend: Bool {
        // The token is optional for direct no-auth backends such as local Ollama.
        guard let env, env.activeProfile?.baseURL != nil else { return false }
        return !isStreaming
    }

    var hasAssistantPreview: Bool {
        isStreaming || !(statusText?.isEmpty ?? true) || !streamingText.isEmpty || !streamingReasoning.isEmpty
    }

    func shouldShowAssistantPreview(alongside messages: [ChatMessage]) -> Bool {
        guard hasAssistantPreview else { return false }
        guard let pendingAssistantPreviewMessageID else { return true }
        return !messages.contains { $0.id == pendingAssistantPreviewMessageID }
    }

    func reconcileAssistantPreview(with messages: [ChatMessage]) {
        guard let pendingAssistantPreviewMessageID,
              messages.contains(where: { $0.id == pendingAssistantPreviewMessageID })
        else { return }
        self.pendingAssistantPreviewMessageID = nil
        streamingText = ""
        streamingReasoning = ""
    }

    func send(_ rawText: String, attachments: [PendingAttachment] = []) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), canSend,
              let env, let store, var conversation,
              let base = env.activeProfile?.baseURL else { return }
        let token = env.activeToken ?? ""

        guard let model = env.backendMode.resolvedChatModel(
            conversationModel: conversation.modelID,
            defaultModel: env.preferredModel
        ) else {
            errorMessage = AppError.modelError(
                "No chat model is selected. Choose a model in Settings or wait for model discovery to finish."
            ).userMessage
            return
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
        streamingText = ""
        streamingReasoning = ""
        statusText = nil
        pendingAssistantPreviewMessageID = nil
        errorMessage = nil

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
        env: AppEnvironment,
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
        } catch {
            finish(error: AppError.from(error))
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

    /// The resolved inputs for a streaming turn, plus a helper that runs a
    /// store mutation and then streams the reply. Shared by `resend`/`regenerate`.
    private struct TurnContext {
        let vm: ChatViewModel
        let convoID: UUID
        let model: String
        let base: URL
        let token: String
        let env: AppEnvironment
        let store: ChatStore

        /// Run `mutate` (truncate/edit the history), then stream a fresh reply.
        @MainActor
        func task(_ mutate: @escaping @Sendable (ChatStore) async throws -> Void) {
            vm.task = Task { [weak vm] in
                do {
                    try await mutate(store)
                } catch {
                    vm?.finish(error: AppError.from(error))
                    return
                }
                await vm?.streamReply(
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
        streamingText = ""
        streamingReasoning = ""
        statusText = nil
        pendingAssistantPreviewMessageID = nil
        errorMessage = nil

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
        env: AppEnvironment,
        store: ChatStore
    ) async {
        guard let detail = try? await store.conversationDetail(id: conversationId) else {
            finish(error: .modelError("Could not load the conversation history."))
            return
        }
        // Scope which server tools this turn may use (spec §2.3). Omitted entirely
        // for backends with no tool manifest, keeping those requests standard.
        // Deep Research rides the additive `x_research` flag (server forces its
        // own search loop); `nil` when off keeps the request standard.
        let request = ChatRequest(
            model: model,
            messages: detail.wireHistory(),
            stream: true,
            reasoningEffort: detail.conversation.reasoningEffort(
                thinkingEnabled: env.thinkingEnabled(for: model),
                disabledEffort: env.disabledReasoningEffortForCurrentBackend()
            ),
            xTools: detail.conversation.requestedToolNames(
                supporting: env.backendMode.capabilities?.tools
            ),
            xResearch: detail.conversation.deepResearchEnabled ? true : nil
        )
        let stream = env.backendMode.usesOllamaNativeChat
            ? env.ollamaChatClient.stream(request, base: base, token: token)
            : env.chatClient.stream(request, base: base, token: token)

        do {
            for try await event in stream {
                switch event {
                case .token(let t):
                    statusText = nil
                    streamingText += t
                case .reasoning(let r):
                    streamingReasoning += r
                case .status(let s): statusText = s
                case .done: break
                }
            }
            let emptyResponse = streamingText.isEmpty
            finish(
                error: emptyResponse
                    ? .modelError("The stream completed without any assistant text.")
                    : nil
            )
        } catch {
            finish(error: AppError.from(error))
        }
    }

    /// Stop button (FR-A9): abort the SSE connection; keep whatever streamed.
    func stop() {
        task?.cancel()
        finish(error: nil)
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

    private func finish(error: AppError?) {
        guard isStreaming else { return }
        isStreaming = false
        statusText = nil
        task = nil

        // Commit any streamed text as one complete assistant message.
        let committed = streamingText
        let committedReasoning = streamingReasoning
        if let store, let conversation, !committed.isEmpty {
            let assistant = Message(
                conversationId: conversation.id, role: "assistant",
                content: committed, reasoning: committedReasoning, isComplete: true
            )
            pendingAssistantPreviewMessageID = assistant.id
            Task { [weak self] in
                do {
                    try await store.insertMessage(assistant, attachments: [])
                    try await store.updateConversation(
                        id: conversation.id, title: nil, modelID: nil, updatedAt: .now
                    )
                    await self?.maybeGenerateTitle()
                } catch {
                    self?.handleAssistantCommitFailure(messageID: assistant.id, error: error)
                }
            }
        } else {
            streamingText = ""
            streamingReasoning = ""
            pendingAssistantPreviewMessageID = nil
        }

        if let error, error != .cancelled {
            errorMessage = error.userMessage
        }
    }

    private func handleAssistantCommitFailure(messageID: UUID, error: Error) {
        guard pendingAssistantPreviewMessageID == messageID else { return }
        pendingAssistantPreviewMessageID = nil
        streamingText = ""
        errorMessage = AppError.from(error).userMessage
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
        let client: ChatClienting = env.backendMode.usesOllamaNativeChat
            ? env.ollamaChatClient
            : env.chatClient
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
        try? await store.updateConversation(id: conversation.id, title: title, modelID: nil, updatedAt: nil)
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
