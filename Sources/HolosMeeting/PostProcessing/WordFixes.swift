import Foundation
import HolosCore
import HolosSpeakers

/// The pure part of the meeting word-fix stage (`WordFixStage`, docs/design.md "Meeting word fixes"): replacing
/// phrases of a segment's text while its words keep their times. A replaced phrase takes the time span of the words it
/// replaced, its new words share that span evenly, and every other word keeps its time; the segment keeps its ID,
/// start and end, so speaker turns and exports find it as before. Each change is marked (`TranscriptSegment.fixes`)
/// with what the recognizer wrote there, so the review can show it.
public enum WordFixes {
    /// One replacement in a segment's text.
    public struct Replacement: Sendable, Equatable {
        /// UTF-16 range of the text replaced.
        public var range: Range<Int>
        /// What goes there.
        public var text: String
        public var kind: TranscriptWordFixKind

        public init(range: Range<Int>, text: String, kind: TranscriptWordFixKind) {
            self.range = range; self.text = text; self.kind = kind
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
        }

        public init(text: String, words: [TimedWord], marks: [Mark] = []) {
            self.text = text; self.words = words; self.marks = marks
        }

        /// Nil when the segment's word offsets do not fit its text (they decrease, overlap, or run past it): such a
        /// segment is left as it is rather than fixed in the wrong place.
        public init?(_ segment: TranscriptSegment) {
            text = segment.text
            words = segment.words
            marks = []
            let length = segment.text.utf16.count
            var previousEnd = 0
            for word in words {
                guard word.utf16Offset >= previousEnd, word.utf16Length >= 0,
                      word.utf16Offset + word.utf16Length <= length else { return nil }
                previousEnd = word.utf16Offset + word.utf16Length
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
    /// overlaps an earlier replacement, or touches a fix already made is left out, as is one with nothing but spaces.
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
                  replacement.text.contains(where: { !$0.isWhitespace }) else { continue }
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
                                          heard: mark.heard, kind: mark.kind))
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
            let heard = String(decoding: utf16[replacement.range], as: UTF16.self)
            let markStart = start + leading.count
            marks.append(Working.Mark(range: markStart..<(markStart + replacement.text.utf16.count), heard: heard,
                                      kind: replacement.kind))
            if timed {
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
                (effective[$0].utf16Offset..<(effective[$0].utf16Offset + effective[$0].utf16Length)).overlaps(mark.range)
            }
            guard let first = touched.first, let last = touched.last else { return nil }
            return TranscriptWordFix(first: first, end: last + 1, heard: mark.heard, kind: mark.kind)
        }
        fixed.fixes = fixes.isEmpty ? nil : fixes
        return fixed
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
                if fix.kind == .term { terms += 1 } else { corrections += 1 }
            }
        }
    }
}
