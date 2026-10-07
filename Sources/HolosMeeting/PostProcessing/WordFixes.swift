import Foundation
import HolosCore
import HolosSpeakers

/// The pure part of the meeting word-fix stage (`WordFixStage`, docs/design.md "Meeting word fixes"): replacing
/// phrases of a segment's text while its words keep their times. A replaced phrase takes the time span of the words it
/// replaced, its new words share that span evenly, and every other word keeps its time; the segment keeps its ID,
/// start and end, so speaker turns and exports find it as before. Each change is marked (`TranscriptSegment.fixes`)
/// with what the recognizer wrote there, so the review can show it.
/// A word's UTF-16 range in its segment's text, read from disk: the one way it is made. Nil when it does not fit a text
/// of `textLength` units (negative, or past the end): checked by subtraction, so no damaged offset or length can
/// overflow, and no range is ever made backwards (which would trap).
func utf16Range(offset: Int, length: Int, within textLength: Int) -> Range<Int>? {
    guard offset >= 0, length >= 0, offset <= textLength, length <= textLength - offset else { return nil }
    return offset..<(offset + length)
}

extension EffectiveWord {
    /// `utf16Range(offset:length:within:)` of this word.
    func utf16Range(within textLength: Int) -> Range<Int>? {
        HolosMeeting.utf16Range(offset: utf16Offset, length: utf16Length, within: textLength)
    }
}

extension TimedWord {
    /// `utf16Range(offset:length:within:)` of this word.
    func utf16Range(within textLength: Int) -> Range<Int>? {
        HolosMeeting.utf16Range(offset: utf16Offset, length: utf16Length, within: textLength)
    }
}

extension TranscriptWordFix {
    /// How many recognizer words `heard` stands for: `heardWords`, recorded on every fix written from this version on;
    /// for an older fix without it, `heard`'s whitespace-separated tokens (wrong for text without spaces between its
    /// words, "你好世界" over two timed words: such a fix cannot be edited around, `TranscriptWordEdit.olderFix`).
    ///
    /// The one way it is read: nil when it cannot be right (not positive; more words than `heard` has characters, as
    /// each recognizer word gives it at least one; more than `available`, the recognizer words left where it stands),
    /// so no arithmetic is ever made on a damaged count. A fix whose recorded count is not right is not sound
    /// (`TranscriptWordEdit.isSound`).
    func heardWordCount(within available: Int = .max) -> Int? {
        let count: Int
        if let heardWords {
            guard heardWords <= heard.utf16.count else { return nil }
            count = heardWords
        } else {
            count = WordFixes.tokens(of: Array(heard.utf16)).count
        }
        return count > 0 && count <= available ? count : nil
    }
}

public enum WordFixes {
    /// One replacement in a segment's text.
    public struct Replacement: Sendable, Equatable {
        /// UTF-16 range of the text replaced.
        public var range: Range<Int>
        /// What goes there.
        public var text: String
        public var kind: TranscriptWordFixKind
        /// Provenance to record instead of the text currently in `range`. Live edit chains use this to collapse
        /// A→B→C into one A→C mark even when recovery starts from the intermediate B.
        public var heard: String?
        /// `TranscriptWordFix.heardWords` for the mark.
        public var heardWords: Int?
        /// The timed words of `text` (offsets from its start), used as they are instead of splitting `text` at its
        /// spaces: a revert restores the recognizer's own words ("你好" and "世界" in "你好世界").
        public var words: [TimedWord]?
        /// `TranscriptWordFix.deleted` for the mark.
        public var deleted: Bool?

        public init(range: Range<Int>, text: String, kind: TranscriptWordFixKind, heard: String? = nil,
                    heardWords: Int? = nil, words: [TimedWord]? = nil, deleted: Bool? = nil) {
            self.range = range; self.text = text; self.kind = kind; self.heard = heard; self.heardWords = heardWords
            self.words = words; self.deleted = deleted
        }
    }

    /// A segment while it is being fixed: its text, its timed words (none for an untimed segment), and the fixes made
    /// so far as UTF-16 ranges of the text.
    public struct Working: Sendable, Equatable {
        public var text: String
        public var words: [TimedWord]
        public var marks: [Mark]

