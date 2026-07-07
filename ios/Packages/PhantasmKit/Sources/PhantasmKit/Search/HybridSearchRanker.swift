import Foundation

/// Reciprocal-rank fusion of the keyword (FTS5/bm25) and semantic (cosine)
/// result lists. RRF needs no score calibration between the two rankings —
/// only positions — which matters here because bm25 and cosine live on
/// unrelated scales. A conversation ranked by both lists beats one ranked by
/// either alone; ties break toward the better single-list rank, keyword first.
public enum HybridSearchRanker {
    /// The standard RRF dampening constant: rank differences near the top stay
    /// meaningful without letting the #1 spot dominate the fused score.
    private static let k: Double = 60

    public static func fuse(
        keyword: [ConversationSearchResult],
        semantic: [ConversationSearchResult]
    ) -> [ConversationSearchResult] {
        struct Entry {
            var result: ConversationSearchResult
            var score: Double = 0
            var bestRank = Int.max
            var arrival: Int
        }
        var entries: [UUID: Entry] = [:]
        var arrivals = 0

        // Keyword list first, so a conversation in both keeps its FTS snippet
        // (highlighted match) over the semantic one (message prefix).
        for (rank, result) in keyword.enumerated() {
            entries[result.id] = Entry(
                result: result, score: rrf(rank), bestRank: rank, arrival: arrivals
            )
            arrivals += 1
        }
        for (rank, result) in semantic.enumerated() {
            if var entry = entries[result.id] {
                entry.score += rrf(rank)
                entry.bestRank = min(entry.bestRank, rank)
                if entry.result.snippet == nil { entry.result.snippet = result.snippet }
                entries[result.id] = entry
            } else {
                entries[result.id] = Entry(
                    result: result, score: rrf(rank), bestRank: rank, arrival: arrivals
                )
                arrivals += 1
            }
        }

        return entries.values
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.bestRank != $1.bestRank { return $0.bestRank < $1.bestRank }
                return $0.arrival < $1.arrival
            }
            .map(\.result)
    }

    private static func rrf(_ rank: Int) -> Double {
        1 / (k + Double(rank + 1))
    }
}
