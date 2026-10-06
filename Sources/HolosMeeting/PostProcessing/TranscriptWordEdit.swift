import Foundation
import HolosCore
import HolosSpeakers

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
        guard var working = WordFixes.Working(segment, preservingExistingFixes: true) else {
            throw HolosError.invalidInput("That segment's word positions cannot be edited safely.")
        }
        let fixes = segment.fixes ?? []
        var lower = request.first
        var upper = request.end
        let deletion = text.isEmpty
        if deletion {
            // The deleted words go into a neighbour of the same turn, which keeps their time and provenance.
            if upper < words.count, editable(upper) {
                upper += 1
            } else if lower > 0, editable(lower - 1) {
                lower -= 1
            } else if words.count == request.end - request.first {
                throw HolosError.invalidInput("A segment cannot lose all its words yet; leave at least one word.")
            } else {
                throw HolosError.invalidInput("These words can be deleted only with a word beside them in the same "
                                              + "turn; change them instead.")
            }
        }
        // A mark is never split: the span takes in every fix it touches.
        var grew = true
        while grew {
            grew = false
            for fix in fixes where fix.first < upper && lower < fix.end {
                if fix.first < lower { lower = fix.first; grew = true }
                if fix.end > upper { upper = fix.end; grew = true }
            }
        }
        guard lower >= 0, upper <= words.count, (lower..<upper).allSatisfy(editable) else { throw notShown }
        let touched = fixes.filter { $0.first < upper && lower < $0.end }
        if touched.contains(where: { $0.kind == .liveCorrection }) {
            throw HolosError.invalidInput("Words corrected while the meeting was recording cannot be edited here yet.")
        }
        guard touched.allSatisfy({ [.correction, .term, .reviewRevert, .reviewEdit].contains($0.kind) }) else {
            throw HolosError.invalidInput("These words were changed by a newer Voice is Local and cannot be edited here.")
        }

        let utf16 = Array(segment.text.utf16)
        func characters(_ words: [EffectiveWord], _ range: Range<Int>) -> Range<Int> {
            words[range.lowerBound].utf16Offset..<(words[range.upperBound - 1].utf16Offset
                + words[range.upperBound - 1].utf16Length)
        }
        func string(_ range: Range<Int>) -> String { String(decoding: utf16[range], as: UTF16.self) }
        let span = characters(words, lower..<upper)
        let selected = characters(words, request.first..<request.end)
        guard span.lowerBound >= 0, span.upperBound <= utf16.count, span.lowerBound <= selected.lowerBound,
              selected.upperBound <= span.upperBound else {
            throw HolosError.invalidInput("That segment's word positions cannot be edited safely.")
        }
        let meant = cleaned(string(span.lowerBound..<selected.lowerBound) + (deletion ? " " : text)
            + string(selected.upperBound..<span.upperBound))
        let shown = string(span)
        guard meant != shown, !meant.isEmpty else { return nil }

        // What the recognizer wrote: unmarked words as they are, an automatic fix or an earlier edit its `heard`, and
        // a Review revert its own words (the recognizer's, restored).
        func recognized(_ range: Range<Int>) -> String {
            let text = string(characters(words, range))
            return WordFixes.tokens(of: Array(text.utf16)).count == range.count
                ? text : words[range].map(\.text).joined(separator: " ")
        }
        var pieces: [String] = []
        var word = lower
        while word < upper {
            if let fix = touched.first(where: { $0.first == word }) {
                pieces.append(fix.kind == .reviewRevert ? recognized(fix.first..<fix.end) : fix.heard)
                word = fix.end
            } else {
                let next = touched.map(\.first).filter { $0 > word }.min() ?? upper
                pieces.append(recognized(word..<next))
                word = next
            }
        }
        let heard = cleaned(pieces.joined(separator: " "))
        guard !heard.isEmpty else {
            throw HolosError.invalidInput("That segment's word positions cannot be edited safely.")
        }

        working.marks.removeAll { $0.range.overlaps(span) }
        let edited = WordFixes.applying([.init(range: span, text: meant, kind: .reviewEdit, heard: heard)], to: working)
        guard edited.text != working.text || edited.marks != working.marks else { return nil }

        var result = current
        result.id = UUID().uuidString
        result.createdAt = now
        result.segments[index] = WordFixes.finished(edited, segment: segment)
        var newBase: Transcript?
        if let baseID = current.fixedFrom {
            guard let base, base.id == baseID else {
                throw HolosError.invalidInput("The transcript the words were fixed from cannot be read.")
            }
            let edited = try editingBase(base, segment: segment, words: words, span: lower..<upper, meant: meant,
                                         heard: heard, now: now)
            newBase = edited
            result.fixedFrom = edited.id
            result.liveCorrectedFrom = edited.liveCorrectedFrom
        } else {
            result.liveCorrectedFrom = current.liveCorrectedFrom ?? current.id
        }
        return Result(transcript: result, base: newBase, heard: heard, meant: meant, shown: shown, deletion: deletion,
                      before: lower > 0 && editable(lower - 1) ? words[lower - 1].text : nil,
                      after: upper < words.count && editable(upper) ? words[upper].text : nil)
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

    private static let notShown = HolosError.invalidInput(
        "Only words shown in one turn can be edited together; some of these are hidden (echo) or in another turn.")

    /// `base` with the same edit, made on the words the current segment's span stands for there.
    private static func editingBase(_ base: Transcript, segment: TranscriptSegment, words: [EffectiveWord],
                                    span: Range<Int>, meant: String, heard: String, now: Date) throws -> Transcript {
        guard let index = base.segments.firstIndex(where: { $0.id == segment.id }),
              let bounds = baseBounds(fixes: segment.fixes ?? [], current: words,
                                      base: WordTiming.effectiveWords(of: base.segments[index])) else {
            throw HolosError.invalidInput("These words cannot be matched to the transcript they were fixed from.")
        }
        let baseSegment = base.segments[index]
        let baseWords = WordTiming.effectiveWords(of: baseSegment)
        let first = bounds[span.lowerBound]
        let end = bounds[span.upperBound]
        guard first >= 0, first < end, end <= baseWords.count,
              var working = WordFixes.Working(baseSegment, preservingExistingFixes: true) else {
            throw HolosError.invalidInput("These words cannot be matched to the transcript they were fixed from.")
        }
        let range = baseWords[first].utf16Offset..<(baseWords[end - 1].utf16Offset + baseWords[end - 1].utf16Length)
        working.marks.removeAll { $0.range.overlaps(range) }
        let edited = WordFixes.applying([.init(range: range, text: meant, kind: .reviewEdit, heard: heard)],
                                        to: working)
        var result = base
        result.id = UUID().uuidString
        result.createdAt = now
        result.fixedFrom = nil
        result.liveCorrectedFrom = base.liveCorrectedFrom ?? base.id
        result.segments[index] = WordFixes.finished(edited, segment: baseSegment)
        return result
    }

    /// For each word boundary `0...current.count` of a fixed segment, the boundary in its unfixed `base` segment; -1
    /// inside a mark. An automatic fix took `tokens(heard)` base words; a Review revert, a live correction, and a Review
    /// edit occupy their own words in the base too. Nil when the unmarked words do not match.
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
            let count: Int
            switch fix.kind {
            case .correction, .term: count = WordFixes.tokens(of: Array(fix.heard.utf16)).count
            case .reviewRevert, .liveCorrection, .reviewEdit: count = fix.end - fix.first
            default: return nil
            }
            guard count > 0, baseWord + count <= base.count else { return nil }
            baseWord += count
            word = fix.end
        }
        guard unchanged(upTo: current.count), baseWord == base.count else { return nil }
        bounds[current.count] = baseWord
        return bounds
    }
}
