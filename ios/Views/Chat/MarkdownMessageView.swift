import MarkdownUI
import PhantasmKit
import SwiftUI

/// Renders assistant markdown (FR-A4) with fenced code blocks (copy button) and
/// inline images (FR-A7), including base64 data-URIs resolved via a custom image
/// provider.
struct MarkdownMessageView: View {
    let text: String
    /// Locally-cached server image bytes, keyed by file id. A referenced image
    /// present here renders from local bytes (offline / after URL expiry) instead
    /// of refetching; absent ones still load over the network.
    var cachedImages: [String: ServerImageRef.CachedImage] = [:]

    var body: some View {
        let resolved = ServerImageRef.inlineCached(text, cache: cachedImages)
        let extracted = Base64ImageExtractor().extractCached(resolved)
        Markdown(extracted.markdown)
            .markdownTheme(.phantasmChat)
            .markdownImageProvider(PhantasmImageProvider(images: extracted.images))
            .markdownBlockStyle(\.codeBlock) { configuration in
                CodeBlockView(configuration: configuration)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

private extension Theme {
    static let phantasmChat = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(16)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Color(.secondarySystemBackground))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            compactHeading(configuration, scale: 1.22)
        }
        .heading2 { configuration in
            compactHeading(configuration, scale: 1.14)
        }
        .heading3 { configuration in
            compactHeading(configuration, scale: 1.08)
        }
        .heading4 { configuration in
            compactHeading(configuration, scale: 1)
        }
        .heading5 { configuration in
            compactHeading(configuration, scale: 0.96)
        }
        .heading6 { configuration in
            compactHeading(configuration, scale: 0.92)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.16))
                .markdownMargin(top: .zero, bottom: .em(0.45))
        }
        .blockquote { configuration in
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: .em(0.25), bottom: .em(0.45))
        }
        .image { configuration in
            configuration.label
                .markdownMargin(top: .em(0.25), bottom: .em(0.5))
        }
        .list { configuration in
            configuration.label
                .markdownMargin(top: .em(0.15), bottom: .em(0.45))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.12))
        }
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
            }
            .markdownMargin(top: .em(0.25), bottom: .em(0.5))
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .relativeLineSpacing(.em(0.12))
        }
        .thematicBreak {
            Divider()
                .markdownMargin(top: .em(0.6), bottom: .em(0.6))
        }

    static func compactHeading(_ configuration: BlockConfiguration, scale: CGFloat) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.08))
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(scale))
            }
            .markdownMargin(top: .em(0.65), bottom: .em(0.28))
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
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.12))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .markdownMargin(top: .em(0.25), bottom: .em(0.5))
    }
}

/// Resolves image URLs for MarkdownUI: `phantasm-img://<n>` placeholders from
/// extracted base64 payloads, and ordinary `http(s)` images via `AsyncImage`.
struct PhantasmImageProvider: ImageProvider {
    let images: [Int: Data]

    func makeImage(url: URL?) -> some View {
        Group {
            if let url, url.scheme == "phantasm-img",
               let index = Int(url.host ?? ""),
               let data = images[index],
               let uiImage = UIImage(data: data) {
                resizable(Image(uiImage: uiImage))
                    .contextMenu { ImageActions(image: uiImage) }
            } else if let url {
                // Server-hosted images arrive as absolute URLs (spec §2.2b), so
                // they load directly; inline base64 is handled above.
                AsyncImage(url: url) { image in
                    resizable(image)
                } placeholder: {
                    ProgressView()
                }
            } else {
                EmptyView()
            }
        }
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
