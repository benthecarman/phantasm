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
    /// Last fully-resolved capability state for each profile used this process.
    /// Switching the Settings selection must not erase the state needed by an
    /// already-open conversation owned by the previous profile.
    private var backendStates: [UUID: BackendState] = [:]

    private struct BackendState {
        let canonicalBaseURL: String
        let effectiveTransport: BackendTransport
        let mode: BackendMode
        let visionModels: Set<String>?
        let toolModels: Set<String>?
        let reasoningEffortsByModel:
            [String: Capabilities.Model.ReasoningEffortAvailability]?
        let contextLengths: [String: Int]?
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
           active.effectiveTransport == .mapleEncrypted {
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

    /// Resolve an immutable session for the conversation's owning profile.
    /// Missing/legacy profile ids fail closed; callers must never substitute the
    /// globally selected profile because doing so can disclose the full history.
    func backendSession(for profileID: UUID?) -> BackendSession? {
        guard let profileID,
              let profile = profiles.first(where: { $0.id == profileID }),
              let baseURL = profile.baseURL else { return nil }

        let state: BackendState
        if profileID == activeProfileID {
            state = currentBackendState(for: profile)
        } else if let cached = backendStates[profileID],
                  cached.canonicalBaseURL
                    == BackendProfile.canonicalBaseURLString(profile.baseURLString),
                  cached.effectiveTransport == profile.effectiveTransport {
            state = cached
        } else {
            let models = profileStore.cachedModels(for: profileID)
            state = BackendState(
                canonicalBaseURL: BackendProfile.canonicalBaseURLString(
                    profile.baseURLString
                ),
                effectiveTransport: profile.effectiveTransport,
                mode: profile.effectiveTransport == .mapleEncrypted
                    ? .mapleEncrypted(models: models)
                    : .plainChatOnly(models: models),
                visionModels: nil,
                toolModels: nil,
                reasoningEffortsByModel: nil,
                contextLengths: nil
            )
        }

        let client: any ChatClienting
        if state.mode.usesOllamaNativeChat {
            client = ollamaChatClient
        } else if state.mode.usesMapleEncryptedChat {
            client = mapleChatClient
        } else {
            client = chatClient
        }
        return BackendSession(
            profile: profile,
            baseURL: baseURL,
            token: keychain.token(for: profileID) ?? "",
            mode: state.mode,
            visionModels: state.visionModels,
            toolModels: state.toolModels,
            reasoningEffortsByModel: state.reasoningEffortsByModel,
            contextLengths: state.contextLengths,
            client: client,
            thinkingPreferences: thinkingPreferences[profileID.uuidString] ?? [:],
            reasoningEffortPreferences:
                reasoningEffortPreferences[profileID.uuidString] ?? [:]
        )
    }

    private func currentBackendState(for profile: BackendProfile) -> BackendState {
        BackendState(
            canonicalBaseURL: BackendProfile.canonicalBaseURLString(
                profile.baseURLString
            ),
            effectiveTransport: profile.effectiveTransport,
            mode: backendMode,
            visionModels: visionModels,
            toolModels: toolModels,
            reasoningEffortsByModel: reasoningEffortsByModel,
            contextLengths: contextLengths
        )
    }

    private func cacheActiveBackendState() {
        guard let profile = activeProfile else { return }
        backendStates[profile.id] = currentBackendState(for: profile)
    }

    /// Delete the server-hosted image blobs a conversation referenced, so the
    /// app owns their lifecycle (spec §2.2b). Best-effort and fire-before-delete:
    /// must run while the messages still exist to read their `/v1/files/<id>`
    /// references. A failure is harmless — the server's TTL pruner is the
    /// backstop. Uses only the conversation's own backend profile; an unbound
    /// legacy conversation fails closed rather than contacting an unrelated one.
    func purgeServerImages(conversationID: UUID) async {
        guard let detail = try? await store.conversationDetail(
            id: conversationID,
            attachmentData: .metadataOnly
        ) else { return }
        let ids = detail.messages.flatMap { ServerImageRef.ids(in: $0.message.content) }
        guard !ids.isEmpty else { return }
        guard let profileID = detail.conversation.profileID else { return }
        let profile = profiles.first { $0.id == profileID }
        guard let profile, let base = profile.baseURL else { return }
        let token = keychain.token(for: profile.id) ?? ""
        await ImageClient().delete(ids: ids, base: base, token: token)
    }

    /// Best-effort server cleanup for the bulk history control. References are
    /// grouped by their owning backend so tokenless and authenticated profiles
    /// both work, and no request is sent to an unrelated active backend.
    func purgeAllServerImages() async {
        guard let details = try? await store.allConversationDetails(
            attachmentData: .metadataOnly
        ) else { return }
        var idsByProfile: [UUID: Set<String>] = [:]
        for detail in details {
            guard let profileID = detail.conversation.profileID,
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

    func upsert(_ profile: BackendProfile, token: String?) throws {
        // Commit the credential first. If secure storage is unavailable, keep
        // both the existing token and all profile metadata unchanged so the UI
        // can report the failure without leaving a half-saved backend.
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedToken.isEmpty {
            try keychain.delete(for: profile.id)
        } else {
            try keychain.setToken(normalizedToken, for: profile.id)
        }

        backendStates[profile.id] = nil
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
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
        backendStates[profile.id] = nil
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
        cacheActiveBackendState()
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
        backendMode = profile.effectiveTransport == .mapleEncrypted
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
            preferMaple: profile.effectiveTransport == .mapleEncrypted
        )
        let mode: BackendMode
        switch result {
        case .success(let resolved):
            mode = resolved
        case .failure:
            // Keep a known Maple profile on the encrypted transport while it is
            // temporarily unreachable. The cached model list preserves the same
            // launch/offline behavior as other backends.
            mode = profile.effectiveTransport == .mapleEncrypted
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
        cacheActiveBackendState()
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

    func setThinkingEnabled(_ enabled: Bool, for model: String?, profileID: UUID) {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return }
        var byModel = thinkingPreferences[profileID.uuidString] ?? [:]
        byModel[model] = enabled
        thinkingPreferences[profileID.uuidString] = byModel
        modelPreferenceStore.saveThinkingPreferences(thinkingPreferences)
    }

    func setSelectedReasoningEffort(
        _ effort: String,
        for model: String?,
        profileID: UUID
    ) {
        guard let session = backendSession(for: profileID),
              session.reasoningEfforts(for: model).contains(effort),
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return }
        var byModel = reasoningEffortPreferences[profileID.uuidString] ?? [:]
        byModel[model] = effort
        reasoningEffortPreferences[profileID.uuidString] = byModel
        modelPreferenceStore.saveReasoningEffortPreferences(reasoningEffortPreferences)
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
        guard let profileID = activeProfileID else { return }
        warm(model: model, profileID: profileID)
    }

    func warm(model: String, profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              profile.autoWarm,
              let base = profile.baseURL else { return }
        guard let session = backendSession(for: profileID) else { return }
        let token = session.token
        let mode = session.mode
        Task.detached { [warmupClient] in
            await warmupClient.warm(model: model, base: base, token: token, mode: mode)
        }
    }
}
