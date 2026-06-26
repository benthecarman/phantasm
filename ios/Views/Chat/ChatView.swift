import GRDBQuery
import PhantasmKit
import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    let vm: ChatViewModel
    /// Auto-raise the keyboard when this chat first appears empty. Only the
    /// cold-launch chat sets this; mid-session new chats leave the keyboard down.
    var autoFocusComposer: Bool = false
    /// Reveal the history drawer (FR-A: chat is the root, history slides over).
    var onOpenHistory: () -> Void = {}
    /// Start a fresh chat from the composer toolbar.
    var onNewChat: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    /// Reactive history for this conversation (drives the list + empty state).
    @Query<MessagesRequest> private var messages: [ChatMessage]
    @State private var input = ""
    @State private var attachments: [PendingAttachment] = []
    /// The user message being edited inline, if any (FR-A: edit a previous message).
    @State private var editingMessageID: UUID?
    @State private var editingText = ""
    @FocusState private var composerFocused: Bool
    /// Picked once per chat (the view is rebuilt per conversation via `.id`).
    @State private var greeting = GreetingPrompts.random()
    @Namespace private var logoNamespace

    init(
        conversation: Conversation,
        viewModel: ChatViewModel,
        autoFocusComposer: Bool = false,
        onOpenHistory: @escaping () -> Void = {},
        onNewChat: @escaping () -> Void = {}
    ) {
        self.conversation = conversation
        self.vm = viewModel
        self.autoFocusComposer = autoFocusComposer
        self.onOpenHistory = onOpenHistory
        self.onNewChat = onNewChat
        _messages = Query(MessagesRequest(conversationId: conversation.id))
    }

    private var visibleMessages: [ChatMessage] {
        messages.filter { $0.message.isComplete }
    }

    private var isEmpty: Bool { visibleMessages.isEmpty && !vm.hasAssistantPreview }

    /// The model selected for this conversation (VM-owned once configured).
    private var currentModelID: String? {
        vm.selectedModel ?? conversation.modelID ?? env.preferredModel
    }

    /// Whether the selected model can accept images (vision-capable).
    private var allowsImageAttachments: Bool {
        env.supportsVision(currentModelID)
    }

    /// Whether the selected model can drive server tools (function calling). A
    /// tool also needs the backend to advertise it; this only gates the model.
    private var modelSupportsTools: Bool {
        env.supportsTools(currentModelID)
    }

    /// The server tools the active backend advertises, or nil if it exposes no
    /// tool manifest (raw Ollama / generic OpenAI) — then the tool selector hides.
    private var backendTools: Capabilities.Tools? {
        env.backendMode.capabilities?.tools
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    emptyState
                } else {
                    messageList
                }
            }
            // Float the composer over the transcript so messages scroll behind it
            // (FR-A "flows over text"), rather than sitting in its own reserved
            // strip with the page background filling the gap behind the keyboard.
            .safeAreaInset(edge: .bottom) {
                ComposerView(
                    input: $input,
                    attachments: $attachments,
                    isStreaming: vm.isStreaming,
                    canSend: vm.canSend,
                    focus: $composerFocused,
                    availableModels: env.availableModels,
                    modelName: currentModelName,
                    modelSelection: modelBinding,
                    visionModels: env.visionModels,
                    toolModels: env.toolModels,
                    defaultModel: env.defaultModelID,
                    allowsImageAttachments: allowsImageAttachments,
                    supportsWebSearch: backendTools?.webSearch ?? false,
                    supportsImageGeneration: backendTools?.imageGeneration ?? false,
                    modelSupportsTools: modelSupportsTools,
                    webSearchEnabled: Binding(
                        get: { vm.webSearchEnabled },
                        set: { vm.setWebSearchEnabled($0) }
                    ),
                    imageGenerationEnabled: Binding(
                        get: { vm.imageGenerationEnabled },
                        set: { vm.setImageGenerationEnabled($0) }
                    ),
                    deepResearchEnabled: Binding(
                        get: { vm.deepResearchEnabled },
                        set: { vm.setDeepResearchEnabled($0) }
                    ),
                    thinkingEnabled: Binding(
                        get: { env.thinkingEnabled(for: currentModelID) },
                        set: { env.setThinkingEnabled($0, for: currentModelID) }
                    ),
                    onSend: send,
                    onStop: { vm.stop() }
                )
            }
            .navigationTitle("")
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
            vm.setViewVisible(true)
            vm.configure(
                env: env,
                store: env.store,
                conversation: conversation,
                sceneIsActive: scenePhase == .active
            )
            // Claude-style: drop the user straight into the composer on cold launch.
            // Mid-session new/empty chats leave the keyboard down (less aggressive).
            if isEmpty && autoFocusComposer { composerFocused = true }
        }
        .onChange(of: scenePhase) { _, phase in
            vm.setSceneActive(phase == .active)
        }
        .onDisappear {
            vm.setViewVisible(false)
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
            Image("MasksLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 96)
                .matchedGeometryEffect(id: "masks-logo", in: logoNamespace)
                .accessibilityLabel("Phantasm")
            Text(greeting)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Tap to toggle the keyboard: raise it to start typing, tap off to dismiss.
        .onTapGesture { composerFocused.toggle() }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleMessages) { message in
                        MessageBubble(
                            message: message,
                            isEditing: editingMessageID == message.id,
                            canEdit: message.message.role == "user" && !vm.isStreaming,
                            canRegenerate: message.message.role == "assistant" && !vm.isStreaming,
                            editText: $editingText,
                            onBeginEdit: { beginEditing(message) },
                            onSubmitEdit: { submitEdit() },
                            onCancelEdit: { editingMessageID = nil },
                            onRegenerate: { vm.regenerate(messageID: message.id) }
                        )
                    }
                    if vm.shouldShowAssistantPreview(alongside: messages) {
                        StreamingBubble(
                            text: vm.streamingText,
                            reasoning: vm.streamingReasoning,
                            status: vm.statusText
                        )
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding()
            }
            // Tap or drag the transcript to dismiss the keyboard (tapping "off"
            // the composer). The tap is simultaneous so message-bubble buttons
            // still fire; the drag gives the iOS-standard swipe-down dismissal.
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            // During streaming, tokens arrive many-per-second; an animated scroll
            // per token stacks overlapping animations and janks. Follow the tail
            // without animation while streaming, and animate the discrete jumps
            // (new committed message, first appear).
            .onChange(of: vm.streamingText) { _, _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: vm.streamingReasoning) { _, _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: messages) { _, _ in
                vm.reconcileAssistantPreview(with: messages)
                scrollToBottom(proxy)
            }
            .onAppear {
                vm.reconcileAssistantPreview(with: messages)
                scrollToBottom(proxy)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isEmpty {
            ToolbarItem(placement: .principal) {
                Image("MasksLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 32)
                    .matchedGeometryEffect(id: "masks-logo", in: logoNamespace)
                    .accessibilityLabel("Phantasm")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button(action: onOpenHistory) {
                Image(systemName: "line.3.horizontal")
            }
            .accessibilityLabel("Chat history")
        }
        if !isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New chat")
                .disabled(env.activeProfile == nil)
            }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func send() {
        let animateLogo = isEmpty
        let text = input
        let pending = attachments
        input = ""
        attachments = []
        composerFocused = false
        if animateLogo {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                vm.send(text, attachments: pending)
            }
        } else {
            vm.send(text, attachments: pending)
        }
    }

    private func beginEditing(_ message: ChatMessage) {
        editingText = message.message.content
        editingMessageID = message.id
        composerFocused = false
    }

    /// Commit the inline edit: truncate after this message and re-ask the model.
    private func submitEdit() {
        guard let id = editingMessageID else { return }
        let text = editingText
        editingMessageID = nil
        vm.resend(afterEditing: id, newText: text)
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
    /// Per-model capability sets for the model picker (nil ⇒ undetectable for
    /// this backend, so the badge is omitted rather than shown as unsupported).
    let visionModels: Set<String>?
    let toolModels: Set<String>?
    /// The configured default model, badged in the picker.
    let defaultModel: String?
    /// Whether the selected model can accept images (vision). Files are always
    /// allowed; only the Photos option is gated.
    let allowsImageAttachments: Bool
    /// Which server tools the backend advertises (spec §2.1). A tool is only
    /// usable when the backend advertises it *and* the model can drive tools.
    let supportsWebSearch: Bool
    let supportsImageGeneration: Bool
    /// Whether the selected model supports tool/function calling.
    let modelSupportsTools: Bool
    let webSearchEnabled: Binding<Bool>
    let imageGenerationEnabled: Binding<Bool>
    let deepResearchEnabled: Binding<Bool>
    let thinkingEnabled: Binding<Bool>
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var showOptions = false
    @State private var showModelPicker = false

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
        .padding(.top, 8)
        // Sit a little above the keyboard when it's open, but drop closer to the
        // bottom edge when it's dismissed (the home-indicator inset is enough
        // breathing room there). Animate so it tracks the keyboard transition.
        .padding(.bottom, focus.wrappedValue ? 8 : 0)
        .animation(.easeInOut(duration: 0.25), value: focus.wrappedValue)
        .sheet(isPresented: $showOptions) {
            ComposerOptionsSheet(
                attachments: $attachments,
                allowsImageAttachments: allowsImageAttachments,
                supportsWebSearch: supportsWebSearch,
                supportsImageGeneration: supportsImageGeneration,
                modelSupportsTools: modelSupportsTools,
                webSearchEnabled: webSearchEnabled,
                imageGenerationEnabled: imageGenerationEnabled,
                deepResearchEnabled: deepResearchEnabled,
                thinkingEnabled: thinkingEnabled
            )
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: availableModels,
                selection: modelSelection,
                visionModels: visionModels,
                toolModels: toolModels,
                defaultModel: defaultModel
            )
        }
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

    /// Opens the "+" options sheet (attachments, tools, model).
    private var addButton: some View {
        Button {
            showOptions = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .disabled(isStreaming)
        .accessibilityLabel("Add attachment or options")
    }

    /// Model selector pill (FR-A): a capsule showing the active model that opens
    /// a sheet to switch (matching the "+" options sheet). Hidden when the
    /// backend advertises no models.
    @ViewBuilder
    private var modelPicker: some View {
        if !availableModels.isEmpty {
            Button {
                showModelPicker = true
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
            .disabled(isStreaming)
            .accessibilityLabel("Model")
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
