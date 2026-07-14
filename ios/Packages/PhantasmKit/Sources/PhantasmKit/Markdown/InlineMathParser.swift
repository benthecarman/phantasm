import Foundation

public struct PreparedInlineMath: Equatable, Sendable {
    public let markdown: String
    public let expressions: [Int: String]

    public init(markdown: String, expressions: [Int: String]) {
        self.markdown = markdown
        self.expressions = expressions
    }
}

/// Replaces `$…$` math with inline-image placeholders that MarkdownUI can lay
/// out with surrounding text. Code, escaped dollars, currency-like unmatched
/// input, and display-math delimiters remain untouched.
public enum InlineMathParser {
    private static let placeholderScheme = "phantasm-math"
    private static let emphasisBoundary = "\u{200B}"

    public static func prepare(_ source: String) -> PreparedInlineMath {
        guard source.contains("$") else {
            return PreparedInlineMath(markdown: source, expressions: [:])
        }

        var markdown = ""
        var expressions: [Int: String] = [:]
        var cursor = source.startIndex
        var lineStart = source.startIndex
        var inlineCodeTicks: Int?
        var fence: (marker: Character, length: Int)?
        var emphasis: [String] = []

        while cursor < source.endIndex {
            if cursor == lineStart, inlineCodeTicks == nil,
               let marker = fenceMarker(at: cursor, in: source) {
                if let active = fence {
                    if marker.marker == active.marker, marker.length >= active.length {
                        fence = nil
                    }
                } else {
                    fence = marker
                }
                let afterLine = indexAfterLine(startingAt: cursor, in: source)
                markdown.append(contentsOf: source[cursor..<afterLine])
                cursor = afterLine
                lineStart = cursor
                continue
            }

            if fence != nil {
                let afterLine = indexAfterLine(startingAt: cursor, in: source)
                markdown.append(contentsOf: source[cursor..<afterLine])
                cursor = afterLine
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
                let afterRun = source.index(cursor, offsetBy: run)
                markdown.append(contentsOf: source[cursor..<afterRun])
                cursor = afterRun
                continue
            }

            if inlineCodeTicks == nil, character == "$" {
                let run = repeatedCount(of: "$", at: cursor, in: source)
                if run >= 2 {
                    let afterRun = source.index(cursor, offsetBy: run)
                    markdown.append(contentsOf: source[cursor..<afterRun])
                    cursor = afterRun
                    continue
                }
            }

            if inlineCodeTicks == nil,
               let afterOpening = inlineOpeningEnd(at: cursor, in: source),
               let closing = inlineClosingDollar(after: afterOpening, in: source) {
                let rawExpression = source[afterOpening..<closing]
                let expression = String(rawExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let looksLikeCurrency = source[afterOpening].isNumber
                    && rawExpression.contains(where: \.isWhitespace)
                if !expression.isEmpty, !looksLikeCurrency {
                    let index = expressions.count
                    expressions[index] = expression
                    appendPlaceholder(index, emphasis: emphasis, to: &markdown)
                    cursor = source.index(after: closing)
                    continue
                }
            }

            if inlineCodeTicks == nil,
               !isEscaped(cursor, in: source),
               let delimiter = emphasisDelimiter(at: cursor, in: source) {
                updateEmphasis(
                    &emphasis,
                    delimiter: delimiter.text,
                    marker: delimiter.marker,
                    previous: sourceCharacter(before: cursor, in: source),
                    next: sourceCharacter(at: delimiter.end, in: source)
                )
                markdown.append(contentsOf: source[cursor..<delimiter.end])
                cursor = delimiter.end
                continue
            }

            markdown.append(character)
            cursor = source.index(after: cursor)
            if character == "\n" || character == "\r" {
                lineStart = cursor
            }
        }

        return PreparedInlineMath(markdown: markdown, expressions: expressions)
    }

    private static func appendPlaceholder(
        _ index: Int,
        emphasis: [String],
        to markdown: inout String
    ) {
        if !emphasis.isEmpty {
            markdown.append(emphasisBoundary)
            for delimiter in emphasis.reversed() {
                markdown.append(delimiter)
            }
        } else {
            markdown.append(emphasisBoundary)
        }

        markdown.append("![Equation](\(placeholderScheme)://\(index))")

        if !emphasis.isEmpty {
            for delimiter in emphasis {
                markdown.append(delimiter)
            }
            markdown.append(emphasisBoundary)
        } else {
            markdown.append(emphasisBoundary)
        }
    }

    private static func inlineOpeningEnd(
        at index: String.Index,
        in source: String
    ) -> String.Index? {
        guard source[index] == "$", !isEscaped(index, in: source) else { return nil }
        let next = source.index(after: index)
        guard next < source.endIndex, source[next] != "$", !source[next].isWhitespace else {
            return nil
        }
        return next
    }

    private static func inlineClosingDollar(
        after expressionStart: String.Index,
        in source: String
    ) -> String.Index? {
        var cursor = expressionStart
        while cursor < source.endIndex {
            let value = source[cursor]
            if value == "\n" || value == "\r" { return nil }
            if value == "`" { return nil }
            if value == "$", !isEscaped(cursor, in: source) {
                let next = source.index(after: cursor)
                let previous = source.index(before: cursor)
                let isSingleDollar = source[previous] != "$"
                    && (next == source.endIndex || source[next] != "$")
                let isAfterContent = !source[previous].isWhitespace
                let isBeforeDigit = next < source.endIndex && source[next].isNumber
                if isSingleDollar, isAfterContent, !isBeforeDigit {
                    return cursor
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func emphasisDelimiter(
        at index: String.Index,
        in source: String
    ) -> (text: String, marker: Character, end: String.Index)? {
        let marker = source[index]
        guard marker == "*" || marker == "_" || marker == "~" else { return nil }
        let run = repeatedCount(of: marker, at: index, in: source)
        guard marker != "~" || run >= 2 else { return nil }
        let length = marker == "~" ? 2 : min(run, 3)
        let end = source.index(index, offsetBy: length)
        return (String(repeating: marker, count: length), marker, end)
    }

    private static func updateEmphasis(
        _ emphasis: inout [String],
        delimiter: String,
        marker: Character,
        previous: Character?,
        next: Character?
    ) {
        let previousIsWhitespace = previous?.isWhitespace ?? true
        let nextIsWhitespace = next?.isWhitespace ?? true
        let previousIsPunctuation = isPunctuation(previous)
        let nextIsPunctuation = isPunctuation(next)
        let leftFlanking = !nextIsWhitespace
            && (!nextIsPunctuation || previousIsWhitespace || previousIsPunctuation)
        let rightFlanking = !previousIsWhitespace
            && (!previousIsPunctuation || nextIsWhitespace || nextIsPunctuation)
        let canOpen = marker == "_"
            ? leftFlanking && (!rightFlanking || previousIsPunctuation)
            : leftFlanking
        let canClose = marker == "_"
            ? rightFlanking && (!leftFlanking || nextIsPunctuation)
            : rightFlanking

        if canClose, emphasis.last == delimiter {
            emphasis.removeLast()
        } else if canOpen {
            emphasis.append(delimiter)
        }
    }

    private static func isPunctuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
        }
    }

    private static func sourceCharacter(
        before index: String.Index,
        in source: String
    ) -> Character? {
        guard index > source.startIndex else { return nil }
        return source[source.index(before: index)]
    }

    private static func sourceCharacter(
        at index: String.Index,
        in source: String
    ) -> Character? {
        index < source.endIndex ? source[index] : nil
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
