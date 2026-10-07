import Foundation
import HolosCore
import HolosSpeakers

/// How a word edit (or its undo) moved a segment's words: `replaced`, word indices before it, became `replacement`;
/// words after them shift by the difference, words before stay. The review's edit field follows its words through
/// these, since a merged or untimed word's time and text may change (docs/meeting-design.md §5.10, "Editing words").
public struct ReviewWordMove: Sendable, Equatable {
    public var segmentID: String
    public var replaced: Range<Int>
    public var replacement: Range<Int>

    public init(segmentID: String, replaced: Range<Int>, replacement: Range<Int>) {
        self.segmentID = segmentID; self.replaced = replaced; self.replacement = replacement
    }

    /// The move undone.
    public var inverse: ReviewWordMove {
        ReviewWordMove(segmentID: segmentID, replaced: replacement, replacement: replaced)
    }

    /// Where `ref` is after the move, and whether it was one of the words replaced (whose text may have changed). A
    /// replaced word goes to the replacement word at the same offset, or its last one.
    public func map(_ ref: WordRef) -> (ref: WordRef, replaced: Bool) {
        guard ref.segmentID == segmentID, ref.word >= replaced.lowerBound else { return (ref, false) }
        if ref.word >= replaced.upperBound {
            return (WordRef(segmentID: segmentID, word: ref.word + replacement.count - replaced.count), false)
        }
        let offset = min(ref.word - replaced.lowerBound, max(0, replacement.count - 1))
        return (WordRef(segmentID: segmentID, word: replacement.lowerBound + offset), true)
    }
}

/// The pure part of editing words in Review (docs/meeting-design.md §5.10, "Editing words"): a run of words of one
/// segment replaced by any text, made both in the current transcript and in the unfixed base it was fixed from, so
/// automatic word fixes made again later keep it. The edit is a word fix of kind `reviewEdit`, whose `heard` is what
/// the recognizer wrote over the whole edited span. Nothing here reads or writes files (`SessionWordEdit` publishes).
public enum TranscriptWordEdit {
    /// Words `[first, end)` of segment `segmentID` (effective word indices, `WordTiming.effectiveWords`) become `text`;
    /// an empty `text` deletes them.
    public struct Request: Sendable, Equatable {
        public var segmentID: String
        public var first: Int
        public var end: Int
        public var text: String

        public init(segmentID: String, first: Int, end: Int, text: String) {
            self.segmentID = segmentID; self.first = first; self.end = end; self.text = text
        }
    }

    public struct Result: Sendable, Equatable {
        /// The new current revision.
        public var transcript: Transcript
        /// The new unfixed revision `transcript.fixedFrom` names, when the edited transcript was a fixed one; nil when
        /// the edited transcript was itself unfixed (then `transcript` is the new unfixed revision).
        public var base: Transcript?
        /// What the recognizer wrote over the edited span (the edit's `heard`).
        public var heard: String
        /// The span's new text.
        public var meant: String
        /// The span's text before the edit, as the review showed it.
        public var shown: String
        /// The words were deleted (merged into a neighbouring word, which `meant` is).
        public var deletion: Bool
        /// The shown words just before and after the span in its segment (learning context), when there are some.
        public var before: String?
        public var after: String?
        /// Where the words moved: the span's word indices in the segment before and after the edit.
        public var move: ReviewWordMove
        /// The whole edited span's move, with the words it took in around the selection (a deletion's neighbour, the
        /// rest of a mark): every one of them is in the edited turn and its replacement is never empty, so the speaker
        /// labels map by it, and by its inverse when the edit is undone (`SpeakerTranscriptRetarget.plan`).
        public var labelsMove: ReviewWordMove
        /// `heard` holds deleted words (this edit is a deletion, or it took in an earlier one: "um cloud" for a word
        /// "um" was merged into): it is not what the recognizer wrote for the new text, so it is never offered as
        /// "often heard as".
        public var holdsDeleted = false
    }

    /// Whether `transcript` holds words edited in Review.
    public static func hasReviewEdits(_ transcript: Transcript) -> Bool {
        transcript.segments.contains { ($0.fixes ?? []).contains { $0.kind == .reviewEdit } }
    }

