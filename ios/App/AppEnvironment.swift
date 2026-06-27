import Foundation
import Observation
import PhantasmKit

/// App-wide services + connection state, injected through the SwiftUI
/// environment. Holds the GRDB-backed chat store, the profile/keychain stores,
/// and the resolved `BackendMode` for the active profile.
@MainActor
@Observable
final class AppEnvironment {
    /// On-device chat history (SQLite + FTS5). Reactive reads use GRDBQuery
    /// against `database.reader`; writes go through the `store` protocol.
    let database: AppDatabase
    var store: ChatStore { database }
    let profileStore = ProfileStore()
    let modelPreferenceStore = ModelPreferenceStore()
    let voicePreferenceStore = VoicePreferenceStore()
    /// Sticky defaults for the per-chat tool selectors (e.g. location), so a tool
    /// the user enables stays on for subsequent new chats.
    let toolPreferenceStore = ToolPreferenceStore()
    let keychain = KeychainStore()
    /// On-device speech: dictation (STT, via the platform speech models) and
    /// read-aloud (TTS, via the system `AVSpeechSynthesizer`). No bundled models.
    let speechSynthesizer: SpeechSynthesizer
    let dictationController: DictationController
    /// Device-backed provider for the app-hosted location tool. Held here (and
    /// wired into `AppToolRegistry` at launch) so the tool's CoreLocation
    /// dependency stays in the app target.
    let locationProvider = LocationProvider()
    let chatClient = ChatClient()
    let ollamaChatClient = OllamaNativeChatClient()
    let capabilitiesClient = CapabilitiesClient()
    let warmupClient = WarmupClient()

    var profiles: [BackendProfile]
    var activeProfileID: UUID?
    var backendMode: BackendMode = .plainChatOnly(models: [])
    var isProbing = false
    /// Models known to accept image input. `nil` means vision is undetectable for
    /// this backend (e.g. a generic OpenAI endpoint), so images are allowed
    /// optimistically rather than hidden.
    var visionModels: Set<String>?
    /// Models known to support tool/function calling. `nil` means it's
    /// undetectable for this backend, so tools are allowed optimistically. The
    /// server tools also require the backend to advertise them (`backendMode`).
    var toolModels: Set<String>?
    /// Models known to support reasoning/thinking. `nil` means it's undetectable
    /// for this backend, so the Thinking toggle is offered optimistically.
    var thinkingModels: Set<String>?
    /// Per-model context window sizes, when the backend reports them. Empty/missing
    /// for a model ⇒ the picker omits the size badge and no overflow warning shows.
    var contextLengths: [String: Int]?
    /// Observable cache over persisted per-profile, per-model Thinking preferences.
    private var thinkingPreferences: [String: [String: Bool]]
    private var capabilityRefreshGeneration = 0

    init() {
        // Schema is tiny; opening the SQLite store + migrations is fast (NFR-A5).
        database = try! AppDatabase.makeShared()
        speechSynthesizer = SpeechSynthesizer(voicePrefs: voicePreferenceStore)
        dictationController = DictationController()
        // Wire the app-hosted location tool's provider into the registry so a
        // forwarded `get_current_location` call resolves on-device.
        AppToolRegistry.configureLocation(provider: locationProvider)
        profiles = profileStore.load()
        thinkingPreferences = modelPreferenceStore.loadThinkingPreferences()
        // Keychain tokens outlive an app uninstall but the UserDefaults profile
        // list does not, so a reinstall can strand tokens with no owning
        // profile. Reconcile the two on launch.
        keychain.deleteTokens(notIn: Set(profiles.map(\.id)))
        activeProfileID = profileStore.activeProfileID ?? profiles.first?.id
        // Lazily refresh capabilities for the active backend on launch; the
        // picker is seeded from the cache (see `availableModels`) in the meantime.
        Task { await refreshCapabilities() }
    }

    var activeProfile: BackendProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    var activeToken: String? {
        activeProfile.flatMap { keychain.token(for: $0.id) }
    }

