import GRDBQuery
import PhantasmKit
import SwiftUI
import UIKit

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
    /// The full-screen image viewer, when an image has been tapped.
    @State private var imageViewer: ImageViewerPresentation?
    @FocusState private var composerFocused: Bool
    /// Picked once per chat (the view is rebuilt per conversation via `.id`).
    @State private var greeting = GreetingPrompts.random()
    /// Whether the transcript is parked at (or very near) the bottom. Auto-scroll
    /// only follows the streaming tail while this is true; once the user scrolls
    /// up to read history it goes false and we stop yanking them back down.
    @State private var isPinnedToBottom = true
    /// Whether the user's finger is currently on the transcript (tracking or
    /// dragging). While true, tail-follow scrolls are suppressed so per-token
    /// `scrollTo`s can't fight the gesture.
    @State private var isUserScrolling = false
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
        messages.filter { item in
            guard item.message.isComplete else { return false }
            let m = item.message
            // Hide protocol-plumbing rows that carry no user-facing prose: the
            // forwarded app-tool call (an empty assistant body that rides
            // `tool_calls`) and any auto-resolved tool's result (raw data meant for
            // the model, not the transcript). An interactive answer — e.g. an
            // `ask_user` pick — still shows.
            // …except a `render_chart` call: its row carries the chart to draw, so
            // keep it visible even though its prose body is empty.
            if m.role == "assistant", m.toolCalls != nil, m.content.isEmpty {
                return item.hasChartRender
            }
            if m.role == "tool", AppToolRegistry.isAutoResolved(name: m.name) { return false }
            return true
        }
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

    /// Whether the selected model can produce reasoning output through Phantasm.
    /// Non-Phantasm backends do not expose the app's Thinking toggle.
    private var modelSupportsThinking: Bool {
        env.supportsThinking(currentModelID)
    }

    private var reasoningEfforts: [String] {
        env.reasoningEfforts(for: currentModelID)
    }

    /// Whether this backend exposes the app's Thinking control at all. Unknown
    /// endpoint support hides the row; explicit unsupported renders disabled.
    private var showsThinkingToggle: Bool {
        switch env.thinkingSupport(for: currentModelID) {
        case .supported, .unsupported: return true
        case .unknown: return false
        }
    }

    /// Token estimate for the current history, recomputed only when `messages`
    /// change (`.onChange` below). Computing it inline in `body` re-scanned
    /// every message's characters — megabytes with inline-base64 images — on
    /// every body evaluation.
    @State private var estimatedTokens = 0

    /// Estimated context-window usage for this conversation, or `nil` when the
    /// model's window is unknown (then no usage indicator appears).
    private var contextUsage: ContextUsage? {
        guard let length = currentModelID.flatMap({ env.contextLengths?[$0] }),
              length > 0 else { return nil }
        return ContextUsage(estimatedTokens: estimatedTokens, contextLength: length)
    }

    /// The active orchestrator manifest, or nil for raw Ollama / generic OpenAI.
    private var backendCapabilities: Capabilities? {
        env.backendMode.capabilities
    }

    /// Whether app-hosted tools (e.g. location) can ride this turn. They resolve
    /// on-device via standard OpenAI tool-calling, so any backend can carry them
    /// — orchestrator, native Ollama, or a plain OpenAI endpoint. The model must
    /// also be tool-capable (`modelSupportsTools`), checked in the composer.
    private var supportsAppTools: Bool {
        true
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
              VStack(spacing: 8) {
                if let prompt = vm.pendingPrompt {
                    // One view per interactive app-tool prompt kind. A new
                    // interactive tool adds a case here (and an `AppToolPrompt` one).
                    switch prompt {
                    case .multipleChoice(let choice):
                        ChoicePromptView(choice: choice) { vm.answerPendingPrompt($0) }
                            .id(choice.toolCallId)
                    case .calendarEvent(let confirmation):
                        CalendarEventPromptView(confirmation: confirmation) {
                            vm.answerPendingCalendarEvent(confirm: $0)
                        }
                        .id(confirmation.toolCallId)
                    }
                }
                ComposerView(
                    input: $input,
                    attachments: $attachments,
                    isStreaming: vm.isStreaming,
                    canSend: vm.canSend && (vm.pendingPrompt?.acceptsFreeTextAnswer ?? true),
                    focus: $composerFocused,
                    dictation: env.dictationController,
                    availableModels: env.availableModels,
                    modelName: currentModelName,
                    modelSelection: modelBinding,
                    visionModels: env.visionModels,
                    toolModels: env.toolModels,
                    contextLengths: env.contextLengths,
                    defaultModel: env.defaultModelID,
                    allowsImageAttachments: allowsImageAttachments,
                    supportsWebSearch: backendCapabilities?.hasToolSelector(ToolSelectorName.webSearch) ?? false,
                    supportsImageGeneration: backendCapabilities?.hasToolSelector(ToolSelectorName.imageGeneration) ?? false,
                    supportsLocation: supportsAppTools,
                    supportsHealth: supportsAppTools,
                    supportsCalendar: supportsAppTools,
                    modelSupportsTools: modelSupportsTools,
                    showsThinkingToggle: showsThinkingToggle,
                    modelSupportsThinking: modelSupportsThinking,
                    webSearchEnabled: Binding(
                        get: { vm.webSearchEnabled },
                        set: { vm.setWebSearchEnabled($0) }
                    ),
                    imageGenerationEnabled: Binding(
                        get: { vm.imageGenerationEnabled },
                        set: { vm.setImageGenerationEnabled($0) }
                    ),
                    locationEnabled: Binding(
                        get: { vm.locationEnabled },
                        set: { vm.setLocationEnabled($0) }
                    ),
                    healthEnabled: Binding(
                        get: { vm.healthEnabled },
                        set: { vm.setHealthEnabled($0) }
                    ),
                    calendarEnabled: Binding(
                        get: { vm.calendarEnabled },
                        set: { vm.setCalendarEnabled($0) }
                    ),
                    availableModes: vm.availableModes,
                    modeID: Binding(
                        get: { vm.modeID },
                        set: { vm.setModeID($0) }
                    ),
                    reasoningEfforts: reasoningEfforts,
                    thinkingEnabled: Binding(
                        get: { env.thinkingEnabled(for: currentModelID) },
                        set: { env.setThinkingEnabled($0, for: currentModelID) }
                    ),
                    selectedReasoningEffort: Binding(
                        get: { env.selectedReasoningEffort(for: currentModelID) },
                        set: { env.setSelectedReasoningEffort($0, for: currentModelID) }
                    ),
                    onSend: send,
                    onStop: {
                        Haptics.impact(.light)
                        vm.stop()
                    }
                )
              }
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
        .onChange(of: messages) { _, updated in
            estimatedTokens = ContextWindow.estimatedTokens(for: updated)
        }
        .task(id: conversation.id) {
            estimatedTokens = ContextWindow.estimatedTokens(for: messages)
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
        .onChange(of: vm.errorMessage) { _, message in
            if message != nil { Haptics.notify(.error) }
        }
        .fullScreenCover(item: $imageViewer) { presentation in
            ImageViewerView(images: presentation.images, startID: presentation.startID)
        }
    }

    /// Open the full-screen viewer on the tapped image, with the whole
    /// conversation's images available to swipe through. Falls back to showing
    /// just the tapped image if it isn't in the gallery (e.g. a not-yet-cached
    /// remote image).
    private func openImageViewer(messageID: UUID, index: Int, image: UIImage) {
        Haptics.selection()
        let gallery = ConversationImages.gallery(from: visibleMessages)
        let targetID = "\(messageID):\(index)"
        if gallery.contains(where: { $0.id == targetID }) {
            imageViewer = ImageViewerPresentation(images: gallery, startID: targetID)
        } else {
            let solo = GalleryImage(id: targetID, image: image)
            imageViewer = ImageViewerPresentation(images: [solo], startID: targetID)
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
                            canResend: message.message.role == "user" && !vm.isStreaming,
                            canRegenerate: message.message.role == "assistant" && !vm.isStreaming,
                            editText: $editingText,
                            onBeginEdit: { beginEditing(message) },
                            onSubmitEdit: { submitEdit() },
                            onCancelEdit: {
                                Haptics.selection()
                                editingMessageID = nil
                            },
                            onResend: {
                                Haptics.impact(.medium)
                                vm.resend(messageID: message.id)
                            },
                            onRegenerate: {
                                Haptics.impact(.medium)
                                vm.regenerate(messageID: message.id)
                            },
                            onTapImage: openImageViewer
                        )
                    }
                    StreamingPreviewSection(
                        vm: vm,
                        messages: messages,
                        onGrow: { followTail(proxy) }
                    )
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding()
            }
            // Tap or drag the transcript to dismiss the keyboard (tapping "off"
            // the composer). The tap is simultaneous so message-bubble buttons
            // still fire; the drag gives the iOS-standard swipe-down dismissal.
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            // Decide whether to keep following the streaming tail. The trap here
            // is that a token arriving grows the content *before* the follow
            // scroll catches up, which briefly looks identical to the user
            // scrolling up. We tell them apart by the scroll offset's direction:
            //   • Re-pin whenever the bottom is in view (distance ~0). Uses
            //     `visibleRect` so it's correct regardless of insets/keyboard.
            //   • Unpin only when the offset actually *decreased* (a real upward
            //     scroll) AND we're now away from the bottom. Content growth never
            //     decreases the offset, so it can't stop the follow.
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                ScrollSnapshot(
                    offsetY: geometry.contentOffset.y,
                    distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY
                )
            } action: { old, new in
                if new.distanceFromBottom < pinThreshold {
                    isPinnedToBottom = true
                } else if new.offsetY < old.offsetY - scrollUpDeadzone {
                    isPinnedToBottom = false
                }
            }
            // A finger on the transcript always beats tail-following. Without
            // this, streaming phases where content height is constant (e.g. the
            // collapsed thinking chip while reasoning tokens arrive) would issue
            // a `scrollTo(bottom)` per token that snaps the view back mid-drag,
            // making it impossible to scroll up and escape the re-pin zone.
            .onScrollPhaseChange { _, newPhase in
                isUserScrolling = newPhase == .tracking || newPhase == .interacting
            }
            .onChange(of: messages) { _, _ in
                vm.reconcileAssistantPreview(with: messages)
                if isPinnedToBottom { scrollToBottom(proxy) }
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let usage = contextUsage {
                    ContextUsageIndicator(
                        usage: usage,
                        tokensPerSecond: vm.latestTokensPerSecond
                    )
                }
                Button {
                    Haptics.selection()
                    onNewChat()
                } label: {
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
    /// How close to the bottom (points) counts as "at the bottom" — within this,
    /// we re-pin and resume following the streaming tail.
    private let pinThreshold: CGFloat = 40
    /// Upward offset travel (points) a move must exceed to read as a deliberate
    /// scroll-up rather than scroll jitter.
    private let scrollUpDeadzone: CGFloat = 4

    /// Follow the streaming tail without animation, but only while pinned and
    /// the user's finger is off the transcript — so scrolling up to read
    /// history isn't fought by per-token scrolls.
    private func followTail(_ proxy: ScrollViewProxy) {
        if isPinnedToBottom && !isUserScrolling { scrollToBottom(proxy, animated: false) }
    }

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
        env.dictationController.stop()
        Haptics.impact(.medium)
        let animateLogo = isEmpty
        let text = input
        let pending = attachments
        composerFocused = false
        // Sending is an explicit "take me to the latest" intent: re-pin so the
        // committed message and the streamed reply are followed even if the user
        // had scrolled up while reading.
        isPinnedToBottom = true
        let accepted: Bool
        if animateLogo {
            accepted = withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                vm.send(text, attachments: pending)
            }
        } else {
            accepted = vm.send(text, attachments: pending)
        }
        // Clear the draft only when the send was accepted, so a rejected send
        // (no model selected yet, missing backend) doesn't eat the message.
        if accepted {
            input = ""
            attachments = []
        }
    }

    private func beginEditing(_ message: ChatMessage) {
        Haptics.selection()
        editingText = message.message.content
        editingMessageID = message.id
        composerFocused = false
    }

    /// Commit the inline edit: truncate after this message and re-ask the model.
    private func submitEdit() {
        guard let id = editingMessageID else { return }
        Haptics.impact(.medium)
        let text = editingText
        editingMessageID = nil
        vm.resend(afterEditing: id, newText: text)
    }
}

