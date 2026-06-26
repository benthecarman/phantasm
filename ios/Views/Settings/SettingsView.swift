import PhantasmKit
import SwiftUI

/// Backend profile management (FR-A1, NFR-A6). Add/edit/delete profiles, set the
/// active one. Tokens are stored in the Keychain via `AppEnvironment`.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Invoked after chat history is fully cleared, so the host can drop the
    /// (now-tombstoned) open conversation and present a fresh chat.
    var onHistoryCleared: () -> Void = {}

    @State private var editing: BackendProfile?
    @State private var isCreating = false
    @State private var isConfirmingDeleteAll = false

    /// Combined status of the on-device speech models for the Settings row, in a
    /// single pass so the label and the download affordance can't disagree.
    private var voiceModelState: (statusText: String, needsDownload: Bool) {
        switch (env.speechModels.sttStatus, env.speechModels.ttsStatus) {
        case (.ready, .ready): return ("Ready", false)
        case (.failed, _), (_, .failed): return ("Failed", true)
        case (.preparing, _), (_, .preparing): return ("Preparing…", false)
        case (.notLoaded, .notLoaded): return ("Not downloaded", true)
        default: return ("Not downloaded", false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(env.profiles) { profile in
                        Button {
                            env.setActive(profile.id)
                        } label: {
                            HStack {
                                Image(systemName: profile.id == env.activeProfileID
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(profile.id == env.activeProfileID ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                VStack(alignment: .leading) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.baseURLString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    editing = profile
                                } label: {
                                    Image(systemName: "info.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { env.delete(profile) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { editing = profile } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("Backends")
                } footer: {
                    Text("Tap to use a backend. Tap the ⓘ to edit its connection or default model.")
                }

                Section {
                    Button {
                        isCreating = true
                    } label: {
                        Label("Add Backend", systemImage: "plus")
                    }
                }

                Section {
                    Toggle("Auto-speak responses", isOn: Binding(
                        get: { env.voicePreferenceStore.autoSpeak },
                        set: { env.voicePreferenceStore.autoSpeak = $0 }
                    ))
                    HStack {
                        Text("Voice models")
                        Spacer()
                        Text(voiceModelState.statusText).foregroundStyle(.secondary)
                    }
                    if voiceModelState.needsDownload {
                        Button {
                            env.speechModels.prepareAll()
                        } label: {
                            Label("Download voice models", systemImage: "arrow.down.circle")
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Dictation and read-aloud run entirely on-device. The speech models download once on first use, then work offline. Auto-speak reads each reply aloud when it finishes.")
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingDeleteAll = true
                    } label: {
                        Label("Delete All Chat History", systemImage: "trash")
                    }
                } footer: {
                    Text("Permanently removes every conversation and its messages from this device. This can't be undone.")
                }
            }
            .navigationTitle("Settings")
            // Pull to re-probe the active backend, picking up tools toggled on
            // server-side (web search / image generation) without a relaunch.
            .refreshable { await env.refreshCapabilities() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { profile in
                ProfileEditView(profile: profile)
            }
            .sheet(isPresented: $isCreating) {
                ProfileEditView(profile: nil)
            }
            .alert(
                "Confirm",
                isPresented: $isConfirmingDeleteAll,
            ) {
                Button("Delete All", role: .destructive) {
                    let store = env.store
                    Task {
                        try? await store.deleteAllConversations()
                        onHistoryCleared()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete all chat history?")
            }
        }
    }
}