        public struct Mark: Sendable, Equatable {
            /// UTF-16 range of the new text.
            public var range: Range<Int>
            /// What the recognizer wrote there.
            public var heard: String
            public var kind: TranscriptWordFixKind
            /// `TranscriptWordFix.heardWords`.
            public var heardWords: Int? = nil
            /// `TranscriptWordFix.deleted`.
            public var deleted: Bool? = nil
        }

        public init(text: String, words: [TimedWord], marks: [Mark] = []) {
            self.text = text; self.words = words; self.marks = marks
        }

        /// Nil when the segment's word offsets do not fit its text (they decrease, overlap, or run past it): such a
        /// segment is left as it is rather than fixed in the wrong place.
        public init?(_ segment: TranscriptSegment, preservingExistingFixes: Bool = false) {
            text = segment.text
            words = segment.words
            marks = []
            let length = segment.text.utf16.count
            var previousEnd = 0
            for word in words {
                guard let range = word.utf16Range(within: length), range.lowerBound >= previousEnd else { return nil }
                previousEnd = range.upperBound
            }
            if preservingExistingFixes {
                let effective = WordTiming.effectiveWords(of: segment)
                for fix in segment.fixes ?? [] {
                    guard let range = WordFixes.characterRange(of: fix, words: effective,
                                                               textLength: segment.text.utf16.count) else {
                        return nil
                    }
                    marks.append(Mark(range: range, heard: fix.heard, kind: fix.kind, heardWords: fix.heardWords,
                                      deleted: fix.deleted))
                }
            }
        }
    }

    /// The learned corrections' replacements in `working` (`CorrectionList.matches`: whole words and phrases, any case
    /// and spacing, a capital the sentence gave carried over), as dictation applies them.
    public static func corrections(in working: Working, list: CorrectionList) -> [Replacement] {
        list.matches(in: working.text).map {
            Replacement(range: $0.range.location..<($0.range.location + $0.range.length), text: $0.meant,
                        kind: .correction)
        }
    }