/// Isolates the per-token `@Observable` reads (`streamingText`, `statusText`,
/// …) in their own view so only THIS view re-evaluates per streamed token.
/// When `ChatView.body` read them directly, every token re-rendered the whole
/// visible transcript — every bubble re-ran chart decoding and image extraction
/// on the main actor, dropping frames exactly during streaming (NFR-A4).
///
/// The tail-follow scrolling rides along here for the same reason: an
/// `.onChange(of: vm.streamingText)` in the parent would re-register the
/// parent's dependency on the per-token property.
private struct StreamingPreviewSection: View {
    let vm: ChatViewModel
    let messages: [ChatMessage]
    /// Called when streamed content grows (token/reasoning): the parent scrolls
    /// the tail into view. Tokens arrive many-per-second; the parent follows
    /// without animation so overlapping animations don't jank.
    let onGrow: () -> Void

    var body: some View {
        Group {
            if vm.shouldShowAssistantPreview(alongside: messages) {
                StreamingBubble(
                    text: vm.streamingText,
                    reasoning: vm.streamingReasoning,
                    reasoningDuration: vm.streamingReasoningDuration,
                    status: vm.statusText,
                    progress: vm.statusProgress,
                    startedAt: vm.streamingStartedAt
                )
            }
        }
        .onChange(of: vm.streamingText) { _, _ in onGrow() }
        .onChange(of: vm.streamingReasoning) { _, _ in onGrow() }
    }
}

