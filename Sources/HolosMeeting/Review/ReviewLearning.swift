import Foundation
import HolosCore
import HolosSpeakers

/// What a review window's word edits teach (docs/meeting-design.md §5.10, "Editing words"), worked out once, when the
/// window closes, from the transcript it leaves: nothing is learned while editing, so nothing has to be taken back. An
/// edit undone or reverted before then is not in that transcript, so it is never learned. Pure.
enum ReviewLearning {
    /// The `reviewEdit` fixes of `final` that `opened` (the transcript the window opened on) did not have, as edits:
    /// what the recognizer wrote, the words' shown text now, and the shown words around them. In transcript order
    /// (segments by start, then track; fixes by position), so for two edits teaching the same heard phrase, the later
    /// one in the meeting comes last. An edit back to what the recognizer wrote (a Revert) teaches nothing.
    static func netEdits(opened: Transcript, final: Transcript) -> [ReviewWordEdit] {
        let before = Dictionary(opened.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = final.segments.sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        var edits: [ReviewWordEdit] = []
        for segment in ordered {
            let words = WordTiming.effectiveWords(of: segment)
            let known = Set(before[segment.id].map(Self.edits(in:)) ?? [])
            for fix in (segment.fixes ?? []).sorted(by: { $0.first < $1.first }) where fix.kind == .reviewEdit {
                guard fix.first >= 0, fix.first < fix.end, fix.end <= words.count,
                      let meant = TranscriptWordEdit.shownText(of: segment, first: fix.first, end: fix.end) else {
                    continue
                }
                let heard = TranscriptWordEdit.cleaned(fix.heard)
                let shown = TranscriptWordEdit.cleaned(meant)
                guard heard != shown, !known.contains(Key(heard: heard, meant: shown)) else { continue }
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

    /// The corrections `edits` teach (`teach`: the app's rule, `TranscriptEditLearning`), one per heard phrase
    /// (`CorrectionList.key`): of two edits teaching the same phrase differently, the later one in the meeting wins.
    static func corrections(_ edits: [ReviewWordEdit], teach: (ReviewWordEdit) -> [Correction]) -> [Correction] {
        var order: [String] = []
        var byKey: [String: Correction] = [:]
        for edit in edits {
            for correction in teach(edit) {
                let key = CorrectionList.key(correction.heard)
                guard !key.isEmpty else { continue }
                if byKey[key] == nil { order.append(key) }
                byKey[key] = correction
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private struct Key: Hashable {
        var heard: String
        var meant: String
    }

    /// The Review edits a segment already had.
    private static func edits(in segment: TranscriptSegment) -> [Key] {
        let words = WordTiming.effectiveWords(of: segment)
        return (segment.fixes ?? []).compactMap { fix in
            guard fix.kind == .reviewEdit, fix.first >= 0, fix.first < fix.end, fix.end <= words.count,
                  let meant = TranscriptWordEdit.shownText(of: segment, first: fix.first, end: fix.end) else {
                return nil
            }
            return Key(heard: TranscriptWordEdit.cleaned(fix.heard), meant: TranscriptWordEdit.cleaned(meant))
        }
    }
}
