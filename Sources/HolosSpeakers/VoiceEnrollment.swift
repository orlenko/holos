import Foundation
import HolosCore

/// A turn a voice sample extractor is asked about: its ID and its span on the session timeline.
public struct TurnRef: Codable, Sendable, Equatable {
    public var id: String
    public var start: Double
    public var end: Double

    public init(id: String, start: Double, end: Double) {
        self.id = id; self.start = start; self.end = end
    }

    public init(_ turn: ProjectedTurn) {
        self.init(id: turn.id, start: turn.start, end: turn.end)
    }
}

/// Voice samples from confirmed speakers (docs/meeting-design.md §4.10, "Enrollment"). Pure: the embeddings come from
/// a `VoiceSampleExtractor` (HolosMeeting), which is asked only about the turns `candidateTurns` returns.
public enum VoiceEnrollment {
    /// Turns shorter than this never qualify.
    public static let minimumTurnSeconds = 2.0
    /// A turn farther than this (cosine distance) from the first mean is dropped as an outlier.
    public static let outlierDistance = 0.5
    /// A turn's dominant fresh speaker must cover at least this share of it…
    public static let dominantShare = 0.6
    /// …and no other fresh speaker more than this share.
    public static let otherShare = 0.25

    /// The turns of `speakerIDs` that may contribute to a sample: not reassigned, not produced or trimmed by a split
    /// (`modified`), not overlapped, at least 2 s long, and not excluded from enrollment. In projection order.
    public static func candidateTurns(for speakerIDs: [String], projection: SpeakerProjection) -> [ProjectedTurn] {
        let speakers = Set(speakerIDs)
        return projection.turns.filter { turn in
            guard let speakerID = turn.speakerID, speakers.contains(speakerID) else { return false }
            return !turn.reassigned && !turn.modified && !turn.overlap && !turn.excludedFromEnrollment
                && turn.start.isFinite && turn.end.isFinite
                && turn.end - turn.start >= minimumTurnSeconds - timeEpsilon
        }
    }

    /// §4.10 enrollment rules. `speakerIDs` are the session's speakers linked to one profile.
    ///
    /// Qualifying turns are `candidateTurns` that have an embedding in `turnEmbeddings` (matched by turn ID; an empty
    /// or non-finite vector does not count). When they span both conditions (microphone and system tracks), only the
    /// condition with more speech is used. The vector is their speech-weighted mean (a turn's speech is its duration),
    /// L2-normalized; one outlier pass then drops turns more than 0.5 cosine distance from it and recomputes.
    /// `weak` when the remaining speech is under `minSampleSeconds`. Nil when `projection` is not of `run`, nothing
    /// qualifies, or the mean has no direction.
    public static func sample(for speakerIDs: [String], projection: SpeakerProjection, run: DiarizationRun,
                              turnEmbeddings: [TurnEmbedding], minSampleSeconds: Double = 20)
        -> (vector: FloatVector, speechSeconds: Double, condition: RecordingCondition, weak: Bool, droppedOutlierTurns: Int)? {
        guard projection.runID == run.id else { return nil }
        var embeddings: [String: [Float]] = [:]
        for embedding in turnEmbeddings where embeddings[embedding.turnID] == nil {
            let values = embedding.vector.values
            guard !values.isEmpty, values.allSatisfy(\.isFinite) else { continue }
            embeddings[embedding.turnID] = values
        }
        let entries = candidateTurns(for: speakerIDs, projection: projection).compactMap { turn -> Entry? in
            embeddings[turn.id].map { Entry(condition: RecordingCondition(track: turn.track),
                                            seconds: turn.end - turn.start, vector: $0) }
        }
        guard !entries.isEmpty else { return nil }
        let room = entries.filter { $0.condition == .room }
        let call = entries.filter { $0.condition == .call }
        let chosen = speech(call) > speech(room) ? call : (room.isEmpty ? call : room)
        guard let condition = chosen.first?.condition, let mean = weightedMean(chosen) else { return nil }
        let kept = chosen.filter { VectorMath.cosineDistance(mean, $0.vector) <= outlierDistance }
        let dropped = chosen.count - kept.count
        guard !kept.isEmpty, let vector = dropped == 0 ? mean : weightedMean(kept) else { return nil }
        let seconds = speech(kept)
        return (FloatVector(vector), seconds, condition, seconds < minSampleSeconds, dropped)
    }

