import Foundation

/// A text-to-vector encoder for semantic history search.
///
/// Implementations must return L2-normalized vectors (so cosine similarity is a
/// plain dot product) and must be stable for a given `identifier`: vectors from
/// different models or revisions are never comparable, so the identifier is
/// persisted alongside every stored vector and changing it invalidates the
/// index (the indexer simply re-embeds).
public protocol TextEmbedder: Sendable {
    /// Stable key naming the model + revision that produced the vectors.
    var identifier: String { get }

    /// Load model assets if needed. Throwing means embedding is unavailable
    /// right now (e.g. OS assets not downloaded and no network) — callers
    /// degrade to keyword-only search rather than surfacing an error.
    func prepareIfNeeded() async throws

    /// Embed one text into an L2-normalized vector.
    func embed(_ text: String) async throws -> [Float]
}

/// Raw-float storage codec + the small vector math hybrid search needs.
/// Vectors persist as contiguous native-endian `Float` bytes (both supported
/// architectures are little-endian; the blob never leaves the device).
public enum VectorCodec {
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = data.copyBytes(to: buffer) / MemoryLayout<Float>.stride
        }
    }

    /// Dot product — equals cosine similarity for normalized vectors.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    /// L2-normalize. A zero vector normalizes to itself.
    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
