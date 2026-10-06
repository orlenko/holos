import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import Testing

// Editing words in Review, the pure part (docs/meeting-design.md §5.10, "Editing words"): `TranscriptWordEdit` on
// hand-built transcripts. Helpers are prefixed `edit`.

/// One timed segment: word `i` starts at `start + i` seconds and lasts 0.8 s.
private func editSegment(_ words: [String], id: String = "S1", start: Double = 0) -> TranscriptSegment {
    SessionFixtures.segment(words, track: "system", start: start, wordSeconds: 1, id: id)
}

private func editTranscript(_ segments: [TranscriptSegment]) -> Transcript {
    SessionFixtures.transcript(segments)
}

/// `base` with `corrections` applied as the word-fix stage applies them: a fixed revision whose `fixedFrom` is `base`.
private func editFixed(_ base: Transcript, _ corrections: [Correction]) async throws -> Transcript {
    try await WordFixStage.fix(base, title: "", corrections: CorrectionList(entries: corrections),
                               terms: CorrectionList(), dependencies: .none).transcript
}

private func editRequest(_ first: Int, _ end: Int, _ text: String, segment: String = "S1")
    -> TranscriptWordEdit.Request {
    TranscriptWordEdit.Request(segmentID: segment, first: first, end: end, text: text)
}

@Test func aWordEditKeepsTheWordsTimeAndRecordsWhatWasHeard() throws {
    let current = editTranscript([editSegment(["ask", "cloud", "now"])])
    let result = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claude"), in: current, base: nil))
    let segment = result.transcript.segments[0]
    #expect(segment.text == "ask Claude now")
    #expect(segment.words.map(\.text) == ["ask", "Claude", "now"])
    #expect(segment.words[1].start == 1 && segment.words[1].end == 1.8)
    #expect(segment.fixes == [TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit, heardWords: 1)])
    #expect(result.transcript.id != current.id && result.transcript.fixedFrom == nil)
    #expect(result.transcript.liveCorrectedFrom == current.id, "An unfixed transcript stays its own word space.")
    #expect(result.base == nil)
    #expect(result.heard == "cloud" && result.meant == "Claude" && result.shown == "cloud" && !result.deletion)
    #expect(result.before == "ask" && result.after == "now")
    #expect(TranscriptWordEdit.hasReviewEdits(result.transcript) && !TranscriptWordEdit.hasReviewEdits(current))
}

/// A timed segment whose words' ranges are given as (offset, length) pairs into `text`, as a recognizer reports them.
private func editRanged(_ text: String, _ ranges: [(Int, Int)], id: String = "S1") -> TranscriptSegment {
    let utf16 = Array(text.utf16)
    let words = ranges.enumerated().map { index, range in
        TimedWord(text: String(decoding: utf16[range.0..<(range.0 + range.1)], as: UTF16.self),
                  start: Double(index), end: Double(index) + 0.8, utf16Offset: range.0, utf16Length: range.1)
    }
    return TranscriptSegment(id: id, start: 0, end: Double(ranges.count), text: text, words: words, track: "system")
}

@Test func aSpaceAtTheFrontOfAWordsRangeStaysWhereItIs() async throws {
    // Apple's speech recognition: " cloud" and " now" carry the space before them.
    let apple = editTranscript([editRanged("ask cloud now", [(0, 3), (3, 6), (9, 4)])])
    #expect(TranscriptWordEdit.shownText(of: apple.segments[0], first: 1, end: 2) == "cloud")
    let edited = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claude"), in: apple, base: nil))
    #expect(edited.transcript.segments[0].text == "ask Claude now")
    #expect(WordTiming.effectiveWords(of: edited.transcript.segments[0]).map(\.text) == ["ask", "Claude", " now"])
    let twoWords = try #require(try TranscriptWordEdit.editing(editRequest(1, 3, "Claude later"), in: apple,
                                                                base: nil))
    #expect(twoWords.transcript.segments[0].text == "ask Claude later")
    // The same through a fixed revision and its base.
    let base = editTranscript([editRanged("ask cloud now please", [(0, 3), (3, 6), (9, 4), (13, 7)])])
    let fixed = try await editFixed(base, [Correction(heard: "please", meant: "pls")])
    #expect(fixed.segments[0].text == "ask cloud now pls")
    let both = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claude"), in: fixed, base: base))
    #expect(both.transcript.segments[0].text == "ask Claude now pls")
    #expect(both.base?.segments[0].text == "ask Claude now please")
    // Whisper-style ranges with the space after the word instead.
    let trailing = editTranscript([editRanged("ask cloud now", [(0, 4), (4, 6), (10, 3)])])
    let after = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claude"), in: trailing, base: nil))
    #expect(after.transcript.segments[0].text == "ask Claude now")
}

