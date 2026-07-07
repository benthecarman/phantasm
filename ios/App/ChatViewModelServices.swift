import Foundation
import PhantasmKit
import UIKit
import UserNotifications

@MainActor
protocol ChatViewModelEnvironment: AnyObject {
    var activeProfile: BackendProfile? { get }
    var activeToken: String? { get }
    var backendMode: BackendMode { get }
    var preferredModel: String? { get }
    var chatStreamingClient: any ChatClienting { get }
    var ollamaStreamingClient: any ChatClienting { get }
    var autoSpeakEnabled: Bool { get }

    func supportsTools(_ model: String?) -> Bool
    func thinkingEnabled(for model: String?) -> Bool
    func reasoningEffort(for model: String?) -> String?
    func setDefaultLocationEnabled(_ enabled: Bool)
    func requestLocationAuthorizationWhenInUse()
    func setDefaultHealthEnabled(_ enabled: Bool)
    func requestHealthAuthorization()
    func setDefaultCalendarEnabled(_ enabled: Bool)
    func requestCalendarAuthorization()
    func warm(model: String)
    func speak(_ text: String, messageID: UUID)
    /// Fire-and-forget: bring the semantic search index up to date after a
    /// turn commits new message rows.
    func indexSearchEmbeddings()
}

extension AppEnvironment: ChatViewModelEnvironment {
    var chatStreamingClient: any ChatClienting { chatClient }
    var ollamaStreamingClient: any ChatClienting { ollamaChatClient }
    var autoSpeakEnabled: Bool { voicePreferenceStore.autoSpeak }

    func setDefaultLocationEnabled(_ enabled: Bool) {
        toolPreferenceStore.locationEnabledDefault = enabled
    }

    func requestLocationAuthorizationWhenInUse() {
        locationProvider.requestAuthorizationWhenInUse()
    }

    func setDefaultHealthEnabled(_ enabled: Bool) {
        toolPreferenceStore.healthEnabledDefault = enabled
    }

    func requestHealthAuthorization() {
        healthProvider.requestAuthorization()
    }

    func setDefaultCalendarEnabled(_ enabled: Bool) {
        toolPreferenceStore.calendarEnabledDefault = enabled
    }

    func requestCalendarAuthorization() {
        calendarProvider.requestAuthorization()
    }

    func speak(_ text: String, messageID: UUID) {
        speechSynthesizer.speak(text, messageID: messageID)
    }

    func indexSearchEmbeddings() {
        Task { [searchIndexer] in await searchIndexer.indexPending() }
    }
}

@MainActor
protocol BackgroundTaskManaging {
    var invalidTaskID: UIBackgroundTaskIdentifier { get }
    func beginBackgroundTask(
        named name: String,
        expirationHandler: @escaping @MainActor () -> Void
    ) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier)
}

struct UIApplicationBackgroundTaskManager: BackgroundTaskManaging {
    var invalidTaskID: UIBackgroundTaskIdentifier { .invalid }

    func beginBackgroundTask(
        named name: String,
        expirationHandler: @escaping @MainActor () -> Void
    ) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in expirationHandler() }
        }
    }

    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(id)
    }
}

@MainActor
protocol NotificationManaging {
    func requestAuthorizationIfNeeded() async
    func scheduleBackgroundCompletion(conversationID: UUID?) async
}

struct UserNotificationManager: NotificationManaging {
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func scheduleBackgroundCompletion(conversationID: UUID?) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let isAuthorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .denied:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Phantasm"
        content.body = "Your response is ready."
        content.sound = .default

        let id = ChatCompletionNotification.identifier(for: conversationID)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(request)
    }
}

protocol ImageFetching: Sendable {
    func fetch(_ url: URL) async -> ServerImageRef.CachedImage?
}

extension ImageClient: ImageFetching {}
