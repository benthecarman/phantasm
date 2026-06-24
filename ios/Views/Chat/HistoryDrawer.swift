import GRDBQuery
import PhantasmKit
import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            list
            Divider()
            footer
        }
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .trailing) {
            // A hairline on the edge that faces the chat so the drawer reads as a
            // distinct surface instead of bleeding into the content behind it.
            Divider()
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
                Button {
                    onSelect(result.conversation)
                } label: {
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    result.conversation.id == selection?.id ? Color.accentColor.opacity(0.12) : Color.clear
                )
            }
            .onDelete(perform: deleteConversations)
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

    private func deleteConversations(_ offsets: IndexSet) {
        let ids = offsets.map { results[$0].conversation.id }
        if ids.contains(where: { $0 == selection?.id }) { onNewChat() }
        let store = env.store
        Task {
            for id in ids {
                try? await store.deleteConversation(id: id)
            }
        }
    }
}
