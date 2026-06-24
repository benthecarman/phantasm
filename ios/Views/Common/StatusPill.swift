import SwiftUI

/// A small "activity" pill used for `x_status` progress and the backend mode
/// indicator.
struct StatusPill: View {
    let text: String
    var systemImage: String = "sparkles"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemFill))
        .clipShape(Capsule())
    }
}
