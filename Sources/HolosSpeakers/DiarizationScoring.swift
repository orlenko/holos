import Foundation

/// One speaker's speech from `start` to `end`, in seconds.
public struct LabelledInterval: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker; self.start = start; self.end = end
    }
}

/// Diarization error of a hypothesis against a reference, in seconds of speaker time over scored frames.
public struct DiarizationScore: Sendable, Equatable {
    /// Reference speaker time: seconds × speakers talking, over frames outside the collar.
    public var referenceSeconds: Double
    public var missSeconds: Double
    public var falseAlarmSeconds: Double
    public var confusionSeconds: Double
    /// (miss + false alarm + confusion) / reference. With no reference time: 0 without errors, else 1.
    public var der: Double
    /// Reference → hypothesis speaker; only pairs that share scored time.
    public var mapping: [String: String]
    /// Distinct speakers with at least one valid interval.
    public var referenceSpeakers: Int
    public var hypothesisSpeakers: Int

    public init(referenceSeconds: Double, missSeconds: Double, falseAlarmSeconds: Double, confusionSeconds: Double,
                der: Double, mapping: [String: String], referenceSpeakers: Int, hypothesisSpeakers: Int) {
        self.referenceSeconds = referenceSeconds; self.missSeconds = missSeconds
        self.falseAlarmSeconds = falseAlarmSeconds; self.confusionSeconds = confusionSeconds; self.der = der
        self.mapping = mapping; self.referenceSpeakers = referenceSpeakers
        self.hypothesisSpeakers = hypothesisSpeakers
    }
}

/// Speaker labels can be private reference names: printing, `dump`, and test-failure output of an interval or a
/// score show times, counts, and metrics only (docs/meeting-design.md §1.9).
extension LabelledInterval: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "LabelledInterval(start: \(start), end: \(end))" }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["start": start, "end": end], displayStyle: .struct)
    }
}

extension DiarizationScore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "DiarizationScore(der: \(der), referenceSeconds: \(referenceSeconds), missSeconds: \(missSeconds), "
            + "falseAlarmSeconds: \(falseAlarmSeconds), confusionSeconds: \(confusionSeconds), "
            + "mappedPairs: \(mapping.count), referenceSpeakers: \(referenceSpeakers), "
            + "hypothesisSpeakers: \(hypothesisSpeakers))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "der": der, "referenceSeconds": referenceSeconds, "missSeconds": missSeconds,
            "falseAlarmSeconds": falseAlarmSeconds, "confusionSeconds": confusionSeconds,
            "mappedPairs": mapping.count, "referenceSpeakers": referenceSpeakers,
            "hypothesisSpeakers": hypothesisSpeakers,
        ], displayStyle: .struct)
    }
}