/// A snapshot of the transcript's scroll state used to decide tail-following.
/// `distanceFromBottom` is derived from `visibleRect` so it's 0 at the bottom
/// regardless of content insets; `offsetY` lets us tell a real upward scroll
/// (offset decreases) apart from content growing during streaming (offset holds).
private struct ScrollSnapshot: Equatable {
    var offsetY: CGFloat
    var distanceFromBottom: CGFloat
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
    /// On-device dictation; the mic button drives it and its transcript is
    /// mirrored into `input`.
    let dictation: DictationController
    let availableModels: [String]
    let modelName: String
    let modelSelection: Binding<String>
    /// Per-model capability sets for the model picker (nil ⇒ undetectable for
    /// this backend, so the badge is omitted rather than shown as unsupported).
    let visionModels: Set<String>?
    let toolModels: Set<String>?
    /// Per-model context window sizes for the picker's size badge.
    let contextLengths: [String: Int]?
    /// The configured default model, badged in the picker.
    let defaultModel: String?
    /// Whether the selected model can accept images (vision). Files are always
    /// allowed; only the Photos option is gated.
    let allowsImageAttachments: Bool
    /// Which server tools the backend advertises (spec §2.1). A tool is only
    /// usable when the backend advertises it *and* the model can drive tools.
    let supportsWebSearch: Bool
    let supportsImageGeneration: Bool
    /// Whether app-hosted tools (e.g. location) can ride — i.e. the backend is an
    /// orchestrator that forwards them. Combined with `modelSupportsTools`.
    let supportsLocation: Bool
    let supportsHealth: Bool
    let supportsCalendar: Bool
    /// Whether the selected model supports tool/function calling.
    let modelSupportsTools: Bool
    /// Whether the backend exposes the app's Thinking control at all.
    let showsThinkingToggle: Bool
    /// Whether the selected model supports reasoning/thinking output.
    let modelSupportsThinking: Bool
    let webSearchEnabled: Binding<Bool>
    let imageGenerationEnabled: Binding<Bool>
    let locationEnabled: Binding<Bool>
    let healthEnabled: Binding<Bool>
    let calendarEnabled: Binding<Bool>
    /// Research modes the backend advertises (e.g. Deep Research). Empty ⇒ the
    /// composer hides the research UI (graceful, older/non-orchestrator backends).
    let availableModes: [Capabilities.Mode]
    /// The per-message research mode selection (nil = ordinary turn).
    let modeID: Binding<String?>
    let reasoningEfforts: [String]
    let thinkingEnabled: Binding<Bool>
    let selectedReasoningEffort: Binding<String>
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var showOptions = false
    @State private var showModelPicker = false
    /// The composer text captured when dictation starts, so the live transcript
    /// is appended to (not overwriting) what the user already typed.
    @State private var dictationBase = ""
    /// Recording was latched hands-free (slid up past the lock threshold).
    @State private var dictationLocked = false
    /// 0…1 progress of the slide-up-to-lock and slide-to-cancel gestures, for
    /// animating the hint affordances.
    @State private var dictationLockProgress: CGFloat = 0
    @State private var dictationCancelProgress: CGFloat = 0

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

