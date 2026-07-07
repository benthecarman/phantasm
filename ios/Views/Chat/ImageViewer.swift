import PhantasmKit
import SwiftUI
import UIKit

/// One image in the conversation-wide gallery. `id` is stable across rebuilds
/// (`"<messageID>:<ordinal>"`) so a tap can resolve to its position in the
/// gallery. Carries encoded bytes where possible so a long, image-heavy chat
/// doesn't decode every image the moment the viewer opens; pages decode on
/// demand via `load()`.
struct GalleryImage: Identifiable, Equatable {
    enum Source {
        case encoded(Data)
        case decoded(UIImage)
    }

    let id: String
    let source: Source

    init(id: String, data: Data) {
        self.id = id
        self.source = .encoded(data)
    }

    init(id: String, image: UIImage) {
        self.id = id
        self.source = .decoded(image)
    }

    func load() -> UIImage? {
        switch source {
        case .encoded(let data): return UIImage(data: data)
        case .decoded(let image): return image
        }
    }

    static func == (lhs: GalleryImage, rhs: GalleryImage) -> Bool { lhs.id == rhs.id }
}

/// Builds the ordered list of every renderable image in a conversation, in
/// visual (top-to-bottom, in-message) order. User attachments and assistant
/// inline/cached images are gathered with the same ordinals the renderers use,
/// so a tapped image maps to its gallery position by id.
enum ConversationImages {
    static func gallery(from messages: [ChatMessage]) -> [GalleryImage] {
        var out: [GalleryImage] = []
        for cm in messages {
            let m = cm.message
            if m.role == "user" {
                let images = cm.attachments.filter { $0.kind == AttachmentKind.image.rawValue }
                for (i, att) in images.enumerated() {
                    out.append(GalleryImage(id: "\(m.id):\(i)", data: att.data))
                }
            } else {
                // Mirror MessageBubble/MarkdownMessageView: restore extracted
                // inline images, inline cached server images, then pull every
                // base64 payload in appearance order.
                var cache: [String: ServerImageRef.CachedImage] = [:]
                for a in cm.attachments where a.kind == AttachmentKind.remoteImage.rawValue {
                    cache[a.name] = ServerImageRef.CachedImage(data: a.data, mime: a.mimeType)
                }
                let restored = InlineImageRef.restore(m.content, images: cm.inlineImages)
                let resolved = ServerImageRef.inlineCached(restored, cache: cache)
                let extracted = Base64ImageExtractor().extractCached(resolved)
                for index in extracted.images.keys.sorted() {
                    if let data = extracted.images[index] {
                        out.append(GalleryImage(id: "\(m.id):\(index)", data: data))
                    }
                }
            }
        }
        return out
    }
}

/// The full-screen viewer presentation: the gallery and which image to open on.
struct ImageViewerPresentation: Identifiable {
    let id = UUID()
    let images: [GalleryImage]
    let startID: String
}

/// Full-screen, swipe-between-images viewer (Photos-style): paged horizontally
/// across every image in the conversation, each pinch/double-tap zoomable.
struct ImageViewerView: View {
    let images: [GalleryImage]
    @State private var selection: String
    @Environment(\.dismiss) private var dismiss

    init(images: [GalleryImage], startID: String) {
        self.images = images
        _selection = State(initialValue: startID)
    }

    private var current: UIImage? {
        images.first { $0.id == selection }?.load()
    }

    private var selectedIndex: Int? {
        images.firstIndex { $0.id == selection }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                // Paged TabViews materialize every child up front, so each page
                // defers its decode until it (or a neighbor) is selected — a
                // long, image-heavy chat must not decode everything on open.
                ForEach(Array(images.enumerated()), id: \.element.id) { index, item in
                    GalleryPage(
                        item: item,
                        isActive: selectedIndex.map { abs(index - $0) <= 1 } ?? false
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .ignoresSafeArea()

            HStack {
                closeButton
                Spacer()
                if let current { ImageActionsMenu(image: current) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .statusBarHidden()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.4), in: Circle())
        }
        .accessibilityLabel("Close")
    }
}

/// One gallery page: decodes its image when it first becomes the selection (or
/// its neighbor), not when the viewer opens.
private struct GalleryPage: View {
    let item: GalleryImage
    let isActive: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
                    .ignoresSafeArea()
            } else {
                Color.clear
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            guard active, image == nil else { return }
            image = item.load()
        }
    }
}

/// Save / share actions for the image on screen (FR-A7), styled for the dark viewer.
private struct ImageActionsMenu: View {
    let image: UIImage

    var body: some View {
        Menu {
            Button {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                Haptics.notify(.success)
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
            ShareLink(item: Image(uiImage: image), preview: .init("Image", image: Image(uiImage: image))) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.4), in: Circle())
        }
        .accessibilityLabel("Image actions")
    }
}

/// A `UIScrollView`-backed zoom/pan container for one image, giving the native
/// pinch-to-zoom, double-tap-to-zoom and pan that the SwiftUI primitives lack.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView(image: image)
    }

    func updateUIView(_ uiView: ZoomableImageScrollView, context: Context) {}
}

/// Lays its `UIImageView` out edge-to-edge and keeps it centred while zoomed.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    init(image: UIImage) {
        super.init(frame: .zero)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }
        centerContent()
    }

    /// Pin the content to centre when it's smaller than the viewport (i.e. while
    /// unzoomed, and along whichever axis stays smaller than the screen).
    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let target: CGFloat = 3
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }
}
