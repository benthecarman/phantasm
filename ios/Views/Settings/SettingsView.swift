import PhantasmKit
import SwiftUI

/// Backend profile management (FR-A1, NFR-A6). Add/edit/delete profiles, set the
/// active one. Tokens are stored in the Keychain via `AppEnvironment`.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var editing: BackendProfile?
    @State private var isCreating = false

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
            }
            .navigationTitle("Settings")
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
        }
    }
}
