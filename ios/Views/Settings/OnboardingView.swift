import PhantasmKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    let onComplete: () -> Void

    @State private var step: Step = .backend
    @State private var name = "My Backend"
    @State private var urlString = "https://"
    @State private var token = ""
    @State private var defaultModel = ""
    @State private var autoWarm = false
    @State private var resolvedTransport: BackendTransport = .standard
    @State private var revealToken = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var testedURLString: String?
    @State private var testedToken: String?
    @State private var models: [String] = []

    @State private var locationEnabled = false
    @State private var healthEnabled = false
    @State private var calendarEnabled = false
    /// Scanner → confirmation as one sheet (FR-A12). A confirmed pairing saves
    /// + activates the profile itself, replacing this form's save.
    @State private var pairingRoute: PairingSheetRoute?

    enum Step {
        case backend
        case tools
    }

    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .backend:
                    backendForm
                case .tools:
                    toolsForm
                }
            }
            .navigationTitle(step == .backend ? "Set Up Phantasm" : "Choose Tools")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $pairingRoute) { _ in
                PairingFlowSheet(route: $pairingRoute) {
                    // Profile saved + active; skip the manual form.
                    step = .tools
                }
            }
        }
    }

    private var backendForm: some View {
        Form {
            Section {
                Button {
                    Haptics.selection()
                    pairingRoute = .scan
                } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("Running the Phantasm orchestrator? `phantasm-orchestrator pair` prints a code to scan — no typing. Or fill in the connection below.")
            }

            Section {
                TextField("Name", text: $name)
                TextField("Base URL", text: $urlString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(revealToken ? "Hide token" : "Reveal token")
                    }
                }
            } header: {
                Text("Backend")
            } footer: {
                Text("Phantasm sends chat requests to this backend. Use a server you control or trust.")
            }

            if !models.isEmpty {
                Section {
                    Picker("Default model", selection: $defaultModel) {
                        Text("Auto").tag("")
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Auto-warm model", isOn: $autoWarm)
                } footer: {
                    Text("Auto-warm preloads the active model after connecting. Leave it off if your server should stay idle until you send a message.")
                }
            }

            Section {
                Button {
                    Haptics.selection()
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        if isTesting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!isValid || isTesting)

                if let testResult {
                    switch testResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            } footer: {
                Text("A successful connection is required before continuing.")
            }

            Section {
                Button("Continue") {
                    if saveBackend() {
                        step = .tools
                    }
                }
                .disabled(!canContinue)
            }
        }
    }

    private var toolsForm: some View {
        Form {
            Section {
                Text("Device tools are off by default. If you enable one, Phantasm can read that data only when a chat uses the tool, then send the result to your configured backend as part of the conversation.")
                    .foregroundStyle(.secondary)
            }

            Section("Device Tools") {
                disclosureToggle(
                    title: "Location",
                    systemImage: "location",
                    text: "Shares your approximate current location and place details when the model asks for it.",
                    isOn: $locationEnabled
                )
                disclosureToggle(
                    title: "Health",
                    systemImage: "heart",
                    text: "Reads selected Apple Health metrics such as activity, sleep, workouts, and nutrition when requested. Read-only; Phantasm never writes Health data.",
                    isOn: $healthEnabled
                )
                disclosureToggle(
                    title: "Calendar",
                    systemImage: "calendar",
                    text: "Reads matching calendar events when requested. Creating an event always asks for confirmation before saving.",
                    isOn: $calendarEnabled
                )
            }

            Section("Server Tools") {
                toolInfo(
                    title: "Web access",
                    systemImage: "globe",
                    text: "When your backend supports it, the model can search or fetch web pages to answer a chat."
                )
                toolInfo(
                    title: "Media generation",
                    systemImage: "wand.and.stars",
                    text: "When your backend supports it, generated images and audio are returned in the assistant message with native viewing and playback."
                )
            }

            Section {
                Button("Start Chatting") {
                    finish()
                }
            } footer: {
                Text("You can change these defaults later from the chat tool menu.")
            }
        }
    }

    private func disclosureToggle(
        title: String,
        systemImage: String,
        text: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: Binding(
            get: { isOn.wrappedValue },
            set: { newValue in
                isOn.wrappedValue = newValue
                requestPermissionIfNeeded(title: title, enabled: newValue)
            }
        )) {
            toolLabel(title: title, systemImage: systemImage, text: text)
        }
    }

    private func toolInfo(title: String, systemImage: String, text: String) -> some View {
        toolLabel(title: title, systemImage: systemImage, text: text)
    }

    private func toolLabel(title: String, systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: normalizedURLString)?.scheme != nil
    }

    private var canContinue: Bool {
        guard testedURLString == normalizedURLString,
              testedToken == normalizedToken else { return false }
        if case .success = testResult { return true }
        return false
    }

    private var normalizedURLString: String {
        BackendProfile.normalizedBaseURLString(urlString)
    }

    private var normalizedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func testConnection() async {
        guard let base = URL(string: normalizedURLString) else { return }
        isTesting = true
        testResult = nil
        let result = await env.backendResolver.resolve(
            base: base,
            token: normalizedToken,
            preferMaple: BackendProfile.defaultTransport(for: normalizedURLString) == .mapleEncrypted
        )
        isTesting = false
        switch result {
        case .success(let mode):
            models = mode.models
            resolvedTransport = mode.usesMapleEncryptedChat ? .mapleEncrypted : .standard
            testedURLString = normalizedURLString
            testedToken = normalizedToken
            Haptics.notify(.success)
            testResult = .success(mode.connectionTestMessage)
        case .failure(let error):
            testedURLString = nil
            testedToken = nil
            Haptics.notify(.error)
            testResult = .failure(error.userMessage)
        }
    }

    private func saveBackend() -> Bool {
        let profile = BackendProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURLString: normalizedURLString,
            defaultModel: defaultModel.isEmpty ? nil : defaultModel,
            transport: resolvedTransport == .mapleEncrypted
                ? .mapleEncrypted
                : BackendProfile.defaultTransport(for: normalizedURLString),
            autoWarm: autoWarm
        )
        do {
            try env.upsert(
                profile,
                token: normalizedToken.isEmpty ? nil : normalizedToken
            )
        } catch {
            Haptics.notify(.error)
            testResult = .failure(
                "Couldn’t save the credential securely. Your backend settings were not changed."
            )
            return false
        }
        env.setActive(profile.id)
        return true
    }

    private func requestPermissionIfNeeded(title: String, enabled: Bool) {
        guard enabled else { return }
        switch title {
        case "Location":
            env.requestLocationAuthorizationWhenInUse()
        case "Health":
            env.requestHealthAuthorization()
        case "Calendar":
            env.requestCalendarAuthorization()
        default:
            break
        }
    }

    private func finish() {
        env.toolPreferenceStore.locationEnabledDefault = locationEnabled
        env.toolPreferenceStore.healthEnabledDefault = healthEnabled
        env.toolPreferenceStore.calendarEnabledDefault = calendarEnabled
        Haptics.notify(.success)
        onComplete()
    }
}