    /// `working` with `replacements` made. A replacement must cover part of at least one word; it takes the whole
    /// words it touches (in a timed segment), whose time span its new words share evenly. One that touches no word,
    /// overlaps an earlier replacement, or touches a fix already made is left out. Only a live correction may be
    /// empty: that is one piece of a nonempty correction distributed across a replay segment boundary.
    public static func applying(_ replacements: [Replacement], to working: Working) -> Working {
        let utf16 = Array(working.text.utf16)
        let timed = !working.words.isEmpty
        // The UTF-16 ranges of the words: the timed words', or the text's whitespace-separated tokens.
        let wordRanges: [Range<Int>] = timed
            ? working.words.map { $0.utf16Offset..<($0.utf16Offset + $0.utf16Length) }
            : tokens(of: utf16)
        struct Region {
            var range: Range<Int>
            var words: Range<Int>
            var replacement: Replacement
        }
        var regions: [Region] = []
        // In text order; of two starting at one place, the one given first.
        let ordered = replacements.enumerated().sorted {
            ($0.element.range.lowerBound, $0.offset) < ($1.element.range.lowerBound, $1.offset)
        }.map(\.element)
        for replacement in ordered {
            let range = replacement.range
            guard range.lowerBound >= 0, range.upperBound <= utf16.count, !range.isEmpty,
                  replacement.kind == .liveCorrection
                    || replacement.text.contains(where: { !$0.isWhitespace }) else { continue }
            let touched = wordRanges.indices.filter { wordRanges[$0].overlaps(range) }
            guard let first = touched.first, let last = touched.last else { continue }
            // A timed segment's replaced words are replaced whole; an untimed one's text is replaced as matched.
            let region = timed
                ? min(range.lowerBound, wordRanges[first].lowerBound)..<max(range.upperBound, wordRanges[last].upperBound)
                : range
            guard regions.last.map({ $0.range.upperBound <= region.lowerBound }) ?? true,
                  !working.marks.contains(where: { $0.range.overlaps(region) }) else { continue }
            regions.append(Region(range: region, words: first..<(last + 1), replacement: replacement))
        }
        guard !regions.isEmpty else { return working }

        var text: [UInt16] = []
        var words: [TimedWord] = []
        var marks: [Working.Mark] = []
        var cursor = 0
        var nextWord = 0
        var existing = working.marks.sorted { $0.range.lowerBound < $1.range.lowerBound }[...]
        /// Copies the text and words before `end` unchanged, shifted to where they now are.
        func copy(upTo end: Int) {
            let shift = text.count - cursor
            text += utf16[cursor..<end]
            if timed {
                while nextWord < working.words.count, working.words[nextWord].utf16Offset < end {
                    var word = working.words[nextWord]
                    word.utf16Offset += shift
                    words.append(word)
                    nextWord += 1
                }
            }
            while let mark = existing.first, mark.range.lowerBound < end {
                marks.append(Working.Mark(range: (mark.range.lowerBound + shift)..<(mark.range.upperBound + shift),
                                          heard: mark.heard, kind: mark.kind, heardWords: mark.heardWords,
                                          deleted: mark.deleted))
                existing = existing.dropFirst()
            }
            cursor = end
        }
        for region in regions {
            copy(upTo: region.range.lowerBound)
            let replacement = region.replacement
            let start = text.count
            let leading = Array(utf16[region.range.lowerBound..<replacement.range.lowerBound])
            let trailing = Array(utf16[replacement.range.upperBound..<region.range.upperBound])
            let new = leading + Array(replacement.text.utf16) + trailing
            text += new
            let heard = replacement.heard ?? String(decoding: utf16[replacement.range], as: UTF16.self)
            let markStart = start + leading.count
            // An automatic fix replaced the words it touches: their count is recorded, whatever the spaces in `heard`
            // say ("你好世界" over two timed words, "“type c”" over two).
            var heardWords = replacement.heardWords
            if heardWords == nil, replacement.kind == .correction || replacement.kind == .term {
                heardWords = region.words.count
            }
            if !replacement.text.isEmpty {
                marks.append(Working.Mark(range: markStart..<(markStart + replacement.text.utf16.count), heard: heard,
                                          kind: replacement.kind, heardWords: heardWords,
                                          deleted: replacement.deleted))
            }
            if timed, let given = replacement.words, leading.isEmpty, trailing.isEmpty {
                // The words are given (a revert's, the recognizer's own): never split again at the spaces.
                for word in given {
                    var placed = word
                    placed.utf16Offset += start
                    words.append(placed)
                }
                nextWord = region.words.upperBound
            } else if timed, new == Array(utf16[region.range]) {
                // The same text written back (a revert kept on a new base): its words stay as they are.
                for word in working.words[region.words] {
                    var placed = word
                    placed.utf16Offset += start - region.range.lowerBound
                    words.append(placed)
                }
                nextWord = region.words.upperBound
            } else if timed {
                let replaced = working.words[region.words]
                let from = replaced.first?.start ?? 0
                let to = max(replaced.last?.end ?? from, from)
                let confidences = replaced.compactMap(\.confidence)
                let pieces = tokens(of: new)
                let step = pieces.isEmpty ? 0 : (to - from) / Double(pieces.count)
                for (index, piece) in pieces.enumerated() {
                    words.append(TimedWord(text: String(decoding: new[piece], as: UTF16.self),
                                           start: from + Double(index) * step,
                                           end: index == pieces.count - 1 ? to : from + Double(index + 1) * step,
                                           utf16Offset: start + piece.lowerBound,
                                           utf16Length: piece.count,
                                           confidence: confidences.min()))
                }
                nextWord = region.words.upperBound
            }
            cursor = region.range.upperBound
        }
        copy(upTo: utf16.count)
        return Working(text: String(decoding: text, as: UTF16.self), words: words, marks: marks)
    }

