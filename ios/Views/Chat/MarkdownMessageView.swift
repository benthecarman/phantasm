import MarkdownUI
import PhantasmKit
import ImageIO
import AVKit
import SwiftUI

/// Renders assistant markdown (FR-A4) with fenced code blocks (copy button) and
/// inline images (FR-A7), including base64 data-URIs resolved via a custom image
/// provider.
struct MarkdownMessageView: View {
    let text: String
    /// Persisted inline-image attachments keyed by `phantasm-file://` name.
    /// These feed the renderer as bytes, avoiding a base64 encode/decode cycle.
    var storedImages: [String: ServerImageRef.CachedImage] = [:]
    /// Locally-cached server image bytes, keyed by file id. A referenced image
    /// present here renders from local bytes (offline / after URL expiry) instead
    /// of refetching; absent ones still load over the network.
    var cachedImages: [String: ServerImageRef.CachedImage] = [:]
    /// Origin allowed for automatic signed-image loads. Nil means remote images
    /// remain explicit links (the safe streaming/default behavior).
    var trustedImageBase: URL? = nil
    /// Live streaming preview: the view re-renders per token, so inline base64
    /// images are stripped without decoding (no multi-MB regex/decode on the
    /// main actor per token); they render when the message commits.
    var isStreaming = false
    /// Tapping an inline image opens the full-screen viewer. Reports the image's
    /// ordinal within this message (its `phantasm-img://` index) and decoded bytes.
    var onTapImage: (Int, UIImage) -> Void = { _, _ in }

