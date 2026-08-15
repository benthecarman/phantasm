import Foundation

/// A token-budgeted, wire-ready view of persisted history. The original rows
/// and attachment BLOBs remain untouched; only the inference request is compacted.
public struct PreparedHistory: Sendable {
    public let messages: [ChatMessage]
    public let earlierSummary: String?

    /// Only payloads used by `wireContent`: user image attachments and extracted
    /// inline images. Remote-image cache rows are display-only and never ride the
    /// prompt, while text attachments already carry their extracted text in metadata.
    public var requiredAttachmentIDs: [UUID] {
        messages.flatMap(\.attachments).compactMap { attachment in
            switch AttachmentKind(rawValue: attachment.kind) {
            case .image, .inlineImage:
                return attachment.id
            case .text, .remoteImage, .none:
                return nil
            }
        }
    }

    public func hydratingAttachments(from payloads: [UUID: Data]) -> PreparedHistory {
        PreparedHistory(
            messages: messages.map { item in
                var item = item
                item.attachments = item.attachments.map { attachment in
                    guard let data = payloads[attachment.id] else { return attachment }
                    var attachment = attachment
                    attachment.data = data
                    return attachment
                }
                return item
            },
            earlierSummary: earlierSummary
        )
    }

    public func wireHistory() -> [WireMessage] {
        var wire = messages.wireHistory()
        if let earlierSummary, !earlierSummary.isEmpty {
            wire.insert(
                WireMessage(
                    role: "system",
                    content: "Earlier conversation (compacted):\n\(earlierSummary)"
                ),
                at: 0
            )
        }
        return wire
    }
}

/// Keeps recent turns verbatim and replaces an older prefix with a small,
/// deterministic transcript. Estimation deliberately errs high: exact model
/// tokenizers are not available on-device, and image tokenization is model-specific.
public enum HistoryCompactor {
    private static let defaultContextLength = 32_768
    private static let maximumInputTokens = 32_768
    private static let minimumInputTokens = 4_096
    private static let summaryReserveTokens = 1_024
    private static let estimatedTokensPerImage = 1_200
    private static let maximumSummaryCharacters = 4_000
    private static let maximumSummaryCharactersPerMessage = 400

    public static func inputTokenBudget(
        contextLength: Int?,
        reservedInputTokens: Int = 0
    ) -> Int {
        let context = max(contextLength ?? defaultContextLength, minimumInputTokens)
        let outputReserve = max(2_048, context / 8)
        let available = context - outputReserve - max(0, reservedInputTokens)
        return min(maximumInputTokens, max(1_024, available))
    }

    /// Whether selected tool schemas leave enough room for at least one small
    /// user turn after preserving the normal output reserve.
    public static func toolsFit(
        contextLength: Int?,
        reservedInputTokens: Int
    ) -> Bool {
        guard let contextLength, contextLength > 0 else { return true }
        let outputReserve = max(2_048, contextLength / 8)
        return contextLength - outputReserve - max(0, reservedInputTokens) >= 1_024
    }

    public static func prepare(
        _ history: [ChatMessage],
        contextLength: Int?,
        reservedInputTokens: Int = 0
    ) -> PreparedHistory {
        let completed = history.filter { $0.message.isComplete }
        guard !completed.isEmpty else {
            return PreparedHistory(messages: [], earlierSummary: nil)
        }

        let groups = historyGroups(completed)
        let budget = inputTokenBudget(
            contextLength: contextLength,
            reservedInputTokens: reservedInputTokens
        )
        let recentBudget = max(1_024, budget - summaryReserveTokens)
        var selected: [[ChatMessage]] = []
        var used = 0

        for group in groups.reversed() {
            let cost = estimatedTokens(in: group)
            // The newest logical turn is always retained, even when one very
            // large attachment exceeds the soft latency budget by itself.
            if !selected.isEmpty && used + cost > recentBudget { break }
            selected.append(group)
            used += cost
        }
        selected.reverse()
        let keptCount = selected.reduce(0) { $0 + $1.count }
        let omittedCount = completed.count - keptCount
        let kept = selected.flatMap { $0 }
        let summary = omittedCount > 0
            ? compactSummary(of: Array(completed.prefix(omittedCount)))
            : nil
        return PreparedHistory(messages: kept, earlierSummary: summary)
    }

    /// Group an assistant tool-call message with all immediately following tool
    /// results. Compaction can then never cut a valid call/result exchange in half.
    private static func historyGroups(_ history: [ChatMessage]) -> [[ChatMessage]] {
        var groups: [[ChatMessage]] = []
        var index = 0
        while index < history.count {
            var group = [history[index]]
            if history[index].message.role == "assistant",
               history[index].message.toolCalls != nil {
                var next = index + 1
                while next < history.count, history[next].message.role == "tool" {
                    group.append(history[next])
                    next += 1
                }
                index = next
            } else {
                index += 1
            }
            groups.append(group)
        }
        return groups
    }

    private static func estimatedTokens(in group: [ChatMessage]) -> Int {
        max(1, group.reduce(0) { total, item in
            var bytes = item.message.content.utf8.count
                + item.message.reasoning.utf8.count
                + (item.message.toolCalls?.utf8.count ?? 0)
            for attachment in item.attachments {
                switch AttachmentKind(rawValue: attachment.kind) {
                case .image, .inlineImage:
                    bytes += estimatedTokensPerImage * 4
                case .text:
                    bytes += attachment.text.utf8.count
                case .remoteImage, .none:
                    break
                }
            }
            return total + max(16, bytes / 4)
        })
    }

    private static func compactSummary(of history: [ChatMessage]) -> String? {
        var lines: [String] = []
        var remaining = maximumSummaryCharacters
        for item in history where remaining > 0 {
            let role: String
            switch item.message.role {
            case "user": role = "User"
            case "assistant": role = "Assistant"
            case "tool": role = "Tool"
            default: role = item.message.role.capitalized
            }
            let collapsed = item.message.content
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !collapsed.isEmpty else { continue }
            let allowance = min(maximumSummaryCharactersPerMessage, remaining)
            let excerpt = String(collapsed.prefix(allowance))
            lines.append("\(role): \(excerpt)")
            remaining -= excerpt.count
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
