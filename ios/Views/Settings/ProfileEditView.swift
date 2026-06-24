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
    @State private var models: [String] = []
    @State private var loadingModels = false

    init(profile: BackendProfile?) {
        self.existing = profile
        _name = State(initialValue: profile?.name ?? "")
        _urlString = State(initialValue: profile?.baseURLString ?? "https://")
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
                    TextField("Base URL (e.g. https://ollama.example.ts.net)", text: $urlString)
                        .textInputAutocapitalization(.never)
                    SecureField("Bearer token", text: $token)
                }

                Section {
                    Picker("Default model", selection: $defaultModel) {
                        Text("Auto (first available)").tag("")
                        ForEach(pickerOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        Task { await loadModels() }
                    } label: {
                        HStack {
                            Label(models.isEmpty ? "Load models" : "Reload models",
                                  systemImage: "arrow.clockwise")
                            if loadingModels { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!canLoadModels || loadingModels)
                } header: {
                    Text("Default model")
                } footer: {
                    if models.isEmpty && !loadingModels {
                        Text("Tap Load to fetch models from the backend.")
                    }
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
                if canLoadModels {
                    Task { await loadModels() }
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: urlString)?.scheme != nil
    }

    private var canLoadModels: Bool {
        URL(string: urlString)?.scheme != nil
    }

    /// The discovered models, plus the currently-saved model if it's not in the
    /// list (so a previously-chosen value still shows as selected).
    private var pickerOptions: [String] {
        var opts = models
        if !defaultModel.isEmpty && !opts.contains(defaultModel) {
            opts.insert(defaultModel, at: 0)
        }
        return opts
    }

    private func loadModels() async {
        guard let base = URL(string: urlString) else { return }
        loadingModels = true
        models = await env.capabilitiesClient.models(base: base, token: token)
        loadingModels = false
    }

    private func test() async {
        guard let base = URL(string: urlString) else { return }
        isTesting = true
        testResult = nil
        let result = await env.capabilitiesClient.validate(base: base, token: token)
        isTesting = false
        switch result {
        case .success(let mode):
            models = mode.models
            switch mode {
            case .full(let caps):
                let tools = (caps.tools?.webSearch ?? false) || (caps.tools?.imageGeneration ?? false)
                let toolNote = tools ? " Web search / image tools available." : " Chat only — no tools advertised."
                testResult = .success("Connected. \(modelCount(caps.models.count)).\(toolNote)")
            case .plainChatOnly(let models):
                let suffix = models.isEmpty ? "" : " \(modelCount(models.count))."
                testResult = .success("Connected — chat only (no web search or image tools).\(suffix)")
            }
        case .failure(let error):
            testResult = .failure(error.userMessage)
        }
    }

    private func modelCount(_ n: Int) -> String {
        "\(n) model\(n == 1 ? "" : "s")"
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
