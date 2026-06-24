import PhantasmKit
import SwiftData
import SwiftUI

/// Top-level navigation: conversation list (sidebar) + chat detail. Collapses to
/// a stack on iPhone; split view on iPad (NFR-A1 bonus).
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var selection: Conversation?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selection {
                ChatView(conversation: selection)
                    .id(selection.id)
            } else {
                ContentUnavailableView(
                    "No Chat Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a chat or start a new one.")
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if env.activeProfile == nil {
                Section {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Add a backend to start", systemImage: "server.rack")
                    }
                }
            }
            ForEach(conversations) { convo in
                NavigationLink(value: convo) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(convo.title).lineLimit(1)
                        Text(convo.updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteConversations)
        }
        .navigationTitle("Chats")
        .overlay(alignment: .bottom) { modeBanner }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: newChat) { Image(systemName: "square.and.pencil") }
                    .disabled(env.activeProfile == nil)
            }
        }
    }

    @ViewBuilder
    private var modeBanner: some View {
        let label = env.backendMode.showsTools ? "Full (tools available)" : "Plain chat"
        if env.activeProfile != nil {
            StatusPill(text: label, systemImage: env.backendMode.showsTools ? "wand.and.stars" : "text.bubble")
                .padding(.bottom, 8)
        }
    }

    private func newChat() {
        let convo = Conversation(
            title: "New Chat",
            modelID: env.preferredModel,
            profileID: env.activeProfileID
        )
        context.insert(convo)
        try? context.save()
        selection = convo
    }

    private func deleteConversations(_ offsets: IndexSet) {
        for index in offsets {
            let convo = conversations[index]
            if convo.id == selection?.id { selection = nil }
            context.delete(convo)
        }
        try? context.save()
    }
}
