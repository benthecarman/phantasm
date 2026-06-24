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
                Section("Backends") {
                    ForEach(env.profiles) { profile in
                        Button {
                            editing = profile
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.baseURLString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == env.activeProfileID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { env.delete(profile) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            if profile.id != env.activeProfileID {
                                Button { env.setActive(profile.id) } label: {
                                    Label("Activate", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                        }
                    }
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