    /// `segment` with the text, words and fixes of `working`: each fix as the effective words it covers
    /// (`WordTiming.effectiveWords`, the index space of speaker turns). Nil fixes when none were made, so an unfixed
    /// segment stays as it was.
    public static func finished(_ working: Working, segment: TranscriptSegment) -> TranscriptSegment {
        var fixed = segment
        fixed.text = working.text
        fixed.words = working.words
        fixed.fixes = nil
        guard !working.marks.isEmpty else { return fixed }
        let effective = WordTiming.effectiveWords(of: fixed)
        let fixes: [TranscriptWordFix] = working.marks.compactMap { mark in
            let touched = effective.indices.filter {
                effective[$0].utf16Range(within: fixed.text.utf16.count)?.overlaps(mark.range) == true
            }
            guard let first = touched.first, let last = touched.last else { return nil }
            return TranscriptWordFix(first: first, end: last + 1, heard: mark.heard, kind: mark.kind,
                                     heardWords: mark.heardWords, deleted: mark.deleted)
        }
        fixed.fixes = fixes.isEmpty ? nil : fixes
        return fixed
    }

    /// A new revision of `transcript` with the fix covering `word` changed back to the recognizer's words from
    /// `base`. Other fixes and their marks stay. Both revisions must have the same segments; this is deliberately a
    /// word-fix operation, not a general transcript editor.
    public static func reverting(_ word: WordRef, in transcript: Transcript, to base: Transcript,
                                 now: Date = Date()) throws -> Transcript {
        guard transcript.fixedFrom == base.id,
              let segmentIndex = transcript.segments.firstIndex(where: { $0.id == word.segmentID }),
              let baseSegment = base.segments.first(where: { $0.id == word.segmentID }) else {
            throw HolosError.invalidInput("That word fix no longer belongs to the current transcript.")
        }
        let segment = transcript.segments[segmentIndex]
        let fixes = segment.fixes ?? []
        guard let targetIndex = fixes.firstIndex(where: {
            ($0.kind == .correction || $0.kind == .term) && $0.first <= word.word && word.word < $0.end
        }) else {
            throw HolosError.invalidInput("That word was not fixed automatically.")
        }
        let target = fixes[targetIndex]
        let currentWords = WordTiming.effectiveWords(of: segment)
        guard let currentRange = characterRange(of: target, words: currentWords, textLength: segment.text.utf16.count),
              let originalRange = originalRange(of: targetIndex, fixes: fixes, currentWords: currentWords,
                                                segment: baseSegment) else {
            throw HolosError.invalidInput("That word fix cannot be matched to the original transcript.")
        }
        let original = Array(baseSegment.text.utf16)
        let heard = String(decoding: original[originalRange], as: UTF16.self)
        guard var working = Working(segment) else {
            throw HolosError.invalidInput("That segment's word positions cannot be edited safely.")
        }
        working.marks = fixes.enumerated().compactMap { index, fix in
            guard index != targetIndex,
                  let range = characterRange(of: fix, words: currentWords,
                                             textLength: segment.text.utf16.count) else { return nil }
            return Working.Mark(range: range, heard: fix.heard, kind: fix.kind, heardWords: fix.heardWords,
                                deleted: fix.deleted)
        }
        // The recognizer's own words come back, with their times and boundaries, never split again at the spaces of
        // the text ("你好世界" is the two words "你好" and "世界" again, as in the base).
        let baseLength = baseSegment.text.utf16.count
        let restored = baseSegment.words.filter { word in
            word.utf16Range(within: baseLength).map {
                originalRange.lowerBound <= $0.lowerBound && $0.upperBound <= originalRange.upperBound
            } ?? false
        }.map { word in
            var relative = word
            relative.utf16Offset -= originalRange.lowerBound
            return relative
        }
        working = applying([Replacement(range: currentRange, text: heard, kind: .reviewRevert,
                                        words: restored.isEmpty ? nil : restored)], to: working)

        var result = transcript
        result.id = UUID().uuidString
        result.createdAt = now
        result.segments[segmentIndex] = finished(working, segment: segment)
        return result
    }

    static func characterRange(of fix: TranscriptWordFix, words: [EffectiveWord], textLength: Int)
        -> Range<Int>? {
        guard TranscriptWordEdit.isSound(fix, wordCount: words.count),
              let first = words[fix.first].utf16Range(within: textLength),
              let last = words[fix.end - 1].utf16Range(within: textLength),
              first.lowerBound < last.upperBound else { return nil }
        return first.lowerBound..<last.upperBound
    }

