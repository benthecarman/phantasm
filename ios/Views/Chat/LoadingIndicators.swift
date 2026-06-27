import SwiftUI

/// The waiting-for-first-token indicator shown in `StreamingBubble` before any
/// text, reasoning, or `x_status` arrives.
///
/// A themed verb with a gold shimmer sweeping across the glyphs. One verb is
/// chosen per turn (seeded from the turn start) and held for the whole wait;
/// pairs with the `x_status` sparkle pill.
struct ConjuringLoader: View {
    /// When the turn began — used to pick a stable verb for this turn.
    var seed: Date = .distantPast

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    private let verbs = ["Conjuring…", "Summoning…", "Materializing…", "Channeling…"]

    private var verb: String {
        let bucket = Int(seed.timeIntervalSinceReferenceDate.rounded())
        return verbs[abs(bucket) % verbs.count]
    }

    var body: some View {
        label(verb)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    sweep = true
                }
            }
            .accessibilityLabel("Waiting for a reply")
    }

    private func label(_ verb: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
            Text(verb)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(Color.accentColor.opacity(0.55))
        .overlay { if !reduceMotion { shimmer(verb) } }
    }

    /// The same content, brighter, masked to a moving band — reads as a glint
    /// travelling across the text.
    private func shimmer(_ verb: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
            Text(verb)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .mask(
            LinearGradient(
                colors: [.clear, .white, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 60)
            .offset(x: sweep ? 110 : -110)
        )
    }
}

#Preview("Conjuring") {
    ConjuringLoader()
        .padding(40)
}
