import SwiftUI

struct PrivacyDataView: View {
    var body: some View {
        List {
            Section {
                Label("Chat history and attachments are stored on this device.", systemImage: "iphone")
                Label("Backend URLs and model choices use app preferences.", systemImage: "gearshape")
                Label("Bearer tokens are stored in Keychain.", systemImage: "key")
            } header: {
                Text("Stored Locally")
            }

            Section {
                Label("Prompts, attachments, and conversation history are sent to your configured backend when you send a message.", systemImage: "arrow.up.right")
                Label("Siri and Shortcuts questions are sent to the active backend without saving a chat.", systemImage: "sparkles")
            } header: {
                Text("Sent to Backend")
            } footer: {
                Text("Use a backend you control or trust. Phantasm does not include a developer-hosted backend by default.")
            }

            Section {
                Label("Location shares your approximate current location only when enabled and requested by the model.", systemImage: "location")
                Label("Health reads selected Apple Health metrics only when enabled and requested. It is read-only.", systemImage: "heart")
                Label("Calendar reads matching events only when enabled and requested. Creating events requires confirmation.", systemImage: "calendar")
            } header: {
                Text("Device Tools")
            } footer: {
                Text("Tool results become part of the chat sent to your configured backend.")
            }
        }
        .navigationTitle("Privacy & Data")
    }
}