@Test func punctuationTheRecognizerDidNotTimeGoesWithItsWord() throws {
    // "Hello." and "you?" are timed as "Hello" and "you".
    let segment = editRanged("Hello. How are you?", [(0, 5), (7, 3), (11, 3), (15, 3)])
    let current = editTranscript([segment])
    #expect(TranscriptWordEdit.shownText(of: segment, first: 0, end: 1) == "Hello.")
    #expect(TranscriptWordEdit.shownText(of: segment, first: 3, end: 4) == "you?")
    let question = try #require(try TranscriptWordEdit.editing(editRequest(0, 1, "Hello?"), in: current, base: nil))
    #expect(question.transcript.segments[0].text == "Hello? How are you?")
    #expect(question.heard == "Hello.")
    let last = try #require(try TranscriptWordEdit.editing(editRequest(3, 4, "they!"), in: current, base: nil))
    #expect(last.transcript.segments[0].text == "Hello. How are they!")
    #expect(try TranscriptWordEdit.editing(editRequest(0, 1, "Hello."), in: current, base: nil) == nil,
            "The field's text as it started changes nothing.")
}

@Test func aCorruptEditedRangeIsReadOnlyWithinItsSegment() {
    var segment = editSegment(["one", "two", "three"])
    segment.fixes = [TranscriptWordFix(first: 1, end: Int.max, heard: "x", kind: .reviewEdit)]
    let words = EchoFilter.reviewEditedWords(in: editTranscript([segment]))
    #expect(words == [WordRef(segmentID: "S1", word: 1), WordRef(segmentID: "S1", word: 2)])
}

@Test func moreAndFewerWordsShareTheEditedSpansTime() throws {
    let current = editTranscript([editSegment(["ask", "cloud", "now"])])
    let more = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "  Claude   Code "), in: current,
                                                            base: nil))
    let words = more.transcript.segments[0].words
    #expect(more.transcript.segments[0].text == "ask Claude Code now")
    #expect(words.map(\.text) == ["ask", "Claude", "Code", "now"])
    #expect(abs(words[1].start - 1) < 1e-9 && abs(words[1].end - 1.4) < 1e-9)
    #expect(abs(words[2].start - 1.4) < 1e-9 && abs(words[2].end - 1.8) < 1e-9)
    #expect(words[3].start == 2, "Words after the span keep their times.")
    #expect(more.transcript.segments[0].fixes == [TranscriptWordFix(first: 1, end: 3, heard: "cloud", kind: .reviewEdit,
                                                                    heardWords: 1)])

    let fewer = try #require(try TranscriptWordEdit.editing(editRequest(0, 2, "Ask"), in: current, base: nil))
    #expect(fewer.transcript.segments[0].text == "Ask now")
    #expect(fewer.transcript.segments[0].words.first.map { ($0.start, $0.end) }.map { $0 == (0, 1.8) } == true)
    #expect(fewer.heard == "ask cloud" && fewer.meant == "Ask")
}

@Test func aDeletionMergesIntoTheNextWordOrElseThePreviousOne() throws {
    let current = editTranscript([editSegment(["I", "um", "think"])])
    let next = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, ""), in: current, base: nil))
    let segment = next.transcript.segments[0]
    #expect(segment.text == "I think")
    #expect(segment.words.map(\.text) == ["I", "think"])
    #expect(segment.words[1].start == 1 && segment.words[1].end == 2.8, "The deleted word's time goes to its neighbour.")
    #expect(segment.fixes == [TranscriptWordFix(first: 1, end: 2, heard: "um think", kind: .reviewEdit,
                                                heardWords: 2, deleted: true)], "A deletion, which teaches nothing.")
    #expect(next.deletion && next.heard == "um think" && next.meant == "think")

    let last = try #require(try TranscriptWordEdit.editing(editRequest(2, 3, " "), in: current, base: nil))
    #expect(last.transcript.segments[0].text == "I um")
    #expect(last.transcript.segments[0].fixes == [TranscriptWordFix(first: 1, end: 2, heard: "um think",
                                                                    kind: .reviewEdit, heardWords: 2, deleted: true)])
    // Not past a word another turn shows: the previous word is taken instead.
    let fenced = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, ""), in: current, base: nil,
                                                              editable: { $0 < 2 }))
    #expect(fenced.transcript.segments[0].text == "I think")
    #expect(fenced.transcript.segments[0].fixes == [TranscriptWordFix(first: 0, end: 1, heard: "I um",
                                                                      kind: .reviewEdit, heardWords: 2,
                                                                      deleted: true)])
    // A segment never loses all its words.
    let lone = editTranscript([editSegment(["um"])])
    #expect(throws: HolosError.self) { try TranscriptWordEdit.editing(editRequest(0, 1, ""), in: lone, base: nil) }
}

