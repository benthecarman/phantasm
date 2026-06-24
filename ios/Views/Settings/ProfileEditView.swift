import PhantasmKit
import SwiftUI

/// Add/edit a backend profile with a "Test connection" check that validates
/// reachability + auth and reports the resolved mode (FR-A1, FR-A2).
struct ProfileEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let existing: BackendProfile?

    @State private var name: String
    @State private var urlString: String
    @State private var token: String
    @State private var defaultModel: String
    @State private var testResult: TestResult?
    @State private var isTesting = false

    init(profile: BackendProfile?) {
        self.existing = profile
        _name = State(initialValue: profile?.name ?? "")
        _urlString = State(initialValue: profile?.baseURLString ?? "http://")
        _defaultModel = State(initialValue: profile?.defaultModel ?? "")
        // Pre-fill the token from the Keychain when editing.
        _token = State(initialValue: "")
    }

    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("Base URL (e.g. http://192.168.1.10:8080)", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Bearer token", text: $token)
                    TextField("Default model (optional)", text: $defaultModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!isValid || isTesting)

                    if let testResult {
                        switch testResult {
                        case .success(let msg):
                            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Backend" : "Edit Backend")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
            .onAppear {
                if let existing, token.isEmpty {
                    token = env.keychain.token(for: existing.id) ?? ""
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: urlString)?.scheme != nil
    }

    private func test() async {
        guard let base = URL(string: urlString) else { return }
        isTesting = true
        testResult = nil
        let model = defaultModel.isEmpty ? "llama3.1" : defaultModel
        let result = await env.capabilitiesClient.validate(base: base, token: token, pingModel: model)
        isTesting = false
        switch result {
        case .success(let mode):
            switch mode {
            case .full(let caps):
                let tools = (caps.tools?.webSearch ?? false) || (caps.tools?.imageGeneration ?? false)
                testResult = .success("Connected. \(caps.models.count) model(s)\(tools ? ", tools available" : "").")
            case .plainChatOnly:
                testResult = .success("Connected (plain chat).")
            }
        case .failure(let error):
            testResult = .failure(error.userMessage)
        }
    }

    private func save() {
        let profile = BackendProfile(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            baseURLString: urlString.trimmingCharacters(in: .whitespaces),
            defaultModel: defaultModel.isEmpty ? nil : defaultModel
        )
        env.upsert(profile, token: token.isEmpty ? nil : token)
        dismiss()
    }
}
