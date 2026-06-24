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
    }

    var activeProfile: BackendProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    var activeToken: String? {
        activeProfile.flatMap { keychain.token(for: $0.id) }
    }

    /// Models to offer in the picker for the active backend.
    var availableModels: [String] {
        let advertised = backendMode.models
        if !advertised.isEmpty { return advertised }
        if let m = activeProfile?.defaultModel, !m.isEmpty { return [m] }
        return []
    }

    func upsert(_ profile: BackendProfile, token: String?) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        if let token, !token.isEmpty {
            try? keychain.setToken(token, for: profile.id)
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
              let base = profile.baseURL,
              let token = keychain.token(for: profile.id) else {
            backendMode = .plainChatOnly(models: [])
            return
        }
        isProbing = true
        backendMode = await capabilitiesClient.probe(base: base, token: token)
        isProbing = false
    }
}