@Test func aDeletionBesideAWordCorrectedWhileRecordingGoesIntoTheOtherNeighbour() throws {
    // "think" was corrected live (it cannot be edited here): "um" goes into "I" instead.
    var segment = editSegment(["I", "um", "think"])
    segment.fixes = [TranscriptWordFix(first: 2, end: 3, heard: "thing", kind: .liveCorrection, heardWords: 1)]
    let deleted = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, ""), in: editTranscript([segment]),
                                                               base: nil))
    #expect(deleted.transcript.segments[0].text == "I think")
    #expect(deleted.heard == "I um" && deleted.meant == "I")
    #expect(deleted.transcript.segments[0].fixes?.contains { $0.kind == .liveCorrection && $0.heard == "thing" } == true,
            "The live correction stays.")
    // With no other neighbour, it is refused, saying why.
    var alone = editSegment(["um", "think"])
    alone.fixes = [TranscriptWordFix(first: 1, end: 2, heard: "thing", kind: .liveCorrection, heardWords: 1)]
    let refusal = #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 1, ""), in: editTranscript([alone]), base: nil)
    }
    #expect(refusal?.localizedDescription == TranscriptWordEdit.liveCorrected.localizedDescription)
}

@Test func anEditOfAFixedTranscriptIsMadeInItsBaseTooSoWordFixesKeepIt() async throws {
    let base = editTranscript([editSegment(["ask", "cloud", "now", "please"])])
    let corrections = [Correction(heard: "cloud", meant: "Claude"), Correction(heard: "please", meant: "pls")]
    let fixed = try await editFixed(base, corrections)
    #expect(fixed.segments[0].text == "ask Claude now pls")

    let result = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claudia"), in: fixed, base: base))
    let newBase = try #require(result.base)
    #expect(newBase.segments[0].text == "ask Claudia now please")
    #expect(newBase.segments[0].fixes == [TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit,
                                                            heardWords: 1)])
    #expect(newBase.fixedFrom == nil && newBase.liveCorrectedFrom == base.id)
    #expect(result.transcript.segments[0].text == "ask Claudia now pls")
    #expect(result.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit, heardWords: 1),
        TranscriptWordFix(first: 3, end: 4, heard: "please", kind: .correction, heardWords: 1),
    ])
    #expect(result.transcript.fixedFrom == newBase.id && result.transcript.liveCorrectedFrom == base.id)
    #expect(result.heard == "cloud" && result.shown == "Claude")
    // The word-fix stage, made again from the new base with the same corrections, gives the edited transcript.
    let again = try await editFixed(newBase, corrections)
    #expect(again.segments == result.transcript.segments)
}

@Test func anEditTouchingPartOfAFixTakesTheWholeFix() async throws {
    let base = editTranscript([editSegment(["we", "knew", "work", "here"])])
    let fixed = try await editFixed(base, [Correction(heard: "knew work", meant: "New York")])
    #expect(fixed.segments[0].text == "we New York here")
    let result = try #require(try TranscriptWordEdit.editing(editRequest(2, 3, "Yorkshire"), in: fixed, base: base))
    #expect(result.transcript.segments[0].text == "we New Yorkshire here")
    #expect(result.transcript.segments[0].fixes == [TranscriptWordFix(first: 1, end: 3, heard: "knew work",
                                                                      kind: .reviewEdit, heardWords: 2)])
    #expect(result.base?.segments[0].text == "we New Yorkshire here")
    #expect(result.shown == "New York" && result.meant == "New Yorkshire" && result.heard == "knew work")
    // Edited again: still what the recognizer wrote, not the first edit's text.
    let twice = try #require(try TranscriptWordEdit.editing(editRequest(1, 3, "Newark"), in: result.transcript,
                                                             base: result.base))
    #expect(twice.transcript.segments[0].fixes == [TranscriptWordFix(first: 1, end: 2, heard: "knew work",
                                                                     kind: .reviewEdit, heardWords: 2)])
    #expect(twice.base?.segments[0].text == "we Newark here")
}

