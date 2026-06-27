import MarkdownUI
import PhantasmKit
import SwiftUI

/// Renders assistant markdown (FR-A4) with fenced code blocks (copy button) and
/// inline images (FR-A7), including base64 data-URIs resolved via a custom image
/// provider.
struct MarkdownMessageView: View {
    let text: String
    /// Backend origin used to resolve server-hosted `/v1/images/<id>` references,
    /// which arrive as relative paths (spec §2.2b). Nil => only inline/absolute
    /// images render.
    var imageBaseURL: URL? = nil

    var body: some View {
        let extracted = Base64ImageExtractor().extractCached(text)
        Markdown(extracted.markdown)
            .markdownImageProvider(
                PhantasmImageProvider(images: extracted.images, baseURL: imageBaseURL)
            )
            .markdownBlockStyle(\.codeBlock) { configuration in
                CodeBlockView(configuration: configuration)
            }
            .textSelection(.enabled)
    }
}

/// A fenced code block with a copy-to-clipboard button (FR-A4).
private struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.language ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = configuration.content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .padding(12)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Resolves image URLs for MarkdownUI: `phantasm-img://<n>` placeholders from
/// extracted base64 payloads, and ordinary `http(s)` images via `AsyncImage`.
struct PhantasmImageProvider: ImageProvider {
    let images: [Int: Data]
    /// Origin for resolving relative `/v1/images/<id>` references to absolute URLs.
    var baseURL: URL? = nil

    func makeImage(url: URL?) -> some View {
        Group {
            if let url, url.scheme == "phantasm-img",
               let index = Int(url.host ?? ""),
               let data = images[index],
               let uiImage = UIImage(data: data) {
                resizable(Image(uiImage: uiImage))
                    .contextMenu { ImageActions(image: uiImage) }
            } else if let url {
                AsyncImage(url: resolve(url)) { image in
                    resizable(image)
                } placeholder: {
                    ProgressView()
                }
            } else {
                EmptyView()
            }
        }
    }

    /// A server-hosted image arrives as a relative path (`/v1/images/<id>?…`);
    /// resolve it against the backend origin. Absolute URLs pass through.
    private func resolve(_ url: URL) -> URL {
        guard url.scheme == nil, let baseURL else { return url }
        return URL(string: url.absoluteString, relativeTo: baseURL)?.absoluteURL ?? url
    }

    private func resizable(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Save / share actions for a generated image (FR-A7).
private struct ImageActions: View {
    let image: UIImage

    var body: some View {
        Button {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        } label: {
            Label("Save to Photos", systemImage: "square.and.arrow.down")
        }
        if let data = image.pngData() {
            ShareLink(item: Image(uiImage: image), preview: .init("Generated image", image: Image(uiImage: image))) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .id(data.count)
        }
    }
}
