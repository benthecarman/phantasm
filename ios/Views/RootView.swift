import PhantasmKit
import SwiftUI

/// Top-level navigation (Claude-style): the app opens straight into a chat with
/// the composer ready. Conversation history lives in a slide-over drawer the
/// user pulls in from the leading edge or the toolbar button.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(NotificationRouter.self) private var notificationRouter
    @Environment(\.scenePhase) private var scenePhase

    /// The displayed conversation. A new chat is an in-memory draft (a value with
    /// a fresh id) that isn't written to the store until its first message is sent.
    @State private var selection: Conversation?
    /// The chat created at cold launch. Only this one auto-raises the keyboard;
    /// new chats started mid-session do not (the auto-focus is "open the app and
    /// start typing", not "every empty chat grabs the keyboard").
    @State private var initialChatID: UUID?
    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var showStorageWarning = false
    @State private var isDrawerOpen = false
    @State private var chatViewModels = ChatViewModelCache()
    /// Live drag translation while the user is swiping the drawer.
    @State private var dragOffset: CGFloat = 0

    private let drawerWidth: CGFloat = 320
    private let edgeSwipeWidth: CGFloat = 24
    private let toolbarGestureExclusionHeight: CGFloat = 44

    var body: some View {
        Group {
            if showOnboarding {
                OnboardingView {
                    showOnboarding = false
                    startNewChat()
                }
            } else {
                ZStack(alignment: .leading) {
                    chatArea
                        .disabled(isDrawerOpen)

                    edgeOpenArea
                    scrim
                    drawer
                }
                .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: isDrawerOpen)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onHistoryCleared: { startNewChat() })
        }
        .onChange(of: scenePhase) { _, phase in
            chatViewModels.setSceneActive(phase == .active)
        }
        .onChange(of: notificationRouter.pendingConversationID) { _, id in
            if let id { openConversation(id: id) }
        }
        .onChange(of: env.profiles) { _, _ in
            if shouldShowOnboarding {
                showOnboarding = true
                closeDrawer()
            }
        }
        .alert("Chat history unavailable", isPresented: $showStorageWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "The message store could not be opened (the disk may be full). "
                    + "You can still chat, but this session's messages won't be saved."
            )
        }
        .task {
            if env.databaseOpenFailed { showStorageWarning = true }
            if shouldShowOnboarding {
                showOnboarding = true
                return
            }
            if selection == nil {
                let chat = makeNewChat()
                initialChatID = chat.id
                selection = chat
            }
            // A tap that cold-launched the app may have set this before the view
            // appeared, so `.onChange` won't have fired for it.
            if let id = notificationRouter.pendingConversationID {
                openConversation(id: id)
            }
        }
    }

    private var shouldShowOnboarding: Bool {
        env.profiles.isEmpty
    }

    private var edgeOpenArea: some View {
        GeometryReader { proxy in
            edgeOpenHitRegion(in: proxy)
        }
        .allowsHitTesting(!isDrawerOpen)
    }

    private func edgeOpenHitRegion(in proxy: GeometryProxy) -> some View {
        let topOffset = proxy.safeAreaInsets.top + toolbarGestureExclusionHeight
        let height = max(0, proxy.size.height - topOffset)

        return Color.clear
            .frame(width: edgeSwipeWidth, height: height)
            .contentShape(Rectangle())
            .gesture(edgeOpenGesture)
            .position(x: edgeSwipeWidth / 2, y: topOffset + height / 2)
    }

    // MARK: Chat

    @ViewBuilder
    private var chatArea: some View {
        if let selection {
            ChatView(
                conversation: selection,
                viewModel: chatViewModels.viewModel(for: selection.id),
                autoFocusComposer: selection.id == initialChatID,
                onOpenHistory: { openDrawer() },
                onNewChat: { startNewChat() }
            )
            .id(selection.id)
        } else {
            Color(.systemBackground)
        }
    }

    // MARK: Drawer

    private var scrim: some View {
        Color.black
            .opacity(isDrawerOpen ? 0.3 * dimFactor : 0)
            .ignoresSafeArea()
            .allowsHitTesting(isDrawerOpen)
            .onTapGesture { closeDrawer() }
    }

    private var drawer: some View {
        HistoryDrawer(
            selection: selection,
            onSelect: { open($0) },
            onNewChat: { startNewChat() },
            onOpenSettings: { showSettings = true; closeDrawer() },
            onDeleted: { chatViewModels.discard(ids: $0) }
        )
        .frame(width: drawerWidth)
        .frame(maxHeight: .infinity)
        .offset(x: drawerXOffset)
        .gesture(closeDragGesture)
        .allowsHitTesting(isDrawerOpen)
        .accessibilityHidden(!isDrawerOpen)
        .shadow(color: .black.opacity(isDrawerOpen ? 0.2 : 0), radius: 12, x: 4)
    }

    /// The drawer's current x position, honoring an in-progress drag.
    private var drawerXOffset: CGFloat {
        let base = isDrawerOpen ? 0 : -drawerWidth
        return max(-drawerWidth, min(0, base + dragOffset))
    }

    /// 0…1 how far open the drawer is, for fading the scrim with the drag.
    private var dimFactor: Double {
        Double((drawerXOffset + drawerWidth) / drawerWidth)
    }

    // MARK: Gestures

    /// Swipe in from the leading edge to reveal the drawer.
    private var edgeOpenGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isDrawerOpen, value.startLocation.x < 24, value.translation.width > 0 else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard !isDrawerOpen, value.startLocation.x < 24 else { return }
                if value.translation.width > drawerWidth / 3 { openDrawer() }
                dragOffset = 0
            }
    }

    /// Swipe the open drawer back to the left to dismiss it.
    private var closeDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isDrawerOpen, value.translation.width < 0 else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard isDrawerOpen else { return }
                if value.translation.width < -drawerWidth / 3 { closeDrawer() }
                dragOffset = 0
            }
    }

    // MARK: Actions

    private func makeNewChat() -> Conversation {
        // Leave `modelID` unset so the composer falls through to the active
        // backend's `env.preferredModel` (ChatView.currentModelID). Baking the
        // default in here would freeze it, so switching backends wouldn't update
        // the composer's model. The resolved model is persisted on first send.
        Conversation(
            title: "New Chat",
            modelID: nil,
            profileID: env.activeProfileID,
            // Sticky: a new chat inherits the last device-tool choices, so enabling
            // one keeps it on across chats.
            locationEnabled: env.toolPreferenceStore.locationEnabledDefault,
            healthEnabled: env.toolPreferenceStore.healthEnabledDefault,
            calendarEnabled: env.toolPreferenceStore.calendarEnabledDefault
        )
    }

    private func startNewChat() {
        selection = makeNewChat()
        closeDrawer()
    }

    private func open(_ convo: Conversation) {
        selection = convo
        closeDrawer()
    }

    /// Navigate to the chat behind a tapped completion notification. The
    /// conversation must be reloaded from the store (the notification only
    /// carries its id), and the pending id is cleared so a later tap of the
    /// same chat registers as a fresh change.
    private func openConversation(id: UUID) {
        Task {
            defer { notificationRouter.pendingConversationID = nil }
            guard let detail = try? await env.store.conversationDetail(id: id) else { return }
            selection = detail.conversation
            closeDrawer()
        }
    }

    private func openDrawer() {
        dragOffset = 0
        guard !isDrawerOpen else { return }
        Haptics.selection()
        isDrawerOpen = true
    }

    private func closeDrawer() {
        dragOffset = 0
        guard isDrawerOpen else { return }
        Haptics.selection()
        isDrawerOpen = false
    }
}

@MainActor
private final class ChatViewModelCache {
    private var models: [UUID: ChatViewModel] = [:]
    private let capacity = 16

    func viewModel(for id: UUID) -> ChatViewModel {
        if let model = models[id] { return model }
        // Bound the cache: idle VMs for long-closed chats are recreated
        // cheaply, but a streaming VM must survive (it owns the live turn).
        if models.count >= capacity {
            for (key, model) in models where !model.isStreaming {
                models.removeValue(forKey: key)
                if models.count < capacity { break }
            }
        }
        let model = ChatViewModel()
        models[id] = model
        return model
    }

    /// Stop any in-flight turn and drop the cached VMs for deleted chats — a
    /// deleted conversation's stream must not keep running or commit into
    /// rows that no longer exist.
    func discard(ids: [UUID]) {
        for id in ids {
            guard let model = models.removeValue(forKey: id) else { continue }
            if model.isStreaming { model.stop() }
        }
    }

    func setSceneActive(_ active: Bool) {
        for model in models.values {
            model.setSceneActive(active)
        }
    }
}
