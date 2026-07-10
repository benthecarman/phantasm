import PhantasmKit
import SwiftUI

/// Add/edit a backend profile with a "Test connection" check that validates
/// reachability + auth and reports the resolved mode (FR-A1, FR-A2). Also the
/// landing screen for a scanned/deep-linked pairing URI (FR-A12): `pairing`
/// prefills the connection fields, and nothing is stored until the user
/// reviews and taps Save — that explicit save is the confirmation step
/// docs/qr-pairing.md requires before trusting a scanned backend.
struct ProfileEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let existing: BackendProfile?
    private let pairing: PairingPayload?
    private let onSaved: () -> Void

    @State private var name: String
    @State private var urlString: String
    @State private var token: String
    @State private var defaultModel: String
    @State private var autoWarm: Bool
    @State private var resolvedTransport: BackendTransport
    @State private var resolvedTransportCanonicalURLString: String?
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var revealToken = false
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var showPairingQR = false

    /// `pairing` overrides the connection fields with the scanned payload;
    /// pass the matched existing profile too (see
    /// `PairingPayload.matchingProfile`) so a re-pair edits in place — its
    /// default model and auto-warm are kept, and a payload without a token
    /// inherits the saved one via the Keychain prefill instead of blanking it.
    init(
        profile: BackendProfile?,
        pairing: PairingPayload? = nil,
        onSaved: @escaping () -> Void = {}
    ) {
        self.existing = profile
        self.pairing = pairing
        self.onSaved = onSaved
        let initialURLString = pairing?.baseURLString ?? profile?.baseURLString ?? "https://"
        let initialURLMatchesProfile = profile.map {
            BackendProfile.canonicalBaseURLString($0.baseURLString)
                == BackendProfile.canonicalBaseURLString(initialURLString)
        } ?? false
        let initialTransport: BackendTransport = initialURLMatchesProfile
            ? (profile?.transport ?? .standard)
            : .standard
        _name = State(initialValue: pairing.map(\.displayName) ?? profile?.name ?? "")
        _urlString = State(initialValue: initialURLString)
        _defaultModel = State(initialValue: profile?.defaultModel ?? "")
        _autoWarm = State(initialValue: profile?.autoWarm ?? false)
        _resolvedTransport = State(initialValue: initialTransport)
        _resolvedTransportCanonicalURLString = State(initialValue:
            initialTransport == .mapleEncrypted
                ? BackendProfile.canonicalBaseURLString(initialURLString)
                : nil
        )
        // Pre-fill the token from the Keychain when editing (see onAppear);
        // a pairing token wins over the stored one.
        _token = State(initialValue: pairing?.token ?? "")
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
                    if pairing != nil {
                        Text("Filled in from the pairing code. Phantasm will send your chats to this backend — review the address and only save a server that's yours or one you trust.")
                    } else {
                        Text("Leave the token blank for a backend that doesn't require auth (e.g. local Ollama or an orchestrator with auth disabled).")
                    }
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

                if existing != nil && pairing == nil {
                    Section {
                        Button {
                            Haptics.selection()
                            showPairingQR = true
                        } label: {
                            Label("Show Pairing QR Code", systemImage: "qrcode")
                        }
                        .disabled(!isValid)
                    } footer: {
                        Text("Pair another device by scanning this backend's connection — including its token — with that device's camera.")
                    }
                }
            }
            .navigationTitle(
                pairing != nil ? "Pair Backend" : (existing == nil ? "Add Backend" : "Edit Backend")
            )
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
            .sheet(isPresented: $showPairingQR) {
                // Live field values, so what's shared is what's on screen —
                // including an edited-but-unsaved token.
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                PairingQRView(payload: PairingPayload(
                    baseURLString: BackendProfile.normalizedBaseURLString(urlString),
                    token: normalizedToken.isEmpty ? nil : normalizedToken,
                    name: trimmedName.isEmpty ? nil : trimmedName
                ))
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

    private var normalizedURLString: String {
        BackendProfile.normalizedBaseURLString(urlString)
    }

    private var pickerOptions: [String] {
        models
    }

    private func loadModels() async {
        let requestedURLString = normalizedURLString
        guard let base = URL(string: requestedURLString) else { return }
        loadingModels = true
        let result = await env.backendResolver.resolve(
            base: base,
            token: normalizedToken,
            preferMaple: effectiveTransportForCurrentURL == .mapleEncrypted
        )
        guard normalizedURLString == requestedURLString else {
            loadingModels = false
            return
        }
        if case .success(let mode) = result {
            models = mode.models
            resolvedTransport = mode.usesMapleEncryptedChat ? .mapleEncrypted : .standard
            resolvedTransportCanonicalURLString = BackendProfile.canonicalBaseURLString(
                requestedURLString
            )
        } else {
            models = []
        }
        clearStaleDefaultModel()
        loadingModels = false
    }

    private func test() async {
        let requestedURLString = normalizedURLString
        guard let base = URL(string: requestedURLString) else { return }
        isTesting = true
        testResult = nil
        let result = await env.backendResolver.resolve(
            base: base,
            token: normalizedToken,
            preferMaple: effectiveTransportForCurrentURL == .mapleEncrypted
        )
        guard normalizedURLString == requestedURLString else {
            isTesting = false
            return
        }
        isTesting = false
        switch result {
        case .success(let mode):
            models = mode.models
            resolvedTransport = mode.usesMapleEncryptedChat ? .mapleEncrypted : .standard
            resolvedTransportCanonicalURLString = BackendProfile.canonicalBaseURLString(
                requestedURLString
            )
            clearStaleDefaultModel()
            Haptics.notify(.success)
            testResult = .success(mode.connectionTestMessage)
        case .failure(let error):
            testResult = .failure(error.userMessage)
            Haptics.notify(.error)
        }
    }

    private func save() {
        let profile = BackendProfile(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            baseURLString: normalizedURLString,
            defaultModel: defaultModel.isEmpty ? nil : defaultModel,
            transport: effectiveTransportForCurrentURL,
            autoWarm: autoWarm
        )
        let token = normalizedToken
        env.upsert(profile, token: token.isEmpty ? nil : token)
        // A pairing is an explicit "use this backend"; manual adds keep the
        // current selection. upsert already activates (and refreshes) when
        // nothing was active or this is the active profile, so only an actual
        // switch needs setActive — skipping otherwise avoids a double probe.
        if pairing != nil, env.activeProfileID != profile.id {
            env.setActive(profile.id)
        }
        Haptics.notify(.success)
        dismiss()
        onSaved()
    }

    private var effectiveTransportForCurrentURL: BackendTransport {
        let defaultTransport = BackendProfile.defaultTransport(for: normalizedURLString)
        if defaultTransport == .mapleEncrypted { return .mapleEncrypted }
        let canonicalURLString = BackendProfile.canonicalBaseURLString(normalizedURLString)
        guard resolvedTransportCanonicalURLString == canonicalURLString else { return .standard }
        return resolvedTransport
    }

    private func clearStaleDefaultModel() {
        guard !models.isEmpty,
              !defaultModel.isEmpty,
              !models.contains(defaultModel) else { return }
        defaultModel = ""
    }
}
