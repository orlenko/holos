import Foundation
import HolosCore
import HolosSpeakers

/// What a meeting's word edits teach (docs/meeting-design.md §5.10, "Editing words"), worked out when a review window
/// closes from every word edited in the meeting's transcript as it is then: nothing is learned while editing, so
/// nothing has to be taken back, and an edit undone or reverted is not in the transcript. Learning the same transcript
/// again changes nothing (the app keeps an existing correction for a phrase), so no state is kept between reviews.
/// Pure.
enum ReviewLearning {
    /// The `reviewEdit` fixes of `transcript` as edits: what the recognizer wrote, the words' shown text, and the shown
    /// words around them. In transcript order (segments by start, then track; fixes by position). An edit back to what
    /// the recognizer wrote (a Revert) is left out.
    static func edits(in transcript: Transcript) -> [ReviewWordEdit] {
        let ordered = transcript.segments.sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        var edits: [ReviewWordEdit] = []
        for segment in ordered {
            let words = WordTiming.effectiveWords(of: segment)
            for fix in (segment.fixes ?? []).sorted(by: { $0.first < $1.first }) where fix.kind == .reviewEdit {
                guard fix.first >= 0, fix.first < fix.end, fix.end <= words.count,
                      let meant = TranscriptWordEdit.shownText(of: segment, first: fix.first, end: fix.end) else {
                    continue
                }
                let heard = TranscriptWordEdit.cleaned(fix.heard)
                let shown = TranscriptWordEdit.cleaned(meant)
                guard heard != shown else { continue }
                edits.append(ReviewWordEdit(
                    heard: heard, meant: shown,
                    before: fix.first > 0 ? TranscriptWordEdit.shownText(of: segment, first: fix.first - 1,
                                                                         end: fix.first) : nil,
                    after: fix.end < words.count ? TranscriptWordEdit.shownText(of: segment, first: fix.end,
                                                                                end: fix.end + 1) : nil))
            }
        }
        return edits
    }

    /// The corrections `edits` teach (`teach`: the app's rule, `TranscriptEditLearning`), in order, each heard phrase
    /// (`CorrectionList.key`) once: the first edit teaching it, in the meeting's order, gives it.
    static func corrections(_ edits: [ReviewWordEdit], teach: (ReviewWordEdit) -> [Correction]) -> [Correction] {
        var seen = Set<String>()
        var result: [Correction] = []
        for edit in edits {
            for correction in teach(edit) {
                let key = CorrectionList.key(correction.heard)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                result.append(correction)
            }
        }
        return result
    }
}