/// Speaker-diarization metrics (docs/meeting-design.md §5.3, R25). Labels are compared only for equality; the
/// types that hold them print no labels. `agreement` returns its mapping in a plain tuple, which the caller must
/// not print.
///
/// Both functions work on 10 ms frames: frame `i` covers `[i, i + 1) × 10 ms` and a speaker is active in it when its
/// centre lies in one of the speaker's intervals (`start ≤ centre < end`; one speaker's overlapping intervals count
/// once). A frame whose centre is closer than `collar` seconds to a reference interval's start or end is not scored.
/// Intervals with a non-finite time or `end ≤ start` are ignored; times are clamped to ±10⁹ s.
///
/// The mapping is one-to-one and maximizes the frames each pair shares among scored frames: the Hungarian method
/// when both sides have at most 20 speakers, otherwise greedy by shared frames (ties by reference, then hypothesis
/// label). Only pairs that share at least one frame are mapped.
public enum DiarizationScoring {
    /// Frame-based (10 ms) DER with a no-score collar around reference boundaries; optimal one-to-one mapping
    /// (Hungarian up to 20 × 20, greedy by overlap above that).
    ///
    /// Per scored frame with `r` reference and `h` hypothesis speakers, `c` of them mapped pairs: miss
    /// `max(0, r − h)`, false alarm `max(0, h − r)`, confusion `min(r, h) − c`, reference `r`.
    public static func der(reference: [LabelledInterval], hypothesis: [LabelledInterval],
                           collar: Double = 0.25) -> DiarizationScore {
        let timeline = FrameTimeline(reference: reference, hypothesis: hypothesis, collar: collar)
        let mapping = timeline.optimalMapping()
        var referenceFrames = 0
        var missFrames = 0
        var falseAlarmFrames = 0
        var confusionFrames = 0
        for piece in timeline.pieces {
            let r = piece.reference.count
            let h = piece.hypothesis.count
            let correct = piece.reference.filter { mapping[$0].map(piece.hypothesis.contains) ?? false }.count
            referenceFrames += r * piece.frames
            missFrames += max(0, r - h) * piece.frames
            falseAlarmFrames += max(0, h - r) * piece.frames
            confusionFrames += (min(r, h) - correct) * piece.frames
        }
        let errors = missFrames + falseAlarmFrames + confusionFrames
        let der = referenceFrames > 0
            ? Double(errors) / Double(referenceFrames)
            : errors > 0 ? 1 : 0
        return DiarizationScore(
            referenceSeconds: seconds(referenceFrames), missSeconds: seconds(missFrames),
            falseAlarmSeconds: seconds(falseAlarmFrames), confusionSeconds: seconds(confusionFrames), der: der,
            mapping: timeline.names(of: mapping), referenceSpeakers: timeline.referenceNames.count,
            hypothesisSpeakers: timeline.hypothesisNames.count)
    }

    /// For Otter references (turns cover silence): over frames where both sides have a speaker, the share whose
    /// mapped speaker differs. Reported as "agreement with Otter", not DER.
    ///
    /// A compared frame agrees when the mapped speaker of one of its reference speakers is among its hypothesis
    /// speakers. `confusion` is the share of compared seconds that do not agree (0 when nothing is compared);
    /// `comparedSeconds` is the scored time where both sides have a speaker; `mapping` is reference → hypothesis.
    public static func agreement(reference: [LabelledInterval], hypothesis: [LabelledInterval],
                                 collar: Double = 0.25) -> (confusion: Double, comparedSeconds: Double, mapping: [String: String]) {
        let timeline = FrameTimeline(reference: reference, hypothesis: hypothesis, collar: collar)
        let mapping = timeline.optimalMapping()
        var comparedFrames = 0
        var confusedFrames = 0
        for piece in timeline.pieces where !piece.reference.isEmpty && !piece.hypothesis.isEmpty {
            comparedFrames += piece.frames
            let agrees = piece.reference.contains { mapping[$0].map(piece.hypothesis.contains) ?? false }
            if !agrees { confusedFrames += piece.frames }
        }
        let confusion = comparedFrames > 0 ? Double(confusedFrames) / Double(comparedFrames) : 0
        return (confusion, seconds(comparedFrames), timeline.names(of: mapping))
    }

    /// Frames per second.
    static let framesPerSecond = 100.0
    /// Mapping by the Hungarian method up to this many speakers on each side.
    static let hungarianLimit = 20
    /// Times are clamped to ±this many seconds so frame indices always fit in `Int`.
    static let timeLimit = 1e9

    private static func seconds(_ frames: Int) -> Double {
        Double(frames) / framesPerSecond
    }
}

// MARK: - Frames

/// Scored frames as runs ("pieces") with a constant set of active speakers, plus the frames each reference and
/// hypothesis speaker pair shares. Built by sweeping interval edges, so a 3 h recording costs a few thousand pieces
/// rather than a million frames.
struct FrameTimeline {
    struct Piece {
        /// Indices into `referenceNames` and `hypothesisNames`, ascending.
        let reference: [Int]
        let hypothesis: [Int]
        let frames: Int
    }

    /// Sorted speaker labels.
    let referenceNames: [String]
    let hypothesisNames: [String]
    /// Scored runs where at least one side has a speaker.
    let pieces: [Piece]
    /// `shared[r][h]`: scored frames where reference `r` and hypothesis `h` are both active.
    let shared: [[Int]]

