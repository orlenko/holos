import Foundation
import HolosCore

public enum DiarizationNormalizer {
    /// Engine segments shorter than this are dropped.
    static let minimumSegmentSeconds = 0.05

    /// Prefixes engine labels with the track ("system:S1"), drops segments shorter than 0.05 s, sorts by
    /// (start, clusterID), sets overlapCount, and builds ClusterSummary (speechSeconds = union length per cluster).
    /// Segments with a non-finite time are dropped too. Clusters are listed in cluster ID order.
    public static func normalize(_ output: DiarizerOutput, track: String) -> TrackDiarization {
        var segments: [DiarizationSegment] = []
        segments.reserveCapacity(output.segments.count)
        for raw in output.segments
        where raw.start.isFinite && raw.end.isFinite && raw.end - raw.start >= minimumSegmentSeconds - timeEpsilon {
            segments.append(DiarizationSegment(track: track, clusterID: clusterID(track: track, speaker: raw.speaker),
                                               start: raw.start, end: raw.end, quality: raw.quality))
        }
        segments.sort { ($0.start, $0.clusterID, $0.end) < ($1.start, $1.clusterID, $1.end) }

        // Sorted by start, so every segment that intersects segment i and starts at or after it follows i
        // until the first one that starts at or after i's end.
        var others = [Set<String>](repeating: [], count: segments.count)
        for i in segments.indices {
            var j = i + 1
            while j < segments.count, segments[j].start < segments[i].end - timeEpsilon {
                if segments[j].clusterID != segments[i].clusterID {
                    others[i].insert(segments[j].clusterID)
                    others[j].insert(segments[i].clusterID)
                }
                j += 1
            }
        }
        for i in segments.indices {
            segments[i].overlapCount = others[i].count
        }

        var rangesByCluster: [String: [SecondsRange]] = [:]
        for segment in segments {
            rangesByCluster[segment.clusterID, default: []].append(SecondsRange(start: segment.start, end: segment.end))
        }
        let clusters = rangesByCluster.keys.sorted().map { id in
            ClusterSummary(clusterID: id, track: track,
                           speechSeconds: Intervals.length(Intervals.union(rangesByCluster[id] ?? [])))
        }
        return TrackDiarization(track: track, policy: .diarized, segments: segments, clusters: clusters)
    }

    /// Session-local cluster ID for an engine label: "<track>:<label>".
    static func clusterID(track: String, speaker: String) -> String { "\(track):\(speaker)" }
}

// MARK: - Interval helpers shared by the speaker algorithms

/// Tolerance for comparing times and durations computed from decimal inputs, so a boundary that is
/// "exactly" at a threshold in decimal does not flip on floating-point rounding.
let timeEpsilon = 1e-9

/// A half-open range of session seconds `[start, end)`.
struct SecondsRange: Equatable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
}

enum Intervals {
    /// The sorted, disjoint union of `ranges`; ranges that touch are joined. Empty ranges are ignored.
    static func union(_ ranges: [SecondsRange]) -> [SecondsRange] {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var merged: [SecondsRange] = []
        merged.reserveCapacity(sorted.count)
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Total length of a sorted, disjoint union.
    static func length(_ union: [SecondsRange]) -> Double {
        union.reduce(0) { $0 + $1.duration }
    }

    /// Seconds of `[start, end)` covered by a sorted, disjoint union.
    static func overlap(_ union: [SecondsRange], start: Double, end: Double) -> Double {
        guard end > start else { return 0 }
        var index = firstIndex(in: union, endingAfter: start)
        var total = 0.0
        while index < union.count, union[index].start < end {
            total += max(0, min(end, union[index].end) - max(start, union[index].start))
            index += 1
        }
        return total
    }

    /// Index of the first range of a sorted, disjoint union whose end is after `time` (`union.count` if none).
    static func firstIndex(in union: [SecondsRange], endingAfter time: Double) -> Int {
        var low = 0
        var high = union.count
        while low < high {
            let middle = (low + high) / 2
            if union[middle].end > time { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
