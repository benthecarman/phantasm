import Foundation

/// Turns assistant markdown into clean prose for text-to-speech.
///
/// Assistant messages are markdown and may embed generated images as base64
/// `data:` URIs (FR-A7). Reading any of that aloud — URLs, base64 blobs, `**`,
/// `#`, code — sounds like noise, so we strip markup down to the words a person
/// would actually say. Image links (data-URI, `phantasm-img://`, and http) are
/// dropped entirely; fenced code blocks collapse to a short spoken marker.
public enum SpeakableText {
    /// Plain, speakable prose extracted from a markdown message.
    public static func plainText(from markdown: String) -> String {
        // Collapse multi-MB base64 data-URIs to short placeholders first (reuses
        // the image extractor's memoized regex) so the cleanup passes below never
        // run over giant strings.
        var text = Base64ImageExtractor().extractCached(markdown).markdown

        text = replace(text, R.codeFenceBacktick, with: " code block. ")
        text = replace(text, R.codeFenceTilde, with: " code block. ")
        // Image links — drop entirely (covers data:, phantasm-img:// and http).
        text = replace(text, R.imageLink, with: " ")
        // Inline links `[text](url)` -> just the link text.
        text = replace(text, R.inlineLink, with: "$1")

        let cleanedLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(cleanLine)
        text = cleanedLines.joined(separator: "\n")

        // Strip remaining inline emphasis / code markers.
        for token in ["**", "__", "~~", "`", "*", "_"] {
            text = text.replacingOccurrences(of: token, with: "")
        }

        // Collapse runs of blank lines and stray whitespace into tidy spacing.
        text = replace(text, R.spaces, with: " ")
        text = replace(text, R.blankLines, with: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes leading block markers (headings, quotes, list bullets, rules) from
    /// a single line.
    private static func cleanLine(_ line: Substring) -> String {
        var s = String(line).trimmingCharacters(in: .whitespaces)
        if R.horizontalRule.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            return "" // horizontal rule
        }
        s = replace(s, R.heading, with: "") // ATX headings
        s = replace(s, R.blockquote, with: "") // blockquote
        s = replace(s, R.bullet, with: "") // unordered list bullet
        s = replace(s, R.orderedItem, with: "") // ordered list marker
        return s
    }

    private static func replace(_ input: String, _ regex: NSRegularExpression, with template: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }

    /// Patterns are fixed literals, so compile them once and reuse across calls
    /// (matching `Base64ImageExtractor`'s cached-regex approach) rather than
    /// recompiling ~10 of them on every message.
    private enum R {
        static let codeFenceBacktick = regex(#"(?s)```.*?```"#)
        static let codeFenceTilde = regex(#"(?s)~~~.*?~~~"#)
        static let imageLink = regex(#"!\[[^\]]*\]\([^)]*\)"#)
        static let inlineLink = regex(#"\[([^\]]*)\]\([^)]*\)"#)
        static let horizontalRule = regex(#"^(-{3,}|\*{3,}|_{3,})$"#)
        static let heading = regex(#"^#{1,6}\s+"#)
        static let blockquote = regex(#"^>\s?"#)
        static let bullet = regex(#"^[-*+]\s+"#)
        static let orderedItem = regex(#"^\d+\.\s+"#)
        static let spaces = regex(#"[ \t]+"#)
        static let blankLines = regex(#"\n{2,}"#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            // Patterns are compile-time constants; a failure is a programmer error.
            try! NSRegularExpression(pattern: pattern)
        }
    }
}
