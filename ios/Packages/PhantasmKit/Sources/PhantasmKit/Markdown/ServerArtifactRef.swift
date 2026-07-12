import Foundation

/// Signed, server-hosted media embedded as ordinary Markdown links. Standard
/// clients see usable `Video:` / `Audio:` links; Phantasm renders them natively.
public enum ServerArtifactRef {
    public enum Kind: String, Equatable, Sendable {
        case video
        case audio
    }

    public struct Artifact: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let url: URL
        public let kind: Kind

        public init(id: String, label: String, url: URL, kind: Kind) {
            self.id = id
            self.label = label
            self.url = url
            self.kind = kind
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

    /// Remove trusted Phantasm media links from Markdown and return them as
    /// structured artifacts for native playback. Untrusted/lookalike links stay
    /// in Markdown and require the user's normal explicit link tap.
    public static func extractTrusted(in text: String, backendBase: URL?) -> Extraction {
        guard let regex else { return .init(markdown: text, artifacts: []) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var output = text
        var artifacts: [Artifact] = []
        for match in matches.reversed() {
            let kindText = ns.substring(with: match.range(at: 1)).lowercased()
            let label = ns.substring(with: match.range(at: 2))
            let target = ns.substring(with: match.range(at: 3))
            let id = ns.substring(with: match.range(at: 4))
            guard let url = resolvedContentURL(target, backendBase: backendBase),
                  let kind = Kind(rawValue: kindText),
                  ServerImageRef.isTrustedContentURL(url, backendBase: backendBase)
            else { continue }
            artifacts.insert(.init(id: id, label: label, url: url, kind: kind), at: 0)
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
        pattern: #"\[(Video|Audio):\s*([^\]]+)\]\(((?:https?://[^)\s]*|)/v1/files/([A-Za-z0-9_-]+)/content[^)\s]*)\)"#,
        options: [.caseInsensitive]
    )

    private static func resolvedContentURL(_ target: String, backendBase: URL?) -> URL? {
        if target.hasPrefix("/") {
            guard let backendBase else { return nil }
            return URL(string: target, relativeTo: backendBase)?.absoluteURL
        }
        return URL(string: target)
    }
}
