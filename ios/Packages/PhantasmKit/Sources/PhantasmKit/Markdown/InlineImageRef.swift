import Foundation

/// Persist-time extraction of inline base64 images from message content.
///
/// The orchestrator's default delivery embeds generated images as
/// `![alt](data:image/…;base64,…)` markdown (spec §2.2b). Storing that raw
/// would put megabytes of base64 in the hottest table and everything that
/// touches it (FTS, embeddings, list reads). So the store extracts each
/// payload into an `.inlineImage` attachment row and leaves a compact
/// `phantasm-file://<id>` link in the content; `restore` re-inlines the data
/// URI wherever the original markdown is needed (the wire, the renderer).
/// Round-trip is byte-exact: the model re-sees precisely what it produced.
///
/// The `phantasm-file://` scheme string is part of the persisted content
/// format — links using it live in message rows, so renaming it requires a
/// data migration, not just a code change.
public enum InlineImageRef {
    public struct ExtractedImage: Sendable, Equatable {
        /// Generated id — becomes the attachment's `name` and the link target.
        public let name: String
        /// Full MIME type, e.g. `image/png`.
        public let mime: String
        public let data: Data
    }

    public struct Extraction: Sendable {
        /// Content with each data URI replaced by `phantasm-file://<name>`.
        public let text: String
        public let images: [ExtractedImage]
    }

    /// Pull every decodable `data:image/…` markdown image out of `text`.
    /// An undecodable payload is dropped to a `*(image)*` marker (same
    /// behavior as the renderer's extractor) rather than kept.
    public static func extract(_ text: String) -> Extraction {
        guard text.contains("](data:image/"), let regex = dataURIRegex else {
            return Extraction(text: text, images: [])
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return Extraction(text: text, images: []) }

        var images: [ExtractedImage] = []
        var output = ""
        var cursor = 0
        for match in matches {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let alt = ns.substring(with: match.range(at: 1))
            let type = ns.substring(with: match.range(at: 2))
            let payload = ns.substring(with: match.range(at: 3))
            if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
                let name = UUID().uuidString
                images.append(ExtractedImage(name: name, mime: "image/\(type)", data: data))
                output += "![\(alt)](phantasm-file://\(name))"
            } else {
                output += "*(image)*"
            }
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return Extraction(text: output, images: images)
    }

    /// Rewrite every `phantasm-file://<name>` link whose name is in `images`
    /// back to its inline `data:` URI. Names not in `images` are left as-is
    /// (their attachment row is gone; the renderer collapses the dead link).
    public static func restore(_ text: String, images: [String: ServerImageRef.CachedImage]) -> String {
        guard !images.isEmpty, text.contains("phantasm-file://") else { return text }
        // Memoized like `ServerImageRef.inlineCached`: committed rows re-render
        // per layout/scroll pass, and re-encoding bytes to base64 each time is
        // main-thread work proportional to the image sizes.
        let key = (text + "|" + images.keys.sorted().joined(separator: ",")) as NSString
        if let hit = memo.object(forKey: key) { return hit as String }
        var result = text
        for (name, image) in images {
            result = result.replacingOccurrences(
                of: "phantasm-file://\(name)",
                with: "data:\(image.mime);base64,\(image.data.base64EncodedString())"
            )
        }
        memo.setObject(result as NSString, forKey: key, cost: result.utf8.count)
        return result
    }

    /// Process-wide memo for `restore`, byte-budgeted (restored strings embed
    /// full base64 payloads) and evicted under memory pressure.
    private static let memo: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 64
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Matches `![alt](data:image/<type>;base64,<payload>)`.
    /// Groups: 1 = alt text, 2 = image subtype, 3 = base64 payload.
    private static let dataURIRegex = try? NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(data:image/([a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=\s]+)\)"#
    )
}
