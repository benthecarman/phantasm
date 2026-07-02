import Foundation

/// Extracts inline base64 data-URI images from assistant markdown (FR-A7).
///
/// Markdown renderers generally won't load `data:` image URLs, and huge base64
/// blobs inside the markdown string slow incremental re-rendering. So we replace
/// each `data:image/...;base64,...` link target with a short placeholder URL
/// (`phantasm-img://<n>`) and hand back the decoded payloads separately for the
/// image provider to resolve. HTTP(S) image links are left untouched.
public struct Base64ImageExtractor: Sendable {
    public struct Result: Sendable {
        /// Markdown with data-URIs replaced by `phantasm-img://<n>` placeholders.
        public let markdown: String
        /// Decoded image bytes keyed by placeholder index.
        public let images: [Int: Data]
    }

    public init() {}

    /// Memoized `extract`. Committed messages re-render on every layout/scroll
    /// pass with stable content, so caching by content avoids re-running the
    /// regex and re-decoding (potentially multi-MB) base64 on the main thread.
    public func extractCached(_ markdown: String) -> Result {
        ExtractionCache.shared.result(for: markdown, extractor: self)
    }

    public func extract(_ markdown: String) -> Result {
        guard let regex = Self.dataURIImageRegex else {
            return Result(markdown: markdown, images: [:])
        }

        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return Result(markdown: markdown, images: [:])
        }

        var images: [Int: Data] = [:]
        var output = ""
        var cursor = 0
        var index = 0

        for match in matches {
            // group 1 = base64 payload of the data: URI
            let full = match.range
            let payloadRange = match.range(at: 1)
            guard payloadRange.location != NSNotFound else { continue }

            output += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))

            let payload = ns.substring(with: payloadRange)
            // The pattern admits whitespace (wrapped base64), which the strict
            // decoder rejects; ignore it so wrapped payloads still decode.
            if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
                images[index] = data
                output += "![generated](phantasm-img://\(index))"
                index += 1
            } else {
                // Couldn't decode — drop the broken image link gracefully.
                output += "*(image)*"
            }
            cursor = full.location + full.length
        }
        output += ns.substring(from: cursor)

        return Result(markdown: output, images: images)
    }

    /// Matches `![alt](data:image/<type>;base64,<payload>)`, capturing payload.
    private static let dataURIImageRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(data:image/[a-zA-Z0-9.+-]+;base64,([A-Za-z0-9+/=\s]+)\)"#,
        options: []
    )
}

/// Process-wide LRU memoization for `Base64ImageExtractor.extract`, keyed by the
/// exact markdown string. Cost is the decoded image byte total so the cache
/// evicts on memory pressure / a byte budget rather than growing unbounded.
private final class ExtractionCache: @unchecked Sendable {
    static let shared = ExtractionCache()

    private final class Box {
        let result: Base64ImageExtractor.Result
        init(_ result: Base64ImageExtractor.Result) { self.result = result }
    }

    private let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 128
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    func result(for markdown: String, extractor: Base64ImageExtractor) -> Base64ImageExtractor.Result {
        let key = markdown as NSString
        if let hit = cache.object(forKey: key) { return hit.result }
        let result = extractor.extract(markdown)
        // Count the stored markdown too: a no-image entry keeps a full copy of
        // the (possibly large) string, which used to cost 0 and sit outside the
        // byte budget.
        let cost = result.images.values.reduce(result.markdown.utf8.count) { $0 + $1.count }
        cache.setObject(Box(result), forKey: key, cost: cost)
        return result
    }
}
