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
    @State private var autoWarm: Bool
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var revealToken = false
    @State private var models: [String] = []
    @State private var loadingModels = false

    init(profile: BackendProfile?) {
        self.existing = profile
        _name = State(initialValue: profile?.name ?? "")
        _urlString = State(initialValue: profile?.baseURLString ?? "https://")
        _defaultModel = State(initialValue: profile?.defaultModel ?? "")
        _autoWarm = State(initialValue: profile?.autoWarm ?? false)
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
                Section {
                    TextField("Name", text: $name)
                    TextField("Base URL (e.g. https://ollama.example.ts.net)", text: $urlString)
                        .textInputAutocapitalization(.never)
                    HStack {
                        Group {
                            if revealToken {
                                TextField("Bearer token (optional)", text: $token)
                            } else {
                                SecureField("Bearer token (optional)", text: $token)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        if !token.isEmpty {
                            Button {
                                Haptics.selection()
                                revealToken.toggle()
                            } label: {
                                Image(systemName: revealToken ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(revealToken ? "Hide token" : "Reveal token")
                        }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Leave the token blank for a backend that doesn't require auth (e.g. local Ollama or an orchestrator with auth disabled).")
                }

                Section {
                    Picker("Default model", selection: $defaultModel) {
                        Text("Auto (first available)").tag("")
                        ForEach(pickerOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        Haptics.selection()
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
                    Toggle("Auto-warm model", isOn: $autoWarm)
                } footer: {
                    Text("Preload the active model when you connect or switch to this backend, so the first reply skips cold-start. Off by default.")
                }

                Section {
                    Button {
                        Haptics.selection()
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

    private var normalizedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let base = URL(string: BackendProfile.normalizedBaseURLString(urlString)) else { return }
        loadingModels = true
        models = await env.capabilitiesClient.models(base: base, token: normalizedToken)
        loadingModels = false
    }

    private func test() async {
        guard let base = URL(string: BackendProfile.normalizedBaseURLString(urlString)) else { return }
        isTesting = true
        testResult = nil
        let result = await env.capabilitiesClient.validate(base: base, token: normalizedToken)
        isTesting = false
        switch result {
        case .success(let mode):
            models = mode.models
            Haptics.notify(.success)
            switch mode {
            case .full(let caps):
                let tools = caps.hasToolSelector(ToolSelectorName.webSearch)
                    || caps.hasToolSelector(ToolSelectorName.utilities)
                    || caps.hasToolSelector(ToolSelectorName.imageGeneration)
                let toolNote = tools ? " Web access / image tools available." : " Chat only — no tools advertised."
                testResult = .success("Connected. \(modelCount(caps.models.count)).\(toolNote)")
            case .ollamaNative(let models):
                let suffix = models.isEmpty ? "" : " \(modelCount(models.count))."
                testResult = .success("Connected — native Ollama chat.\(suffix)")
            case .plainChatOnly(let models):
                let suffix = models.isEmpty ? "" : " \(modelCount(models.count))."
                testResult = .success("Connected — chat only (no web search or image tools).\(suffix)")
            }
        case .failure(let error):
            testResult = .failure(error.userMessage)
            Haptics.notify(.error)
        }
    }

    private func modelCount(_ n: Int) -> String {
        "\(n) model\(n == 1 ? "" : "s")"
    }

    private func save() {
        let profile = BackendProfile(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            baseURLString: BackendProfile.normalizedBaseURLString(urlString),
            defaultModel: defaultModel.isEmpty ? nil : defaultModel,
            autoWarm: autoWarm
        )
        let token = normalizedToken
        env.upsert(profile, token: token.isEmpty ? nil : token)
        Haptics.notify(.success)
        dismiss()
    }
}