    var body: some View {
        let artifacts = ServerArtifactRef.extractTrusted(in: text, backendBase: trustedImageBase)
        let extracted: Base64ImageExtractor.Result = isStreaming
            ? .init(
                markdown: Base64ImageExtractor.streamingSanitized(artifacts.markdown), images: [:]
            )
            : preparedImages(in: artifacts.markdown)
        VStack(alignment: .leading, spacing: 10) {
            if !extracted.markdown.isEmpty {
                Markdown(extracted.markdown)
                    .markdownTheme(.phantasmChat)
                    .markdownImageProvider(PhantasmImageProvider(
                        images: extracted.images,
                        trustedBase: trustedImageBase,
                        onTap: onTapImage
                    ))
                    .markdownBlockStyle(\.codeBlock) { configuration in
                        CodeBlockView(configuration: configuration)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if !isStreaming {
                ForEach(artifacts.artifacts) { artifact in
                    switch artifact.kind {
                    case .video:
                        GeneratedVideoView(artifact: artifact)
                    case .audio:
                        GeneratedAudioView(artifact: artifact)
                    }
                }
            }
        }
    }

    private func preparedImages(in source: String) -> Base64ImageExtractor.Result {
        let base64 = Base64ImageExtractor().extractCached(source)
        let next = (base64.images.keys.max() ?? -1) + 1
        let stored = InlineImageRef.placeholders(
            in: base64.markdown, images: storedImages, startingAt: next
        )
        let server = ServerImageRef.cachedPlaceholders(
            in: stored.markdown,
            cache: cachedImages,
            startingAt: next + stored.images.count
        )
        return .init(
            markdown: server.markdown,
            images: base64.images.merging(stored.images) { current, _ in current }
                .merging(server.images) { current, _ in current }
        )
    }
}

private struct GeneratedAudioView: View {
    let artifact: ServerArtifactRef.Artifact
    @State private var player: AVPlayer
    @State private var isPlaying = false
    @State private var playbackError: String?

    init(artifact: ServerArtifactRef.Artifact) {
        self.artifact = artifact
        _player = State(initialValue: AVPlayer(url: artifact.url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    if isPlaying {
                        player.pause()
                        isPlaying = false
                    } else {
                        do {
                            try activateAudioPlaybackSession()
                            player.play()
                            playbackError = nil
                            isPlaying = true
                        } catch {
                            playbackError = "Audio playback failed."
                        }
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel(isPlaying ? "Pause generated audio" : "Play generated audio")

                Label(artifact.label, systemImage: "waveform")
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                ShareLink(item: artifact.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share generated audio")
            }
            if let playbackError {
                Text(playbackError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear {
            player.pause()
            isPlaying = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
            player.seek(to: .zero)
            isPlaying = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
            isPlaying = false
            playbackError = "Audio playback failed."
        }
    }

    private func activateAudioPlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try session.setActive(true)
    }
}

private struct GeneratedVideoView: View {
    let artifact: ServerArtifactRef.Artifact
    @State private var player: AVPlayer

    init(artifact: ServerArtifactRef.Artifact) {
        self.artifact = artifact
        _player = State(initialValue: AVPlayer(url: artifact.url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VideoPlayer(player: player)
                .frame(minHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Label(artifact.label, systemImage: "film")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                ShareLink(item: artifact.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share generated video")
            }
            .foregroundStyle(.secondary)
        }
        .onDisappear { player.pause() }
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
/// extracted base64 payloads, and ordinary `http(s)` images loaded to bytes.
struct PhantasmImageProvider: ImageProvider {
    /// Sentinel ordinal for a remote image: it has no place in the per-message
    /// base64 ordering, so a tap on it resolves to the solo-image fallback.
    static let remoteOrdinal = Int.min

    let images: [Int: Data]
    let trustedBase: URL?
    var onTap: (Int, UIImage) -> Void = { _, _ in }

    func makeImage(url: URL?) -> some View {
        Group {
            if let url, url.scheme == "phantasm-img",
               let index = Int(url.host ?? ""),
               let data = images[index],
               let uiImage = decodedUIImage(data) {
                InlineUIImage(image: uiImage)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(index, uiImage) }
                    .contextMenu { ImageActions(image: uiImage) }
            } else if let url, let trustedBase,
                      ServerImageRef.isTrustedContentURL(url, backendBase: trustedBase) {
                // Server-hosted / external images arrive as absolute URLs (spec
                // §2.2b). Load them to bytes (not `AsyncImage`) so a tap can hand
                // the decoded `UIImage` to the viewer; inline base64 is above.
                RemoteImage(url: url, trustedBase: trustedBase) { uiImage in
                    onTap(Self.remoteOrdinal, uiImage)
                }
            } else if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Link(destination: url) {
                    Label("External image — tap to open", systemImage: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                EmptyView()
            }
        }
    }
}

/// An inline `http(s)` image loaded to a `UIImage` (rather than `AsyncImage`) so
/// a tap can hand the decoded bytes to the full-screen viewer and save/share.
private struct RemoteImage: View {
    let url: URL
    let trustedBase: URL
    let onTap: (UIImage) -> Void
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                InlineUIImage(image: image)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(image) }
                    .contextMenu { ImageActions(image: image) }
            } else if loadFailed {
                // A ref that can't resolve (its blob is gone, or the URL is
                // unreachable) collapses to nothing rather than leaving a stuck
                // spinner above the surrounding content. The spinner is reserved
                // for an in-flight load that's actually expected to arrive.
                EmptyView()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        loadFailed = false
        if let loaded = await RemoteImageCache.shared.image(for: url, trustedBase: trustedBase) {
            image = loaded
        } else {
            loadFailed = true
        }
    }
}

/// Process-wide in-memory cache for fetched remote images, so re-rendering a
/// row while scrolling doesn't re-download. `NSCache` is thread-safe and evicts
/// under memory pressure.
private final class RemoteImageCache: @unchecked Sendable {
    static let shared = RemoteImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL, trustedBase: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        // Bound the wait: a stalled fetch should resolve to a failure (and
        // collapse the placeholder) rather than spin indefinitely.
        guard let cached = await ImageClient().fetch(url, trustedBase: trustedBase),
              let source = CGImageSourceCreateWithData(cached.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= 16_384, height.intValue <= 16_384,
              width.int64Value * height.int64Value <= 40_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return nil }
        guard let image = decodedUIImage(cached.data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// UIKit-backed rendering is required for animated GIF/WebP; SwiftUI's `Image`
/// displays only the first frame of an animated `UIImage`.
private struct InlineUIImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.image = image
        if image.images != nil { view.startAnimating() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        let width = proposal.width ?? image.size.width
        guard image.size.width > 0 else { return CGSize(width: width, height: width) }
        return CGSize(width: width, height: width * image.size.height / image.size.width)
    }
}

private func decodedUIImage(_ data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return UIImage(data: data)
    }
    let count = CGImageSourceGetCount(source)
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any]
    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    guard width > 0, height > 0, width <= 16_384, height <= 16_384,
          Int64(width) * Int64(height) <= 40_000_000 else { return nil }
    guard count > 1 else {
        guard let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: frame)
    }
    var frames: [UIImage] = []
    var duration = 0.0
    let area = max(1, width * height)
    let frameCap = max(1, min(600, 80_000_000 / area))
    for index in 0..<min(count, frameCap) {
        guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
        frames.append(UIImage(cgImage: frame))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            ?? 0.1
    }
    guard !frames.isEmpty else { return nil }
    return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
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
        ShareLink(
            item: Image(uiImage: image),
            preview: .init("Generated image", image: Image(uiImage: image))
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}
