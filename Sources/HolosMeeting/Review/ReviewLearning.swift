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
        // The fix kinds learning reads: those the editor knows (`editableKinds`, and a live correction it refuses).
        let readable = TranscriptWordEdit.editableKinds.union([.liveCorrection])
        // A transcript with a segment ID used twice cannot say which segment a turn's words are in: nothing is learned.
        // An unfixed revision with one cannot say which segment holds what the recognizer wrote: no context from it.
        guard !TranscriptWordEdit.hasRepeatedSegmentIDs(transcript) else { return [] }
        let base = base.flatMap { TranscriptWordEdit.hasRepeatedSegmentIDs($0) ? nil : $0 }
        // Read once for every segment (a meeting can hold tens of thousands of segments and turns): the unfixed
        // segments by ID, and each turn's spans by segment.
        let baseSegments = base.map { base in
            Dictionary(base.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var spansOf: [String: [(turn: Int, span: WordSpan)]] = [:]
        for (index, turn) in turns.enumerated() {
            for span in turn { spansOf[span.segmentID, default: []].append((index, span)) }
        }
        let segmentsByID = Dictionary(transcript.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Each segment read once, when an edit or its context needs it (nil: it cannot be trusted).
        var cache: [String: Prepared?] = [:]
        func prepared(_ id: String) -> Prepared? {
            if let known = cache[id] { return known }
            let made = segmentsByID[id].flatMap { segment in
                Self.prepare(segment, readable: readable,
                             baseSegment: base?.id == transcript.fixedFrom ? baseSegments?[segment.id] : nil,
                             spans: spansOf[segment.id] ?? [])
            }
            cache[id] = .some(made)
            return made
        }
        /// The context word before (`before`) or after words `first..<end` of segment `segmentID`, in turn `owner`:
        /// the word beside them in the segment; at the segment's edge, the turn's word beside them in the segment its
        /// spans go on in (a one-word segment inside a longer turn has context too). Never a word another turn holds,
        /// nor hidden echo (a span that does not reach the edge of its segment leaves words between).
        func neighbour(owner: Int, segmentID: String, first: Int, end: Int,
                       before: Bool) -> (shown: String, heard: String?)? {
            guard let this = prepared(segmentID) else { return nil }
            let index = before ? first - 1 : end
            if index >= 0, index < this.words.count { return Self.context(index, in: this, owner: owner) }
            guard owner >= 0, owner < turns.count else { return nil }
            let spans = turns[owner]
            let edge = before ? first : end - 1
            guard let at = spans.firstIndex(where: {
                $0.segmentID == segmentID && $0.first <= edge && edge < $0.end
            }) else { return nil }
            let next = before ? at - 1 : at + 1
            guard spans.indices.contains(next), spans[next].segmentID != segmentID,
                  let other = prepared(spans[next].segmentID) else { return nil }
            let span = spans[next]
            guard before ? span.end == other.words.count : span.first == 0 else { return nil }
            return Self.context(before ? span.end - 1 : span.first, in: other, owner: owner)
        }
        let ordered = transcript.segments.sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        var edits: [ReviewWordEdit] = []
        for segment in ordered {
            // Only a segment with words edited here teaches anything.
            guard (segment.fixes ?? []).contains(where: { $0.kind == .reviewEdit }) else { continue }
            // A segment that cannot be trusted (word ranges, marks: `TranscriptWordEdit.isDamaged`) teaches nothing,
            // neither its own edits nor context for them.
            guard let this = prepared(segment.id) else { continue }
            // Nor one where an edit touches (holds, or stands beside) a fix of a kind a newer version wrote: what the
            // recognizer wrote there cannot be told, as the editor cannot edit it (`TranscriptWordEdit.editableKinds`).
            let marks = segment.fixes ?? []
            let newer = marks.filter { !readable.contains($0.kind) }
            if marks.contains(where: { edit in
                edit.kind == .reviewEdit && newer.contains { $0.first <= edit.end && edit.first <= $0.end }
            }) {
                continue
            }
            let words = this.words
            let utf16 = this.utf16
            /// The turns holding every word of `range`, in order (the first is the one an edit belongs to).
            func turnsHolding(_ range: Range<Int>, among candidates: [Int]? = nil) -> [Int] {
                guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= this.holders.count else { return [] }
                var left = candidates ?? this.holders[range.lowerBound]
                for word in range where !left.isEmpty { left = left.filter { this.holds($0, word) } }
                return left
            }
            let trivial = this.trivial
            // Only words edited together that one shown turn still holds: a relabel may since have put them in two
            // turns, and a correction learned from them would mix two speakers' words.
            // A deletion (or an edit that took one in) teaches nothing: its `heard` holds the deleted words, and
            // learning it would make dictation drop them everywhere ("um cloud" → "Claude"). It is left out before
            // edits side by side are joined, so an edit beside it is learned on its own.
            let fixes = (segment.fixes ?? []).filter { fix in
                fix.kind == .reviewEdit && fix.deleted != true && TranscriptWordEdit.isSound(fix, wordCount: words.count)
                    && !turnsHolding(fix.first..<fix.end).isEmpty
            }.sorted { $0.first < $1.first }
            // Edits side by side in one turn ("bull" → "pull", then "requested" → "request") are one span: learned
            // apart, each would take the other's corrected word as what was heard beside it ("pull requested"), and
            // neither rule would match what the recognizer wrote ("bull requested"). Each span keeps the turns holding
            // all of it, narrowed as it grows (only the new words are checked).
            // Only edits that change words are joined: one changing only punctuation or case ("Hello." → "Hello?")
            // beside "cloud" → "Claude" would teach ". cloud" → "? Claude". It is learned on its own (`trivial`), and
            // stands as context as it is now shown.
            var spans: [(fixes: [TranscriptWordFix], owners: [Int])] = []
            for fix in fixes {
                if let last = spans.last, let previous = last.fixes.last, previous.end == fix.first,
                   !trivial(previous), !trivial(fix) {
                    let owners = turnsHolding(fix.first..<fix.end, among: last.owners)
                    if !owners.isEmpty {
                        spans[spans.count - 1].fixes.append(fix)
                        spans[spans.count - 1].owners = owners
                        continue
                    }
                }
                spans.append(([fix], turnsHolding(fix.first..<fix.end)))
            }
            for (span, owners) in spans {
                guard let first = span.first?.first, let end = span.last?.end, let owner = owners.first,
                      let meant = TranscriptWordEdit.shownText(first: first, end: end, words: words, utf16: utf16)
                else { continue }
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
                let before = neighbour(owner: owner, segmentID: segment.id, first: first, end: end, before: true)
                let after = neighbour(owner: owner, segmentID: segment.id, first: first, end: end, before: false)
                edits.append(ReviewWordEdit(heard: heard, meant: shown, before: before?.shown, after: after?.shown,
                                            heardBefore: before?.heard, heardAfter: after?.heard))
            }
        }
        return edits
    }

    /// One segment as learning reads it (`prepare`, once per segment): its words and text, each word's fix, which
    /// turns hold each word, what the recognizer wrote under a fix (`recognized`), and whether an edit changes only
    /// punctuation or case (`trivial`).
    private struct Prepared {
        var words: [EffectiveWord]
        var utf16: [UInt16]
        var fixAt: [Int: TranscriptWordFix]
        var holders: [[Int]]
        var recognized: (TranscriptWordFix, String) -> String?
        var trivial: (TranscriptWordFix) -> Bool

        func holds(_ turn: Int, _ word: Int) -> Bool {
            word >= 0 && word < holders.count && holders[word].contains(turn)
        }
    }

    /// `segment` read for learning; nil when it cannot be trusted (`TranscriptWordEdit.isDamaged`). `baseSegment`: the
    /// same segment of the unfixed revision, where what the recognizer wrote under an automatic fix is read (not when
    /// it cannot be trusted either); `spans`: the turns' spans in it; `readable`: the fix kinds learning reads.
    private static func prepare(_ segment: TranscriptSegment, readable: Set<TranscriptWordFixKind>,
                                baseSegment: TranscriptSegment?,
                                spans: [(turn: Int, span: WordSpan)]) -> Prepared? {
        if TranscriptWordEdit.isDamaged(segment) { return nil }
        let words = WordTiming.effectiveWords(of: segment)
        let utf16 = Array(segment.text.utf16)
        // Where each word boundary is in the unfixed segment, for what the recognizer wrote under a fix.
        let baseSegment = baseSegment.flatMap { TranscriptWordEdit.isDamaged($0) ? nil : $0 }
        let baseWords = baseSegment.map(WordTiming.effectiveWords(of:))
        let baseUTF16 = baseSegment.map { Array($0.text.utf16) } ?? []
        let bounds = baseWords.flatMap {
            TranscriptWordEdit.baseBounds(fixes: segment.fixes ?? [], current: words, base: $0, baseText: baseUTF16)
        }
        /// What the recognizer wrote over `fix`, the same extent its shown text has (`shown`: punctuation the
        /// recognizer did not time included): from the unfixed segment for an automatic fix; else its `heard` when its
        /// shown text is just its words; nil when that cannot be told (no context then).
        let recognized = { (fix: TranscriptWordFix, shown: String) -> String? in
            // A kind a newer version wrote: what its `heard` means is not known here, so it is no provenance.
            guard readable.contains(fix.kind) else { return nil }
            // A deletion's `heard` holds the deleted words too: beside an edit, it would teach dropping them.
            if fix.deleted == true { return nil }
            // A damaged fix (its words out of the segment's) has nothing that can be read.
            guard TranscriptWordEdit.isSound(fix, wordCount: words.count) else { return nil }
            if fix.kind == .correction || fix.kind == .term, let baseWords, let bounds, fix.end < bounds.count,
               bounds[fix.first] >= 0, bounds[fix.end] >= 0 {
                let range = TranscriptWordEdit.extent(of: bounds[fix.first]..<bounds[fix.end], words: baseWords,
                                                      utf16: baseUTF16)
                if !range.isEmpty { return String(decoding: baseUTF16[range], as: UTF16.self) }
            }
            let own = words[fix.first..<fix.end].map(\.text).joined(separator: " ")
            return TranscriptWordEdit.cleaned(own) == TranscriptWordEdit.cleaned(shown)
                ? TranscriptWordEdit.cleaned(fix.heard) : nil
        }
        // Which turns (by index, ascending) hold each word of the segment, read once from the spans (clamped to the
        // words: a span read from disk can hold any numbers), so nothing walks every turn per word.
        var holders = Array(repeating: [Int](), count: words.count)
        for (index, span) in spans {
            let lower = max(span.first, 0), upper = min(span.end, words.count)
            guard lower < upper else { continue }
            for word in lower..<upper where holders[word].last != index { holders[word].append(index) }
        }
        /// A Review edit that changes only punctuation or letter case (`changesOnlyPunctuationOrCase`), its shown text
        /// against what the recognizer wrote.
        let trivial = { (fix: TranscriptWordFix) -> Bool in
            guard fix.kind == .reviewEdit, TranscriptWordEdit.isSound(fix, wordCount: words.count),
                  let shown = TranscriptWordEdit.shownText(first: fix.first, end: fix.end, words: words, utf16: utf16)
            else { return false }
            return TranscriptEditLearning.changesOnlyPunctuationOrCase(heard: fix.heard, meant: shown)
        }
        // Each word's fix (marks never overlap here: `isDamaged`), read once.
        var fixAt: [Int: TranscriptWordFix] = [:]
        for fix in segment.fixes ?? [] where TranscriptWordEdit.isSound(fix, wordCount: words.count) {
            for word in fix.first..<fix.end { fixAt[word] = fix }
        }
        return Prepared(words: words, utf16: utf16, fixAt: fixAt, holders: holders, recognized: recognized,
                        trivial: trivial)
    }

    /// `context`, for word `index` of `segment` in turn `owner`.
    private static func context(_ index: Int, in segment: Prepared, owner: Int) -> (shown: String, heard: String?)? {
        context(index, words: segment.words, utf16: segment.utf16, fixAt: segment.fixAt,
                inTurn: { segment.holds(owner, $0) }, trivial: segment.trivial, recognized: segment.recognized)
    }

    /// Word `index` of `segment` as context, when the edit's own turn holds it (`inTurn`): its shown text, and what the
    /// recognizer wrote there when a fix changed it (`heard`: nil when as shown). A word under a fix (an automatic
    /// correction or term, a live correction) stands with its whole fix: "Claude" shown is "cloud" heard, so a
    /// correction learned beside it matches the recognizer's text ("as cloud" → "ask Claude"). A fix the turn does not
    /// hold all of ("newark" made "New York", split as "as New" / "York") gives no context: part of it has no heard
    /// text of its own, and corrected text never stands for what was heard ("as New" would match nothing). Both sides
    /// cover the same characters (`recognized`): "cloud." for "Claude.", never "cloud" beside "Claude.".
    /// `words` and `utf16`: the segment's, read once; `fixAt`: each word's fix (its marks never overlap). An edit
    /// changing only punctuation or case (`trivial`) stands as it is now shown, on both sides.
    private static func context(_ index: Int, words: [EffectiveWord], utf16: [UInt16], fixAt: [Int: TranscriptWordFix],
                                inTurn: (Int) -> Bool, trivial: (TranscriptWordFix) -> Bool,
                                recognized: (TranscriptWordFix, String) -> String?) -> (shown: String, heard: String?)? {
        guard index >= 0, index < words.count, inTurn(index) else { return nil }
        if let fix = fixAt[index], fix.kind != .reviewRevert {
            // A damaged fix (its words out of the segment's) gives no context.
            guard TranscriptWordEdit.isSound(fix, wordCount: words.count), (fix.first..<fix.end).allSatisfy(inTurn),
                  let whole = TranscriptWordEdit.shownText(first: fix.first, end: fix.end, words: words, utf16: utf16)
            else {
                return nil
            }
            if trivial(fix) { return (TranscriptWordEdit.cleaned(whole), nil) }
            guard let written = recognized(fix, whole) else { return nil }
            let shown = TranscriptWordEdit.cleaned(whole)
            let heard = TranscriptWordEdit.cleaned(written)
            return (shown, heard == shown ? nil : heard)
        }
        guard let shown = TranscriptWordEdit.shownText(first: index, end: index + 1, words: words, utf16: utf16) else {
            return nil
        }
        return (shown, nil)
    }

    /// The corrections `edits` teach (`teach`: the app's rule, `TranscriptEditLearning`), in order, each heard phrase
    /// (`CorrectionList.key`) once: the first edit teaching it, in the meeting's order, gives it. Never one that
    /// replaces what was heard by nothing (words deleted: dictation would drop them everywhere).
    static func corrections(_ edits: [ReviewWordEdit], teach: (ReviewWordEdit) -> [Correction]) -> [Correction] {
        var seen = Set<String>()
        var result: [Correction] = []
        for edit in edits where !edit.deletion && !TranscriptWordEdit.cleaned(edit.meant).isEmpty {
            for correction in teach(edit) {
                let key = CorrectionList.key(correction.heard)
                guard !key.isEmpty, !TranscriptWordEdit.cleaned(correction.meant).isEmpty,
                      seen.insert(key).inserted else { continue }
                result.append(correction)
            }
        }
        return result
    }
}
