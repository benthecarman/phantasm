import Foundation

/// Signed, server-hosted non-image artifacts embedded as ordinary Markdown
/// links. The first dynamic-workflow release emits video links using the stable
/// `Video: <filename>` label; standard clients still see a normal usable link.
public enum ServerArtifactRef {
    public struct Artifact: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let url: URL

        public init(id: String, label: String, url: URL) {
            self.id = id
            self.label = label
            self.url = url
        }
    }

    public struct Extraction: Equatable, Sendable {
        public let markdown: String
        public let artifacts: [Artifact]

        public init(markdown: String, artifacts: [Artifact]) {
            self.markdown = markdown
            self.artifacts = artifacts
        }
    }

    /// Remove trusted Phantasm video links from Markdown and return them as
    /// structured artifacts for native playback. Untrusted/lookalike links stay
    /// in Markdown and require the user's normal explicit link tap.
    public static func extractTrusted(in text: String, backendBase: URL?) -> Extraction {
        guard let regex else { return .init(markdown: text, artifacts: []) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var output = text
        var artifacts: [Artifact] = []
        for match in matches.reversed() {
            let label = ns.substring(with: match.range(at: 1))
            let target = ns.substring(with: match.range(at: 2))
            let id = ns.substring(with: match.range(at: 3))
            guard let url = URL(string: target),
                  ServerImageRef.isTrustedContentURL(url, backendBase: backendBase)
            else { continue }
            artifacts.insert(.init(id: id, label: label, url: url), at: 0)
            if let range = Range(match.range, in: output) {
                output.removeSubrange(range)
            }
        }
        return .init(
            markdown: output.trimmingCharacters(in: .whitespacesAndNewlines),
            artifacts: artifacts
        )
    }

    private static let regex = try? NSRegularExpression(
        pattern: #"\[Video:\s*([^\]]+)\]\((https?://[^)\s]*/v1/files/([A-Za-z0-9_-]+)/content[^)\s]*)\)"#,
        options: [.caseInsensitive]
    )
}
