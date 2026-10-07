import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// What a meeting's word edits teach (docs/meeting-design.md §5.10, "Editing words"), worked out when a review window
/// closes from every word edited in the meeting's transcript as it is then: nothing is learned while editing, so
/// nothing has to be taken back, and an edit undone or reverted is not in the transcript. What the meeting taught is
/// kept in corrections.json with the rules (`CorrectionList.reviewTaught`, saved with them), so a close teaches only
/// what is new: a correction deleted or changed in Corrections is not taught again, and one whose write failed is
/// taught at the next close.
enum ReviewLearning {
    /// The `reviewEdit` fixes of `transcript` as edits: what the recognizer wrote, the words' shown text, and the shown
    /// words around them as context. In transcript order (segments by start, then track; fixes by position). An edit
    /// back to what the recognizer wrote (a Revert) is left out. `turns`: the shown turns' word spans (a word the echo
    /// mask hides is in none). An edit is learned only when one turn holds all its words, and its context is taken
    /// from that same turn only (never another speaker's word, nor hidden echo); turns may overlap, so a word in two
    /// turns never joins them. `base`: the unfixed revision `transcript` was fixed from (`fixedFrom`), where what the
    /// recognizer wrote beside an edit (under an automatic fix) is read, punctuation included.
    static func edits(in transcript: Transcript, turns: [[WordSpan]], base: Transcript? = nil) -> [ReviewWordEdit] {
        let ordered = transcript.segments.sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        var edits: [ReviewWordEdit] = []
        for segment in ordered {
            // A segment that cannot be trusted (word ranges, marks: `TranscriptWordEdit.isDamaged`) teaches nothing,
            // neither its own edits nor context for them.
            if TranscriptWordEdit.isDamaged(segment) { continue }
            let words = WordTiming.effectiveWords(of: segment)
            let utf16 = Array(segment.text.utf16)
            // Where each word boundary is in the unfixed segment, for what the recognizer wrote under a fix.
            // (Not when it cannot be trusted either: then no context is read from it.)
            let baseSegment = base.flatMap { base in
                base.id == transcript.fixedFrom ? base.segments.first { $0.id == segment.id } : nil
            }.flatMap { TranscriptWordEdit.isDamaged($0) ? nil : $0 }
            let baseWords = baseSegment.map(WordTiming.effectiveWords(of:))
            let bounds = baseWords.flatMap {
                TranscriptWordEdit.baseBounds(fixes: segment.fixes ?? [], current: words, base: $0)
            }
            /// What the recognizer wrote over `fix`, the same extent its shown text has (`shown`: punctuation the
            /// recognizer did not time included): from the unfixed segment for an automatic fix; else its `heard`
            /// when its shown text is just its words; nil when that cannot be told (no context then).
            func recognized(_ fix: TranscriptWordFix, shown: String) -> String? {
                // A deletion's `heard` holds the deleted words too: beside an edit, it would teach dropping them.
                if fix.deleted == true { return nil }
                // A damaged fix (its words out of the segment's) has nothing that can be read.
                guard TranscriptWordEdit.isSound(fix, wordCount: words.count) else { return nil }
                if fix.kind == .correction || fix.kind == .term, let baseSegment, let baseWords, let bounds,
                   fix.end < bounds.count,
                   bounds[fix.first] >= 0, bounds[fix.end] >= 0 {
                    let baseText = Array(baseSegment.text.utf16)
                    let range = TranscriptWordEdit.extent(of: bounds[fix.first]..<bounds[fix.end], words: baseWords,
                                                          utf16: baseText)
                    if !range.isEmpty { return String(decoding: baseText[range], as: UTF16.self) }
                }
                let own = words[fix.first..<fix.end].map(\.text).joined(separator: " ")
                return TranscriptWordEdit.cleaned(own) == TranscriptWordEdit.cleaned(shown) ? fix.heard : nil
            }
            func holds(_ turn: [WordSpan], _ word: Int) -> Bool {
                turn.contains { $0.segmentID == segment.id && $0.first <= word && word < $0.end }
            }
            /// The one turn holding every word of `range`, nil when none does.
            func turn(holding range: Range<Int>) -> [WordSpan]? {
                turns.first { turn in range.allSatisfy { holds(turn, $0) } }
            }
            // Only words edited together that one shown turn still holds: a relabel may since have put them in two
            // turns, and a correction learned from them would mix two speakers' words.
            // A deletion (or an edit that took one in) teaches nothing: its `heard` holds the deleted words, and
            // learning it would make dictation drop them everywhere ("um cloud" → "Claude"). It is left out before
            // edits side by side are joined, so an edit beside it is learned on its own.
            let fixes = (segment.fixes ?? []).filter { fix in
                fix.kind == .reviewEdit && fix.deleted != true && TranscriptWordEdit.isSound(fix, wordCount: words.count)
                    && turn(holding: fix.first..<fix.end) != nil
            }.sorted { $0.first < $1.first }
            // Edits side by side in one turn ("bull" → "pull", then "requested" → "request") are one span: learned
            // apart, each would take the other's corrected word as what was heard beside it ("pull requested"), and
            // neither rule would match what the recognizer wrote ("bull requested").
            var spans: [[TranscriptWordFix]] = []
            for fix in fixes {
                if let last = spans.last?.last, let start = spans.last?.first?.first, last.end == fix.first,
                   turn(holding: start..<fix.end) != nil {
                    spans[spans.count - 1].append(fix)
                } else {
                    spans.append([fix])
                }
            }
            for span in spans {
                guard let first = span.first?.first, let end = span.last?.end, let owner = turn(holding: first..<end),
                      let meant = TranscriptWordEdit.shownText(of: segment, first: first, end: end) else { continue }
                // What the recognizer wrote over the span: each edit's `heard`, with the text between them as it is
                // (no space where the words had none).
                var written = TranscriptWordEdit.cleaned(span[0].heard)
                for (previous, next) in zip(span, span.dropFirst()) {
                    // Shown extents meet but for the whitespace between them: none means the words had no space.
                    let end = TranscriptWordEdit.extent(of: previous.first..<previous.end, words: words, utf16: utf16)
                    let start = TranscriptWordEdit.extent(of: next.first..<next.end, words: words, utf16: utf16)
                    let spaced = end.isEmpty || start.isEmpty || end.upperBound != start.lowerBound
                    written += (spaced ? " " : "") + TranscriptWordEdit.cleaned(next.heard)
                }
                let heard = TranscriptWordEdit.cleaned(written)
                let shown = TranscriptWordEdit.cleaned(meant)
                guard heard != shown else { continue }
                let inTurn = { (word: Int) in holds(owner, word) }
                let before = context(first - 1, in: segment, words: words, inTurn: inTurn, recognized: recognized)
                let after = context(end, in: segment, words: words, inTurn: inTurn, recognized: recognized)
                edits.append(ReviewWordEdit(heard: heard, meant: shown, before: before?.shown, after: after?.shown,
                                            heardBefore: before?.heard, heardAfter: after?.heard))
            }
        }
        return edits
    }

