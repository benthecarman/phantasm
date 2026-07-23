import PhantasmKit
import SwiftUI

/// A compact, persistent view of how much of the selected model's context window
/// this chat occupies. The ring lives in the toolbar; tapping it reveals the
/// estimate without permanently taking space away from the transcript.
struct ContextUsageIndicator: View {
    let usage: ContextUsage
    let tokensPerSecond: Double?

    @State private var showsDetails = false

    private var tint: Color {
        if usage.isOverLimit { return .red }
        if usage.isNearLimit { return .orange }
        return .accentColor
    }

    private var percentage: Int {
        Int((usage.fraction * 100).rounded())
    }

    var body: some View {
        Button {
            Haptics.selection()
            showsDetails.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: usage.displayedFraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if usage.isOverLimit {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 22, height: 22)
            .padding(3)
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.25), value: usage.displayedFraction)
            .animation(.easeInOut(duration: 0.25), value: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context usage")
        .accessibilityValue("Approximately \(percentage) percent")
        .accessibilityHint("Shows estimated token usage for this chat")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            details
                .presentationCompactAdaptation(.popover)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Context", systemImage: "memorychip")
                    .font(.headline)
                Spacer(minLength: 24)
                Text("\(percentage)%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(tint)
            }

            ProgressView(value: usage.displayedFraction)
                .tint(tint)

            Text("~\(usage.estimatedTokens.formatted()) of \(usage.contextLength.formatted()) tokens")
                .font(.subheadline.weight(.medium))

            if let tokensPerSecond {
                HStack {
                    Label("Latest response", systemImage: "gauge.with.dots.needle.50percent")
                    Spacer()
                    Text("\(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s")
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.medium))
            }

            Text(detailMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 285)
        .accessibilityElement(children: .combine)
    }

    private var detailMessage: String {
        if usage.isOverLimit {
            return "This chat may exceed the model's context window, so its oldest messages can be dropped. Token use is estimated from saved messages and attachments."
        }
        if usage.isNearLimit {
            return "This chat is approaching the model's context limit. Token use is estimated from saved messages and attachments."
        }
        return "Token use is estimated. Generation speed uses backend timing when available and otherwise uses a local estimate."
    }
}
