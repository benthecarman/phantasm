import PDFKit
import PhantasmKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// An attachment chosen in the composer but not yet sent. Images carry compressed
/// bytes (+ a thumbnail for the chip); text files carry their extracted text.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let kind: AttachmentKind
    let name: String
    var imageData: Data = Data()
    var mimeType: String = "image/jpeg"
    var text: String = ""
    var thumbnail: UIImage?

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

/// Loads picked photos and files into `PendingAttachment`s. Images are downscaled
/// and re-encoded as JPEG to keep request payloads sane; text files (incl. PDFs)
/// are extracted to plain text on-device and truncated to a cap.
enum AttachmentLoader {
    /// Longest edge an attached image is scaled down to before upload.
    static let maxImageDimension: CGFloat = 1536
    static let jpegQuality: CGFloat = 0.7
    /// Cap on inlined file text so a huge file can't blow up the prompt.
    static let maxFileCharacters = 200_000
    /// Input caps are deliberately larger than the final character cap to
    /// preserve compatibility with ordinary documents while avoiding an
    /// unbounded `Data(contentsOf:)` allocation for a picked file.
    static let maxTextSourceBytes = 1 * 1024 * 1024
    static let maxPDFSourceBytes = 25 * 1024 * 1024
    static let maxPDFPages = 200

    /// File types offered to the document importer.
    static let importableTypes: [UTType] = [
        .plainText, .text, .pdf, .json, .commaSeparatedText, .sourceCode, .yaml, .xml, .rtf,
    ]

    private struct FilePayload: Sendable {
        let name: String
        let text: String
    }

    static func image(from item: PhotosPickerItem) async -> PendingAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let original = UIImage(data: data) else { return nil }
        let scaled = downscale(original)
        guard let jpeg = scaled.jpegData(compressionQuality: jpegQuality) else { return nil }
        return PendingAttachment(
            kind: .image,
            name: "Photo",
            imageData: jpeg,
            mimeType: "image/jpeg",
            thumbnail: scaled
        )
    }

    /// Builds an attachment from an image captured with the camera (already a
    /// `UIImage`, so no async `Transferable` load is needed).
    static func image(from original: UIImage) -> PendingAttachment? {
        let scaled = downscale(original)
        guard let jpeg = scaled.jpegData(compressionQuality: jpegQuality) else { return nil }
        return PendingAttachment(
            kind: .image,
            name: "Photo",
            imageData: jpeg,
            mimeType: "image/jpeg",
            thumbnail: scaled
        )
    }

    static func file(at url: URL) async -> PendingAttachment? {
        guard let payload = await Task.detached(priority: .userInitiated, operation: {
            filePayload(at: url)
        }).value else { return nil }
        return PendingAttachment(kind: .text, name: payload.name, text: payload.text)
    }

    private static func filePayload(at url: URL) -> FilePayload? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               size > maxPDFSourceBytes { return nil }
            guard let doc = PDFDocument(url: url) else { return nil }
            var extracted = ""
            for index in 0..<min(doc.pageCount, maxPDFPages) {
                guard let page = doc.page(at: index), let pageText = page.string else { continue }
                let remaining = maxFileCharacters - extracted.count
                guard remaining > 0 else { break }
                extracted += String(pageText.prefix(remaining))
                extracted += "\n"
                if extracted.count >= maxFileCharacters { break }
            }
            text = extracted
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maxTextSourceBytes),
                  !data.isEmpty else { return nil }
            guard let decoded = decodeTextPrefix(data) else { return nil }
            text = decoded
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return FilePayload(name: name, text: String(trimmed.prefix(maxFileCharacters)))
    }

    /// A bounded read can stop in the middle of a UTF-8 scalar. Drop at most
    /// the three incomplete trailing bytes before falling back to Latin-1, so a
    /// large valid UTF-8 document does not turn into mojibake at the cap.
    private static func decodeTextPrefix(_ data: Data) -> String? {
        if let decoded = String(data: data, encoding: .utf8) { return decoded }
        for count in 1...3 where data.count > count {
            if let decoded = String(data: Data(data.dropLast(count)), encoding: .utf8) {
                return decoded
            }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxImageDimension else { return image }
        let scale = maxImageDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