    /// Word `index` of `segment` as context, when the edit's own turn holds it (`inTurn`): its shown text, and what the
    /// recognizer wrote there when a fix changed it (`heard`: nil when as shown). A word under a fix (an automatic
    /// correction or term, a live correction) stands with its whole fix: "Claude" shown is "cloud" heard, so a
    /// correction learned beside it matches the recognizer's text ("as cloud" → "ask Claude"). A fix the turn does not
    /// hold all of ("newark" made "New York", split as "as New" / "York") gives no context: part of it has no heard
    /// text of its own, and corrected text never stands for what was heard ("as New" would match nothing). Both sides
    /// cover the same characters (`recognized`): "cloud." for "Claude.", never "cloud" beside "Claude.".
    private static func context(_ index: Int, in segment: TranscriptSegment, words: [EffectiveWord],
                                inTurn: (Int) -> Bool,
                                recognized: (TranscriptWordFix, String) -> String?) -> (shown: String, heard: String?)? {
        guard index >= 0, index < words.count, inTurn(index) else { return nil }
        if let fix = (segment.fixes ?? []).first(where: { $0.first <= index && index < $0.end }),
           fix.kind != .reviewRevert {
            // A damaged fix (its words out of the segment's) gives no context.
            guard TranscriptWordEdit.isSound(fix, wordCount: words.count), (fix.first..<fix.end).allSatisfy(inTurn),
                  let whole = TranscriptWordEdit.shownText(of: segment, first: fix.first, end: fix.end),
                  let written = recognized(fix, whole) else {
                return nil
            }
            let shown = TranscriptWordEdit.cleaned(whole)
            let heard = TranscriptWordEdit.cleaned(written)
            return (shown, heard == shown ? nil : heard)
        }
        guard let shown = TranscriptWordEdit.shownText(of: segment, first: index, end: index + 1) else { return nil }
        return (shown, nil)
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