@Test func aMoveReplacesOnlyTheSelectedWordsNotTheRestOfTheFixTheyTookIn() async throws {
    let base = editTranscript([editSegment(["we", "knew", "work", "here"])])
    let fixed = try await editFixed(base, [Correction(heard: "knew work", meant: "New York")])
    // "New" of "New York" becomes "Greater New": "York" keeps its own place.
    let result = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Greater New"), in: fixed, base: base))
    #expect(result.transcript.segments[0].text == "we Greater New York here")
    #expect(result.move == ReviewWordMove(segmentID: "S1", replaced: 1..<2, replacement: 1..<3))
    let york = result.move.map(WordRef(segmentID: "S1", word: 2))
    #expect(york.ref.word == 3 && !york.replaced, "A field on “York” follows it to “York”, never onto “New”.")
    #expect(result.move.map(WordRef(segmentID: "S1", word: 1)).replaced)
    // A deletion: the neighbour it merged into keeps its place, not replaced.
    let plain = editTranscript([editSegment(["I", "um", "think"])])
    let deleted = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, ""), in: plain, base: nil))
    #expect(deleted.move == ReviewWordMove(segmentID: "S1", replaced: 1..<2, replacement: 1..<1))
    let think = deleted.move.map(WordRef(segmentID: "S1", word: 2))
    #expect(think.ref.word == 1 && !think.replaced)
}

@Test func anEditOfAnAutomaticFixKeepsTheRecognizersPunctuationForItsRevert() async throws {
    // The recognizer wrote "cloud."; the correction replaced "cloud" only, giving "Claude.".
    let base = editTranscript([editSegment(["ask", "cloud."])])
    let fixed = try await editFixed(base, [Correction(heard: "cloud", meant: "Claude")])
    #expect(fixed.segments[0].text == "ask Claude.")
    let edited = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claudia."), in: fixed, base: base))
    #expect(edited.heard == "cloud.", "What the recognizer wrote over the whole word, its period too.")
    // Revert: an edit back to what the recognizer wrote.
    let reverted = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, edited.heard), in: edited.transcript,
                                                                base: edited.base))
    #expect(reverted.transcript.segments[0].text == "ask cloud.")
    #expect(reverted.base?.segments[0].text == "ask cloud.")
}

@Test func whatWasHeardKeepsTheRecognizersTextExactlySoARevertRestoresIt() async throws {
    // No space between the words: "你好世界" timed as "你好" and "世界".
    let chinese = editTranscript([editRanged("你好世界", [(0, 2), (2, 2)])])
    let edited = try #require(try TranscriptWordEdit.editing(editRequest(0, 2, "你好地球"), in: chinese, base: nil))
    #expect(edited.transcript.segments[0].text == "你好地球")
    #expect(edited.heard == "你好世界")
    #expect(edited.transcript.segments[0].fixes == [TranscriptWordFix(first: 0, end: 1, heard: "你好世界",
                                                                      kind: .reviewEdit, heardWords: 2)])
    let back = try #require(try TranscriptWordEdit.editing(editRequest(0, 1, edited.heard), in: edited.transcript,
                                                            base: nil))
    #expect(back.transcript.segments[0].text == "你好世界")
    #expect(back.transcript.segments[0].fixes?.first?.heardWords == 2, "Still two recognizer words.")

    // Punctuation of its own: "hello — there" timed as "hello" and "there".
    let dash = editTranscript([editRanged("hello — there", [(0, 5), (8, 5)])])
    let hi = try #require(try TranscriptWordEdit.editing(editRequest(0, 2, "hi — there"), in: dash, base: nil))
    #expect(hi.heard == "hello — there")
    #expect(hi.transcript.segments[0].fixes?.first?.heardWords == 2)
    let restored = try #require(try TranscriptWordEdit.editing(editRequest(0, 3, hi.heard), in: hi.transcript,
                                                                base: nil))
    #expect(restored.transcript.segments[0].text == "hello — there")

    // Through a fixed revision and its base: made again from the new base, the word-fix stage gives the same words.
    let base = editTranscript([editRanged("hello — there please", [(0, 5), (8, 5), (14, 6)])])
    let corrections = [Correction(heard: "please", meant: "pls")]
    let fixed = try await editFixed(base, corrections)
    #expect(fixed.segments[0].text == "hello — there pls")
    let both = try #require(try TranscriptWordEdit.editing(editRequest(0, 2, "hi — there"), in: fixed, base: base))
    #expect(both.heard == "hello — there")
    #expect(both.base?.segments[0].text == "hi — there please")
    #expect(both.base?.segments[0].fixes?.first?.heardWords == 2)
    let again = try await editFixed(try #require(both.base), corrections)
    #expect(again.segments == both.transcript.segments)
    let reverted = try #require(try TranscriptWordEdit.editing(editRequest(0, 3, both.heard), in: both.transcript,
                                                                base: both.base))
    #expect(reverted.transcript.segments[0].text == "hello — there pls")
    #expect(reverted.base?.segments[0].text == "hello — there please")
}

