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
        .modelContainer(env.container)
    }
}
