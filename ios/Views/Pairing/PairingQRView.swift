import CoreImage.CIFilterBuiltins
import PhantasmKit
import SwiftUI

/// Renders an existing profile as a scannable pairing QR (FR-A12) so a second
/// device pairs without touching the server. Generated locally via CoreImage —
/// the URI (token included) never leaves the device. The code is hidden behind
/// an explicit reveal since anyone who captures it gets the backend, and it is
/// display-only: no share-sheet export of the raw URI.
struct PairingQRView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: PairingPayload

    /// Rendered once on reveal — the payload is immutable for the sheet's
    /// lifetime, so re-running CoreImage per body evaluation is pure waste.
    @State private var revealedImage: UIImage?
    @State private var generationFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let revealedImage {
                    qrContent(revealedImage)
                } else {
                    warning
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .navigationTitle("Pair Another Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var warning: some View {
        ContentUnavailableView {
            Label("This code is a key", systemImage: "qrcode")
        } description: {
            Text(payload.token == nil
                ? "Anyone who scans it can see this backend's address. Show it only to devices you trust."
                : "It contains your access token — anyone who scans or photographs it can use your backend. Show it only to devices you trust.")
        } actions: {
            VStack(spacing: 8) {
                Button("Show Code") {
                    Haptics.selection()
                    revealedImage = Self.qrImage(for: payload.uri)
                    generationFailed = revealedImage == nil
                }
                .buttonStyle(.borderedProminent)
                if generationFailed {
                    Text("The pairing link couldn't be rendered as a QR code.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func qrContent(_ image: UIImage) -> some View {
        Group {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
            VStack(spacing: 6) {
                Text("Scan with the other device's camera, or from Settings → Pair via QR Code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(payload.baseURLString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    /// Apple documents CIContext as expensive to create and meant for reuse.
    private static let ciContext = CIContext()

    /// CoreImage QR at medium error correction, scaled without smoothing so
    /// modules stay crisp.
    private static func qrImage(for uri: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = Self.ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
