import Foundation

/// A rough estimate of how much of a model's context window a conversation
/// occupies, so the app can warn before history silently overflows (Ollama
/// truncates the oldest turns when the prompt exceeds `num_ctx`).
///
/// The estimate is deliberately approximate — the app has no tokenizer — but a
/// character-based heuristic is enough to flag a conversation that is getting
/// close to the limit.
public struct ContextUsage: Equatable, Sendable {
    public let estimatedTokens: Int
    public let contextLength: Int

    public init(estimatedTokens: Int, contextLength: Int) {
        self.estimatedTokens = estimatedTokens
        self.contextLength = contextLength
    }

    /// Fraction of the window used (clamped at 0; may exceed 1 when over limit).
    public var fraction: Double {
        guard contextLength > 0 else { return 0 }
        return Double(estimatedTokens) / Double(contextLength)
    }

    /// Within the warning band but not yet over the window.
    public var isNearLimit: Bool {
        fraction >= ContextWindow.warnThreshold && !isOverLimit
    }

    /// The estimate already meets or exceeds the window — older turns will be
    /// dropped from the model's view.
    public var isOverLimit: Bool {
        estimatedTokens >= contextLength
    }
}

public enum ContextWindow {
    /// Rough English-text ratio: ~4 characters per token. Intentionally on the
    /// conservative (high-token) side so we warn a little early rather than late.
    public static let charactersPerToken = 4
    /// Flat per-image allowance. Vision inputs are tiled and far denser than
    /// their data-URI length implies, so they're counted separately.
    public static let imageTokenCost = 768
    /// Warn once the estimate reaches this fraction of the window.
    public static let warnThreshold = 0.8

    /// Estimated prompt tokens for the history actually sent upstream: completed
    /// messages' text plus inlined text attachments, with a flat cost per image.
    /// Reasoning is excluded — it is never replayed into future prompts.
    public static func estimatedTokens(for messages: [ChatMessage]) -> Int {
        var characters = 0
        var images = 0
        for item in messages where item.message.isComplete {
            characters += item.message.content.count
            for attachment in item.attachments {
                if attachment.kind == AttachmentKind.image.rawValue {
                    images += 1
                } else if attachment.kind == AttachmentKind.text.rawValue {
                    characters += attachment.text.count
                }
            }
        }
        return characters / charactersPerToken + images * imageTokenCost
    }

    /// Usage against a known context window, or `nil` when the window is unknown
    /// (the app then shows no warning rather than guessing).
    public static func usage(for messages: [ChatMessage], contextLength: Int?) -> ContextUsage? {
        guard let contextLength, contextLength > 0 else { return nil }
        return ContextUsage(
            estimatedTokens: estimatedTokens(for: messages),
            contextLength: contextLength
        )
    }

    /// Compact human label for a window size, e.g. `8192 → "8K"`, `1048576 → "1M"`.
    public static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let millions = Double(tokens) / 1_048_576
            return String(format: millions >= 10 ? "%.0fM" : "%.1fM", millions)
        }
        if tokens >= 1_000 {
            return "\(Int((Double(tokens) / 1024).rounded()))K"
        }
        return "\(tokens)"
    }
}
