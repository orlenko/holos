import Foundation
import HolosCore
import HolosStorage

extension WordFixStage {
    /// `transcriptID` and every transcript it was corrected from, back to `unfixedID`, newest first: labels made for
    /// any of them are the labels of `transcriptID` (Review's word edits and automatic fixes keep them).
    static func correctionChain(_ transcriptID: String, events: [ArchiveEvent]) -> [String] {
        var chain = [transcriptID]
        while let base = events.last(where: {
            ($0.kind == MeetingEventKind.wordsFixed || $0.kind == MeetingEventKind.liveHintsApplied
                || $0.kind == MeetingEventKind.transcriptEdited)
                && $0.details["transcriptID"] == chain[chain.count - 1]
        })?.details["base"], !base.isEmpty, !chain.contains(base) {
            chain.append(base)
        }
        return chain
    }
}