@Test func everyAutomaticFixRecordsTheWordsItReplacedSoItsSegmentStaysEditable() async throws {
    // Punctuation attached to the words: "type c" in "“type c”" replaced two timed words.
    let quoted = editTranscript([editSegment(["we", "use", "“type", "c”", "here"])])
    let typeC = try await editFixed(quoted, [Correction(heard: "type c", meant: "Type-C")])
    #expect(typeC.segments[0].text == "we use “Type-C” here")
    #expect(typeC.segments[0].fixes?.first?.heardWords == 2)
    let here = try #require(try TranscriptWordEdit.editing(editRequest(3, 4, "there"), in: typeC, base: quoted))
    #expect(here.transcript.segments[0].text == "we use “Type-C” there")
    #expect(here.base?.segments[0].text == "we use “type c” there")
    let typeCRevert = try WordFixes.reverting(WordRef(segmentID: "S1", word: 2), in: typeC, to: quoted)
    #expect(typeCRevert.segments[0].text == "we use “type c” here")

    // No spaces between the words: "你好世界" timed as "你好" and "世界", made "你好地球".
    let chinese = editTranscript([editRanged("你好世界 再见", [(0, 2), (2, 2), (5, 2)])])
    let fixed = try await editFixed(chinese, [Correction(heard: "你好世界", meant: "你好地球")])
    #expect(fixed.segments[0].text == "你好地球 再见")
    #expect(fixed.segments[0].fixes == [TranscriptWordFix(first: 0, end: 1, heard: "你好世界", kind: .correction,
                                                          heardWords: 2)], "It replaced two words.")
    let other = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "拜拜"), in: fixed, base: chinese))
    #expect(other.transcript.segments[0].text == "你好地球 拜拜")
    #expect(other.base?.segments[0].text == "你好世界 拜拜")
    let edit = try #require(try TranscriptWordEdit.editing(editRequest(0, 1, "你好朋友"), in: fixed, base: chinese))
    #expect(edit.heard == "你好世界" && edit.transcript.segments[0].fixes?.first?.heardWords == 2)
    #expect(edit.base?.segments[0].text == "你好朋友 再见")
    let reverted = try WordFixes.reverting(WordRef(segmentID: "S1", word: 0), in: fixed, to: chinese)
    #expect(reverted.segments[0].text == "你好世界 再见")
}

@Test func aRevertBringsBackTheRecognizersOwnWordsSoTheSegmentStaysEditable() async throws {
    struct Case {
        var base: Transcript
        var heard: String
        var meant: String
        /// The fixed word in the fixed revision, and the last word (edited after the revert) in the reverted one.
        var fixedWord: Int
        var lastWord: Int
        var lastText: String
        var edited: String
    }
    for item in [
        // No spaces between the words: "你好世界" timed as "你好" and "世界".
        Case(base: editTranscript([editRanged("你好世界 再见", [(0, 2), (2, 2), (5, 2)])]), heard: "你好世界",
             meant: "你好地球", fixedWord: 0, lastWord: 2, lastText: "拜拜", edited: "你好世界 拜拜"),
        Case(base: editTranscript([editSegment(["we", "knew", "work", "here"])]), heard: "knew work",
             meant: "New York", fixedWord: 1, lastWord: 3, lastText: "there", edited: "we knew work there"),
    ] {
        let fixed = try await editFixed(item.base, [Correction(heard: item.heard, meant: item.meant)])
        let reverted = try WordFixes.reverting(WordRef(segmentID: "S1", word: item.fixedWord), in: fixed,
                                               to: item.base)
        // Exactly the recognizer's words again: text, times, and boundaries.
        #expect(reverted.segments[0].text == item.base.segments[0].text)
        #expect(reverted.segments[0].words == item.base.segments[0].words)
        #expect(reverted.segments[0].fixes?.first?.kind == .reviewRevert)
        #expect(reverted.segments[0].fixes?.first.map { $0.end - $0.first } == 2)
        // A later edit in the segment still maps onto the base.
        let edit = try #require(try TranscriptWordEdit.editing(editRequest(item.lastWord, item.lastWord + 1,
                                                                           item.lastText),
                                                               in: reverted, base: item.base))
        #expect(edit.transcript.segments[0].text == item.edited)
        #expect(edit.base?.segments[0].text == item.edited)
    }
}

