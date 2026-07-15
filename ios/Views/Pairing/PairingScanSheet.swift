import AVFoundation
import PhantasmKit
import SwiftUI
import VisionKit

/// Camera scanner for pairing QR codes (FR-A12). The camera keeps running
/// across non-pairing codes (a wrong QR shows a hint, not a dead end).
/// Scanning is an accelerator, never the only path: unsupported hardware and
/// a denied camera each get an explanatory fallback with a paste-the-link
/// alternative, and the scanner is only mounted once camera access is
/// actually authorized (mounting earlier would swallow the authorization
/// error and show a dead black view).
struct PairingScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (PairingPayload) -> Void

    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hint: String?
    @State private var scannerStartupError: String?
    @State private var handled = false

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    fallback(
                        title: "Camera Scanning Unavailable",
                        message: "This device can't scan QR codes in the app."
                    )
                } else {
                    switch cameraStatus {
                    case .authorized:
                        scanner
                    case .notDetermined:
                        ProgressView()
                            .task {
                                let granted = await AVCaptureDevice.requestAccess(for: .video)
                                cameraStatus = granted ? .authorized : .denied
                            }
                    default:
                        fallback(
                            title: "Camera Access Denied",
                            message: "Allow camera access in Settings to scan, or paste the link instead.",
                            showOpenSettings: true
                        )
                    }
                }
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var scanner: some View {
        QRScannerRepresentable(
            onScan: { handle($0) },
            onStartupError: { error in
                scannerStartupError = "Camera scanning couldn't start: \(error.localizedDescription)"
            },
            onStartupSuccess: { scannerStartupError = nil }
        )
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    hintLabel
                    pasteButton
                }
                .padding(.bottom, 24)
            }
    }

    /// Unsupported-hardware / denied-camera path: the same link the QR encodes
    /// can be AirDropped or messaged and pasted here (it's printed next to the
    /// QR by `phantasm-orchestrator pair`, and shareable from another device's
    /// backend settings).
    private func fallback(
        title: String,
        message: String,
        showOpenSettings: Bool = false
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "qrcode.viewfinder")
        } description: {
            Text(message)
        } actions: {
            VStack(spacing: 12) {
                hintLabel
                pasteButton
                if showOpenSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { UIApplication.shared.open(url) }
                }
            }
        }
    }

    @ViewBuilder
    private var hintLabel: some View {
        if let message = hint ?? scannerStartupError {
            Text(message)
                .font(.callout)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var pasteButton: some View {
        Button {
            Haptics.selection()
            if let pasted = UIPasteboard.general.string {
                handle(pasted)
            } else {
                hint = "The clipboard doesn't contain any text."
            }
        } label: {
            Label("Paste Setup Link", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(.bordered)
    }

    private func handle(_ raw: String) {
        guard !handled else { return }
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            hint = PairingURI.ParseError.notPairingURI.userMessage
            return
        }
        do {
            let payload = try PairingURI.parse(url)
            handled = true
            Haptics.notify(.success)
            // No dismiss() here: hosts drive a single sheet(item:) route, so
            // swapping to the confirmation stage replaces this content in
            // place — dismissing first would race the next presentation.
            onScan(payload)
        } catch let error as PairingURI.ParseError {
            hint = error.userMessage
        } catch {
            hint = PairingURI.ParseError.notPairingURI.userMessage
        }
    }
}

/// Thin VisionKit wrapper: QR symbology only, single item, system highlight.
/// Only mounted with camera access already authorized (see PairingScanSheet),
/// so startScanning() can't fail on permissions.
private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onStartupError: (Error) -> Void
    let onStartupSuccess: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScan: onScan,
            onStartupError: onStartupError,
            onStartupSuccess: onStartupSuccess
        )
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
            context.coordinator.reportStartupSuccessIfNeeded()
        } catch {
            context.coordinator.reportStartupError(error)
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        let onStartupError: (Error) -> Void
        let onStartupSuccess: () -> Void
        var didReportStartupError = false

        init(
            onScan: @escaping (String) -> Void,
            onStartupError: @escaping (Error) -> Void,
            onStartupSuccess: @escaping () -> Void
        ) {
            self.onScan = onScan
            self.onStartupError = onStartupError
            self.onStartupSuccess = onStartupSuccess
        }

        func reportStartupError(_ error: Error) {
            guard !didReportStartupError else { return }
            didReportStartupError = true
            DispatchQueue.main.async { [onStartupError] in
                onStartupError(error)
            }
        }

        func reportStartupSuccessIfNeeded() {
            guard didReportStartupError else { return }
            didReportStartupError = false
            DispatchQueue.main.async { [onStartupSuccess] in
                onStartupSuccess()
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .barcode(let barcode) in addedItems {
                guard let value = barcode.payloadStringValue else { continue }
                onScan(value)
                return
            }
        }
    }
}
