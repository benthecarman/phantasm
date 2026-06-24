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
            if let data = Data(base64Encoded: payload) {
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
