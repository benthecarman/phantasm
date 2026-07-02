import GRDBQuery
import PhantasmKit
import SwiftUI
import UIKit

/// The slide-over history pane (Claude-style): a "new chat" affordance at the
/// top, a full-text search field, the reverse-chronological conversation list,
/// settings, and the backend mode banner. Chat detail stays the root of the app;
/// this drawer overlays it.
struct HistoryDrawer: View {
    @Environment(AppEnvironment.self) private var env
    /// Empty search → all conversations (recent first); non-empty → ranked FTS5
    /// results across titles + message content. Bound to the search field below.
    @Query(ConversationsRequest()) private var results: [ConversationSearchResult]

    /// The currently displayed conversation (may be an unsaved new chat).
    let selection: Conversation?
    let onSelect: (Conversation) -> Void
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void
    /// Called with the ids being deleted, before the rows are removed — the
    /// owner stops any in-flight turn for them and drops their cached VMs.
    var onDeleted: ([UUID]) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            list
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .trailing) {
            // A hairline on the edge that faces the chat so the drawer reads as a
            // distinct surface instead of bleeding into the content behind it.
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 0.5)
        }
    }

    private var header: some View {
        HStack {
            Text("Chats")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // Bound to the GRDBQuery request: editing re-runs the FTS5 search live.
            TextField("Search chats", text: $results.searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !$results.searchText.wrappedValue.isEmpty {
                Button {
                    Haptics.selection()
                    $results.searchText.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var list: some View {
        List {
            if env.activeProfile == nil {
                Button(action: onOpenSettings) {
                    Label("Add a backend to start", systemImage: "server.rack")
                }
            }
            ForEach(results) { result in
                let isSelected = result.conversation.id == selection?.id
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.conversation.title).lineLimit(1)
                    if let snippet = result.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(result.conversation.updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The row used to lean on List's default insets for padding; we
                // zero those out below (so the red fill reaches the edges) and
                // reinstate the spacing here on the content itself.
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                // Opaque row surface (selection tint composited over the drawer's
                // own color) so the swipe's red fill stays hidden until the row is
                // dragged aside. Must sit *under* the swipe modifier.
                .background {
                    ZStack {
                        Color(.secondarySystemBackground)
                        if isSelected { Color.accentColor.opacity(0.12) }
                    }
                }
                .swipeToDelete {
                    Haptics.notify(.warning)
                    deleteConversation(result.conversation)
                }
                // A tap selects the chat. Unlike a Button, a tap gesture fails once
                // the finger moves past its slop, so a swipe-to-delete no longer
                // also fires selection (which was opening the chat + closing the
                // drawer mid-delete).
                .onTapGesture { onSelect(result.conversation) }
                // Zero insets + hidden separator let the red fill span the entire
                // row edge-to-edge instead of the system's inset pill.
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        // Let the drawer's surface show through the list instead of the list's own
        // (system-background) fill, so the whole sidebar reads as one color.
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            if env.activeProfile != nil {
                StatusPill(text: backendModeLabel, systemImage: backendModeIcon)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var backendModeLabel: String {
        switch env.backendMode {
        case .full:
            return env.backendMode.showsTools ? "Tools enabled" : "Tools disabled"
        case .ollamaNative:
            return "Ollama native"
        case .plainChatOnly:
            return "Plain chat"
        }
    }

    private var backendModeIcon: String {
        switch env.backendMode {
        case .full:
            return env.backendMode.showsTools ? "wand.and.stars" : "server.rack"
        case .ollamaNative:
            return "cpu"
        case .plainChatOnly:
            return "text.bubble"
        }
    }

    private func deleteConversation(_ conversation: Conversation) {
        deleteConversations(ids: [conversation.id])
    }

    private func deleteConversations(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        // Stop in-flight turns first: a deleted chat's stream must not keep
        // running (holding the backend) or commit into rows being removed.
        onDeleted(ids)
        if let selectionID = selection?.id, ids.contains(selectionID) { onNewChat() }
        let store = env.store
        Task {
            for id in ids {
                // Clean up server-hosted images first — it reads the messages
                // that deleteConversation then hard-deletes.
                await env.purgeServerImages(conversationID: id)
                try? await store.deleteConversation(id: id)
            }
        }
    }
}

// MARK: - Swipe to delete

private extension View {
    /// Full-bleed swipe-to-delete: dragging the row leftward reveals a red fill
    /// that spans the *entire* row (no system inset "pill", no "Delete" label —
    /// just a trash glyph). Releasing past the commit threshold runs `action`; a
    /// shorter drag springs back.
    func swipeToDelete(action: @escaping () -> Void) -> some View {
        modifier(SwipeToDelete(action: action))
    }
}

private struct SwipeToDelete: ViewModifier {
    let action: () -> Void

    @State private var offset: CGFloat = 0
    /// Whether the drag has crossed `commitThreshold` — drives the "armed" cue
    /// (icon scale) and gates the one-shot haptic so it fires only on crossing.
    @State private var armed = false
    /// Measured row width, so a committed swipe slides the content fully off and
    /// the red fills the rest of the row.
    @State private var rowWidth: CGFloat = 0
    /// Horizontal-vs-vertical intent, decided once at the start of a drag (nil =
    /// undecided). Deciding up front — instead of re-checking width-vs-height
    /// every frame — keeps the row tracking the finger through the final pixels of
    /// a slide-back, where the cumulative horizontal delta shrinks below any
    /// incidental vertical drift and a per-frame guard would freeze it.
    @State private var horizontalDrag: Bool?
    /// Reused, pre-prepared generator — firing it is cheap, unlike building a
    /// fresh `UIImpactFeedbackGenerator` + `prepare()` on the main thread mid-drag
    /// (that synchronous spin-up was the stall felt when crossing the threshold).
    @State private var armHaptic = UIImpactFeedbackGenerator(style: .rigid)

    /// Leftward drag distance past which releasing commits the delete.
    private let commitThreshold: CGFloat = 100

    /// Icon scale derived purely from `offset` (1 → 1.25 across a short band just
    /// past the threshold). Keeping it a function of the drag — rather than a
    /// spring keyed on a bool — means nothing animates mid-drag, so the row tracks
    /// the finger 1:1 with no stall when sliding back.
    private var iconScale: CGFloat {
        1 + min(0.25, max(0, -offset - commitThreshold) / 40 * 0.25)
    }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            // Sits behind the opaque row content, filling the whole row. Only the
            // strip uncovered as the row slides left actually shows red.
            .background {
                Color.red
                    .overlay(alignment: .trailing) {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .scaleEffect(iconScale)
                            .padding(.trailing, 24)
                            .opacity(Double(min(1, -offset / commitThreshold)))
                    }
            }
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { rowWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newValue in rowWidth = newValue }
                }
            }
            .clipped()
            .simultaneousGesture(
                // simultaneous (not exclusive) so the List keeps scrolling
                // vertically and the row's tap still selects the chat.
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        // Decide direction once, on the first movement, then commit
                        // to it for the rest of the drag (so the final pixels of a
                        // slide-back still track the finger).
                        if horizontalDrag == nil {
                            horizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                            if horizontalDrag == true { armHaptic.prepare() }
                        }
                        guard horizontalDrag == true else { return }
                        // Track the finger but clamp closed at 0 — this lets you
                        // drag back the whole way to fully shut it.
                        offset = min(0, value.translation.width)
                        let nowArmed = -offset >= commitThreshold
                        if nowArmed != armed {
                            // Tick only when *arming* (crossing far enough), not
                            // when backing off — a haptic on the slide-back is what
                            // stalled it near the threshold.
                            if nowArmed {
                                armHaptic.impactOccurred()
                                armHaptic.prepare()
                            }
                            armed = nowArmed
                        }
                    }
                    .onEnded { _ in
                        horizontalDrag = nil
                        if offset < -commitThreshold {
                            // Slide the content fully off so the red fills the rest
                            // of the row, then delete after a short beat — long
                            // enough to register the fill, short enough not to hang.
                            let target = rowWidth > 0 ? -rowWidth : -2000
                            withAnimation(.easeOut(duration: 0.18)) { offset = target }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                action()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                offset = 0
                            }
                            armed = false
                        }
                    }
            )
    }
}
