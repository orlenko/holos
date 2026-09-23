import Foundation

/// Own one reducer per source track. Provisional hypotheses never enter finalized results.
public struct TranscriptReducer: Sendable {
    public private(set) var finalized: [TranscriptSegment] = []
    public private(set) var provisional: [TranscriptSegment] = []

    public init() {}

    public mutating func apply(_ update: TranscriptUpdate) throws {
        let segment = update.segment
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
              segment.end >= segment.start else {
            throw HolosError.invalidInput("Recognition produced an invalid time range.")
        }
        let overlaps: (TranscriptSegment) -> Bool = {
            $0.start < segment.end && segment.start < $0.end ||
            ($0.start == segment.start && $0.end == segment.end)
        }
        if finalized.contains(where: { $0 == segment }) { return }
        guard !finalized.contains(where: overlaps) else {
            throw HolosError.invalidInput("Recognition attempted to replace finalized audio.")
        }
        provisional.removeAll(where: overlaps)
        if update.isFinal {
            if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalized.append(segment)
                finalized.sort { $0.start < $1.start }
            }
        } else {
            provisional.append(segment)
            provisional.sort { $0.start < $1.start }
        }
    }
}
