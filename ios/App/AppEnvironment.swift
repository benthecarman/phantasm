import Foundation
import Observation
import PhantasmKit
import SwiftData

/// App-wide services + connection state, injected through the SwiftUI
/// environment. Holds the SwiftData container, the profile/keychain stores, and
/// the resolved `BackendMode` for the active profile.
@MainActor
@Observable
final class AppEnvironment {
    let container: ModelContainer
    let profileStore = ProfileStore()
    let keychain = KeychainStore()
    let chatClient = ChatClient()
    let capabilitiesClient = CapabilitiesClient()

    var profiles: [BackendProfile]
    var activeProfileID: UUID?
    var backendMode: BackendMode = .plainChatOnly(models: [])
    var isProbing = false

    init() {
        // Schema is tiny; container creation is fast (NFR-A5 cold start).
        container = try! ModelContainer(for: Conversation.self, Message.self)
        let store = profileStore
        profiles = store.load()
        activeProfileID = store.activeProfileID ?? profiles.first?.id
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
    /// instantly on launch, before the probe completes), then the default model.
    var availableModels: [String] {
        let advertised = backendMode.models
        if !advertised.isEmpty { return advertised }
        if let id = activeProfileID {
            let cached = profileStore.cachedModels(for: id)
            if !cached.isEmpty { return cached }
        }
        if let m = activeProfile?.defaultModel, !m.isEmpty { return [m] }
        return []
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
    }
}
