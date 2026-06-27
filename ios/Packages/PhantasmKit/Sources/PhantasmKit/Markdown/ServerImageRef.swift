import Foundation

/// Helpers for the server-hosted image references the orchestrator embeds under
/// URL delivery (spec §2.2b): markdown links whose target is an absolute
/// `…/v1/files/<id>/content?exp=…&sig=…` URL. The `<id>` is the server's content
/// hash — used to clean the blob up (`DELETE /v1/files/<id>`) when its
/// conversation is deleted.
public enum ServerImageRef {
    private static let marker = "/v1/files/"

    /// Every distinct `<id>` referenced by `/v1/files/<id>/content` occurrences
    /// in `text`, in first-seen order. The id is the run of base64url characters
    /// after the marker (terminated by `/`, `?`, `)`, quote, whitespace, …),
    /// matching the server's own id charset.
    public static func ids(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var search = text.startIndex
        while let range = text.range(of: marker, range: search..<text.endIndex) {
            let tail = text[range.upperBound...]
            let id = tail.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if !id.isEmpty, seen.insert(String(id)).inserted {
                out.append(String(id))
            }
            search = range.upperBound
        }
        return out
    }

    /// Bytes + mime of a cached image, for inlining a reference back into markdown.
    public struct CachedImage: Sendable {
        public let data: Data
        public let mime: String
        public init(data: Data, mime: String) {
            self.data = data
            self.mime = mime
        }
    }

    /// Each server-image markdown link in `text` as its `(id, full url)`. The
    /// full URL (signature included) is what the client fetches while it's fresh.
    public static func references(in text: String) -> [(id: String, url: String)] {
        guard let regex = linkRegex else { return [] }
        let ns = text as NSString
        return regex
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { (ns.substring(with: $0.range(at: 2)), ns.substring(with: $0.range(at: 1))) }
    }

    /// Rewrite every server-image link whose id is in `cache` to an inline
    /// `data:` URI, so it renders from local bytes — offline and after the signed
    /// URL expires. Uncached links are left untouched (they still load over the
    /// network while their URL is valid).
    public static func inlineCached(_ text: String, cache: [String: CachedImage]) -> String {
        guard !cache.isEmpty else { return text }
        var result = text
        for ref in references(in: text) {
            guard let img = cache[ref.id] else { continue }
            let uri = "data:\(img.mime);base64,\(img.data.base64EncodedString())"
            result = result.replacingOccurrences(of: ref.url, with: uri)
        }
        return result
    }

    /// Matches a markdown link target `](<url>)` whose URL is a
    /// `/v1/files/<id>/content` reference. Group 1 = full URL, group 2 = id.
    private static let linkRegex = try? NSRegularExpression(
        pattern: #"\]\(([^)\s]*?/v1/files/([A-Za-z0-9_-]+)/content[^)\s]*)\)"#
    )
}