    /// Delete the server-hosted image blobs a conversation referenced, so the
    /// app owns their lifecycle (spec §2.2b). Best-effort and fire-before-delete:
    /// must run while the messages still exist to read their `/v1/files/<id>`
    /// references. A failure is harmless — the server's TTL pruner is the
    /// backstop. Uses the conversation's own backend profile (falling back to the
    /// active one) for the base URL + token.
    func purgeServerImages(conversationID: UUID) async {
        guard let detail = try? await store.conversationDetail(id: conversationID) else { return }
        let ids = detail.messages.flatMap { ServerImageRef.ids(in: $0.message.content) }
        guard !ids.isEmpty else { return }
        let profile = profiles.first { $0.id == detail.conversation.profileID } ?? activeProfile
        guard let profile, let base = profile.baseURL,
              let token = keychain.token(for: profile.id)
        else { return }
        await ImageClient().delete(ids: ids, base: base, token: token)
    }

    /// Models to offer in the picker for the active backend. Prefers the live
    /// probe result, falls back to the per-backend cache (so the full list shows
    /// instantly on launch, before the probe completes). The saved default is
    /// included even if it was not advertised, so existing selections remain
    /// visible.
    var availableModels: [String] {
        var models = discoveredModels
        if let defaultModel = activeDefaultModel, !models.contains(defaultModel) {
            models.append(defaultModel)
        }
        return models.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The active profile's configured default model, if any. Surfaced so the
    /// model picker can badge it.
    var defaultModelID: String? { activeDefaultModel }

    /// The model to preselect for new chats and unsent conversations.
    var preferredModel: String? {
        backendMode.resolvedChatModel(
            conversationModel: nil,
            defaultModel: activeDefaultModel
        )
    }

    private var activeDefaultModel: String? {
        guard let model = activeProfile?.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return nil }
        return model
    }

    private var discoveredModels: [String] {
        if !backendMode.models.isEmpty { return backendMode.models }
        guard let id = activeProfileID else { return [] }
        return profileStore.cachedModels(for: id)
    }

