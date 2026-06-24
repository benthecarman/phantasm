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
    private(set) var statusText: String?
    var errorMessage: String?

    private var env: AppEnvironment?
    private var store: ChatStore?
    /// The active conversation's metadata (a value, not the stored history). For a
    /// new chat this is an in-memory draft that isn't written until the first send.
    private var conversation: Conversation?
    private var task: Task<Void, Never>?

    func configure(env: AppEnvironment, store: ChatStore, conversation: Conversation) {
        self.env = env
        self.store = store
        self.conversation = conversation
    }

    /// The model the composer should display / preselect for this conversation.
    var selectedModel: String? { conversation?.modelID }

    var canSend: Bool {
        // The token is optional for direct no-auth backends such as local Ollama.
        guard let env, env.activeProfile?.baseURL != nil else { return false }
        return !isStreaming
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
        statusText = nil
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

        // Full history each turn (stateless server, XR-2), read back from the store.
        guard let detail = try? await store.conversationDetail(id: conversation.id) else {
            finish(error: .modelError("Could not load the conversation history."))
            return
        }
        let request = ChatRequest(model: model, messages: detail.wireHistory(), stream: true)
        let stream = env.backendMode.usesOllamaNativeChat
            ? env.ollamaChatClient.stream(request, base: base, token: token)
            : env.chatClient.stream(request, base: base, token: token)

        do {
            for try await event in stream {
                switch event {
                case .token(let t):
                    statusText = nil
                    streamingText += t
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
        streamingText = ""
        if let store, let conversation, !committed.isEmpty {
            let assistant = Message(
                conversationId: conversation.id, role: "assistant",
                content: committed, isComplete: true
            )
            Task { [weak self] in
                try? await store.insertMessage(assistant, attachments: [])
                try? await store.updateConversation(
                    id: conversation.id, title: nil, modelID: nil, updatedAt: .now
                )
                await self?.maybeGenerateTitle()
            }
        }

        if let error, error != .cancelled {
            errorMessage = error.userMessage
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
        let client: ChatClienting = env.backendMode.usesOllamaNativeChat
            ? env.ollamaChatClient
            : env.chatClient
        let request = ChatRequest(
            model: model,
            messages: history + [WireMessage(role: "user", content: Self.titlePrompt)],
            stream: true,
            reasoningEffort: "none"
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
