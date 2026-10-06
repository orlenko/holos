import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// What a meeting's word edits teach (docs/meeting-design.md §5.10, "Editing words"), worked out when a review window
/// closes from every word edited in the meeting's transcript as it is then: nothing is learned while editing, so
/// nothing has to be taken back, and an edit undone or reverted is not in the transcript. The meeting keeps what it
/// has taught (`review-learned.json`), so a close teaches only what is new: a correction deleted or changed in
/// Corrections is not taught again, and one whose write failed is taught at the next close.
enum ReviewLearning {
    /// review-learned.json: the corrections this meeting's review closes taught (their write succeeded).
    struct Taught: Codable, Equatable {
        var version: Int
        var corrections: [Correction]
    }

    /// What this meeting taught already; empty when nothing was. Throws when the record cannot be read (damaged, or
    /// written by a newer Voice is Local): nothing is taught then, rather than teaching again what was deleted.
    static func taught(session: URL) throws -> [Correction] {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.reviewLearned(session), maxBytes: 4 << 20) else {
            return []
        }
        let record = try JSONDecoder().decode(Taught.self, from: data)
        guard record.version <= 1 else {
            throw HolosError.unavailable("What this meeting taught was recorded by a newer Voice is Local.")
        }
        return record.corrections
    }

    /// Adds `corrections` to what this meeting taught, one value per heard phrase (a later lesson replaces the earlier
    /// one for its phrase): read, merged, and written (atomically) under the meeting's speaker lock, so two closes
    /// (another Voice is Local running on the same folder) cannot lose each other's entries.
    static func recordTaught(adding corrections: [Correction], session: URL) throws {
        try SessionArchive.withSpeakerLock(at: session) {
            var merged = try Self.taught(session: session)
            for correction in untaught(corrections, taught: merged) {
                let key = CorrectionList.key(correction.heard)
                merged.removeAll { CorrectionList.key($0.heard) == key }
                merged.append(correction)
            }
            try AtomicFile.writeJSON(Taught(version: 1, corrections: merged), to: SessionPaths.reviewLearned(session))
        }
    }

    /// `corrections` this meeting has not taught: none with the same heard phrase (`CorrectionList.key`) and meaning.
    static func untaught(_ corrections: [Correction], taught: [Correction]) -> [Correction] {
        let known = Set(taught.map { "\(CorrectionList.key($0.heard))\u{1f}\($0.meant)" })
        return corrections.filter { !known.contains("\(CorrectionList.key($0.heard))\u{1f}\($0.meant)") }
    }

    /// The `reviewEdit` fixes of `transcript` as edits: what the recognizer wrote, the words' shown text, and the shown
    /// words around them as context. In transcript order (segments by start, then track; fixes by position). An edit
    /// back to what the recognizer wrote (a Revert) is left out. `turns`: the shown turns' word spans (a word the echo
    /// mask hides is in none). An edit is learned only when one turn holds all its words, and its context is taken
    /// from that same turn only (never another speaker's word, nor hidden echo); turns may overlap, so a word in two
    /// turns never joins them.
    static func edits(in transcript: Transcript, turns: [[WordSpan]]) -> [ReviewWordEdit] {
        let ordered = transcript.segments.sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        var edits: [ReviewWordEdit] = []
        for segment in ordered {
            let words = WordTiming.effectiveWords(of: segment)
            let utf16 = Array(segment.text.utf16)
            func holds(_ turn: [WordSpan], _ word: Int) -> Bool {
                turn.contains { $0.segmentID == segment.id && $0.first <= word && word < $0.end }
            }
            /// The one turn holding every word of `range`, nil when none does.
            func turn(holding range: Range<Int>) -> [WordSpan]? {
                turns.first { turn in range.allSatisfy { holds(turn, $0) } }
            }
            // Only words edited together that one shown turn still holds: a relabel may since have put them in two
            // turns, and a correction learned from them would mix two speakers' words.
            let fixes = (segment.fixes ?? []).filter { fix in
                fix.kind == .reviewEdit && fix.first >= 0 && fix.first < fix.end && fix.end <= words.count
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
                let before = context(first - 1, in: segment, words: words, inTurn: inTurn)
                let after = context(end, in: segment, words: words, inTurn: inTurn)
                edits.append(ReviewWordEdit(heard: heard, meant: shown, before: before?.shown, after: after?.shown,
                                            heardBefore: before?.heard, heardAfter: after?.heard))
            }
        }
        return edits
    }

    /// Word `index` of `segment` as context, when the edit's own turn holds it (`inTurn`): its shown text, and what the
    /// recognizer wrote there when a fix changed it (`heard`: nil when as shown). A word under a fix (an automatic
    /// correction or term, a live correction) stands with its whole fix, when that turn holds it all: "Claude" shown
    /// is "cloud" heard, so a correction learned beside it matches the recognizer's text ("as cloud" → "ask Claude").
    private static func context(_ index: Int, in segment: TranscriptSegment, words: [EffectiveWord],
                                inTurn: (Int) -> Bool) -> (shown: String, heard: String?)? {
        guard index >= 0, index < words.count, inTurn(index) else { return nil }
        if let fix = (segment.fixes ?? []).first(where: { $0.first <= index && index < $0.end }),
           fix.kind != .reviewRevert,
           (fix.first..<fix.end).allSatisfy(inTurn),
           let whole = TranscriptWordEdit.shownText(of: segment, first: fix.first, end: fix.end) {
            let shown = TranscriptWordEdit.cleaned(whole)
            let heard = TranscriptWordEdit.cleaned(fix.heard)
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
