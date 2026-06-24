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

    func configure(env: AppEnvironment, context: ModelContext, conversation: Conversation) {
        self.env = env
        self.context = context
        self.conversation = conversation
    }

    var canSend: Bool {
        guard let env, env.activeProfile?.baseURL != nil, env.activeToken != nil else { return false }
        return !isStreaming
    }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend,
              let env, let context, let conversation,
              let base = env.activeProfile?.baseURL,
              let token = env.activeToken else { return }

        let model = conversation.modelID
            ?? env.activeProfile?.defaultModel
            ?? env.availableModels.first
            ?? "llama3.1"

        // Persist the user message.
        let user = Message(role: "user", content: text, isComplete: true)
        user.conversation = conversation
        context.insert(user)
        if conversation.title == "New Chat" {
            conversation.title = String(text.prefix(40))
        }
        conversation.updatedAt = .now
        conversation.modelID = model
        try? context.save()

        let request = ChatRequest(model: model, messages: conversation.wireHistory(), stream: true)

        isStreaming = true
        streamingText = ""
        statusText = nil
        errorMessage = nil

        let client = env.chatClient
        task = Task { [weak self] in
            do {
                for try await event in client.stream(request, base: base, token: token) {
                    guard let self else { return }
                    switch event {
                    case .token(let t): self.streamingText += t
                    case .status(let s): self.statusText = s
                    case .done: break
                    }
                }
                self?.finish(error: nil)
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
        }
        streamingText = ""

        if let error, error != .cancelled {
            errorMessage = error.userMessage
        }
    }
}
