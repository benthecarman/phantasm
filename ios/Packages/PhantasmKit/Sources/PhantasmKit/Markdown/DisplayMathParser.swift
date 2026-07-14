import Foundation

public enum MarkdownDisplayBlock: Equatable, Sendable {
    case markdown(String)
    case math(String)
}

/// Splits `$$…$$` display math from ordinary markdown while leaving code spans,
/// fenced code blocks, escaped delimiters, and unmatched input untouched.
public enum DisplayMathParser {
    public static func blocks(in source: String) -> [MarkdownDisplayBlock] {
        guard source.contains("$$") else { return source.isEmpty ? [] : [.markdown(source)] }

        var blocks: [MarkdownDisplayBlock] = []
        var markdownStart = source.startIndex
        var cursor = source.startIndex
        var lineStart = source.startIndex
        var mathStart: String.Index?
        var mathOpening: String.Index?
        var inlineCodeTicks: Int?
        var fence: (marker: Character, length: Int)?

        while cursor < source.endIndex {
            if let expressionStart = mathStart,
               let afterDelimiter = displayDelimiterEnd(at: cursor, in: source) {
                let expression = source[expressionStart..<cursor]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !expression.isEmpty, let mathOpening {
                    appendMarkdown(source[markdownStart..<mathOpening], to: &blocks)
                    blocks.append(.math(expression))
                    markdownStart = afterDelimiter
                }
                cursor = afterDelimiter
                mathStart = nil
                mathOpening = nil
                continue
            }

            if mathStart != nil {
                cursor = source.index(after: cursor)
                continue
            }

            if cursor == lineStart, inlineCodeTicks == nil,
               let marker = fenceMarker(at: cursor, in: source) {
                if let active = fence {
                    if marker.marker == active.marker, marker.length >= active.length {
                        fence = nil
                    }
                } else {
                    fence = marker
                }
                cursor = indexAfterLine(startingAt: cursor, in: source)
                lineStart = cursor
                continue
            }

            if fence != nil {
                cursor = indexAfterLine(startingAt: cursor, in: source)
                lineStart = cursor
                continue
            }

            let character = source[cursor]
            if character == "`" {
                let run = repeatedCount(of: "`", at: cursor, in: source)
                if inlineCodeTicks == nil {
                    inlineCodeTicks = run
                } else if inlineCodeTicks == run {
                    inlineCodeTicks = nil
                }
                cursor = source.index(cursor, offsetBy: run)
                continue
            }

            if inlineCodeTicks == nil,
               !isEscaped(cursor, in: source),
               let afterDelimiter = displayDelimiterEnd(at: cursor, in: source) {
                mathOpening = cursor
                mathStart = afterDelimiter
                cursor = afterDelimiter
                continue
            }

            if character == "\n" || character == "\r" {
                cursor = source.index(after: cursor)
                lineStart = cursor
            } else {
                cursor = source.index(after: cursor)
            }
        }

        appendMarkdown(source[markdownStart..<source.endIndex], to: &blocks)
        return blocks
    }

    private static func displayDelimiterEnd(
        at index: String.Index,
        in source: String
    ) -> String.Index? {
        guard source[index] == "$" else { return nil }
        let next = source.index(after: index)
        guard next < source.endIndex, source[next] == "$", !isEscaped(index, in: source) else {
            return nil
        }
        return source.index(after: next)
    }

    private static func appendMarkdown(
        _ slice: Substring,
        to blocks: inout [MarkdownDisplayBlock]
    ) {
        guard !slice.isEmpty else { return }
        blocks.append(.markdown(String(slice)))
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index
        var backslashes = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            backslashes += 1
            cursor = previous
        }
        return backslashes.isMultiple(of: 2) == false
    }

    private static func fenceMarker(
        at lineStart: String.Index,
        in source: String
    ) -> (marker: Character, length: Int)? {
        var cursor = lineStart
        var spaces = 0
        while cursor < source.endIndex, source[cursor] == " ", spaces < 4 {
            spaces += 1
            cursor = source.index(after: cursor)
        }
        guard spaces <= 3, cursor < source.endIndex,
              source[cursor] == "`" || source[cursor] == "~" else { return nil }
        let marker = source[cursor]
        let length = repeatedCount(of: marker, at: cursor, in: source)
        return length >= 3 ? (marker, length) : nil
    }

    private static func repeatedCount(
        of character: Character,
        at index: String.Index,
        in source: String
    ) -> Int {
        var count = 0
        var cursor = index
        while cursor < source.endIndex, source[cursor] == character {
            count += 1
            cursor = source.index(after: cursor)
        }
        return count
    }

    private static func indexAfterLine(
        startingAt index: String.Index,
        in source: String
    ) -> String.Index {
        var cursor = index
        while cursor < source.endIndex {
            let character = source[cursor]
            cursor = source.index(after: cursor)
            if character == "\n" || character == "\r" { break }
        }
        return cursor
    }
}
