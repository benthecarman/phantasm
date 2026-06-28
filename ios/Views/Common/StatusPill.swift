import SwiftUI

/// A small "activity" pill used for `x_status` progress and the backend mode
/// indicator.
struct StatusPill: View {
    let text: String
    var systemImage: String = "sparkles"
    var isAnimated = false
    var progress: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false
    @State private var pulse = false

    private var clampedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    private var shouldAnimate: Bool {
        isAnimated && clampedProgress == nil && !reduceMotion
    }

    var body: some View {
        label
            .font(.caption.weight(isAnimated ? .medium : .regular))
            .foregroundStyle(isAnimated ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(backgroundColor)
                    .overlay {
                        if let clampedProgress {
                            progressFill(clampedProgress)
                        } else if shouldAnimate {
                            shimmerBand(opacity: 0.28)
                        }
                    }
            }
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(isAnimated ? Color.accentColor.opacity(0.20) : Color.clear, lineWidth: 1)
            }
            .overlay {
                if shouldAnimate {
                    label
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .mask(shimmerBand(opacity: 1))
                }
            }
            .onAppear(perform: startAnimationIfNeeded)
            .onChange(of: shouldAnimate) { _, _ in startAnimationIfNeeded() }
            .animation(.easeInOut(duration: 0.25), value: clampedProgress)
            .accessibilityLabel(text)
            .accessibilityValue(Text(accessibilityProgressValue))
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .scaleEffect(shouldAnimate ? (pulse ? 1.08 : 0.94) : 1)
                .opacity(shouldAnimate ? (pulse ? 1 : 0.78) : 1)
            Text(text)
        }
    }

    private var backgroundColor: Color {
        if clampedProgress != nil {
            return Color.accentColor.opacity(0.08)
        }
        return isAnimated ? Color.accentColor.opacity(0.10) : Color(.tertiarySystemFill)
    }

    private var accessibilityProgressValue: String {
        guard let clampedProgress else { return "" }
        return "\(Int((clampedProgress * 100).rounded())) percent"
    }

    private func progressFill(_ progress: Double) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor.opacity(0.24))
                .frame(width: proxy.size.width * progress)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(false)
    }

    private func shimmerBand(opacity: Double) -> some View {
        GeometryReader { proxy in
            let width = max(44, proxy.size.width * 0.38)
            LinearGradient(
                colors: [.clear, .white.opacity(opacity), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width, height: proxy.size.height * 2)
            .rotationEffect(.degrees(12))
            .offset(
                x: shimmer ? proxy.size.width + width : -width * 1.5,
                y: -proxy.size.height * 0.5
            )
        }
        .allowsHitTesting(false)
    }

    private func startAnimationIfNeeded() {
        guard shouldAnimate else {
            shimmer = false
            pulse = false
            return
        }
        withAnimation(.linear(duration: 1.45).repeatForever(autoreverses: false)) {
            shimmer = true
        }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