    init(reference: [LabelledInterval], hypothesis: [LabelledInterval], collar: Double) {
        let validReference = reference.filter(Self.isValid)
        let validHypothesis = hypothesis.filter(Self.isValid)
        referenceNames = Array(Set(validReference.map(\.speaker))).sorted()
        hypothesisNames = Array(Set(validHypothesis.map(\.speaker))).sorted()
        let referenceIndex = Dictionary(uniqueKeysWithValues: referenceNames.enumerated().map { ($1, $0) })
        let hypothesisIndex = Dictionary(uniqueKeysWithValues: hypothesisNames.enumerated().map { ($1, $0) })

        enum Kind { case reference(Int), hypothesis(Int), collar }
        var events: [(frame: Int, kind: Kind, delta: Int)] = []
        func add(_ range: Range<Int>, _ kind: Kind) {
            guard !range.isEmpty else { return }
            events.append((range.lowerBound, kind, 1))
            events.append((range.upperBound, kind, -1))
        }
        let collar = collar.isFinite ? max(0, collar) : 0
        for interval in validReference {
            guard let index = referenceIndex[interval.speaker] else { continue }
            add(Self.frames(from: interval.start, to: interval.end), .reference(index))
            if collar > 0 {
                add(Self.collarFrames(around: interval.start, collar: collar), .collar)
                add(Self.collarFrames(around: interval.end, collar: collar), .collar)
            }
        }
        for interval in validHypothesis {
            guard let index = hypothesisIndex[interval.speaker] else { continue }
            add(Self.frames(from: interval.start, to: interval.end), .hypothesis(index))
        }
        events.sort { $0.frame < $1.frame }

        var referenceActive = [Int](repeating: 0, count: referenceNames.count)
        var hypothesisActive = [Int](repeating: 0, count: hypothesisNames.count)
        var collars = 0
        var shared = [[Int]](repeating: [Int](repeating: 0, count: hypothesisNames.count),
                             count: referenceNames.count)
        var pieces: [Piece] = []
        var position = 0
        while position < events.count {
            let frame = events[position].frame
            while position < events.count, events[position].frame == frame {
                let event = events[position]
                switch event.kind {
                case .reference(let index): referenceActive[index] += event.delta
                case .hypothesis(let index): hypothesisActive[index] += event.delta
                case .collar: collars += event.delta
                }
                position += 1
            }
            guard position < events.count, collars == 0 else { continue }
            let length = events[position].frame - frame
            let activeReference = referenceActive.indices.filter { referenceActive[$0] > 0 }
            let activeHypothesis = hypothesisActive.indices.filter { hypothesisActive[$0] > 0 }
            guard length > 0, !activeReference.isEmpty || !activeHypothesis.isEmpty else { continue }
            pieces.append(Piece(reference: activeReference, hypothesis: activeHypothesis, frames: length))
            for r in activeReference {
                for h in activeHypothesis { shared[r][h] += length }
            }
        }
        self.pieces = pieces
        self.shared = shared
    }

    /// Reference index → hypothesis index, one-to-one, maximizing shared frames; pairs sharing nothing are dropped.
    func optimalMapping() -> [Int: Int] {
        let rows = referenceNames.count
        let columns = hypothesisNames.count
        guard rows > 0, columns > 0 else { return [:] }
        var mapping: [Int: Int] = [:]
        if rows <= DiarizationScoring.hungarianLimit, columns <= DiarizationScoring.hungarianLimit {
            if rows <= columns {
                for (r, h) in Self.hungarian(cost: shared.map { $0.map { -$0 } }).enumerated() { mapping[r] = h }
            } else {
                let transposed = (0..<columns).map { h in (0..<rows).map { r in -shared[r][h] } }
                for (h, r) in Self.hungarian(cost: transposed).enumerated() { mapping[r] = h }
            }
        } else {
            var pairs: [(r: Int, h: Int, frames: Int)] = []
            for r in 0..<rows {
                for h in 0..<columns where shared[r][h] > 0 { pairs.append((r, h, shared[r][h])) }
            }
            // Names are sorted, so index order is label order.
            pairs.sort { ($1.frames, $0.r, $0.h) < ($0.frames, $1.r, $1.h) }
            var usedHypotheses = Set<Int>()
            for pair in pairs where mapping[pair.r] == nil && !usedHypotheses.contains(pair.h) {
                mapping[pair.r] = pair.h
                usedHypotheses.insert(pair.h)
            }
        }
        return mapping.filter { shared[$0.key][$0.value] > 0 }
    }

