import Foundation
import HolosCore

/// One effective word with its speaker label (docs/meeting-design.md §5.3, alignment steps 1–4).
public struct AlignedWord: Sendable, Equatable {
    public let ref: WordRef
    public let track: String
    /// Session time.
    public let start: Double
    public let end: Double
    public let estimated: Bool
    /// Cluster or channel speaker; nil = unknown.
    public var label: String?
    /// Overlap with `label`'s segments (0 for a word that snapped to a nearby segment or is unknown).
    public var coveredSeconds: Double
    /// Other clusters overlapping the word by at least the overlap threshold, sorted.
    public var overlapClusters: [String]

    public init(ref: WordRef, track: String, start: Double, end: Double, estimated: Bool,
                label: String? = nil, coveredSeconds: Double = 0, overlapClusters: [String] = []) {
        self.ref = ref; self.track = track; self.start = start; self.end = end; self.estimated = estimated
        self.label = label; self.coveredSeconds = coveredSeconds; self.overlapClusters = overlapClusters
    }
}

/// Word-to-speaker alignment for one track. Pure functions over values.
///
/// Algorithm (per track):
/// 0. `estimateOffset`; the caller shifts the track's diarization by it (`SpeakerRunBuilder` does).
/// 1. Words: segments whose `track` equals the track (a `nil` track counts when the transcript has one
///    track), in start order, expanded with `WordTiming.effectiveWords`.
/// 2. Main cluster: the cluster with the largest overlap with the union of its segments. Ties: the cluster
///    whose overlapping segment starts first, then the smaller cluster ID. No overlap: the nearest segment by
///    edge distance if that distance ≤ `gapSnapSeconds` (same tie rule), else unknown.
/// 3. Overlap: other clusters overlapping the word by at least
///    `min(overlapMinSeconds, overlapMinFraction × duration)`.
/// 4. Flicker smoothing (`smoothFlicker`).
/// 5. Turns (`buildTurns`).
/// 6. `channel` policy: every word gets the channel speaker, no overlap, score 1. `skipped`: no words.
///    `assignWords` applies it to words and `buildTurns(_:parameters:policy:)` to turns (clusterID nil).
public enum SpeakerAlignment {
    /// `estimateOffset` returns 0 with fewer measured words than this.
    static let minimumOffsetWords = 50
    /// The best offset must cover at least this factor of the word time covered at offset 0.
    static let minimumOffsetGain = 1.01

    /// Offset in [−search, +search] (step `offsetStepSeconds`) to add to diarization times that maximizes the
    /// measured-word time covered by any segment; 0 with fewer than 50 measured words, or when the best
    /// offset covers less than 1% more word time than 0. Ties: smallest |offset|.
    public static func estimateOffset(segments: [TranscriptSegment], track: String, diarization: TrackDiarization,
                                      parameters: AlignmentParameters) -> Double {
        estimateOffset(segments: segments, track: track, includeUntracked: nil, diarization: diarization,
                       parameters: parameters)
    }

    /// Steps 1–4 above, for the transcript segments of `track` (diarization already shifted by the offset).
    /// A `channel` policy labels every word with its speaker (step 6); a `skipped` policy yields no words.
    public static func assignWords(segments: [TranscriptSegment], track: String, diarization: TrackDiarization,
                                   parameters: AlignmentParameters) -> [AlignedWord] {
        assignWords(segments: segments, track: track, includeUntracked: nil, diarization: diarization,
                    parameters: parameters)
    }

    /// Step 5, plus step 6 for `policy`. Turns get placeholder IDs; the run builder renumbers them.
    /// `.diarized` (the default): a turn's `clusterID` is its label. `.channel`: `clusterID` nil, no overlap,
    /// score 1. `.skipped`: no turns. Pass the policy the words were assigned with.
    public static func buildTurns(_ words: [AlignedWord], parameters: AlignmentParameters,
                                  policy: TrackPolicy = .diarized) -> [SpeakerTurn] {
        switch policy {
        case .diarized: buildTurns(words, parameters: parameters, channel: false)
        case .channel: buildTurns(words, parameters: parameters, channel: true)
        case .skipped: []
        }
    }