    /// A digest of what a sample of `speakerIDs` is built from: the run, the speakers, and each candidate turn's ID,
    /// track, times, and words. Equal digests mean a re-extraction would ask about the same audio.
    public static func inputDigest(speakerIDs: [String], projection: SpeakerProjection) -> String {
        let speakers = Set(speakerIDs).sorted()
        func text(_ value: String) -> String { "\(value.unicodeScalars.count):\(value)" }
        var parts = ["run=" + text(projection.runID), "speakers=" + speakers.map(text).joined(separator: ",")]
        for turn in candidateTurns(for: speakers, projection: projection).sorted(by: { $0.id < $1.id }) {
            let words = turn.spans.map { "\(text($0.segmentID))@\($0.first)..\($0.end)" }.joined(separator: ",")
            parts.append("turn=\(text(turn.id));\(text(turn.track));\(turn.start)-\(turn.end);[\(words)]")
        }
        return "venroll1:" + FingerprintSHA256.hexDigest(Array(parts.joined(separator: "|").utf8))
    }

    /// The selection a voice sample extractor makes from a fresh diarization pass of one track (§4.10): for each
    /// turn, the fresh speaker whose segments cover the most of it must cover at least 60 % of it and no other
    /// speaker more than 25 % (otherwise it is not clean single-speaker speech and gets nothing); then only that
    /// speaker's windows overlapping the turn are averaged, weighted by overlap seconds, and L2-normalized. Windows
    /// are per (window, speaker slot), so two people in one window never mix. Times are on the session timeline.
    /// `speechSeconds` is the turn's duration. Results follow `turns`.
    public static func turnEmbeddings(turns: [TurnRef], segments: [RawDiarizationSegment],
                                      windows: [EmbeddingWindow]) -> [TurnEmbedding] {
        var intervals: [String: [(start: Double, end: Double)]] = [:]
        for segment in segments where segment.start.isFinite && segment.end.isFinite && segment.end > segment.start {
            intervals[segment.speaker, default: []].append((segment.start, segment.end))
        }
        let merged = intervals.mapValues(mergeIntervals)
        var windowsBySpeaker: [String: [EmbeddingWindow]] = [:]
        for window in windows where window.start.isFinite && window.end.isFinite && window.end > window.start {
            windowsBySpeaker[window.speaker, default: []].append(window)
        }
        var result: [TurnEmbedding] = []
        for turn in turns {
            let duration = turn.end - turn.start
            guard turn.start.isFinite, turn.end.isFinite, duration > timeEpsilon else { continue }
            let covered = merged.map { speaker, spans in
                (speaker: speaker, seconds: spans.reduce(0.0) { $0 + overlap($1.start, $1.end, turn.start, turn.end) })
            }
            guard let best = covered.max(by: { ($0.seconds, $1.speaker) < ($1.seconds, $0.speaker) }),
                  best.seconds >= dominantShare * duration - timeEpsilon,
                  !covered.contains(where: { $0.speaker != best.speaker && $0.seconds > otherShare * duration + timeEpsilon })
            else { continue }
            let weighted = (windowsBySpeaker[best.speaker] ?? []).compactMap { window -> ([Float], Double)? in
                let seconds = overlap(window.start, window.end, turn.start, turn.end)
                return seconds > timeEpsilon ? (window.vector.values, seconds) : nil
            }
            guard let mean = VectorMath.weightedMean(weighted), let norm = VectorMath.norm(mean), norm > 0 else {
                continue
            }
            result.append(TurnEmbedding(turnID: turn.id, speechSeconds: duration,
                                        vector: FloatVector(VectorMath.normalized(mean))))
        }
        return result
    }

    // MARK: - Private

    private struct Entry {
        let condition: RecordingCondition
        let seconds: Double
        let vector: [Float]
    }

    private static func speech(_ entries: [Entry]) -> Double { entries.reduce(0) { $0 + $1.seconds } }

    /// The speech-weighted, L2-normalized mean; nil when it has no direction.
    private static func weightedMean(_ entries: [Entry]) -> [Float]? {
        guard let mean = VectorMath.weightedMean(entries.map { ($0.vector, $0.seconds) }),
              let norm = VectorMath.norm(mean), norm > 0 else { return nil }
        return VectorMath.normalized(mean)
    }

    private static func overlap(_ start: Double, _ end: Double, _ otherStart: Double, _ otherEnd: Double) -> Double {
        max(0, min(end, otherEnd) - max(start, otherStart))
    }

    /// Sorted, non-overlapping intervals covering the same time.
    private static func mergeIntervals(_ spans: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        var result: [(start: Double, end: Double)] = []
        for span in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }
}