            if let error = dictation.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
            }

            TextField("Message", text: $input, axis: .vertical)
                .lineLimit(1...8)
                .focused(focus)
                .disabled(isStreaming)
                .padding(.horizontal, 18)
                .padding(.top, attachments.isEmpty ? 14 : 4)
                .submitLabel(.return)

            HStack(spacing: 8) {
                if dictation.isRecording && dictationLocked {
                    // Hands-free: tap to discard or stop.
                    cancelRecordingButton
                    RecordingIndicator()
                    Spacer(minLength: 8)
                    recordingStopButton
                } else {
                    // Idle + held-recording share this row so the mic's UIKit
                    // gesture view is never torn down mid-press.
                    addButton.opacity(dictation.isRecording ? 0 : 1)
                    modelPicker.opacity(dictation.isRecording ? 0 : 1)
                    Spacer(minLength: 8)
                    control
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: dictation.isRecording)
            .animation(.easeInOut(duration: 0.2), value: dictationLocked)
        }
        // Slide-to-lock and slide-to-cancel affordances, shown while holding.
        .overlay(alignment: .bottomTrailing) {
            if dictation.isRecording && !dictationLocked {
                lockHint.padding(.trailing, 13).offset(y: -52).transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if dictation.isRecording && !dictationLocked {
                cancelHint.padding(.leading, 18).padding(.bottom, 16).transition(.opacity)
            }
        }
        .onChange(of: dictation.liveTranscript) { _, transcript in
            // Mirror the live transcript into the composer, appended to whatever
            // was already typed when dictation started. Empty transcript (start /
            // cancel) reverts to that base text.
            input = transcript.isEmpty
                ? dictationBase
                : (dictationBase.isEmpty ? transcript : dictationBase + " " + transcript)
        }
        .onChange(of: dictation.isRecording) { _, recording in
            if !recording {
                dictationLocked = false
                dictationLockProgress = 0
                dictationCancelProgress = 0
            }
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
                supportsLocation: supportsLocation,
                supportsHealth: supportsHealth,
                supportsCalendar: supportsCalendar,
                modelSupportsTools: modelSupportsTools,
                showsThinkingToggle: showsThinkingToggle,
                modelSupportsThinking: modelSupportsThinking,
                webSearchEnabled: webSearchEnabled,
                imageGenerationEnabled: imageGenerationEnabled,
                locationEnabled: locationEnabled,
                healthEnabled: healthEnabled,
                calendarEnabled: calendarEnabled,
                availableModes: availableModes,
                modeID: modeID,
                reasoningEfforts: reasoningEfforts,
                thinkingEnabled: thinkingEnabled,
                selectedReasoningEffort: selectedReasoningEffort
            )
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: availableModels,
                selection: modelSelection,
                visionModels: visionModels,
                toolModels: toolModels,
                contextLengths: contextLengths,
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
            Haptics.selection()
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
                Haptics.selection()
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

    /// The bottom-trailing control. While idle or holding-to-record it's the mic
    /// (a UIKit-gesture-backed button, Signal-style); otherwise stop or send.
    @ViewBuilder
    private var control: some View {
        if isStreaming {
            stopButton
        } else if dictation.isTranscribing {
            ProgressView()
                .frame(width: 34, height: 34)
                .accessibilityLabel("Transcribing")
        } else if sendEnabled && !dictation.isRecording {
            sendButton
        } else {
            micButton
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            controlIcon("stop.fill", background: Color.primary)
        }
        .accessibilityLabel("Stop")
    }

    private var sendButton: some View {
        Button(action: onSend) {
            controlIcon("arrow.up", background: Color.accentColor)
        }
        .accessibilityLabel("Send")
    }

    /// Hold-to-talk mic (Signal-style). A UIKit `UILongPressGestureRecognizer`
    /// drives it — unlike a SwiftUI gesture it survives the composer re-rendering
    /// as the transcript streams in. Hold to record, release to keep the result,
    /// slide up to lock hands-free, slide sideways to cancel.
    private var micButton: some View {
        controlIcon("mic", background: dictation.isRecording ? Color.red : Color.accentColor)
            .scaleEffect(dictation.isRecording ? 1.1 : 1)
            .animation(.easeOut(duration: 0.15), value: dictation.isRecording)
            .overlay {
                HoldToRecordGesture(
                    onStart: beginHeldRecording,
                    onChange: { lock, cancel in
                        dictationLockProgress = lock
                        dictationCancelProgress = cancel
                    },
                    onLock: lockRecording,
                    onCancel: cancelHeldRecording,
                    onComplete: completeHeldRecording
                )
            }
            .accessibilityLabel("Hold to dictate")
            .accessibilityHint("Hold to record, slide up to lock, slide sideways to cancel")
    }

    // MARK: Dictation gesture handlers

    private func beginHeldRecording() {
        dictationBase = trimmed
        dictationLockProgress = 0
        dictationCancelProgress = 0
        dictation.start()
    }

    private func lockRecording() {
        dictationLocked = true
        dictationLockProgress = 1
        Haptics.impact(.rigid)
    }

    /// Release while held → stop and transcribe; the result lands in the composer.
    private func completeHeldRecording() {
        dictation.stop()
    }

    /// Slide-to-cancel → stop and discard, no transcription.
    private func cancelHeldRecording() {
        dictation.cancel()
    }

    /// "Slide up to lock" affordance shown above the mic while holding; fills in
    /// as the slide approaches the lock threshold.
    private var lockHint: some View {
        VStack(spacing: 3) {
            Image(systemName: "lock.fill")
            Image(systemName: "chevron.up")
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(.thinMaterial, in: Capsule())
        .opacity(0.55 + 0.45 * dictationLockProgress)
        .scaleEffect(1 + 0.15 * dictationLockProgress)
        .offset(y: -10 * dictationLockProgress)
    }

    private var cancelHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.compact.left")
            Text("Slide to cancel")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .opacity(1 - dictationCancelProgress)
    }

    // MARK: Recording bar (shown in place of the normal controls once locked)

    /// Stop recording and keep the transcript in the composer for review/sending.
    private var recordingStopButton: some View {
        Button { dictation.stop() } label: {
            controlIcon("stop.fill", background: Color.red)
        }
        .accessibilityLabel("Stop dictation")
    }

    /// Discard the recording — no transcription.
    private var cancelRecordingButton: some View {
        Button {
            dictation.cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .accessibilityLabel("Cancel dictation")
    }

    private func controlIcon(_ systemName: String, background: some ShapeStyle) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.background)
            .frame(width: 34, height: 34)
            .background(background, in: Circle())
    }
}