    // MARK: - Step 0: offset

    static func estimateOffset(segments: [TranscriptSegment], track: String, includeUntracked: Bool?,
                               diarization: TrackDiarization, parameters: AlignmentParameters) -> Double {
        let search = parameters.offsetSearchSeconds
        let step = parameters.offsetStepSeconds
        guard search.isFinite, step.isFinite, search > 0, step > 0 else { return 0 }
        let words = trackSegments(segments, track: track, includeUntracked: includeUntracked)
            .flatMap { WordTiming.effectiveWords(of: $0) }
            .filter { !$0.estimated && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        guard words.count >= minimumOffsetWords else { return 0 }
        let union = Intervals.union(diarization.segments.map { SecondsRange(start: $0.start, end: $0.end) })
        guard !union.isEmpty else { return 0 }

        // Adding `offset` to every diarization time covers the same word time as subtracting it from every word.
        func coverage(_ offset: Double) -> Double {
            words.reduce(0) { $0 + Intervals.overlap(union, start: $1.start - offset, end: $1.end - offset) }
        }
        let base = coverage(0)
        var bestOffset = 0.0
        var bestCoverage = base
        // Candidates in order of increasing |offset|; only a strictly larger coverage replaces the best,
        // so ties keep the smallest |offset|.
        // Capped while still a Double: a tiny step would otherwise overflow the conversion to Int.
        let steps = Int(min((search / step + 1e-9).rounded(.down), 100_000))
        if steps > 0 {
            for index in 1...steps {
                for sign in [-1.0, 1.0] {
                    // Rounded to microseconds so a recorded offset reads as the decimal step multiple (0.06).
                    let offset = (sign * Double(index) * step * 1e6).rounded() / 1e6
                    let covered = coverage(offset)
                    if covered > bestCoverage + timeEpsilon {
                        bestOffset = offset
                        bestCoverage = covered
                    }
                }
            }
        }
        guard bestOffset != 0, bestCoverage >= base * minimumOffsetGain else { return 0 }
        return bestOffset
    }

    // MARK: - Steps 1–4: words and labels

    /// Step 1's segment choice: segments of `track` in start order. A nil-track segment counts when
    /// `includeUntracked` is true; when it is nil, when no segment names a different track.
    static func trackSegments(_ segments: [TranscriptSegment], track: String,
                              includeUntracked: Bool? = nil) -> [TranscriptSegment] {
        let untracked = includeUntracked ?? segments.allSatisfy { $0.track == nil || $0.track == track }
        return segments.enumerated()
            .filter { $0.element.track == track || ($0.element.track == nil && untracked) }
            .sorted { lhs, rhs in
                let left = lhs.element.start.isFinite ? lhs.element.start : .infinity
                let right = rhs.element.start.isFinite ? rhs.element.start : .infinity
                return (left, lhs.offset) < (right, rhs.offset)
            }
            .map(\.element)
    }

    /// Unlabelled words of `track` in step-1 order. Words with a non-finite time are left out; an end before
    /// the start is treated as a zero-length word.
    static func trackWords(_ segments: [TranscriptSegment], track: String,
                           includeUntracked: Bool?) -> [AlignedWord] {
        var words: [AlignedWord] = []
        for segment in trackSegments(segments, track: track, includeUntracked: includeUntracked) {
            for (index, word) in WordTiming.effectiveWords(of: segment).enumerated()
            where word.start.isFinite && word.end.isFinite {
                words.append(AlignedWord(ref: WordRef(segmentID: segment.id, word: index), track: track,
                                         start: word.start, end: max(word.start, word.end),
                                         estimated: word.estimated))
            }
        }
        return words
    }

    static func assignWords(segments: [TranscriptSegment], track: String, includeUntracked: Bool?,
                            diarization: TrackDiarization, parameters: AlignmentParameters) -> [AlignedWord] {
        let words = trackWords(segments, track: track, includeUntracked: includeUntracked)
        switch diarization.policy {
        case .skipped:
            return []
        case .channel(let speakerID, _):
            return words.map { word in
                var labelled = word
                labelled.label = speakerID
                labelled.coveredSeconds = word.end - word.start
                return labelled
            }
        case .diarized:
            let timelines = ClusterTimeline.make(diarization.segments)
            var labelled = words.map { label($0, timelines: timelines, parameters: parameters) }
            let byID = Dictionary(uniqueKeysWithValues: timelines.map { ($0.clusterID, $0) })
            smoothFlicker(&labelled, timelines: byID, parameters: parameters)
            return labelled
        }
    }

    /// Steps 2 and 3 for one word.
    static func label(_ word: AlignedWord, timelines: [ClusterTimeline],
                      parameters: AlignmentParameters) -> AlignedWord {
        guard !timelines.isEmpty else { return word }
        let start = word.start
        let end = word.end
        let overlaps = timelines.map { $0.overlap(start: start, end: end) }
        var result = word
        let largest = overlaps.max() ?? 0
        if largest > timeEpsilon {
            let tied = overlaps.indices.filter { overlaps[$0] >= largest - timeEpsilon }
            let main = pick(tied, timelines: timelines) {
                $0.earliestOverlappingStart(start: start, end: end)
            }
            result.label = timelines[main].clusterID
            result.coveredSeconds = overlaps[main]
            let threshold = min(parameters.overlapMinSeconds, parameters.overlapMinFraction * (end - start))
            result.overlapClusters = overlaps.indices
                .filter { $0 != main && overlaps[$0] > timeEpsilon && overlaps[$0] >= threshold - timeEpsilon }
                .map { timelines[$0].clusterID }
                .sorted()
            return result
        }

        let distances = timelines.map { $0.edgeDistance(start: start, end: end) }
        let nearest = distances.min() ?? .infinity
        guard nearest <= parameters.gapSnapSeconds + timeEpsilon else { return result }
        let tied = distances.indices.filter { distances[$0] <= nearest + timeEpsilon }
        let main = pick(tied, timelines: timelines) {
            $0.earliestStart(atDistance: nearest, start: start, end: end)
        }
        result.label = timelines[main].clusterID
        result.coveredSeconds = 0
        result.overlapClusters = []
        return result
    }

    /// The tie rule of step 2 over the non-empty `candidates` (indices into `timelines`): the cluster whose
    /// qualifying segment starts first, then the smaller cluster ID.
    private static func pick(_ candidates: [Int], timelines: [ClusterTimeline],
                             segmentStart: (ClusterTimeline) -> Double?) -> Int {
        guard candidates.count > 1 else { return candidates[0] }
        var best = candidates[0]
        var bestStart = segmentStart(timelines[best]) ?? .infinity
        for candidate in candidates.dropFirst() {
            let start = segmentStart(timelines[candidate]) ?? .infinity
            if (start, timelines[candidate].clusterID) < (bestStart, timelines[best].clusterID) {
                best = candidate
                bestStart = start
            }
        }
        return best
    }

    /// Step 4, one left-to-right pass over labels (`nil` included). A maximal run R of words labelled B, with
    /// label A ≠ B on both sides, takes label A only when: R has at most `flickerMaxWords` words; R spans at
    /// most `flickerMaxSeconds`; the pauses from the A word before R to R's first word and from R's last word
    /// to the A word after R are each at most `flickerMaxGapSeconds`; and, when B is a cluster, R starts or
    /// ends within `flickerBoundarySeconds` of a point where an A segment meets a B segment, and no single B
    /// segment at least `flickerMinOwnSegmentSeconds` long covers R. Runs touching either end are kept.
    ///
    /// A relabelled word's `coveredSeconds` becomes its overlap with A's segments, and A leaves its
    /// `overlapClusters`; the displaced cluster B is not recorded as overlap.
    static func smoothFlicker(_ words: inout [AlignedWord], timelines: [String: ClusterTimeline],
                              parameters: AlignmentParameters) {
        var runStart = 0
        while runStart < words.count {
            let runLabel = words[runStart].label
            var runEnd = runStart + 1
            while runEnd < words.count, words[runEnd].label == runLabel { runEnd += 1 }
            defer { runStart = runEnd }
            guard runStart > 0, runEnd < words.count,
                  let a = words[runStart - 1].label, words[runEnd].label == a, a != runLabel,
                  runEnd - runStart <= parameters.flickerMaxWords else { continue }
            let run = words[runStart..<runEnd]
            let first = run.map(\.start).min() ?? words[runStart].start
            let last = run.map(\.end).max() ?? words[runEnd - 1].end
            guard last - first <= parameters.flickerMaxSeconds + timeEpsilon,
                  first - words[runStart - 1].end <= parameters.flickerMaxGapSeconds + timeEpsilon,
                  words[runEnd].start - last <= parameters.flickerMaxGapSeconds + timeEpsilon else { continue }
            let aTimeline = timelines[a]
            if let b = runLabel {
                guard let aTimeline, let bTimeline = timelines[b],
                      meetsNear(aTimeline, bTimeline, first: first, last: last,
                                within: parameters.flickerBoundarySeconds),
                      !bTimeline.hasSegment(covering: first, last,
                                            minimumLength: parameters.flickerMinOwnSegmentSeconds)
                else { continue }
            }
            for index in runStart..<runEnd {
                words[index].label = a
                words[index].coveredSeconds = aTimeline?.overlap(start: words[index].start, end: words[index].end) ?? 0
                words[index].overlapClusters.removeAll { $0 == a }
            }
        }
    }

    /// True when some A segment meets some B segment (they touch or overlap) at a point within `distance` of
    /// `first` or `last`. The meeting points of two segments are the ends of their intersection.
    static func meetsNear(_ a: ClusterTimeline, _ b: ClusterTimeline, first: Double, last: Double,
                          within distance: Double) -> Bool {
        let from = first - distance
        let to = last + distance
        let bSegments = b.segments(near: from, to)
        guard !bSegments.isEmpty else { return false }
        for aSegment in a.segments(near: from, to) {
            for bSegment in bSegments {
                let low = max(aSegment.start, bSegment.start)
                let high = min(aSegment.end, bSegment.end)
                guard low <= high + timeEpsilon else { continue }
                for point in [low, high]
                where abs(first - point) <= distance + timeEpsilon || abs(last - point) <= distance + timeEpsilon {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Step 5: turns

    private static func buildTurns(_ words: [AlignedWord], parameters: AlignmentParameters,
                                   channel: Bool) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        var group: [AlignedWord] = []
        var groupEnd = -Double.infinity

        func flush() {
            guard let first = group.first else { return }
            var spans: [WordSpan] = []
            for word in group {
                if let last = spans.last, last.segmentID == word.ref.segmentID, last.end == word.ref.word {
                    spans[spans.count - 1].end += 1
                } else {
                    spans.append(WordSpan(segmentID: word.ref.segmentID, first: word.ref.word, end: word.ref.word + 1))
                }
            }
            let others = Set(group.flatMap(\.overlapClusters)).sorted()
            let duration = group.reduce(0.0) { $0 + ($1.end - $1.start) }
            let covered = group.reduce(0.0) { $0 + $1.coveredSeconds }
            let score: Double
            if channel {
                score = 1
            } else if first.label == nil || duration <= 0 {
                score = 0
            } else {
                score = min(max(covered / duration, 0), 1)
            }
            let estimated = group.filter(\.estimated).count
            let timing: WordTimingQuality = estimated == 0 ? .measured : estimated == group.count ? .estimated : .mixed
            turns.append(SpeakerTurn(
                id: "T\(turns.count + 1)", track: first.track,
                start: group.map(\.start).min() ?? first.start, end: group.map(\.end).max() ?? first.end,
                speakerID: first.label, clusterID: channel ? nil : first.label, spans: spans,
                overlap: !channel && !others.isEmpty, otherClusters: channel ? [] : others,
                assignmentScore: score, timing: timing))
            group.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let previous = group.last,
               word.label != previous.label || word.start - groupEnd > parameters.turnPauseSeconds + timeEpsilon {
                flush()
            }
            if group.isEmpty { groupEnd = word.end } else { groupEnd = max(groupEnd, word.end) }
            group.append(word)
        }
        flush()
        return turns
    }
}

// MARK: - Per-cluster segment index

/// One cluster's segments on a track, indexed for the per-word queries of steps 2–4.
struct ClusterTimeline {
    let clusterID: String
    /// Sorted by start.
    let segments: [SecondsRange]
    /// Sorted, disjoint union of `segments`.
    let union: [SecondsRange]
    let maxDuration: Double

    init(clusterID: String, segments: [SecondsRange]) {
        self.clusterID = clusterID
        self.segments = segments.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        self.union = Intervals.union(segments)
        self.maxDuration = segments.map(\.duration).max() ?? 0
    }

    /// One timeline per cluster, in cluster ID order.
    static func make(_ segments: [DiarizationSegment]) -> [ClusterTimeline] {
        var byCluster: [String: [SecondsRange]] = [:]
        for segment in segments where segment.start.isFinite && segment.end.isFinite && segment.end > segment.start {
            byCluster[segment.clusterID, default: []].append(SecondsRange(start: segment.start, end: segment.end))
        }
        return byCluster.keys.sorted().map { ClusterTimeline(clusterID: $0, segments: byCluster[$0] ?? []) }
    }

    /// Seconds of `[start, end)` covered by this cluster.
    func overlap(start: Double, end: Double) -> Double {
        Intervals.overlap(union, start: start, end: end)
    }

    /// Segments whose closure intersects `[from, to]`, in start order.
    func segments(near from: Double, _ to: Double) -> [SecondsRange] {
        var index = firstIndex(startingAtOrAfter: from - maxDuration - timeEpsilon)
        var found: [SecondsRange] = []
        while index < segments.count, segments[index].start <= to + timeEpsilon {
            if segments[index].end >= from - timeEpsilon { found.append(segments[index]) }
            index += 1
        }
        return found
    }

    /// The earliest start of a segment that overlaps `[start, end)` by a positive amount.
    func earliestOverlappingStart(start: Double, end: Double) -> Double? {
        segments(near: start, end)
            .first { min($0.end, end) - max($0.start, start) > timeEpsilon }?
            .start
    }

    /// Distance from `[start, end)` to the nearest segment edge: 0 when a segment touches or contains it,
    /// `.infinity` without segments.
    func edgeDistance(start: Double, end: Double) -> Double {
        let index = Intervals.firstIndex(in: union, endingAfter: start)
        var distance = Double.infinity
        if index < union.count { distance = max(0, union[index].start - end) }
        if index > 0 { distance = min(distance, max(0, start - union[index - 1].end)) }
        return distance
    }

    /// The earliest start of a segment whose edge distance to `[start, end)` is `distance`.
    func earliestStart(atDistance distance: Double, start: Double, end: Double) -> Double? {
        segments(near: start - distance, end + distance)
            .first { abs(max(0, $0.start - end, start - $0.end) - distance) <= timeEpsilon }?
            .start
    }

    /// True when one segment at least `minimumLength` long covers `[first, last]`.
    func hasSegment(covering first: Double, _ last: Double, minimumLength: Double) -> Bool {
        segments(near: first, last).contains {
            $0.duration >= minimumLength - timeEpsilon && $0.start <= first + timeEpsilon && $0.end >= last - timeEpsilon
        }
    }

    private func firstIndex(startingAtOrAfter time: Double) -> Int {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].start >= time { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
