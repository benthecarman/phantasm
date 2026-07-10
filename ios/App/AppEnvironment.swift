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
    /// True when the on-disk store failed to open (disk full, corruption) and
    /// this session is running on a throwaway in-memory store. Chat still
    /// works; the UI warns that history won't be saved.
    let databaseOpenFailed: Bool
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
    /// Device-backed provider for the app-hosted health tool. Held here (and wired
    /// into `AppToolRegistry` at launch) so the tool's HealthKit dependency stays
    /// in the app target.
    let healthProvider = HealthKitProvider()
    /// Device-backed provider for the app-hosted calendar tool. Held here (and
    /// wired into `AppToolRegistry` at launch) so the tool's EventKit dependency
    /// stays in the app target.
    let calendarProvider = CalendarProvider()
    let chatClient = ChatClient()
    /// Maple uses the same OpenAI request/stream parser as `chatClient`; this
    /// facade swaps only the encrypted URL loading transport.
    let mapleChatClient = MapleChatClient()
    let ollamaChatClient = OllamaNativeChatClient()
    let capabilitiesClient = CapabilitiesClient()
    let backendResolver = BackendResolver()
    let warmupClient = WarmupClient()
    /// On-device semantic embedder (Apple's contextual embedding — OS-provided
    /// assets, nothing bundled) + the indexer that keeps message vectors in
    /// step with history. Search degrades to keyword-only whenever embedding
    /// is unavailable (assets not downloaded yet, unsupported device).
    let searchEmbedder = ContextualTextEmbedder()
    let searchIndexer: EmbeddingIndexer

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
    /// Per-model reasoning effort availability on a Phantasm backend. Missing
    /// `reasoning_efforts` for one model must not hide controls for another
    /// model that did advertise options.
    var reasoningEffortsByModel: [String: Capabilities.Model.ReasoningEffortAvailability]?
    /// Per-model context window sizes, when the backend reports them. Empty/missing
    /// for a model ⇒ the picker omits the size badge and no overflow warning shows.
    var contextLengths: [String: Int]?
    /// Observable cache over persisted per-profile, per-model Thinking preferences.
    private var thinkingPreferences: [String: [String: Bool]]
    /// Observable cache over explicit per-profile, per-model reasoning effort
    /// choices for models with more than an on/off Thinking control.
    private var reasoningEffortPreferences: [String: [String: String]]
    private var capabilityRefreshGeneration = 0

    enum ThinkingSupport {
        case supported
        case unsupported
        case unknown
    }

    init() {
        // Schema is tiny; opening the SQLite store + migrations is fast (NFR-A5).
        // But a failure (full disk, corruption) must not crash at launch: fall
        // back to an in-memory store so the app still opens and can warn.
        do {
            database = try AppDatabase.makeShared()
            databaseOpenFailed = false
        } catch {
            guard let fallback = try? AppDatabase.empty() else {
                // No I/O involved — if even an in-memory store can't open,
                // there is genuinely nothing to run on.
                fatalError("could not open any message store: \(error)")
            }
            database = fallback
            databaseOpenFailed = true
        }
        speechSynthesizer = SpeechSynthesizer(voicePrefs: voicePreferenceStore)
        dictationController = DictationController()
        searchIndexer = EmbeddingIndexer(database: database, embedder: searchEmbedder)
        // Wire the app-hosted device tool providers into the registry so forwarded
        // location / health / calendar calls resolve on-device.
        AppToolRegistry.configureLocation(provider: locationProvider)
        AppToolRegistry.configureHealth(provider: healthProvider)
        AppToolRegistry.configureCalendar(provider: calendarProvider)
        let loadedProfiles = profileStore.load()
        profiles = loadedProfiles.profiles
        thinkingPreferences = modelPreferenceStore.loadThinkingPreferences()
        reasoningEffortPreferences = modelPreferenceStore.loadReasoningEffortPreferences()
        // Keychain tokens outlive an app uninstall but the UserDefaults profile
        // list does not, so a reinstall can strand tokens with no owning
        // profile. Reconcile the two on launch — but only from a fully-decoded
        // list: a partial or failed load must not delete real tokens.
        if loadedProfiles.isComplete {
            keychain.deleteTokens(notIn: Set(profiles.map(\.id)))
        }
        activeProfileID = profileStore.activeProfileID ?? profiles.first?.id
        // A previously detected Maple profile must select its encrypted client
        // synchronously on launch; otherwise a fast send before the async probe
        // finishes would briefly use the ordinary URLSession and fail with 401.
        if let active = profiles.first(where: { $0.id == activeProfileID }),
           active.transport == .mapleEncrypted {
            backendMode = .mapleEncrypted(models: profileStore.cachedModels(for: active.id))
        }
        // Lazily refresh capabilities for the active backend on launch; the
        // picker is seeded from the cache (see `availableModels`) in the meantime.
        Task { await refreshCapabilities() }
        // Backfill the semantic index for any history that predates it (or
        // arrived while embedding assets weren't available). Incremental —
        // already-embedded messages are skipped.
        Task { [searchIndexer] in await searchIndexer.indexPending() }
    }

    /// Hybrid history search: FTS5 keyword hits fused with semantic (embedding)
    /// hits. Returns nil when the embedder can't run — the caller keeps showing
    /// the reactive keyword-only results. Very short queries skip the semantic
    /// leg: prefix fragments embed as noise, and FTS5's prefix matching already
    /// owns search-as-you-type.
    func searchHistoryHybrid(matching query: String) async -> [ConversationSearchResult]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        guard let vector = try? await searchEmbedder.embed(String(trimmed.prefix(300))) else {
            return nil
        }
        return try? await database.hybridSearchConversations(
            matching: trimmed, queryVector: vector, model: searchEmbedder.identifier
        )
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
        guard let profile, let base = profile.baseURL else { return }
        let token = keychain.token(for: profile.id) ?? ""
        await ImageClient().delete(ids: ids, base: base, token: token)
    }

    /// Best-effort server cleanup for the bulk history control. References are
    /// grouped by their owning backend so tokenless and authenticated profiles
    /// both work, and no request is sent to an unrelated active backend.
    func purgeAllServerImages() async {
        guard let details = try? await store.allConversationDetails() else { return }
        var idsByProfile: [UUID: Set<String>] = [:]
        for detail in details {
            guard let profileID = detail.conversation.profileID ?? activeProfileID,
                  profiles.contains(where: { $0.id == profileID })
            else { continue }
            let ids = detail.messages.flatMap { ServerImageRef.ids(in: $0.message.content) }
            idsByProfile[profileID, default: []].formUnion(ids)
        }
        for (profileID, ids) in idsByProfile {
            guard !ids.isEmpty,
                  let profile = profiles.first(where: { $0.id == profileID }),
                  let base = profile.baseURL
            else { continue }
            await ImageClient().delete(
                ids: Array(ids),
                base: base,
                token: keychain.token(for: profileID) ?? ""
            )
        }
    }

    /// Models to offer in the picker for the active backend. Prefers the live
    /// probe result, falls back to the per-backend cache (so the full list shows
    /// instantly on launch, before the probe completes).
    var availableModels: [String] {
        discoveredModels
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
            seedBackendMode(from: profile)
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
        seedBackendMode(from: profiles.first { $0.id == id })
        Task { await refreshCapabilities() }
    }

    /// Select the persisted transport synchronously while the live probe runs.
    /// This prevents a quick send after editing/switching profiles from using
    /// whichever client's mode happened to be active immediately beforehand.
    private func seedBackendMode(from profile: BackendProfile?) {
        visionModels = nil
        toolModels = nil
        reasoningEffortsByModel = nil
        contextLengths = nil
        guard let profile else {
            backendMode = .plainChatOnly(models: [])
            return
        }
        let models = profileStore.cachedModels(for: profile.id)
        backendMode = profile.transport == .mapleEncrypted
            ? .mapleEncrypted(models: models)
            : .plainChatOnly(models: models)
    }

    func refreshCapabilities() async {
        capabilityRefreshGeneration += 1
        let generation = capabilityRefreshGeneration
        guard let profile = activeProfile,
              let base = profile.baseURL else {
            backendMode = .plainChatOnly(models: [])
            visionModels = nil
            toolModels = nil
            reasoningEffortsByModel = nil
            contextLengths = nil
            isProbing = false
            return
        }
        isProbing = true
        let profileID = profile.id
        let token = keychain.token(for: profileID) ?? ""
        let result = await backendResolver.resolve(
            base: base,
            token: token,
            preferMaple: profile.transport == .mapleEncrypted
        )
        let mode: BackendMode
        switch result {
        case .success(let resolved):
            mode = resolved
        case .failure:
            // Keep a known Maple profile on the encrypted transport while it is
            // temporarily unreachable. The cached model list preserves the same
            // launch/offline behavior as other backends.
            mode = profile.transport == .mapleEncrypted
                ? .mapleEncrypted(models: profileStore.cachedModels(for: profileID))
                : .plainChatOnly(models: [])
        }
        guard isCurrentCapabilityRefresh(generation, profileID: profileID) else { return }
        backendMode = mode
        if case .success = result {
            persistResolvedTransport(mode, for: profileID)
        }
        isProbing = false
        // Cache the discovered model list so it's available instantly next launch.
        let models = mode.models
        if !models.isEmpty {
            profileStore.cacheModels(models, for: profileID)
            clearStaleDefaultModel(for: profileID, availableModels: models)
        }
        let modelCapabilities = await modelCapabilities(for: mode, base: base, token: token)
        guard isCurrentCapabilityRefresh(generation, profileID: profileID) else { return }
        visionModels = modelCapabilities.vision
        toolModels = modelCapabilities.tools
        reasoningEffortsByModel = modelCapabilities.reasoningEfforts
        contextLengths = modelCapabilities.contextLengths
        warmActiveModel(base: base, token: token)
    }

    private func isCurrentCapabilityRefresh(_ generation: Int, profileID: UUID) -> Bool {
        generation == capabilityRefreshGeneration && activeProfileID == profileID
    }

    private func persistResolvedTransport(_ mode: BackendMode, for profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let transport: BackendTransport = mode.usesMapleEncryptedChat
            ? .mapleEncrypted
            : .standard
        guard profiles[index].transport != transport else { return }
        profiles[index].transport = transport
        profileStore.save(profiles)
    }

    private func clearStaleDefaultModel(for profileID: UUID, availableModels: [String]) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }),
              let defaultModel = profiles[idx].defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !defaultModel.isEmpty,
              !availableModels.contains(defaultModel) else { return }
        profiles[idx].defaultModel = nil
        profileStore.save(profiles)
    }

    /// Resolve which models accept images / can drive tools for the current
    /// backend: from the orchestrator manifest when present, by probing Ollama
    /// `/api/show` for a bare native backend, and unknown (optimistic) for
    /// generic OpenAI. Bare Ollama exposes vision/tool/context metadata through
    /// `/api/show`; failed tool probes stay unknown (optimistic) for compatibility.
    private func modelCapabilities(
        for mode: BackendMode,
        base: URL,
        token: String
    ) async -> (
        vision: Set<String>?,
        tools: Set<String>?,
        reasoningEfforts: [String: Capabilities.Model.ReasoningEffortAvailability]?,
        contextLengths: [String: Int]?
    ) {
        switch mode {
        case .full(let caps):
            return (
                caps.visionModelIDs,
                caps.toolModelIDs,
                caps.reasoningEffortsByID,
                caps.contextLengthByID
            )
        case .ollamaNative(let models):
            let capabilities = await capabilitiesClient.fetchOllamaModelCapabilities(
                base: base, token: token, models: models
            )
            return (
                capabilities.visionModels,
                capabilities.toolModels,
                nil,
                capabilities.contextLengths.isEmpty ? nil : capabilities.contextLengths
            )
        case .mapleEncrypted, .plainChatOnly:
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

    /// Whether `model` can produce reasoning/thinking output through the Phantasm
    /// orchestrator. The endpoint must explicitly advertise a non-empty
    /// `reasoning_efforts` list; plain OpenAI-compatible/native Ollama backends
    /// and older manifests without per-model effort data do not expose the app's
    /// Thinking toggle.
    func supportsThinking(_ model: String?) -> Bool {
        thinkingSupport(for: model) == .supported
    }

    func reasoningEfforts(for model: String?) -> [String] {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              case .known(let efforts) = reasoningEffortsByModel?[model] else { return [] }
        return efforts
    }

    func thinkingSupport(for model: String?) -> ThinkingSupport {
        guard case .full = backendMode else { return .unsupported }
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return .unknown }
        guard let availability = reasoningEffortsByModel?[model] else { return .unknown }
        switch availability {
        case .unknown:
            return .unknown
        case .known(let efforts):
            return efforts.isEmpty ? .unsupported : .supported
        }
    }

    /// The effective Thinking setting for `model`: the stored preference, defaulting
    /// on only when the model actually supports reasoning. A model that can't
    /// think reports `false` regardless of the saved toggle, so we never send
    /// `reasoning_effort` to a backend that would ignore (or reject) it. The
    /// preference itself is left intact for when a thinking-capable model is
    /// reselected.
    func thinkingEnabled(for model: String?) -> Bool {
        guard let profileID = activeProfileID,
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              supportsThinking(model) else { return false }
        return thinkingPreferences[profileID.uuidString]?[model] ?? true
    }

    func reasoningEffort(for model: String?) -> String? {
        guard thinkingSupport(for: model) == .supported else { return nil }
        let efforts = reasoningEfforts(for: model)
        guard efforts.count > 2 else {
            return thinkingEnabled(for: model)
                ? preferredEnabledReasoningEffort(from: efforts)
                : disabledReasoningEffort(from: efforts)
        }
        return selectedReasoningEffort(for: model)
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

    func selectedReasoningEffort(for model: String?) -> String {
        let efforts = reasoningEfforts(for: model)
        guard let profileID = activeProfileID,
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return preferredEnabledReasoningEffort(from: efforts) }
        if let stored = reasoningEffortPreferences[profileID.uuidString]?[model],
           efforts.contains(stored) {
            return stored
        }
        return defaultReasoningEffort(from: efforts)
    }

    func setSelectedReasoningEffort(_ effort: String, for model: String?) {
        let efforts = reasoningEfforts(for: model)
        guard efforts.contains(effort),
              let profileID = activeProfileID,
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return }
        var byModel = reasoningEffortPreferences[profileID.uuidString] ?? [:]
        byModel[model] = effort
        reasoningEffortPreferences[profileID.uuidString] = byModel
        modelPreferenceStore.saveReasoningEffortPreferences(reasoningEffortPreferences)
    }

    private func disabledReasoningEffort(from efforts: [String]) -> String? {
        efforts.first { $0.caseInsensitiveCompare(ReasoningEffort.disabled) == .orderedSame }
    }

    private func preferredEnabledReasoningEffort(from efforts: [String]) -> String {
        if efforts.contains(ReasoningEffort.enabledDefault) { return ReasoningEffort.enabledDefault }
        return efforts.first {
            $0.caseInsensitiveCompare(ReasoningEffort.disabled) != .orderedSame
        } ?? ReasoningEffort.enabledDefault
    }

    private func defaultReasoningEffort(from efforts: [String]) -> String {
        preferredEnabledReasoningEffort(from: efforts)
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