@Test func anOlderAutomaticFixWithoutItsCountIsCountedByItsSpaces() async throws {
    // Saved by an earlier version: no `heardWords`. With spaces between the words, the spaces count them.
    let base = editTranscript([editSegment(["ask", "cloud", "now", "please"])])
    var fixed = try await editFixed(base, [Correction(heard: "cloud now", meant: "Claude Now")])
    fixed.segments[0].fixes = fixed.segments[0].fixes?.map { fix in
        TranscriptWordFix(first: fix.first, end: fix.end, heard: fix.heard, kind: fix.kind)
    }
    let edited = try #require(try TranscriptWordEdit.editing(editRequest(3, 4, "pls"), in: fixed, base: base))
    #expect(edited.transcript.segments[0].text == "ask Claude Now pls")
    #expect(edited.base?.segments[0].text == "ask cloud now pls")
    let reverted = try WordFixes.reverting(WordRef(segmentID: "S1", word: 1), in: fixed, to: base)
    #expect(reverted.segments[0].text == "ask cloud now please")

    // Without spaces between its words, it cannot be counted: an edit in its segment is refused, saying why.
    let chinese = editTranscript([editRanged("你好世界 再见", [(0, 2), (2, 2), (5, 2)])])
    var legacy = try await editFixed(chinese, [Correction(heard: "你好世界", meant: "你好地球")])
    legacy.segments[0].fixes = [TranscriptWordFix(first: 0, end: 1, heard: "你好世界", kind: .correction)]
    let refusal = #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(1, 2, "拜拜"), in: legacy, base: chinese)
    }
    #expect(refusal?.localizedDescription == TranscriptWordEdit.olderFix.localizedDescription)
}

@Test func anUntimedSegmentKeepsEstimatedTiming() throws {
    let untimed = TranscriptSegment(id: "S1", start: 0, end: 3, text: "one two three", track: "system")
    let current = editTranscript([untimed])
    let result = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "2 and a half"), in: current,
                                                              base: nil))
    let segment = result.transcript.segments[0]
    #expect(segment.words.isEmpty && segment.text == "one 2 and a half three")
    #expect(segment.start == 0 && segment.end == 3)
    #expect(segment.fixes == [TranscriptWordFix(first: 1, end: 5, heard: "two", kind: .reviewEdit, heardWords: 1)])
    let estimated = WordTiming.effectiveWords(of: segment).allSatisfy { $0.estimated }
    #expect(estimated)
}

@Test func editsThatCannotBeMadeSayWhy() throws {
    let current = editTranscript([editSegment(["ask", "cloud", "now"])])
    #expect(try TranscriptWordEdit.editing(editRequest(1, 2, "cloud"), in: current, base: nil) == nil,
            "The same text changes nothing.")
    #expect(throws: HolosError.self) { try TranscriptWordEdit.editing(editRequest(2, 4, "x"), in: current, base: nil) }
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 1, "x", segment: "S9"), in: current, base: nil)
    }
    // A word another turn shows, or one hidden as echo, is never taken in.
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 2, "x"), in: current, base: nil, editable: { $0 != 1 })
    }
    // A live correction is left to the live hints that made it.
    var live = current
    live.segments[0].fixes = [TranscriptWordFix(first: 1, end: 2, heard: "clod", kind: .liveCorrection)]
    #expect(throws: HolosError.self) { try TranscriptWordEdit.editing(editRequest(0, 2, "x"), in: live, base: nil) }
}

