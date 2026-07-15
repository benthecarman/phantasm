import PhantasmKit
import SwiftUI
import UIKit

/// Thin wrapper around `UIImagePickerController` in camera mode — SwiftUI has no
/// native camera capture. Hands the captured image back through `onCapture`.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// A removable chip for a not-yet-sent attachment in the composer.
struct PendingAttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            Button {
                Haptics.selection()
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch attachment.kind {
        case .image:
            if let thumb = attachment.thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .text:
            FileChipLabel(name: attachment.name)
        case .remoteImage, .inlineImage:
            // A generated image (server-cached or extracted); rendered inline
            // in the assistant markdown, never shown as an attachment chip.
            EmptyView()
        }
    }
}

/// A read-only file chip shown inside a sent message bubble.
struct FileChipLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .frame(maxWidth: 180)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Attachments rendered inside a persisted message bubble (images as thumbnails,
/// text files as chips). Right-aligned to sit above the user's text.
struct MessageAttachmentsView: View {
    let attachments: [Attachment]
    /// Tapping an image opens the full-screen viewer; reports its ordinal among
    /// this message's images (matching the gallery's ordering). The thumbnail
    /// is deliberately not reused as the viewer's full-resolution image.
    var onTapImage: (Int) -> Void = { _ in }

    var body: some View {
        let images = attachments.filter { $0.kind == AttachmentKind.image.rawValue }
        let files = attachments.filter { $0.kind == AttachmentKind.text.rawValue }
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, att in
                        MessageAttachmentThumbnail(attachment: att) {
                            onTapImage(index)
                        }
                    }
                }
            }
            ForEach(files) { att in
                FileChipLabel(name: att.name)
            }
        }
    }
}

/// A transcript-sized image decoded away from the main actor. Recreating a
/// lazy message row reuses the cost-accounted process cache by attachment ID.
private struct MessageAttachmentThumbnail: View {
    let attachment: Attachment
    let onTap: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 120, height: 120)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: attachment.data.count) {
            guard !attachment.data.isEmpty else {
                image = nil
                return
            }
            image = await AttachmentThumbnailCache.shared.image(
                for: attachment.id,
                data: attachment.data
            )
        }
    }
}
