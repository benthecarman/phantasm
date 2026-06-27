import PhantasmKit
import SwiftUI

/// A slim advisory shown above the composer when the conversation is estimated
/// to be near (or past) the selected model's context window. The estimate is
/// approximate — it warns rather than blocks; the turn still sends.
struct ContextLimitBanner: View {
    let usage: ContextUsage

    private var tint: Color { usage.isOverLimit ? .red : .orange }

    private var message: String {
        let window = ContextWindow.formatTokens(usage.contextLength)
        if usage.isOverLimit {
            return "This chat likely exceeds the model's \(window) context. The oldest messages may be dropped."
        }
        return "Approaching the model's \(window) context limit. Older messages may soon be dropped."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}
