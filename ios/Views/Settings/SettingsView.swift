import PhantasmKit
import SwiftUI

/// Backend profile management (FR-A1, NFR-A6). Add/edit/delete profiles, set the
/// active one. Tokens are stored in the Keychain via `AppEnvironment`.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// The root coordinates live turns with the destructive store write and
    /// only starts a fresh chat after deletion succeeds.
    var onDeleteAllHistory: () async throws -> Void = {}

    @State private var editing: BackendProfile?
    @State private var isCreating = false
    @State private var isConfirmingDeleteAll = false
    @State private var isDeletingHistory = false
    @State private var deletionError: String?
    /// Scanner → confirmation as one sheet (FR-A12), so the hand-off between
    /// the two stages can't race a second presentation.
    @State private var pairingRoute: PairingSheetRoute?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(env.profiles) { profile in
                        Button {
                            if profile.id != env.activeProfileID { Haptics.selection() }
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
                                    Haptics.selection()
                                    editing = profile
                                } label: {
                                    Image(systemName: "info.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Haptics.notify(.warning)
                                env.delete(profile)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                Haptics.selection()
                                editing = profile
                            } label: {
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
                        Haptics.selection()
                        isCreating = true
                    } label: {
                        Label("Add Backend", systemImage: "plus")
                    }
                    Button {
                        Haptics.selection()
                        pairingRoute = .scan
                    } label: {
                        Label("Pair via QR Code", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("Running the Phantasm orchestrator? `phantasm-orchestrator pair` prints a code to scan.")
                }

                Section {
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        Label("Voice", systemImage: "waveform")
                    }
                    NavigationLink {
                        PrivacyDataView()
                    } label: {
                        Label("Privacy & Data", systemImage: "hand.raised")
                    }
                } footer: {
                    Text("Read-aloud voice, auto-speak, dictation, and data controls.")
                }

                Section {
                    Button(role: .destructive) {
                        Haptics.notify(.warning)
                        isConfirmingDeleteAll = true
                    } label: {
                        if isDeletingHistory {
                            Label {
                                Text("Deleting Chat History…")
                            } icon: {
                                ProgressView()
                            }
                        } else {
                            Label("Delete All Chat History", systemImage: "trash")
                        }
                    }
                    .disabled(isDeletingHistory)
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
            .sheet(item: $pairingRoute) { _ in
                PairingFlowSheet(route: $pairingRoute)
            }
            .alert(
                "Confirm",
                isPresented: $isConfirmingDeleteAll,
            ) {
                Button("Delete All", role: .destructive) {
                    Haptics.notify(.warning)
                    isDeletingHistory = true
                    Task {
                        defer { isDeletingHistory = false }
                        do {
                            try await onDeleteAllHistory()
                        } catch {
                            deletionError = AppError.from(error).userMessage
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete all chat history?")
            }
            .alert(
                "Couldn't Delete Chat History",
                isPresented: Binding(
                    get: { deletionError != nil },
                    set: { if !$0 { deletionError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionError ?? "Chat history could not be deleted.")
            }
        }
    }
}
