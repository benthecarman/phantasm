import PhantasmKit
import SwiftUI

/// A removable chip for a not-yet-sent attachment in the composer.
struct PendingAttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            Button(action: onRemove) {
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

    var body: some View {
        let images = attachments.filter { $0.kind == AttachmentKind.image.rawValue }
        let files = attachments.filter { $0.kind == AttachmentKind.text.rawValue }
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { att in
                        if let ui = UIImage(data: att.data) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
