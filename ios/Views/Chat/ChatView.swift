import PhantasmKit
import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    /// Reveal the history drawer (FR-A: chat is the root, history slides over).
    var onOpenHistory: () -> Void = {}
    /// Start a fresh chat from the composer toolbar.
    var onNewChat: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var vm = ChatViewModel()
    @State private var input = ""
    @FocusState private var composerFocused: Bool

    private var isEmpty: Bool { conversation.orderedMessages.isEmpty && !vm.isStreaming }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isEmpty {
                    emptyState
                } else {
                    messageList
                }
                Divider()
                ComposerView(
                    input: $input,
                    isStreaming: vm.isStreaming,
                    canSend: vm.canSend,
                    focus: $composerFocused,
                    onSend: send,
                    onStop: { vm.stop() }
                )
            }
            .navigationTitle(isEmpty ? "" : conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .task(id: conversation.id) {
            vm.configure(env: env, context: context, conversation: conversation)
            // Claude-style: drop the user straight into the composer on a new chat.
            if isEmpty { composerFocused = true }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("What can I help with?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = true }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(conversation.orderedMessages) { message in
                        MessageBubble(message: message)
                    }
                    if vm.isStreaming {
                        StreamingBubble(text: vm.streamingText, status: vm.statusText)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding()
            }
            .onChange(of: vm.streamingText) { _, _ in scrollToBottom(proxy) }
            .onChange(of: conversation.messages.count) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: onOpenHistory) {
                Image(systemName: "line.3.horizontal")
            }
            .accessibilityLabel("Chat history")
        }
        ToolbarItem(placement: .principal) {
            if !env.availableModels.isEmpty {
                Menu {
                    Picker("Model", selection: modelBinding) {
                        ForEach(env.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(currentModelName, systemImage: "cpu")
                        .font(.caption)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New chat")
            .disabled(env.activeProfile == nil)
        }
    }

    private var currentModelName: String {
        conversation.modelID ?? env.preferredModel ?? "model"
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { conversation.modelID ?? env.preferredModel ?? "" },
            set: { conversation.modelID = $0; try? context.save() }
        )
    }

    private let bottomID = "bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func send() {
        let text = input
        input = ""
        vm.send(text)
    }
}

/// The message composer with a send / stop control (FR-A3, FR-A9).
struct ComposerView: View {
    @Binding var input: String
    let isStreaming: Bool
    let canSend: Bool
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused(focus)
                .disabled(isStreaming)

            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                }
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(!canSend || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
    }
}
