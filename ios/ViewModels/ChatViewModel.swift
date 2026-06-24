import Foundation
import Observation
import PhantasmKit
import SwiftData

/// Drives one conversation: sends turns, accumulates streamed tokens in memory,
/// and commits a single complete assistant message when the turn ends
/// (buffer-then-commit, NFR-A4 — no per-token disk writes).
@MainActor
@Observable
final class ChatViewModel {
    private(set) var isStreaming = false
    private(set) var streamingText = ""
    private(set) var statusText: String?
    var errorMessage: String?

    private var env: AppEnvironment?
    private var context: ModelContext?
    private var conversation: Conversation?
    private var task: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?

    func configure(env: AppEnvironment, context: ModelContext, conversation: Conversation) {
        self.env = env
        self.context = context
        self.conversation = conversation
    }

    var canSend: Bool {
        // The token is optional for direct no-auth backends such as local Ollama.
        guard let env, env.activeProfile?.baseURL != nil else { return false }
        return !isStreaming
    }

    func send(_ rawText: String, attachments: [PendingAttachment] = []) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), canSend,
              let env, let context, let conversation,
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

        // Persist the conversation lazily: new chats stay ephemeral (and out of
        // the history list) until their first message is sent.
        context.insert(conversation)

        // Persist the user message plus any attachments.
        let user = Message(role: "user", content: text, isComplete: true)
        user.conversation = conversation
        context.insert(user)
        for pending in attachments {
            let attachment = Attachment(
                kind: pending.kind,
                name: pending.name,
                data: pending.imageData,
                mimeType: pending.mimeType,
                text: pending.text
            )
            attachment.message = user
            context.insert(attachment)
        }
        if conversation.title == "New Chat" {
            let derived = text.isEmpty ? (attachments.first?.name ?? "New Chat") : String(text.prefix(40))
            conversation.title = derived
        }
        conversation.updatedAt = .now
        conversation.modelID = model
        try? context.save()

        let request = ChatRequest(model: model, messages: conversation.wireHistory(), stream: true)

        isStreaming = true
        streamingText = ""
        statusText = nil
        errorMessage = nil

        let stream = env.backendMode.usesOllamaNativeChat
            ? env.ollamaChatClient.stream(request, base: base, token: token)
            : env.chatClient.stream(request, base: base, token: token)
        task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .token(let t):
                        self.statusText = nil
                        self.streamingText += t
                    case .status(let s): self.statusText = s
                    case .done: break
                    }
                }
                let emptyResponse = self?.streamingText.isEmpty ?? false
                self?.finish(
                    error: emptyResponse
                        ? .modelError("The stream completed without any assistant text.")
                        : nil
                )
            } catch {
                self?.finish(error: AppError.from(error))
            }
        }
    }

    /// Stop button (FR-A9): abort the SSE connection; keep whatever streamed.
    func stop() {
        task?.cancel()
        finish(error: nil)
    }

    private func finish(error: AppError?) {
        guard isStreaming else { return }
        isStreaming = false
        statusText = nil
        task = nil

        // Commit any streamed text as one complete assistant message.
        if let context, let conversation, !streamingText.isEmpty {
            let assistant = Message(role: "assistant", content: streamingText, isComplete: true)
            assistant.conversation = conversation
            context.insert(assistant)
            conversation.updatedAt = .now
            try? context.save()

            // After the very first assistant reply, replace the first-message
            // placeholder title with a model-generated one (FR: auto-naming).
            if conversation.messages.filter({ $0.role == "assistant" }).count == 1 {
                generateTitle()
            }
        }
        streamingText = ""

        if let error, error != .cancelled {
            errorMessage = error.userMessage
        }
    }

    /// Side-query the model for a short conversation title once the first reply
    /// has landed. Fire-and-forget: failures leave the placeholder title in
    /// place and never surface to the user.
    private func generateTitle() {
        guard let env, let conversation,
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
            messages: conversation.wireHistory() + [WireMessage(role: "user", content: Self.titlePrompt)],
            stream: true,
            reasoningEffort: "none"
        )

        titleTask = Task { [weak self] in
            guard let raw = try? await client.complete(request, base: base, token: token) else { return }
            let title = Self.sanitizedTitle(raw)
            guard !title.isEmpty, let self, let conversation = self.conversation else { return }
            conversation.title = title
            try? self.context?.save()
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