@Test func restoringCopiesThePreviousTranscriptExactly() async throws {
    let base = editTranscript([editSegment(["ask", "cloud", "now"])])
    let fixed = try await editFixed(base, [Correction(heard: "cloud", meant: "Claude")])
    let edited = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claudia"), in: fixed, base: base))
    let restored = TranscriptWordEdit.restoring(fixed)
    #expect(restored.id != fixed.id && restored.id != edited.transcript.id)
    #expect(restored.segments == fixed.segments)
    #expect(restored.fixedFrom == base.id, "The undone edit's base is left unused.")
    #expect(restored.liveCorrectedFrom == fixed.liveCorrectedFrom)
    // An unfixed transcript names itself as its word space, as the edit did.
    let plain = TranscriptWordEdit.restoring(base)
    #expect(plain.segments == base.segments && plain.liveCorrectedFrom == base.id)
}

// MARK: - Echo

/// Ten 0.3 s microphone words every 0.4 s from 10 s, labelled "Me", and the system track's four.
private func editCall() -> (transcript: Transcript, run: DiarizationRun) {
    func segment(_ id: String, words: Int, track: String, start: Double) -> TranscriptSegment {
        var text = ""
        var timed: [TimedWord] = []
        for index in 0..<words {
            let word = "\(id)w\(index)"
            if !text.isEmpty { text += " " }
            let wordStart = start + Double(index) * 0.4
            timed.append(TimedWord(text: word, start: wordStart, end: wordStart + 0.3,
                                   utf16Offset: text.utf16.count, utf16Length: word.utf16.count))
            text += word
        }
        return TranscriptSegment(id: id, start: start, end: start + Double(words) * 0.4, text: text, words: timed,
                                 track: track)
    }
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                                backend: .speech, segments: [segment("M", words: 10, track: "mic", start: 10),
                                                             segment("S", words: 4, track: "system", start: 20)])
    var parameters = AlignmentParameters.v1
    parameters.echoWindowSeconds = 1.0
    parameters.offsetSearchSeconds = 0
    let tracks = [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
                  SpeakerRunBuilder.TrackInput(track: "system", policy: .channel(speakerID: "system:all",
                                                                                 displayName: "Others"))]
    let run = SpeakerRunBuilder.build(sessionID: "SESSION", transcript: transcript, tracks: tracks, engine: nil,
                                      parameters: parameters, id: "RUN").run
    return (transcript, run)
}

/// Frames centred in 10.8–11.5 s (words 2 and 3 of M) are echo, the rest local.
private let editEchoMask: AcousticEchoMask = {
    let count = Int(30 / AcousticEchoMask.hopSeconds)
    let classes = (0..<count).map { frame -> UInt8 in
        let centre = AcousticEchoMask.centre(ofFrame: frame)
        return (centre >= 10.8 && centre < 11.5 ? AcousticEchoMask.FrameClass.echo : .local).rawValue
    }
    return AcousticEchoMask(classes: classes, echoLevels: Array(repeating: 0, count: count))!
}()

@Test func shownWordsMapToStoredIndicesAndHiddenEchoIsNeverEdited() throws {
    let (transcript, run) = editCall()
    let view = SpeakerProjection.make(run: run, transcript: transcript, edits: [], recognition: nil, profileNames: [:],
                                      acousticEcho: editEchoMask)
    let turn = try #require(view.turns.first { $0.track == "mic" })
    let shown = turn.spans.flatMap { span in (span.first..<span.end).map { WordRef(segmentID: span.segmentID, word: $0) } }
    #expect(shown.map(\.word) == [0, 1, 4, 5, 6, 7, 8, 9])
    let editable: (Int) -> Bool = { word in turn.spans.contains { $0.first <= word && word < $0.end } }
    // The third word shown is stored word 4: an edit of it changes that word.
    let third = shown[2]
    let result = try #require(try TranscriptWordEdit.editing(
        editRequest(third.word, third.word + 1, "fixed", segment: "M"), in: transcript, base: nil, editable: editable))
    #expect(result.transcript.segments[0].text.split(separator: " ")[4] == "fixed")
    #expect(result.transcript.segments[0].fixes == [TranscriptWordFix(first: 4, end: 5, heard: "Mw4", kind: .reviewEdit,
                                                                      heardWords: 1)])
    // Shown words 2 and 3 of the list are stored words 1 and 4, with the hidden echo between: never one edit.
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(1, 5, "x", segment: "M"), in: transcript, base: nil,
                                       editable: editable)
    }
    // A deletion next to hidden echo merges into the shown word on the other side.
    let deleted = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "", segment: "M"), in: transcript,
                                                               base: nil, editable: editable))
    #expect(deleted.transcript.segments[0].fixes == [TranscriptWordFix(first: 0, end: 1, heard: "Mw0 Mw1",
                                                                       kind: .reviewEdit, heardWords: 2,
                                                                       deleted: true)])
}