    func names(of mapping: [Int: Int]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: mapping.map { (referenceNames[$0.key], hypothesisNames[$0.value]) })
    }

    // MARK: Frame ranges

    private static func isValid(_ interval: LabelledInterval) -> Bool {
        interval.start.isFinite && interval.end.isFinite && interval.end > interval.start
    }

    /// Frames whose centre `(i + 0.5) / 100` lies in `[start, end)`.
    private static func frames(from start: Double, to end: Double) -> Range<Int> {
        let lower = index(ceilOf: scaled(start) - 0.5)
        let upper = index(ceilOf: scaled(end) - 0.5)
        return lower < upper ? lower..<upper : lower..<lower
    }

    /// Frames whose centre is closer than `collar` to `boundary`.
    private static func collarFrames(around boundary: Double, collar: Double) -> Range<Int> {
        let lower = index(floorOf: scaled(boundary - collar) - 0.5) + 1
        let upper = index(ceilOf: scaled(boundary + collar) - 0.5)
        return lower < upper ? lower..<upper : lower..<lower
    }

    private static func scaled(_ seconds: Double) -> Double {
        let limit = DiarizationScoring.timeLimit
        return min(max(seconds, -limit), limit) * DiarizationScoring.framesPerSecond
    }

    private static func index(ceilOf value: Double) -> Int { Int(value.rounded(.up)) }
    private static func index(floorOf value: Double) -> Int { Int(value.rounded(.down)) }

    // MARK: Assignment

    /// Minimum-cost assignment of every row to a distinct column (rows ≤ columns), by the Hungarian method with
    /// potentials, O(rows² × columns). Returns the column of each row.
    static func hungarian(cost: [[Int]]) -> [Int] {
        let rows = cost.count
        guard rows > 0 else { return [] }
        let columns = cost[0].count
        precondition(rows <= columns, "hungarian needs rows ≤ columns")
        // 1-based; column 0 is the virtual start column.
        var rowPotential = [Int](repeating: 0, count: rows + 1)
        var columnPotential = [Int](repeating: 0, count: columns + 1)
        var rowOfColumn = [Int](repeating: 0, count: columns + 1)
        var previousColumn = [Int](repeating: 0, count: columns + 1)
        for row in 1...rows {
            rowOfColumn[0] = row
            var column = 0
            var slack = [Int](repeating: .max, count: columns + 1)
            var visited = [Bool](repeating: false, count: columns + 1)
            repeat {
                visited[column] = true
                let currentRow = rowOfColumn[column]
                var delta = Int.max
                var nextColumn = 0
                for candidate in 1...columns where !visited[candidate] {
                    let reduced = cost[currentRow - 1][candidate - 1] - rowPotential[currentRow] - columnPotential[candidate]
                    if reduced < slack[candidate] {
                        slack[candidate] = reduced
                        previousColumn[candidate] = column
                    }
                    if slack[candidate] < delta {
                        delta = slack[candidate]
                        nextColumn = candidate
                    }
                }
                for candidate in 0...columns {
                    if visited[candidate] {
                        rowPotential[rowOfColumn[candidate]] += delta
                        columnPotential[candidate] -= delta
                    } else {
                        slack[candidate] -= delta
                    }
                }
                column = nextColumn
            } while rowOfColumn[column] != 0
            repeat {
                let previous = previousColumn[column]
                rowOfColumn[column] = rowOfColumn[previous]
                column = previous
            } while column != 0
        }
        var assignment = [Int](repeating: 0, count: rows)
        for column in 1...columns where rowOfColumn[column] != 0 {
            assignment[rowOfColumn[column] - 1] = column - 1
        }
        return assignment
    }
}
