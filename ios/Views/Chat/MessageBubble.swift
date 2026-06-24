import PhantasmKit
import SwiftUI

/// A single persisted message. User messages render as plain text in a tinted
/// bubble; assistant messages render markdown (with images + code copy).
struct MessageBubble: View {
    let message: Message

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Group {
                if isUser {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    MarkdownMessageView(text: message.content)
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

/// The in-progress assistant turn: plain text while streaming (no markdown
/// re-parse per token, NFR-A4) plus the current `x_status` line (FR-A8).
struct StreamingBubble: View {
    let text: String
    let status: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if let status, !status.isEmpty {
                    StatusPill(text: status)
                }
                if text.isEmpty && (status == nil) {
                    ProgressView()
                } else if !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 40)
        }
    }
}
