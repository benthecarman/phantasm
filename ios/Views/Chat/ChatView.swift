import PhantasmKit
import SwiftUI

struct ChatView: View {
    let conversation: Conversation

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var vm = ChatViewModel()
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            ComposerView(
                input: $input,
                isStreaming: vm.isStreaming,
                canSend: vm.canSend,
                onSend: send,
                onStop: { vm.stop() }
            )
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: conversation.id) {
            vm.configure(env: env, context: context, conversation: conversation)
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
        ToolbarItem(placement: .topBarTrailing) {
            if !env.availableModels.isEmpty {
                Menu {
                    Picker("Model", selection: modelBinding) {
                        ForEach(env.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(conversation.modelID ?? env.availableModels.first ?? "model",
                          systemImage: "cpu")
                        .font(.caption)
                }
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { conversation.modelID ?? env.availableModels.first ?? "" },
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
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
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
