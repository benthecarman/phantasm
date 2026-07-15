import ImageIO
import UIKit

/// CPU-heavy image work shared by composer preparation, transcript thumbnails,
/// and the full-screen viewer. Every public async entry point performs its
/// decode/draw/encode work on a detached worker so SwiftUI never does it while
/// evaluating or updating a view.
enum ImageProcessing {
    struct PreparedJPEG: @unchecked Sendable {
        let data: Data
        let preview: UIImage
    }

    private struct SendableImage: @unchecked Sendable {
        let value: UIImage
    }

    private struct SourceInfo {
        let source: CGImageSource
        let width: Int
        let height: Int
    }

    private static let maxSourceDimension = 16_384
    private static let maxSourcePixels: Int64 = 40_000_000

    static func thumbnail(data: Data, maxPixelSize: Int) async -> UIImage? {
        let image = await Task.detached(priority: .utility) {
            autoreleasepool {
                thumbnailSynchronously(data: data, maxPixelSize: maxPixelSize)
                    .map(SendableImage.init)
            }
        }.value
        return image?.value
    }

    /// Decodes all retained pixels (and bounded animation frames) only for the
    /// full-screen viewer. Immediate caching forces decompression on the worker
    /// instead of deferring it to the next main-thread draw.
    static func fullResolutionImage(data: Data) async -> UIImage? {
        let image = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                fullResolutionImageSynchronously(data: data).map(SendableImage.init)
            }
        }.value
        return image?.value
    }

    static func prepareJPEG(
        data: Data,
        maxPixelSize: Int,
        quality: CGFloat
    ) async -> PreparedJPEG? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                guard let image = thumbnailSynchronously(data: data, maxPixelSize: maxPixelSize),
                      let jpeg = image.jpegData(compressionQuality: quality) else { return nil }
                return PreparedJPEG(data: jpeg, preview: image)
            }
        }.value
    }

    static func prepareJPEG(
        image: UIImage,
        maxPixelSize: Int,
        quality: CGFloat
    ) async -> PreparedJPEG? {
        let input = SendableImage(value: image)
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let original = input.value
                // `UIImage.size` follows its display orientation, unlike raw
                // `CGImage` dimensions. Scaling that oriented size avoids
                // stretching portrait camera captures whose pixels are stored
                // landscape with an orientation tag.
                let width = Int((original.size.width * original.scale).rounded())
                let height = Int((original.size.height * original.scale).rounded())
                guard width > 0, height > 0 else { return nil }

                let longest = max(width, height)
                let ratio = min(1, CGFloat(maxPixelSize) / CGFloat(longest))
                let target = CGSize(
                    width: max(1, (CGFloat(width) * ratio).rounded()),
                    height: max(1, (CGFloat(height) * ratio).rounded())
                )
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = 1
                let prepared = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                    original.draw(in: CGRect(origin: .zero, size: target))
                }
                guard let jpeg = prepared.jpegData(compressionQuality: quality) else { return nil }
                return PreparedJPEG(data: jpeg, preview: prepared)
            }
        }.value
    }

    /// Approximate retained bitmap bytes for `NSCache` accounting. Animated
    /// images include every decoded frame rather than their much smaller
    /// encoded payload size.
    static func decodedByteCost(_ image: UIImage) -> Int {
        let frames = image.images ?? [image]
        return frames.reduce(into: 0) { total, frame in
            let bytes: Int
            if let cgImage = frame.cgImage {
                bytes = cgImage.bytesPerRow * cgImage.height
            } else {
                let pixels = frame.size.width * frame.scale * frame.size.height * frame.scale
                if !pixels.isFinite || pixels >= CGFloat(Int.max / 4) {
                    bytes = Int.max
                } else {
                    bytes = Int(pixels) * 4
                }
            }
            total = total > Int.max - bytes ? Int.max : total + bytes
        }
    }

    private static func thumbnailSynchronously(data: Data, maxPixelSize: Int) -> UIImage? {
        guard maxPixelSize > 0, let info = sourceInfo(data) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            info.source, 0, options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func fullResolutionImageSynchronously(data: Data) -> UIImage? {
        guard let info = sourceInfo(data) else { return nil }
        let count = CGImageSourceGetCount(info.source)
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard count > 1 else {
            guard let frame = CGImageSourceCreateImageAtIndex(info.source, 0, options) else {
                return nil
            }
            return UIImage(cgImage: frame)
        }

        var frames: [UIImage] = []
        var duration = 0.0
        let area = max(1, info.width * info.height)
        let frameCap = max(1, min(600, 80_000_000 / area))
        for index in 0..<min(count, frameCap) {
            guard let frame = CGImageSourceCreateImageAtIndex(info.source, index, options) else {
                continue
            }
            frames.append(UIImage(cgImage: frame))
            let properties = CGImageSourceCopyPropertiesAtIndex(info.source, index, nil)
                as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
                ?? 0.1
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private static func sourceInfo(_ data: Data) -> SourceInfo? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maxSourceDimension, height <= maxSourceDimension,
              Int64(width) * Int64(height) <= maxSourcePixels
        else { return nil }
        return SourceInfo(source: source, width: width, height: height)
    }
}

/// Process-wide thumbnail cache keyed by the stable persisted attachment ID.
/// Its cost limit is expressed in decoded bitmap bytes, not compressed JPEG
/// bytes, so memory pressure reflects what UIKit actually retains.
final class AttachmentThumbnailCache: @unchecked Sendable {
    static let shared = AttachmentThumbnailCache()
    static let maxPixelSize = 360
    private static let maxEntryCost = 8 * 1024 * 1024

    private let cache: NSCache<NSUUID, UIImage>

    init(totalCostLimit: Int = 48 * 1024 * 1024, countLimit: Int = 128) {
        cache = NSCache<NSUUID, UIImage>()
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
    }

    func image(for id: UUID, data: Data) async -> UIImage? {
        let key = id as NSUUID
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = await ImageProcessing.thumbnail(
            data: data, maxPixelSize: Self.maxPixelSize
        ) else { return nil }
        let cost = ImageProcessing.decodedByteCost(image)
        if cost <= Self.maxEntryCost {
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}
