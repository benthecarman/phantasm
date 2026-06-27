import Foundation

/// Helpers for the server-hosted image references the orchestrator embeds when
/// the client opts into URL delivery (spec §2.2b): markdown links whose target
/// is `/v1/images/<id>?exp=…&sig=…` (relative) or an absolute URL with that
/// path. The `<id>` is the server's content hash — used to clean the blob up
/// (`DELETE /v1/images/<id>`) when its conversation is deleted.
public enum ServerImageRef {
    private static let marker = "/v1/images/"

    /// Every distinct `<id>` referenced by `/v1/images/<id>` occurrences in
    /// `text`, in first-seen order. The id is the run of base64url characters
    /// after the marker (terminated by `?`, `)`, `/`, quote, whitespace, …),
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
}