    /// `text` trimmed, each run of whitespace one space.
    public static func cleaned(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The edit made on `current`, whose `fixedFrom` revision is `base` (nil when `current` has none). `editable` says
    /// which word indices of the segment the edit may take in: a deletion is merged into the next such word (else the
    /// previous one), and the span grows to whole word-fix marks; every word it ends up with must be editable. Nil when
    /// the text would not change. Throws `invalidInput` with a message for the person when the edit cannot be made.
    public static func editing(_ request: Request, in current: Transcript, base: Transcript?,
                               editable: (Int) -> Bool = { _ in true }, now: Date = Date()) throws -> Result? {
        let text = cleaned(request.text)
        guard let index = current.segments.firstIndex(where: { $0.id == request.segmentID }) else {
            throw HolosError.invalidInput("Those words are no longer in the transcript; reload and try again.")
        }
        let segment = current.segments[index]
        let words = WordTiming.effectiveWords(of: segment)
        guard request.first >= 0, request.first < request.end, request.end <= words.count else {
            throw HolosError.invalidInput("Those words are no longer in the transcript; reload and try again.")
        }
        guard (request.first..<request.end).allSatisfy(editable) else { throw notShown }
        // A damaged mark (empty, backwards, or past the segment's words) is never walked: the segment is not edited.
        if isDamaged(segment) { throw damagedMarks }
        guard var working = WordFixes.Working(segment, preservingExistingFixes: true) else {
            throw damagedMarks
        }
        let fixes = segment.fixes ?? []
        /// `lower..<upper` with every fix mark it touches taken in (a mark is never split); nil when that runs out of
        /// the words or onto a word the edited turn does not show. Marks are sound here (`isDamaged`).
        func takingInMarks(_ lower: Int, _ upper: Int) -> (lower: Int, upper: Int)? {
            var lower = lower, upper = upper, grew = true
            while grew {
                grew = false
                for fix in fixes where fix.first < upper && lower < fix.end {
                    if fix.first < lower { lower = fix.first; grew = true }
                    if fix.end > upper { upper = fix.end; grew = true }
                }
            }
            guard lower >= 0, upper <= words.count, (lower..<upper).allSatisfy(editable) else { return nil }
            return (lower, upper)
        }
        var lower = request.first
        var upper = request.end
        let deletion = text.isEmpty
        if deletion {
            // The deleted words go into a neighbour of the same turn, which keeps their time and provenance. Each
            // neighbour is judged with the marks it would take in: one whose mark runs out of the turn cannot take
            // them, nor one corrected while recording (it cannot be edited here), so the other one does.
            let liveCorrected = { (span: (lower: Int, upper: Int)) in
                fixes.contains { $0.kind == .liveCorrection && $0.first < span.upper && span.lower < $0.end }
            }
            let next = upper < words.count && editable(upper) ? takingInMarks(lower, upper + 1) : nil
            let previous = lower > 0 && editable(lower - 1) ? takingInMarks(lower - 1, upper) : nil
            let hasNeighbour = (upper < words.count && editable(upper)) || (lower > 0 && editable(lower - 1))
            if let next, !liveCorrected(next) {
                (lower, upper) = next
            } else if let previous, !liveCorrected(previous) {
                (lower, upper) = previous
            } else if let carrier = next ?? previous {
                (lower, upper) = carrier
            } else if hasNeighbour {
                throw notShown
            } else if words.count == request.end - request.first {
                throw HolosError.invalidInput("A segment cannot lose all its words yet; leave at least one word.")
            } else {
                throw HolosError.invalidInput("These words can be deleted only with a word beside them in the same "
                                              + "turn; change them instead.")
            }
        }
        // A mark is never split: the span takes in every fix it touches.
        guard let taken = takingInMarks(lower, upper) else { throw notShown }
        (lower, upper) = taken
        let touched = fixes.filter { $0.first < upper && lower < $0.end }
        if touched.contains(where: { $0.kind == .liveCorrection }) { throw liveCorrected }
        guard touched.allSatisfy({ [.correction, .term, .reviewRevert, .reviewEdit].contains($0.kind) }) else {
            throw HolosError.invalidInput("These words were changed by a newer Voice is Local and cannot be edited here.")
        }

        let utf16 = Array(segment.text.utf16)
        func characters(_ words: [EffectiveWord], _ range: Range<Int>) -> Range<Int> {
            extent(of: range, words: words, utf16: utf16)
        }
        func string(_ range: Range<Int>) -> String { String(decoding: utf16[range], as: UTF16.self) }
        let span = characters(words, lower..<upper)
        let selected = characters(words, request.first..<request.end)
        guard span.lowerBound >= 0, span.upperBound <= utf16.count, span.lowerBound <= selected.lowerBound,
              selected.upperBound <= span.upperBound else {
            throw damagedMarks
        }
        let meant = cleaned(string(span.lowerBound..<selected.lowerBound) + (deletion ? " " : text)
            + string(selected.upperBound..<span.upperBound))
        let shown = string(span)
        guard meant != cleaned(shown), !meant.isEmpty else { return nil }

        // What the recognizer wrote, as the text had it (a Revert writes it back): unmarked words and a Review revert's
        // words (the recognizer's, restored) as shown, an automatic fix the recognizer's words it replaced, an earlier
        // edit its `heard`, and between them the text that is there. How many recognizer words that is goes with it
        // (`heardWords`): text with no space between words ("你好世界") or with punctuation of its own ("—") does not
        // say.
        // An automatic fix's `heard` is only the phrase it matched: the recognizer's words around it in the base
        // (their punctuation, "cloud." for "Claude.") are what it wrote there.
        let baseSegment = base.flatMap { base in
            base.id == current.fixedFrom ? base.segments.first { $0.id == segment.id } : nil
        }
        // The unfixed revision is written too: one that cannot be trusted is never edited, nor read from.
        if let baseSegment, isDamaged(baseSegment) { throw damagedMarks }
        let baseWords = baseSegment.map(WordTiming.effectiveWords(of:))
        let bounds = baseWords.flatMap { baseBounds(fixes: fixes, current: words, base: $0) }
        /// A fix's `heard` with its recognizer words (`heardWordCount`; a damaged count is refused, never added up).
        func recorded(_ fix: TranscriptWordFix) throws -> (text: String, words: Int) {
            guard let count = fix.heardWordCount() else { throw damagedMarks }
            return (fix.heard, count)
        }
        func automatic(_ fix: TranscriptWordFix) throws -> (text: String, words: Int) {
            guard let baseSegment, let baseWords, let bounds, bounds[fix.first] >= 0, bounds[fix.end] >= 0 else {
                return try recorded(fix)
            }
            let range = extent(of: bounds[fix.first]..<bounds[fix.end], words: baseWords,
                               utf16: Array(baseSegment.text.utf16))
            guard !range.isEmpty else { return try recorded(fix) }
            return (String(decoding: Array(baseSegment.text.utf16)[range], as: UTF16.self),
                    bounds[fix.end] - bounds[fix.first])
        }
        var written = ""
        var heardWords = 0
        var previousEnd: Int?
        var word = lower
        while word < upper {
            let piece: Range<Int>
            let recognized: (text: String, words: Int)
            if let fix = touched.first(where: { $0.first == word }) {
                piece = fix.first..<fix.end
                switch fix.kind {
                case .reviewRevert: recognized = (string(characters(words, piece)), piece.count)
                case .correction, .term: recognized = try automatic(fix)
                default: recognized = try recorded(fix)
                }
            } else {
                piece = word..<(touched.map(\.first).filter { $0 > word }.min() ?? upper)
                recognized = (string(characters(words, piece)), piece.count)
            }
            let extent = characters(words, piece)
            if let previousEnd {
                written += previousEnd <= extent.lowerBound ? string(previousEnd..<extent.lowerBound) : " "
            }
            written += recognized.text
            heardWords += recognized.words
            previousEnd = extent.upperBound
            word = piece.upperBound
        }
        let heard = cleaned(written)
        guard !heard.isEmpty, heardWords > 0 else {
            throw damagedMarks
        }

        // A deletion teaches nothing (its `heard` holds the deleted words with the neighbour they merged into), nor
        // does an edit taking in one: the deleted words' heard text cannot be told apart from the rest.
        let deleted = deletion || touched.contains { $0.kind == .reviewEdit && $0.deleted == true } ? true : nil
        working.marks.removeAll { $0.range.overlaps(span) }
        let edited = WordFixes.applying([.init(range: span, text: meant, kind: .reviewEdit, heard: heard,
                                               heardWords: heardWords, deleted: deleted)], to: working)
        guard edited.text != working.text || edited.marks != working.marks else { return nil }

        var result = current
        result.id = UUID().uuidString
        result.createdAt = now
        result.segments[index] = WordFixes.finished(edited, segment: segment)
        // How the words moved. The words the span took in around the selection (the rest of a fix, a deletion's
        // neighbour) are written again as they were, so only the selected words count as replaced; the others keep
        // their own place (in "New York", "York" stays "York" when "New" becomes "Greater New").
        let newCount = WordTiming.effectiveWords(of: result.segments[index]).count - (words.count - (upper - lower))
        let prefix = request.first - lower
        let suffix = upper - request.end
        let selectedCount = newCount - prefix - suffix
        let keptAround = selectedCount >= 0
            && WordFixes.tokens(of: Array(string(span.lowerBound..<selected.lowerBound).utf16)).count == prefix
            && WordFixes.tokens(of: Array(string(selected.upperBound..<span.upperBound).utf16)).count == suffix
        let labelsMove = ReviewWordMove(segmentID: segment.id, replaced: lower..<upper,
                                        replacement: lower..<(lower + max(0, newCount)))
        let move = keptAround
            ? ReviewWordMove(segmentID: segment.id, replaced: request.first..<request.end,
                             replacement: request.first..<(request.first + selectedCount))
            : labelsMove
        var newBase: Transcript?
        if let baseID = current.fixedFrom {
            guard let base, base.id == baseID else {
                throw HolosError.invalidInput("The transcript the words were fixed from cannot be read.")
            }
            let edited = try editingBase(base, segment: segment, words: words, span: lower..<upper, meant: meant,
                                         heard: heard, heardWords: heardWords, deleted: deleted, now: now)
            newBase = edited
            result.fixedFrom = edited.id
            result.liveCorrectedFrom = edited.liveCorrectedFrom
        } else {
            result.liveCorrectedFrom = current.liveCorrectedFrom ?? current.id
        }
        return Result(transcript: result, base: newBase, heard: heard, meant: meant, shown: shown, deletion: deletion,
                      before: lower > 0 && editable(lower - 1) ? words[lower - 1].text : nil,
                      after: upper < words.count && editable(upper) ? words[upper].text : nil, move: move,
                      labelsMove: labelsMove, holdsDeleted: deleted == true)
    }

    /// The text words `range` of a segment show, as the review and the exports show it (`TranscriptText`): from the
    /// first word's offset (the text's start for the segment's first word) to the next word's offset (the text's end
    /// after its last word), without the whitespace at either end. So a word's punctuation that the recognizer did
    /// not time ("Hello" in "Hello.") goes with it, and the space a recognizer puts at the front of a word's range
    /// (Apple's " cloud") stays where it is when the words are replaced.
    static func extent(of range: Range<Int>, words: [EffectiveWord], utf16: [UInt16]) -> Range<Int> {
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound, range.upperBound <= words.count else {
            return 0..<0
        }
        var lower = range.lowerBound == 0 ? 0 : words[range.lowerBound].utf16Offset
        var upper = range.upperBound == words.count ? utf16.count : words[range.upperBound].utf16Offset
        // Offsets that do not fit the text: the words' own ranges (none when they do not fit either: never added up).
        if lower < 0 || upper > utf16.count || lower >= upper {
            guard let first = words[range.lowerBound].utf16Range(within: utf16.count),
                  let last = words[range.upperBound - 1].utf16Range(within: utf16.count) else { return 0..<0 }
            lower = first.lowerBound
            upper = last.upperBound
        }
        guard lower >= 0, lower <= upper, upper <= utf16.count else { return 0..<0 }
        func isSpace(_ unit: UInt16) -> Bool {
            Unicode.Scalar(unit).map { Character($0).isWhitespace } ?? false
        }
        while lower < upper, isSpace(utf16[lower]) { lower += 1 }
        while upper > lower, isSpace(utf16[upper - 1]) { upper -= 1 }
        return lower..<upper
    }

    /// The text words `[first, end)` of `segment` show (`extent`): what an edit field over them starts with.
    public static func shownText(of segment: TranscriptSegment, first: Int, end: Int) -> String? {
        let words = WordTiming.effectiveWords(of: segment)
        guard first >= 0, first < end, end <= words.count else { return nil }
        let utf16 = Array(segment.text.utf16)
        let range = extent(of: first..<end, words: words, utf16: utf16)
        guard !range.isEmpty else { return nil }
        return String(decoding: utf16[range], as: UTF16.self)
    }

    /// A copy of `previous` to make current again (undoing an edit): the same segments, words, and fixes, a new ID. A
    /// transcript that was its own word space keeps naming it, so speaker labels map back by word provenance.
    public static func restoring(_ previous: Transcript, now: Date = Date()) -> Transcript {
        var copy = previous
        copy.id = UUID().uuidString
        copy.createdAt = now
        if copy.fixedFrom == nil, copy.liveCorrectedFrom == nil { copy.liveCorrectedFrom = previous.id }
        return copy
    }

    /// Whether `fix` covers words a segment of `wordCount` effective words has (0 ≤ first < end ≤ wordCount). The one
    /// check every walk over a fix's words makes first: a damaged but decodable transcript can hold any numbers.
    /// A recorded `heardWords` must be right too (`heardWordCount`): one that is not is damaged the same way.
    public static func isSound(_ fix: TranscriptWordFix, wordCount: Int) -> Bool {
        fix.first >= 0 && fix.first < fix.end && fix.end <= wordCount
            && (fix.heardWords == nil || fix.heardWordCount() != nil)
    }

    /// Whether `segment`, as read from disk, cannot be trusted: none of its words is edited, none of its fixes reverted
    /// (`damagedMarks`), and close-time learning skips it. Damaged are:
    /// - a word whose range does not fit the text, or starts before the previous one ends (`utf16Range`);
    /// - a fix mark that is not sound (`isSound`), since every edit takes in the marks it touches;
    /// - two marks over the same word: each word has at most one fix (a fix never overlaps another), and an edit or a
    ///   mapping reading either would take the wrong one.
    public static func isDamaged(_ segment: TranscriptSegment) -> Bool {
        let words = WordTiming.effectiveWords(of: segment)
        let length = segment.text.utf16.count
        var previousEnd = 0
        for word in words {
            guard let range = word.utf16Range(within: length), range.lowerBound >= previousEnd else { return true }
            previousEnd = range.upperBound
        }
        guard let fixes = segment.fixes, !fixes.isEmpty else { return false }
        let count = words.count
        if fixes.contains(where: { !isSound($0, wordCount: count) }) { return true }
        let ordered = fixes.sorted { ($0.first, $0.end) < ($1.first, $1.end) }
        return zip(ordered, ordered.dropFirst()).contains { previous, next in next.first < previous.end }
    }

    /// An edit refused because its segment's word positions or fix marks are damaged.
    public static let damagedMarks = HolosError.invalidInput("That segment's word positions cannot be edited safely.")

    /// `segment` has an automatic fix saved by an earlier version (without `heardWords`) that cannot be counted against
    /// its unfixed `base`: every edit in it is refused (`olderFix`).
    public static func blockedByOlderFix(_ segment: TranscriptSegment, base: TranscriptSegment) -> Bool {
        let fixes = segment.fixes ?? []
        guard fixes.contains(where: { ($0.kind == .correction || $0.kind == .term) && $0.heardWords == nil }) else {
            return false
        }
        return baseBounds(fixes: fixes, current: WordTiming.effectiveWords(of: segment),
                          base: WordTiming.effectiveWords(of: base)) == nil
    }

    /// An edit refused because its words do not all belong to the same speaker turns (turns that overlap hold some of
    /// them): its new words would belong to every turn of every word it replaced, and its undo could not give each
    /// word back to its own turns.
    public static let overlappingTurns = HolosError.invalidInput(
        "These words belong to overlapping speaker turns, so they cannot be edited together here yet; edit words that "
            + "belong to the same turns.")

    /// Each of `words` (word indices of segment `segmentID`) belongs to the same turns (`turns`: their word spans).
    public static func sameOwners(_ words: some Collection<Int>, segmentID: String, turns: [[WordSpan]]) -> Bool {
        let owners = words.map { word in
            Set(turns.indices.filter { index in
                turns[index].contains { $0.segmentID == segmentID && $0.first <= word && word < $0.end }
            })
        }
        return Set(owners).count <= 1
    }

    /// An edit refused because it takes in words corrected while the meeting was recording (`liveCorrection`, whose live
    /// hint would no longer match).
    public static let liveCorrected = HolosError.invalidInput(
        "Words corrected while the meeting was recording cannot be edited here yet.")

    /// An edit refused because its segment has an automatic word fix saved by an earlier version whose replaced words
    /// cannot be told (docs/meeting-design.md §5.10, "Editing words").
    public static let olderFix = HolosError.invalidInput(
        "This segment has a word fix made by an earlier version of Voice is Local, which edits cannot work around yet. "
            + "Its words were not changed.")

    private static let notShown = HolosError.invalidInput(
        "Only words shown in one turn can be edited together; some of these are hidden (echo) or in another turn.")

    /// `base` with the same edit, made on the words the current segment's span stands for there.
    private static func editingBase(_ base: Transcript, segment: TranscriptSegment, words: [EffectiveWord],
                                    span: Range<Int>, meant: String, heard: String, heardWords: Int?, deleted: Bool?,
                                    now: Date) throws -> Transcript {
        guard let index = base.segments.firstIndex(where: { $0.id == segment.id }),
              let bounds = baseBounds(fixes: segment.fixes ?? [], current: words,
                                      base: WordTiming.effectiveWords(of: base.segments[index])) else {
            // An automatic fix saved by an earlier version, without the count of words it replaced, is counted by the
            // spaces in what was heard: wrong for text without spaces between its words ("你好世界").
            let older = (segment.fixes ?? []).contains {
                ($0.kind == .correction || $0.kind == .term) && $0.heardWords == nil
            }
            throw older ? olderFix
                : HolosError.invalidInput("These words cannot be matched to the transcript they were fixed from.")
        }
        let baseSegment = base.segments[index]
        let baseWords = WordTiming.effectiveWords(of: baseSegment)
        let first = bounds[span.lowerBound]
        let end = bounds[span.upperBound]
        guard first >= 0, first < end, end <= baseWords.count,
              var working = WordFixes.Working(baseSegment, preservingExistingFixes: true) else {
            throw HolosError.invalidInput("These words cannot be matched to the transcript they were fixed from.")
        }
        // As in the current transcript: the words' shown text, its boundary whitespace left where it is.
        let range = extent(of: first..<end, words: baseWords, utf16: Array(baseSegment.text.utf16))
        guard !range.isEmpty else {
            throw HolosError.invalidInput("These words cannot be matched to the transcript they were fixed from.")
        }
        working.marks.removeAll { $0.range.overlaps(range) }
        let edited = WordFixes.applying([.init(range: range, text: meant, kind: .reviewEdit, heard: heard,
                                               heardWords: heardWords, deleted: deleted)], to: working)
        var result = base
        result.id = UUID().uuidString
        result.createdAt = now
        result.fixedFrom = nil
        result.liveCorrectedFrom = base.liveCorrectedFrom ?? base.id
        result.segments[index] = WordFixes.finished(edited, segment: baseSegment)
        return result
    }

    /// For each word boundary `0...current.count` of a fixed segment, the boundary in its unfixed `base` segment; -1
    /// inside a mark. An automatic fix took `heardWordCount` base words; a Review revert, a live correction, and a
    /// Review edit occupy their own words in the base too. Nil when the unmarked words do not match.
    static func baseBounds(fixes: [TranscriptWordFix], current: [EffectiveWord], base: [EffectiveWord]) -> [Int]? {
        var bounds = Array(repeating: -1, count: current.count + 1)
        var word = 0
        var baseWord = 0
        func unchanged(upTo end: Int) -> Bool {
            while word < end {
                guard baseWord < base.count, current[word].text == base[baseWord].text else { return false }
                bounds[word] = baseWord
                word += 1
                baseWord += 1
            }
            return true
        }
        for fix in fixes.sorted(by: { ($0.first, $0.end) < ($1.first, $1.end) }) {
            guard fix.first >= word, fix.first < fix.end, fix.end <= current.count, unchanged(upTo: fix.first) else {
                return nil
            }
            bounds[fix.first] = baseWord
            // At most the base words left (`baseWord` <= `base.count` here), compared without adding.
            let left = base.count - baseWord
            let count: Int
            switch fix.kind {
            case .correction, .term:
                guard let heard = fix.heardWordCount(within: left) else { return nil }
                count = heard
            case .reviewRevert, .liveCorrection, .reviewEdit: count = fix.end - fix.first
            default: return nil
            }
            guard count > 0, count <= left else { return nil }
            baseWord += count
            word = fix.end
        }
        guard unchanged(upTo: current.count), baseWord == base.count else { return nil }
        bounds[current.count] = baseWord
        return bounds
    }
}