    func upsert(_ profile: BackendProfile, token: String?) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedToken.isEmpty {
            try? keychain.delete(for: profile.id)
        } else {
            try? keychain.setToken(normalizedToken, for: profile.id)
        }
        profileStore.save(profiles)
        if activeProfileID == nil {
            setActive(profile.id)
        } else if activeProfileID == profile.id {
            Task { await refreshCapabilities() }
        }
    }

    func delete(_ profile: BackendProfile) {
        profiles.removeAll { $0.id == profile.id }
        try? keychain.delete(for: profile.id)
        profileStore.clearCachedModels(for: profile.id)
        thinkingPreferences[profile.id.uuidString] = nil
        modelPreferenceStore.saveThinkingPreferences(thinkingPreferences)
        profileStore.save(profiles)
        if activeProfileID == profile.id {
            setActive(profiles.first?.id)
        }
    }

    func setActive(_ id: UUID?) {
        activeProfileID = id
        profileStore.activeProfileID = id
        Task { await refreshCapabilities() }
    }

    func refreshCapabilities() async {
        capabilityRefreshGeneration += 1
        let generation = capabilityRefreshGeneration
        guard let profile = activeProfile,
              let base = profile.baseURL else {
            backendMode = .plainChatOnly(models: [])
            visionModels = nil
            toolModels = nil
            thinkingModels = nil
            contextLengths = nil
            isProbing = false
            return
        }
        isProbing = true
        let profileID = profile.id
        let token = keychain.token(for: profileID) ?? ""
        let mode = await capabilitiesClient.probe(base: base, token: token)
        guard isCurrentCapabilityRefresh(generation, profileID: profileID) else { return }
        backendMode = mode
        isProbing = false
        // Cache the discovered model list so it's available instantly next launch.
        let models = mode.models
        if !models.isEmpty {
            profileStore.cacheModels(models, for: profileID)
        }
        let modelCapabilities = await modelCapabilities(for: mode, base: base, token: token)
        guard isCurrentCapabilityRefresh(generation, profileID: profileID) else { return }
        visionModels = modelCapabilities.vision
        toolModels = modelCapabilities.tools
        thinkingModels = modelCapabilities.thinking
        contextLengths = modelCapabilities.contextLengths
        warmActiveModel(base: base, token: token)
    }

    private func isCurrentCapabilityRefresh(_ generation: Int, profileID: UUID) -> Bool {
        generation == capabilityRefreshGeneration && activeProfileID == profileID
    }

    /// Resolve which models accept images / can drive tools for the current
    /// backend: from the orchestrator manifest when present, by probing Ollama
    /// `/api/show` for a bare native backend, and unknown (optimistic) for
    /// generic OpenAI. Server tools require the orchestrator, so `toolModels` is
    /// only meaningful in `.full` mode — the other modes leave it unknown.
    private func modelCapabilities(
        for mode: BackendMode,
        base: URL,
        token: String
    ) async -> (
        vision: Set<String>?,
        tools: Set<String>?,
        thinking: Set<String>?,
        contextLengths: [String: Int]?
    ) {
        switch mode {
        case .full(let caps):
            return (
                caps.visionModelIDs,
                caps.toolModelIDs,
                caps.thinkingModelIDs,
                caps.contextLengthByID
            )
        case .ollamaNative(let models):
            let vision = await capabilitiesClient.fetchOllamaVisionModels(
                base: base, token: token, models: models
            )
            return (vision, nil, nil, nil)
        case .plainChatOnly:
            return (nil, nil, nil, nil)
        }
    }

    /// Whether `model` can accept image attachments. Unknown backends return
    /// `true` (optimistic) so we never hide a capability that may exist.
    func supportsVision(_ model: String?) -> Bool {
        guard let visionModels else { return true }
        guard let model else { return false }
        return visionModels.contains(model)
    }

    /// Whether `model` can drive server tools (function calling). Unknown backends
    /// return `true` (optimistic). Note this only gates *which* model can use a
    /// tool — the backend must also advertise the tool (see `backendMode`).
    func supportsTools(_ model: String?) -> Bool {
        guard let toolModels else { return true }
        guard let model else { return false }
        return toolModels.contains(model)
    }

    /// Whether `model` can produce reasoning/thinking output. Unknown backends
    /// return `true` (optimistic) so we never hide a capability that may exist.
    func supportsThinking(_ model: String?) -> Bool {
        guard let thinkingModels else { return true }
        guard let model else { return false }
        return thinkingModels.contains(model)
    }

    /// The effective Thinking setting for `model`: the stored preference, but
    /// only when the model actually supports reasoning. A model that can't think
    /// reports `false` regardless of the saved toggle, so we never send
    /// `reasoning_effort` to a backend that would ignore (or reject) it. The
    /// preference itself is left intact for when a thinking-capable model is
    /// reselected.
    func thinkingEnabled(for model: String?) -> Bool {
        guard let profileID = activeProfileID,
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              supportsThinking(model) else { return false }
        return thinkingPreferences[profileID.uuidString]?[model] ?? false
    }

    func disabledReasoningEffortForCurrentBackend() -> String? {
        disabledReasoningEffort
    }

    private var disabledReasoningEffort: String? {
        // `reasoning_effort: "none"` is useful for the orchestrator and native
        // Ollama path, where it suppresses thinking tokens. Generic OpenAI-
        // compatible endpoints may reject unsupported request fields, so omit the
        // no-op value in plain-chat mode.
        switch backendMode {
        case .full, .ollamaNative:
            return ReasoningEffort.disabled
        case .plainChatOnly:
            return nil
        }
    }

    func setThinkingEnabled(_ enabled: Bool, for model: String?) {
        guard let profileID = activeProfileID,
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return }
        var byModel = thinkingPreferences[profileID.uuidString] ?? [:]
        byModel[model] = enabled
        thinkingPreferences[profileID.uuidString] = byModel
        modelPreferenceStore.saveThinkingPreferences(thinkingPreferences)
    }

    /// Kick off a best-effort preload of the model new chats will use, so the
    /// first turn after launch / a backend switch skips cold-start.
    private func warmActiveModel(base: URL, token: String) {
        guard let model = preferredModel else { return }
        warm(model: model)
    }

    /// Fire-and-forget preload of a specific model on the active backend (e.g.
    /// after the user picks a different model). Gated on the profile's `autoWarm`
    /// opt-in. Failures are silent and never block the UI.
    func warm(model: String) {
        guard let profile = activeProfile, profile.autoWarm,
              let base = profile.baseURL else { return }
        let token = activeToken ?? ""
        let mode = backendMode
        Task.detached { [warmupClient] in
            await warmupClient.warm(model: model, base: base, token: token, mode: mode)
        }
    }
}