    /// The whole original words around `fix.heard`. Repeated heard text is disambiguated by the fixed words' time.
    private static func originalRange(of target: Int, fixes: [TranscriptWordFix], currentWords: [EffectiveWord],
                                      segment: TranscriptSegment) -> Range<Int>? {
        guard fixes.indices.contains(target) else { return nil }
        let fix = fixes[target]
        guard TranscriptWordEdit.isSound(fix, wordCount: currentWords.count) else { return nil }
        let words = WordTiming.effectiveWords(of: segment)
        let ranges = originalWordRanges(fixes: fixes, currentWords: currentWords, originalWords: words)
        guard ranges.indices.contains(target), let wordRange = ranges[target],
              let first = wordRange.first, let last = wordRange.last else { return nil }
        return characterRange(of: TranscriptWordFix(first: first, end: last + 1, heard: fix.heard, kind: fix.kind),
                              words: words, textLength: segment.text.utf16.count)
    }

    /// Original word ranges for every mark, reconstructed in text order. A word fix changes only the words its mark
    /// covers; all words between marks are unchanged. That makes the correspondence stable even when an untimed
    /// segment redistributes its estimated times, and avoids guessing among repeated substrings.
    static func originalWordRanges(fixes: [TranscriptWordFix], currentWords: [EffectiveWord],
                                   originalWords: [EffectiveWord]) -> [Range<Int>?] {
        let ordered = fixes.indices.sorted { (fixes[$0].first, fixes[$0].end) < (fixes[$1].first, fixes[$1].end) }
        var result = Array<Range<Int>?>(repeating: nil, count: fixes.count)
        var current = 0
        var original = 0
        for index in ordered {
            let fix = fixes[index]
            guard fix.first >= current, fix.first < fix.end, fix.end <= currentWords.count else { return [] }
            let unchanged = fix.first - current
            guard original + unchanged <= originalWords.count else { return [] }
            for offset in 0..<unchanged where currentWords[current + offset].text != originalWords[original + offset].text {
                return []
            }
            current += unchanged
            original += unchanged
            // `segment` is the revision named by `fixedFrom`. It already contains live corrections and Review edits,
            // so such a mark occupies its current word span there; automatic fixes still occupy the recognizer words
            // in `heard`.
            // At most the original words left (`original` <= their count here), compared without adding.
            let left = originalWords.count - original
            let counted = fix.kind == .reviewRevert || fix.kind == .liveCorrection || fix.kind == .reviewEdit
                ? fix.end - fix.first
                : fix.heardWordCount(within: left)
            guard let count = counted, count > 0, count <= left else { return [] }
            result[index] = original..<(original + count)
            current = fix.end
            original += count
        }
        guard currentWords.count - current == originalWords.count - original else { return [] }
        for offset in 0..<(currentWords.count - current)
            where currentWords[current + offset].text != originalWords[original + offset].text {
            return []
        }
        return result
    }

    /// Runs of non-whitespace UTF-16 units, as `WordTiming` splits an untimed segment's text.
    static func tokens(of utf16: [UInt16]) -> [Range<Int>] {
        let text = String(decoding: utf16, as: UTF16.self)
        var result: [Range<Int>] = []
        var offset = 0
        var start: Int?
        for character in text {
            let length = character.utf16.count
            if character.isWhitespace {
                if let begun = start { result.append(begun..<offset) }
                start = nil
            } else if start == nil {
                start = offset
            }
            offset += length
        }
        if let begun = start { result.append(begun..<offset) }
        return result
    }

    /// What one word fix replaced, for messages: "12 misheard words were fixed (9 by corrections, 3 word-list terms)".
    public struct Counts: Sendable, Equatable {
        public var corrections = 0
        public var terms = 0
        public var total: Int { corrections + terms }

        public init(corrections: Int = 0, terms: Int = 0) { self.corrections = corrections; self.terms = terms }

        /// The fixes of `transcript`'s segments, by kind.
        public init(_ transcript: Transcript) {
            for fix in transcript.segments.flatMap({ $0.fixes ?? [] }) {
                if fix.kind == .term { terms += 1 }
                if fix.kind == .correction { corrections += 1 }
            }
        }
    }
}
