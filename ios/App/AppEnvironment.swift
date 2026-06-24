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
    let keychain = KeychainStore()
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

    init() {
        // Schema is tiny; opening the SQLite store + migrations is fast (NFR-A5).
        database = try! AppDatabase.makeShared()
        profiles = profileStore.load()
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

    /// Models to offer in the picker for the active backend. Prefers the live
    /// probe result, falls back to the per-backend cache (so the full list shows
    /// instantly on launch, before the probe completes). The saved default is
    /// included even if it was not advertised, so existing selections remain
    /// visible.
    var availableModels: [String] {
        var models = discoveredModels
        if let defaultModel = activeDefaultModel, !models.contains(defaultModel) {
            models.insert(defaultModel, at: 0)
        }
        return models
    }

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
        guard let profile = activeProfile,
              let base = profile.baseURL else {
            backendMode = .plainChatOnly(models: [])
            return
        }
        isProbing = true
        let token = keychain.token(for: profile.id) ?? ""
        backendMode = await capabilitiesClient.probe(base: base, token: token)
        isProbing = false
        // Cache the discovered model list so it's available instantly next launch.
        let models = backendMode.models
        if !models.isEmpty {
            profileStore.cacheModels(models, for: profile.id)
        }
        await refreshVisionModels(base: base, token: token)
        warmActiveModel(base: base, token: token)
    }

    /// Resolve which models accept images for the current backend: from the
    /// orchestrator manifest when present, by probing Ollama `/api/show` for a
    /// bare native backend, and unknown (optimistic) for generic OpenAI.
    private func refreshVisionModels(base: URL, token: String) async {
        switch backendMode {
        case .full(let caps):
            visionModels = caps.visionModels.map(Set.init)
        case .ollamaNative(let models):
            visionModels = await capabilitiesClient.fetchOllamaVisionModels(
                base: base, token: token, models: models
            )
        case .plainChatOnly:
            visionModels = nil
        }
    }

    /// Whether `model` can accept image attachments. Unknown backends return
    /// `true` (optimistic) so we never hide a capability that may exist.
    func supportsVision(_ model: String?) -> Bool {
        guard let visionModels else { return true }
        guard let model else { return false }
        return visionModels.contains(model)
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