@Test func anEditThatMatchesTheCallIsNotDroppedAsTextEchoWhenSpeakersAreLabelledAgain() throws {
    func segment(_ id: String, _ words: [String], track: String, start: Double) -> TranscriptSegment {
        var text = ""
        var timed: [TimedWord] = []
        for (index, word) in words.enumerated() {
            if !text.isEmpty { text += " " }
            timed.append(TimedWord(text: word, start: start + Double(index) * 0.4, end: start + Double(index) * 0.4 + 0.3,
                                   utf16Offset: text.utf16.count, utf16Length: word.utf16.count))
            text += word
        }
        return TranscriptSegment(id: id, start: start, end: start + Double(words.count) * 0.4, text: text,
                                 words: timed, track: track)
    }
    // The call says "that sounds right"; the microphone heard its echo as "that sounds write", 0.3 s later.
    let heard = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                           backend: .speech, segments: [segment("S", ["that", "sounds", "right"], track: "system", start: 10),
                                                        segment("M", ["that", "sounds", "write"], track: "mic",
                                                                start: 10.3)])
    var parameters = AlignmentParameters.v1
    parameters.echoWindowSeconds = 1.0
    #expect(EchoFilter.echoSpans(transcript: heard, parameters: parameters).isEmpty, "Two words in a row are kept.")
    let edited = try #require(try TranscriptWordEdit.editing(editRequest(2, 3, "right", segment: "M"), in: heard,
                                                              base: nil)).transcript
    // The edited word is never echo, nor part of a run that would hide the words around it.
    #expect(EchoFilter.echoSpans(transcript: edited, parameters: parameters).isEmpty)
    var unedited = heard
    unedited.segments[1] = segment("M", ["that", "sounds", "right"], track: "mic", start: 10.3)
    #expect(EchoFilter.echoSpans(transcript: unedited, parameters: parameters)
        == [WordSpan(segmentID: "M", first: 0, end: 3)], "The same words as recognized are the call's echo.")
    // An edited word breaks a run as a word the call did not say: its neighbours do not join into one around it.
    let rarely = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                            backend: .speech, segments: [segment("S", ["I", "think", "so"], track: "system", start: 10),
                                                         segment("M", ["I", "rarely", "think", "so"], track: "mic",
                                                                 start: 10.3)])
    #expect(EchoFilter.echoSpans(transcript: rarely, parameters: parameters).isEmpty)
    let really = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "really", segment: "M"), in: rarely,
                                                              base: nil)).transcript
    #expect(EchoFilter.echoSpans(transcript: really, parameters: parameters).isEmpty,
            "“I think so” around the edited word is not one echo run.")
    // Edited into a word with no letters or digits ("…"): still a break.
    let ellipsis = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "…", segment: "M"), in: rarely,
                                                                base: nil)).transcript
    #expect(EchoFilter.echoSpans(transcript: ellipsis, parameters: parameters).isEmpty)
    let tracks = [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
                  SpeakerRunBuilder.TrackInput(track: "system", policy: .channel(speakerID: "system:all",
                                                                                 displayName: "Others"))]
    let run = SpeakerRunBuilder.build(sessionID: "SESSION", transcript: edited, tracks: tracks, engine: nil,
                                      parameters: parameters).run
    let micWords = run.turns.filter { $0.track == "mic" }.flatMap(\.spans).flatMap { Array($0.first..<$0.end) }
    #expect(micWords == [0, 1, 2], "The corrected words stay in the labels and the exports.")
    #expect(run.droppedWords.isEmpty)
}

@Test func anEditedWordIsNeverHiddenAsEcho() throws {
    let (transcript, run) = editCall()
    // Word 2 is echo by the mask; once the person edited it (here without the review, which would not show it), the
    // projection shows it.
    let edited = try #require(try TranscriptWordEdit.editing(editRequest(2, 3, "Two", segment: "M"), in: transcript,
                                                              base: nil))
    var moved = run
    moved.transcriptID = edited.transcript.id
    let view = SpeakerProjection.make(run: moved, transcript: edited.transcript, edits: [], recognition: nil,
                                      profileNames: [:], acousticEcho: editEchoMask)
    let turn = try #require(view.turns.first { $0.track == "mic" })
    #expect(turn.spans.flatMap { Array($0.first..<$0.end) } == [0, 1, 2, 4, 5, 6, 7, 8, 9])
}
