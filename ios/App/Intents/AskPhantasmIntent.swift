import AppIntents
import Foundation
import PhantasmKit
import SwiftUI

/// The "Ask Phantasm" Siri / Spotlight / Shortcuts action. Runs a single plain
/// turn in the background and hands the text back for Siri to narrate (and show
/// in a snippet) — the app never opens. Deliberately scoped to short, plain Q&A:
/// no tools, no research, a bounded timeout, so it stays inside the system's
/// headless execution window.
struct AskPhantasmIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Phantasm"
    static let description = IntentDescription(
        "Ask the AI a question and get the answer back without opening the app."
    )
    /// Headless: the answer is spoken/shown by Siri, the app stays closed.
    static let openAppWhenRun = false

    @Parameter(
        title: "Question",
        requestValueDialog: "What do you want to ask?"
    )
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let answer = try await AskService.answer(to: question)
        return .result(
            dialog: IntentDialog(stringLiteral: answer),
            view: AskAnswerView(question: question, answer: answer)
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Phantasm \(\.$question)")
    }
}

/// Surfaces `AskPhantasmIntent` as an App Shortcut. iOS auto-registers these on
/// install, which is what produces the "Ask Phantasm" entry in Spotlight, Siri,
/// and the Shortcuts app — no user setup required.
struct PhantasmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPhantasmIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask Phantasm",
            systemImageName: "sparkles"
        )
    }
}

/// Runs a one-shot, plain turn against the active backend and returns the text.
/// No persistence (the answer is ephemeral, by design) and no tools/research, so
/// it reuses the same transport + auth as a normal turn but stays fast.
enum AskService {
    static func answer(to rawQuestion: String) async throws -> String {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AskError.emptyQuestion }

        // Reconstruct the minimal services directly — App Intents are
        // system-instantiated, so there's no `AppEnvironment` to lean on. These
        // are cheap, stateless reads of the same UserDefaults/Keychain the app uses.
        let profileStore = ProfileStore()
        let profiles = profileStore.load().profiles
        let profile = profiles.first { $0.id == profileStore.activeProfileID } ?? profiles.first
        guard let profile, let base = profile.baseURL else { throw AskError.noBackend }
        let token = KeychainStore().token(for: profile.id) ?? ""

        // One session shared by the capability probe and the chat request, so the
        // chat reuses the probe's already-warm TCP/TLS connection instead of doing
        // a second handshake. Bound the whole turn so a slow/hung backend fails with
        // a spoken error rather than the system killing us at its execution limit.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)

        // Probe the backend mode. This resolves the model robustly and lets us
        // suppress thinking tokens only when the endpoint explicitly says the
        // selected model can think. Unknown support omits `reasoning_effort` so
        // stricter backends do not reject a guessed value.
        let mapleSession = MapleEncryptedTransport.session(configuration: config)
        let mode = (try? await BackendResolver(
            session: session,
            mapleSession: mapleSession
        ).resolve(
            base: base,
            token: token,
            preferMaple: profile.effectiveTransport == .mapleEncrypted
        ).get())
            ?? (profile.effectiveTransport == .mapleEncrypted
                ? .mapleEncrypted(models: profileStore.cachedModels(for: profile.id))
                : .plainChatOnly(models: []))
        guard let model = mode.resolvedChatModel(
            conversationModel: nil,
            defaultModel: profile.defaultModel
        ) else { throw AskError.noModel }

        let request = ChatRequest(
            model: model,
            messages: [WireMessage(role: "user", content: question)],
            stream: true,
            reasoningEffort: disabledReasoningEffort(for: model, mode: mode)
        )

        let client: any ChatClienting = mode.usesMapleEncryptedChat
            ? MapleChatClient(session: mapleSession)
            : ChatClient(session: session)
        let answer = try await client.complete(request, base: base, token: token)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AskError.emptyAnswer }
        return answer
    }

    /// `"none"` only for models the Phantasm/orchestrator manifest explicitly
    /// advertises with reasoning effort options. Plain OpenAI-compatible/native
    /// Ollama backends and unknown per-model support omit the field.
    private static func disabledReasoningEffort(for model: String, mode: BackendMode) -> String? {
        guard case .full(let caps) = mode,
              case .known(let efforts) = caps.reasoningEffortsByID[model],
              !efforts.isEmpty else { return nil }
        return ReasoningEffort.disabled
    }
}

/// Errors surfaced back to Siri as spoken dialog.
enum AskError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case emptyQuestion
    case noBackend
    case noModel
    case emptyAnswer

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyQuestion: "I didn't catch a question to ask."
        case .noBackend: "Open Phantasm and set up a backend first."
        case .noModel: "No model is available on your backend yet."
        case .emptyAnswer: "The model didn't return an answer."
        }
    }
}

/// The snippet Siri / Shortcuts shows alongside the spoken answer.
///
/// It paints its own background (`systemBackground`) and uses semantic
/// foreground colors so the text and its surface always resolve from the same
/// appearance — otherwise the answer renders black text against whatever (often
/// dark) chrome Siri/Shortcuts supplies, which is unreadable.
struct AskAnswerView: View {
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(question, systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(answer)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
