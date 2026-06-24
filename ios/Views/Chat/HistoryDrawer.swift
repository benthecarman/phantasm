import PhantasmKit
import SwiftData
import SwiftUI

/// The slide-over history pane (Claude-style): a "new chat" affordance at the
/// top, the reverse-chronological conversation list, settings, and the backend
/// mode banner. Chat detail stays the root of the app; this drawer overlays it.
struct HistoryDrawer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    /// The currently displayed conversation (may be an unsaved new chat).
    let selection: Conversation?
    let onSelect: (Conversation) -> Void
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .background(.background)
    }

    private var header: some View {
        HStack {
            Text("Chats")
                .font(.title3.weight(.semibold))
            Spacer()
            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
            }
            .disabled(env.activeProfile == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var list: some View {
        List {
            if env.activeProfile == nil {
                Button(action: onOpenSettings) {
                    Label("Add a backend to start", systemImage: "server.rack")
                }
            }
            ForEach(conversations) { convo in
                Button {
                    onSelect(convo)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(convo.title).lineLimit(1)
                        Text(convo.updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(convo.id == selection?.id ? Color.accentColor.opacity(0.12) : nil)
            }
            .onDelete(perform: deleteConversations)
        }
        .listStyle(.plain)
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
            return env.backendMode.showsTools ? "Full (tools available)" : "Full"
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
        for index in offsets {
            let convo = conversations[index]
            context.delete(convo)
            if convo.id == selection?.id { onNewChat() }
        }
        try? context.save()
    }
}
