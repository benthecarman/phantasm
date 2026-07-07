import Foundation
import NaturalLanguage

/// `TextEmbedder` backed by Apple's `NLContextualEmbedding` — a BERT-style
/// on-device encoder that ships with the OS, so nothing is bundled with the
/// app. Token vectors are mean-pooled and L2-normalized into one message
/// vector.
///
/// The OS downloads the model assets on demand (system-wide, shared across
/// apps). Until they're available `embed` throws and search degrades to
/// keyword-only; the indexer retries on later passes.
public actor ContextualTextEmbedder: TextEmbedder {
    public enum EmbedderError: Error {
        /// The script model doesn't exist on this OS or its assets can't be
        /// fetched right now.
        case unavailable
        /// The text produced no token vectors (e.g. whitespace-only input).
        case emptyEmbedding
    }

    /// Latin-script model (covers English + ~20 other Latin-script languages).
    /// Bump the suffix if pooling or preprocessing changes — stored vectors are
    /// only comparable within one identifier.
    public nonisolated let identifier = "apple.nlcontextual.latin.v1"

    private var embedding: NLContextualEmbedding?
    private var isLoaded = false

    public init() {}

    public func prepareIfNeeded() async throws {
        if isLoaded { return }
        guard let embedding = embedding ?? NLContextualEmbedding(script: .latin) else {
            throw EmbedderError.unavailable
        }
        self.embedding = embedding
        if !embedding.hasAvailableAssets {
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<NLContextualEmbedding.AssetsResult, Error>) in
                embedding.requestAssets { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }
            guard result == .available else { throw EmbedderError.unavailable }
        }
        try embedding.load()
        isLoaded = true
    }

    public func embed(_ text: String) async throws -> [Float] {
        try await prepareIfNeeded()
        guard let embedding else { throw EmbedderError.unavailable }
        let result = try embedding.embeddingResult(for: text, language: nil)
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var tokens = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            tokens += 1
            return true
        }
        guard tokens > 0 else { throw EmbedderError.emptyEmbedding }
        let mean = sum.map { Float($0 / Double(tokens)) }
        let normalized = VectorCodec.normalized(mean)
        guard normalized.contains(where: { $0 != 0 }) else { throw EmbedderError.emptyEmbedding }
        return normalized
    }
}
