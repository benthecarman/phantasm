import GRDBQuery
import PhantasmKit
import PhotosUI
import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    /// Reveal the history drawer (FR-A: chat is the root, history slides over).
    var onOpenHistory: () -> Void = {}
    /// Start a fresh chat from the composer toolbar.
    var onNewChat: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    /// Reactive history for this conversation (drives the list + empty state).
    @Query<MessagesRequest> private var messages: [ChatMessage]
    /// The live conversation row, for the (auto-generated) title; nil for a draft.
    @Query<ConversationRequest> private var liveConversation: Conversation?
    @State private var vm = ChatViewModel()
    @State private var input = ""
    @State private var attachments: [PendingAttachment] = []
    @FocusState private var composerFocused: Bool
    /// Picked once per chat (the view is rebuilt per conversation via `.id`).
    @State private var greeting = GreetingPrompts.random()

    init(
        conversation: Conversation,
        onOpenHistory: @escaping () -> Void = {},
        onNewChat: @escaping () -> Void = {}
    ) {
        self.conversation = conversation
        self.onOpenHistory = onOpenHistory
        self.onNewChat = onNewChat
        _messages = Query(MessagesRequest(conversationId: conversation.id))
        _liveConversation = Query(ConversationRequest(id: conversation.id))
    }

    private var isEmpty: Bool { messages.isEmpty && !vm.isStreaming }

    /// The conversation title to display: the live (possibly auto-named) row when
    /// persisted, falling back to the in-memory draft.
    private var title: String { liveConversation?.title ?? conversation.title }

    /// The model selected for this conversation (VM-owned once configured).
    private var currentModelID: String? {
        vm.selectedModel ?? conversation.modelID ?? env.preferredModel
    }

    /// Whether the selected model can accept images (vision-capable).
    private var allowsImageAttachments: Bool {
        env.supportsVision(currentModelID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isEmpty {
                    emptyState
                } else {
                    messageList
                }
                ComposerView(
                    input: $input,
                    attachments: $attachments,
                    isStreaming: vm.isStreaming,
                    canSend: vm.canSend,
                    focus: $composerFocused,
                    availableModels: env.availableModels,
                    modelName: currentModelName,
                    modelSelection: modelBinding,
                    allowsImageAttachments: allowsImageAttachments,
                    onSend: send,
                    onStop: { vm.stop() }
                )
            }
            .navigationTitle(isEmpty ? "" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onChange(of: allowsImageAttachments) { _, allowed in
                // Switching to a non-vision model drops any staged images so they
                // can't silently ride along on a model that can't read them.
                if !allowed {
                    attachments.removeAll { $0.kind == .image }
                }
            }
        }
        .task(id: conversation.id) {
            vm.configure(env: env, store: env.store, conversation: conversation)
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
        VStack(spacing: 18) {
            Spacer()
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(greeting)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                    ForEach(messages) { message in
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
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
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
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New chat")
            .disabled(env.activeProfile == nil)
        }
    }

    private var currentModelName: String {
        currentModelID ?? "model"
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { currentModelID ?? "" },
            set: { vm.setModel($0) }
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
        let pending = attachments
        input = ""
        attachments = []
        composerFocused = false
        vm.send(text, attachments: pending)
    }
}

/// The message composer with a send / stop control (FR-A3, FR-A9).
///
/// Styled as a single rounded card: the text grows with the message and the
/// send / stop control lives inside the card, bottom-trailing.
struct ComposerView: View {
    @Binding var input: String
    @Binding var attachments: [PendingAttachment]
    let isStreaming: Bool
    let canSend: Bool
    var focus: FocusState<Bool>.Binding
    let availableModels: [String]
    let modelName: String
    let modelSelection: Binding<String>
    /// Whether the selected model can accept images (vision). Files are always
    /// allowed; only the Photos option is gated.
    let allowsImageAttachments: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false

    private var trimmed: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var sendEnabled: Bool {
        canSend && (!trimmed.isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 4) {
            if !attachments.isEmpty {
                attachmentStrip
            }

            TextField("Message", text: $input, axis: .vertical)
                .lineLimit(1...8)
                .focused(focus)
                .disabled(isStreaming)
                .padding(.horizontal, 18)
                .padding(.top, attachments.isEmpty ? 14 : 4)
                .submitLabel(.return)

            HStack(spacing: 8) {
                addButton
                modelPicker
                Spacer(minLength: 8)
                control
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 6,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: AttachmentLoader.importableTypes,
            allowsMultipleSelection: true
        ) { result in loadFiles(result) }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    PendingAttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var addButton: some View {
        Menu {
            if allowsImageAttachments {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Photos", systemImage: "photo")
                }
            }
            Button {
                showFileImporter = true
            } label: {
                Label("Files", systemImage: "doc")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .disabled(isStreaming)
        .accessibilityLabel("Add attachment")
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var loaded: [PendingAttachment] = []
            for item in items {
                if let attachment = await AttachmentLoader.image(from: item) {
                    loaded.append(attachment)
                }
            }
            await MainActor.run {
                attachments.append(contentsOf: loaded)
                photoItems = []
            }
        }
    }

    private func loadFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        attachments.append(contentsOf: urls.compactMap(AttachmentLoader.file))
    }

    @ViewBuilder
    private var modelPicker: some View {
        if !availableModels.isEmpty {
            Menu {
                Picker("Model", selection: modelSelection) {
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(modelName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if isStreaming {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.background)
                    .frame(width: 34, height: 34)
                    .background(Color.red, in: Circle())
            }
            .accessibilityLabel("Stop")
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.background)
                    .frame(width: 34, height: 34)
                    .background(sendEnabled ? Color.accentColor : Color.secondary.opacity(0.4), in: Circle())
            }
            .disabled(!sendEnabled)
            .animation(.easeOut(duration: 0.15), value: sendEnabled)
            .accessibilityLabel("Send")
        }
    }
}
