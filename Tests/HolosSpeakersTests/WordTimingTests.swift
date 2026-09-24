import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

@Test func untimedSegmentSpreadsWordsEvenly() {
    let segment = TranscriptSegment(id: "S", start: 10, end: 14, text: "one two three four")
    let words = WordTiming.effectiveWords(of: segment)
    #expect(words.map(\.text) == ["one", "two", "three", "four"])
    #expect(words.map(\.start) == [10, 11, 12, 13])
    #expect(words.map(\.end) == [11, 12, 13, 14])
    #expect(words.allSatisfy { $0.estimated })
    #expect(words.map(\.utf16Offset) == [0, 4, 8, 14])
    #expect(words.map(\.utf16Length) == [3, 3, 5, 4])
}

@Test func measuredWordsKeepOffsets() {
    let timed = [
        TimedWord(text: "Hello", start: 1.0, end: 1.4, utf16Offset: 0, utf16Length: 5, confidence: 0.9),
        TimedWord(text: " there", start: 1.5, end: 1.9, utf16Offset: 5, utf16Length: 6),
        TimedWord(text: " Jim", start: 2.1, end: 2.4, utf16Offset: 11, utf16Length: 4),
    ]
    let segment = TranscriptSegment(id: "S", start: 1, end: 2.5, text: "Hello there Jim", words: timed)
    let words = WordTiming.effectiveWords(of: segment)
    #expect(words == timed.map {
        EffectiveWord(text: $0.text, start: $0.start, end: $0.end, utf16Offset: $0.utf16Offset,
                      utf16Length: $0.utf16Length, estimated: false)
    })
}

@Test func untimedTokensUseUTF16OffsetsAndCollapseWhitespace() {
    let segment = TranscriptSegment(id: "S", start: 0, end: 2, text: "  caf\u{E9}\n\u{1F600} ok  ")
    let words = WordTiming.effectiveWords(of: segment)
    #expect(words.map(\.text) == ["caf\u{E9}", "\u{1F600}", "ok"])
    #expect(words.map(\.utf16Offset) == [2, 7, 10])
    #expect(words.map(\.utf16Length) == [4, 2, 2])
    let text = segment.text as NSString
    for word in words {
        #expect(text.substring(with: NSRange(location: word.utf16Offset, length: word.utf16Length)) == word.text)
    }
}

@Test func zeroLengthUntimedSegmentGetsMinimumDuration() {
    let segment = TranscriptSegment(id: "S", start: 5, end: 5, text: "a b")
    let words = WordTiming.effectiveWords(of: segment)
    #expect(words.count == 2)
    #expect(abs(words[0].start - 5) < 1e-12)
    #expect(abs(words[0].end - 5.01) < 1e-12)
    #expect(abs(words[1].end - 5.02) < 1e-12)
}

@Test func blankUntimedSegmentHasNoWords() {
    #expect(WordTiming.effectiveWords(of: TranscriptSegment(start: 0, end: 1, text: " \n ")).isEmpty)
}