/// The pulsing red dot + "Listening…" shown while recording is locked. Owns its
/// own pulse state so it stays out of the composer's state surface.
private struct RecordingIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text("Listening…")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .onAppear { pulse = true }
    }
}

/// A transparent overlay hosting a UIKit `UILongPressGestureRecognizer`
/// (`minimumPressDuration = 0`) that powers Signal-style hold-to-record. UIKit
/// recognizers live on a persistent `UIView`, so — unlike a SwiftUI gesture —
/// they aren't cancelled when the composer re-renders as the transcript streams
/// in. The state machine mirrors Signal's `handleVoiceMemoLongPress`.
private struct HoldToRecordGesture: UIViewRepresentable {
    var onStart: () -> Void
    /// Reports slide progress as (lock 0…1, cancel 0…1) for the hint affordances.
    var onChange: (CGFloat, CGFloat) -> Void
    var onLock: () -> Void
    var onCancel: () -> Void
    var onComplete: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        recognizer.minimumPressDuration = 0
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.owner = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    final class Coordinator: NSObject {
        var owner: HoldToRecordGesture

        private enum Phase { case idle, held, locked }
        private var phase: Phase = .idle
        private var start: CGPoint = .zero

        // Thresholds match Signal: a 20pt deadzone then 80pt of travel to lock
        // (slide up); 100pt sideways to cancel.
        private let lockDeadzone: CGFloat = 20
        private let lockTravel: CGFloat = 80
        private let cancelTravel: CGFloat = 100

        init(owner: HoldToRecordGesture) { self.owner = owner }

        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                phase = .held
                start = gesture.location(in: view)
                owner.onStart()

            case .changed:
                guard phase == .held else { return }
                let location = gesture.location(in: view)
                let up = start.y - location.y
                let sideways = abs(start.x - location.x)

                let lock = max(min((up - lockDeadzone) / lockTravel, 1), 0)
                let cancel = max(min(sideways / cancelTravel, 1), 0)

                if lock >= 1 {
                    phase = .locked
                    owner.onLock()
                    return
                }
                if cancel >= 1 {
                    phase = .idle
                    owner.onCancel()
                    return
                }
                owner.onChange(lock, cancel)

            case .ended:
                if phase == .held {
                    phase = .idle
                    owner.onComplete()
                }
                // Locked: keep recording; the on-screen stop/cancel take over.

            case .cancelled, .failed:
                if phase == .held {
                    phase = .idle
                    owner.onCancel()
                }

            default:
                break
            }
        }
    }
}
