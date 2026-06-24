import PhantasmKit
import SwiftUI

/// Top-level navigation (Claude-style): the app opens straight into a chat with
/// the composer ready. Conversation history lives in a slide-over drawer the
/// user pulls in from the leading edge or the toolbar button.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    /// The displayed conversation. A new chat is an in-memory draft (a value with
    /// a fresh id) that isn't written to the store until its first message is sent.
    @State private var selection: Conversation?
    @State private var showSettings = false
    @State private var isDrawerOpen = false
    /// Live drag translation while the user is swiping the drawer.
    @State private var dragOffset: CGFloat = 0

    private let drawerWidth: CGFloat = 320

    var body: some View {
        ZStack(alignment: .leading) {
            chatArea
                .disabled(isDrawerOpen)

            scrim
            drawer
        }
        .gesture(edgeOpenGesture)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: isDrawerOpen)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            if selection == nil { selection = makeNewChat() }
        }
    }

    // MARK: Chat

    @ViewBuilder
    private var chatArea: some View {
        if let selection {
            ChatView(
                conversation: selection,
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
            onOpenSettings: { showSettings = true; closeDrawer() }
        )
        .frame(width: drawerWidth)
        .frame(maxHeight: .infinity)
        .offset(x: drawerXOffset)
        .gesture(closeDragGesture)
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
        Conversation(
            title: "New Chat",
            modelID: env.preferredModel,
            profileID: env.activeProfileID
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

    private func openDrawer() {
        dragOffset = 0
        isDrawerOpen = true
    }

    private func closeDrawer() {
        dragOffset = 0
        isDrawerOpen = false
    }
}
