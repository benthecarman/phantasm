import GRDBQuery
import PhantasmKit
import SwiftUI
import UserNotifications

@main
struct PhantasmApp: App {
    @State private var env = AppEnvironment()
    @State private var notificationRouter: NotificationRouter
    /// Retained strongly here — `UNUserNotificationCenter.current().delegate` is
    /// a weak reference.
    private let notificationDelegate: ChatNotificationDelegate

    init() {
        // Register the delegate during launch so a tap that cold-launched the
        // app (delivered just after launch finishes) is routed to its chat.
        let router = NotificationRouter()
        let delegate = ChatNotificationDelegate(router: router)
        UNUserNotificationCenter.current().delegate = delegate
        _notificationRouter = State(initialValue: router)
        notificationDelegate = delegate
    }

    var body: some Scene {
        WindowGroup {
            // No capability probe here: AppEnvironment.init already refreshes
            // on construction — probing again from `.task` doubled the
            // cold-start network chatter for nothing.
            RootView()
                .environment(env)
                .environment(notificationRouter)
        }
        // Reactive reads (@Query) observe the SQLite store; writes go through
        // `env.store`, so a read-only context is all the Views need here.
        .databaseContext(.readOnly { env.database.reader })
    }
}
