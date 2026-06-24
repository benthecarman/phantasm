import GRDBQuery
import PhantasmKit
import SwiftUI

@main
struct PhantasmApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .task { await env.refreshCapabilities() }
        }
        // Reactive reads (@Query) observe the SQLite store; writes go through
        // `env.store`, so a read-only context is all the Views need here.
        .databaseContext(.readOnly { env.database.reader })
    }
}
