import Foundation

/// Keeps the semantic index in step with the message table: every completed
/// user/assistant message without a stored vector for the current embedder
/// gets embedded and persisted. Runs opportunistically (launch + after each
/// turn); the same pass doubles as the one-time backfill of pre-existing
/// history, newest messages first so recent chats become semantically
/// searchable soonest.
///
/// All failures are silent: semantic search simply stays partial until a later
/// pass succeeds, and keyword search is unaffected throughout.
public actor EmbeddingIndexer {
    private let database: AppDatabase
    private let embedder: any TextEmbedder

    private var isRunning = false
    private var rerunRequested = false

    /// Messages fetched per DB round-trip.
    private let batchSize = 32
    /// Embedding input cap: one enormous message must not stall a pass, and the
    /// head of a message carries most of its searchable meaning.
    private let maxCharacters = 2_000

    public init(database: AppDatabase, embedder: any TextEmbedder) {
        self.database = database
        self.embedder = embedder
    }

    /// Embed every message still missing a vector. Reentrant-safe: a call while
    /// a pass is running schedules one follow-up pass instead of overlapping.
    public func indexPending() async {
        if isRunning {
            rerunRequested = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            rerunRequested = false
            await drain()
        } while rerunRequested
    }

    private func drain() async {
        // One canary prepare: if the model assets aren't available (first run
        // offline, unsupported OS), skip the whole pass instead of failing
        // message-by-message.
        guard (try? await embedder.prepareIfNeeded()) != nil else { return }
        while true {
            guard let batch = try? await database.messagesNeedingEmbedding(
                model: embedder.identifier, limit: batchSize
            ), !batch.isEmpty else { return }
            for candidate in batch {
                let text = String(candidate.text.prefix(maxCharacters))
                // A per-message failure stores an empty vector: the row is
                // marked unembeddable so the pass can't spin on it forever
                // (semantic search skips empty vectors). Assets are already
                // loaded, so such failures are text-specific, not transient.
                let vector = (try? await embedder.embed(text)) ?? []
                guard (try? await database.storeMessageEmbedding(
                    messageId: candidate.id, model: embedder.identifier, vector: vector
                )) != nil else { return }
            }
            await Task.yield()
        }
    }
}
