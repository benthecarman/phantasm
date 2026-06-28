import Foundation
import Observation
import UserNotifications

/// Shared encoding of the "your response is ready" local notification's
/// identifier. The conversation id is baked into the request identifier so a
/// tap can route back to the originating chat — keep the construction and the
/// parsing in one place so they can't drift.
enum ChatCompletionNotification {
    private static let prefix = "chat-response-"

    /// The notification request identifier for a completed turn. A nil
    /// conversation id (an unsaved draft) yields a non-routable random id.
    static func identifier(for conversationID: UUID?) -> String {
        conversationID.map { "\(prefix)\($0.uuidString)" } ?? UUID().uuidString
    }

    /// The conversation id encoded in a notification identifier, if it is one of
    /// ours; nil for unrelated notifications.
    static func conversationID(from identifier: String) -> UUID? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(prefix.count)))
    }
}

/// Bridges a notification tap to the navigation layer. The delegate sets the
/// tapped conversation here and `RootView` observes it to open that chat.
@MainActor
@Observable
final class NotificationRouter {
    /// Set when the user taps a chat-completion notification; consumed (and
    /// cleared) by `RootView` once it has navigated.
    var pendingConversationID: UUID?
}

/// Receives notification taps. Held strongly by the app (the center's `delegate`
/// is weak) so it survives long enough to handle a cold-launch tap, which is
/// delivered after launch finishes.
final class ChatNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let router: NotificationRouter

    init(router: NotificationRouter) {
        self.router = router
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        if let conversationID = ChatCompletionNotification.conversationID(from: identifier) {
            Task { @MainActor in router.pendingConversationID = conversationID }
        }
        completionHandler()
    }
}
