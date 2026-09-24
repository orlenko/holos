import Foundation
import HolosCore

public enum TurnEmbeddings {
    /// Turns shorter than this get no embedding.
    static let minimumTurnSeconds = 2.0

    /// For each turn with a clusterID, not overlapped, at least 2 s long: the mean of that cluster's windows
    /// overlapping the turn, weighted by overlap seconds, L2-normalized. Other turns get none.
    /// Windows must be on the session timeline, keyed by cluster ID. A turn whose windows differ in size, or
    /// whose mean has zero norm, gets none. `speechSeconds` is the turn's duration. Results follow turn order.
    public static func compute(turns: [SpeakerTurn], windowsByCluster: [String: [EmbeddingWindow]]) -> [TurnEmbedding] {
        let indexed = windowsByCluster.mapValues { windows in
            windows.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
                .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        }
        let longest = indexed.mapValues { windows in windows.map { $0.end - $0.start }.max() ?? 0 }
        var embeddings: [TurnEmbedding] = []
        for turn in turns {
            let duration = turn.end - turn.start
            guard let clusterID = turn.clusterID, !turn.overlap, duration >= minimumTurnSeconds - timeEpsilon,
                  let windows = indexed[clusterID], !windows.isEmpty else { continue }
            // Windows that overlap the turn start after `turn.start − longest window` and before `turn.end`.
            var index = firstIndex(in: windows, startingAtOrAfter: turn.start - (longest[clusterID] ?? 0) - timeEpsilon)
            var weighted: [([Float], Double)] = []
            while index < windows.count, windows[index].start < turn.end {
                let window = windows[index]
                let overlap = min(window.end, turn.end) - max(window.start, turn.start)
                if overlap > timeEpsilon { weighted.append((window.vector.values, overlap)) }
                index += 1
            }
            guard let mean = VectorMath.weightedMean(weighted),
                  let norm = VectorMath.norm(mean), norm > 0 else { continue }
            embeddings.append(TurnEmbedding(turnID: turn.id, speechSeconds: duration,
                                            vector: FloatVector(VectorMath.normalized(mean))))
        }
        return embeddings
    }

    private static func firstIndex(in windows: [EmbeddingWindow], startingAtOrAfter time: Double) -> Int {
        var low = 0
        var high = windows.count
        while low < high {
            let middle = (low + high) / 2
            if windows[middle].start >= time { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
