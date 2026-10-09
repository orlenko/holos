import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import HolosTestSupport
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

/// What the recognizer wrote is kept as it was, two spaces and a line break included: a Revert (the edit back to it,
/// `verbatim`) writes back exactly that text; learning reads it cleaned (`Result.heard`).
@Test func anEditKeepsTheRecognizersWhitespaceSoARevertRestoresItExactly() throws {
    let original = "ask  more\ncloud now"
    let current = editTranscript([editRanged(original, [(0, 3), (5, 4), (10, 5), (16, 3)])])
    let edited = try #require(try TranscriptWordEdit.editing(editRequest(0, 3, "Ask for Claude"), in: current,
                                                             base: nil))
    let mark = try #require(edited.transcript.segments[0].fixes?.first)
    #expect(mark.kind == .reviewEdit && mark.heard == "ask  more\ncloud")
    #expect(edited.heard == "ask more cloud", "Learning reads it cleaned.")
    #expect(edited.transcript.segments[0].text == "Ask for Claude now")
    // The Revert: the edit's words back to its `heard`, as written.
    var revert = editRequest(mark.first, mark.end, mark.heard)
    revert.verbatim = true
    let reverted = try #require(try TranscriptWordEdit.editing(revert, in: edited.transcript, base: nil))
    #expect(reverted.transcript.segments[0].text == original)
    #expect(reverted.transcript.segments[0].words.map(\.text) == ["ask", "more", "cloud", "now"])
    // Typed text has its whitespace made one space, as before.
    let typed = try #require(try TranscriptWordEdit.editing(editRequest(mark.first, mark.end, mark.heard),
                                                            in: edited.transcript, base: nil))
    #expect(typed.transcript.segments[0].text == "ask more cloud now")
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

@Test(.timeLimit(.minutes(1))) func aCorruptEditedRangeExemptsNothingFromEcho() {
    // A mark past the segment's words is damaged: it exempts no word from echo filtering (not even the ones it would
    // cover within the segment), and is never walked.
    var segment = editSegment(["one", "two", "three"])
    segment.fixes = [TranscriptWordFix(first: 1, end: Int.max, heard: "x", kind: .reviewEdit),
                     TranscriptWordFix(first: 0, end: 1, heard: "won", kind: .reviewEdit)]
    #expect(EchoFilter.reviewEditedWords(in: editTranscript([segment])) == [WordRef(segmentID: "S1", word: 0)])
    // 60,000 marks over the same 60,000 words: each word is taken once (the marks are merged first).
    let count = 60_000
    var long = editSegment(Array(repeating: "w", count: count), id: "S2")
    long.fixes = Array(repeating: TranscriptWordFix(first: 0, end: count, heard: "x", kind: .reviewEdit), count: count)
    #expect(EchoFilter.reviewEditedWords(in: editTranscript([long])).count == count)
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
    // A segment's every word deleted goes with the segment (`aSegmentsEveryWordDeletedGoesWithItAndComesBackExactly`).
    let lone = editTranscript([editSegment(["um"])])
    let gone = try #require(try TranscriptWordEdit.editing(editRequest(0, 1, ""), in: lone, base: nil))
    #expect(gone.transcript.segments[0].text.isEmpty && gone.transcript.segments[0].removed != nil)
}

@Test func aSegmentsEveryWordDeletedGoesWithItAndComesBackExactly() throws {
    let current = editTranscript([editSegment(["That", "sounds", "fine?"]),
                                  editSegment(["Thanks,"], id: "S2", start: 3),
                                  editSegment(["Right", "then."], id: "S3", start: 4)])
    let result = try #require(try TranscriptWordEdit.editing(editRequest(0, 1, "", segment: "S2"), in: current,
                                                              base: nil))
    let emptied = result.transcript.segments[1]
    let original = current.segments[1]
    // The segment stays (its ID, times, and track), with no text, words, or fixes; what it held is kept beside it.
    #expect(emptied.id == "S2" && emptied.start == original.start && emptied.end == original.end)
    #expect(emptied.track == original.track)
    #expect(emptied.text.isEmpty && emptied.words.isEmpty && emptied.fixes == nil)
    #expect(emptied.removed == TranscriptRemovedWords(text: "Thanks,", words: original.words, fixes: nil))
    #expect(WordTiming.effectiveWords(of: emptied).isEmpty && !TranscriptWordEdit.isDamaged(emptied))
    #expect(result.transcript.segments[0] == current.segments[0] && result.transcript.segments[2] == current.segments[2])
    #expect(result.transcript.text == "That sounds fine? Right then.", "No empty piece, no double space.")
    #expect(result.deletion && result.meant.isEmpty && result.shown == "Thanks," && result.holdsDeleted)
    #expect(result.before == nil && result.after == nil)
    // Every word, replaced by none: the labels' move, and the field's.
    let move = ReviewWordMove(segmentID: "S2", replaced: 0..<1, replacement: 0..<0)
    #expect(result.move == move && result.labelsMove == move)
    #expect(result.move.map(WordRef(segmentID: "S2", word: 0)).replaced, "A field on the word is never followed.")
    #expect(result.transcript.liveCorrectedFrom == current.id && result.transcript.fixedFrom == nil)
    #expect(result.base == nil)
    #expect(TranscriptWordEdit.hasReviewEdits(result.transcript), "A pass that replaces the transcript keeps it.")
    #expect(TranscriptWordEdit.removedText(of: emptied, fixed: false) == "Thanks,")
    // Nothing more to delete or edit there.
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 1, "", segment: "S2"), in: result.transcript, base: nil)
    }

    // The Restore: the recognizer's words back exactly, their times included.
    let restored = try #require(try TranscriptWordEdit.editing(.restoring(segmentID: "S2"), in: result.transcript,
                                                                base: nil))
    #expect(restored.transcript.segments == current.segments)
    #expect(restored.move == ReviewWordMove(segmentID: "S2", replaced: 0..<0, replacement: 0..<1))
    #expect(restored.labelsMove == restored.move && !restored.deletion && restored.meant == "Thanks,")
    #expect(!TranscriptWordEdit.hasReviewEdits(restored.transcript))
    // Restoring words that are not deleted is refused.
    let refusal = #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(.restoring(segmentID: "S2"), in: current, base: nil)
    }
    #expect(refusal?.localizedDescription == "Those words are no longer deleted; reload and try again.")
}

@Test func aSegmentsEveryWordDeletedInAFixedTranscriptGoesFromItsBaseToo() async throws {
    let base = editTranscript([editSegment(["ask", "now"]), editSegment(["thanks", "cloud"], id: "S2", start: 3)])
    let corrections = [Correction(heard: "cloud", meant: "Claude")]
    let fixed = try await editFixed(base, corrections)
    #expect(fixed.segments[1].text == "thanks Claude")
    let result = try #require(try TranscriptWordEdit.editing(editRequest(0, 2, "", segment: "S2"), in: fixed,
                                                              base: base))
    let newBase = try #require(result.base)
    #expect(result.transcript.fixedFrom == newBase.id && newBase.fixedFrom == nil)
    #expect(newBase.liveCorrectedFrom == base.id && result.transcript.liveCorrectedFrom == base.id)
    // One record in both layers: the recognizer's words, and the fixed ones (their automatic fix with them).
    let kept = try #require(result.transcript.segments[1].removed)
    #expect(newBase.segments[1].removed == kept && newBase.segments[1].text.isEmpty)
    #expect(kept.text == "thanks cloud" && kept.fixes == nil)
    #expect(kept.fixed?.text == "thanks Claude" && kept.fixed?.fixes?.map(\.kind) == [.correction])
    #expect(newBase.segments[0] == base.segments[0])
    #expect(TranscriptWordEdit.removedText(of: result.transcript.segments[1], fixed: true) == "thanks Claude")
    #expect(TranscriptWordEdit.removedText(of: newBase.segments[1], fixed: false) == "thanks cloud")

    // Word fixes made again from the new base keep the deletion (nothing to fix in an empty segment), and the record.
    let again = try await editFixed(newBase, corrections)
    #expect(again.segments[1].text.isEmpty && again.segments[1].removed == kept)
    #expect(again.segments[0] == result.transcript.segments[0])

    // Restored from the edited revision, and from the one word fixes made again: as it was, its fix with it, and the
    // base the recognizer's words.
    for current in [result.transcript, again] {
        let restored = try #require(try TranscriptWordEdit.editing(.restoring(segmentID: "S2"), in: current,
                                                                    base: newBase))
        #expect(restored.transcript.segments == fixed.segments)
        #expect(restored.base?.segments == base.segments)
        #expect(restored.meant == "thanks Claude")
        // Then edited as before: the fix and its unfixed words still match.
        let edited = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claudia", segment: "S2"),
                                                                  in: restored.transcript, base: restored.base))
        #expect(edited.transcript.segments[1].text == "thanks Claudia" && edited.heard == "cloud")
    }

    // Fixed words kept that no longer match the unfixed ones give way to them (as words not fixed yet).
    var stale = again
    stale.segments[1].removed?.fixed = TranscriptSegmentWords(text: "other words", words: [
        TimedWord(text: "other", start: 3, end: 3.8, utf16Offset: 0, utf16Length: 5),
        TimedWord(text: "words", start: 4, end: 4.8, utf16Offset: 6, utf16Length: 5),
    ])
    let fallback = try #require(try TranscriptWordEdit.editing(.restoring(segmentID: "S2"), in: stale, base: newBase))
    #expect(fallback.transcript.segments[1] == base.segments[1])
}

/// An automatic fix whose recorded count of recognizer words does not lie over what it matched in the unfixed revision
/// (a wrong but positive `heardWords`): the segment is not deleted whole, as no edit of it is made, since the two
/// records kept could never be restored together.
@Test func aSegmentWhoseFixDoesNotMatchItsUnfixedWordsIsNotDeletedWhole() async throws {
    let base = editTranscript([editSegment(["thanks", "big", "cloud"], id: "S2")])
    let fixed = try await editFixed(base, [Correction(heard: "cloud", meant: "Claude")])
    var wrong = fixed
    wrong.segments[0].fixes?[0].heardWords = 2
    #expect(!TranscriptWordEdit.isDamaged(wrong.segments[0]), "Sound on its own: only the unfixed words tell.")
    let refusal = #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 3, "", segment: "S2"), in: wrong, base: base)
    }
    #expect(refusal?.localizedDescription == "These words cannot be matched to the transcript they were fixed from.")
    // The same words with the right count are deleted, and restored.
    let deleted = try #require(try TranscriptWordEdit.editing(editRequest(0, 3, "", segment: "S2"), in: fixed,
                                                               base: base))
    let restored = try #require(try TranscriptWordEdit.editing(.restoring(segmentID: "S2"), in: deleted.transcript,
                                                                base: deleted.base))
    #expect(restored.transcript.segments == fixed.segments)
}

@Test func aSegmentWithAWordCorrectedWhileRecordingIsNotDeletedWhole() throws {
    var segment = editSegment(["um", "thing"])
    segment.fixes = [TranscriptWordFix(first: 1, end: 2, heard: "think", kind: .liveCorrection, heardWords: 1)]
    let refusal = #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 2, ""), in: editTranscript([segment]), base: nil)
    }
    #expect(refusal?.localizedDescription == TranscriptWordEdit.liveCorrected.localizedDescription)
    // Words beside another turn's (not editable here) are neither merged into them nor taken with the segment.
    let fenced = #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 1, ""), in: editTranscript([editSegment(["um", "yes"])]),
                                       base: nil, editable: { $0 == 0 })
    }
    #expect(fenced?.localizedDescription.contains("every word of their segment") == true)
}

@Test func deletedWordsKeptBesideWordsOfTheirOwnAreDamaged() throws {
    var segment = editSegment(["Thanks,"])
    segment.removed = TranscriptRemovedWords(text: "Thanks,", words: segment.words)
    #expect(TranscriptWordEdit.isDamaged(segment), "Which of the two it holds cannot be told.")
    // A kept record whose words do not fit its text is never restored.
    let emptied = TranscriptSegment(id: "S1", start: 0, end: 1, text: "", track: "system", removed:
        TranscriptRemovedWords(text: "Hi", words: [TimedWord(text: "Hello", start: 0, end: 1, utf16Offset: 0,
                                                             utf16Length: 5)]))
    #expect(!TranscriptWordEdit.isDamaged(emptied))
    let refusal = #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(.restoring(segmentID: "S1"), in: editTranscript([emptied]), base: nil)
    }
    #expect(refusal?.localizedDescription == TranscriptWordEdit.damagedMarks.localizedDescription)
}

/// An older Voice is Local decodes a segment without knowing `removed`: it reads one with no text and no words, so it
/// shows and exports nothing of the deleted words. A segment with nothing deleted encodes as before.
@Test func anOlderBuildReadsADeletedSegmentAsOneWithNoWords() throws {
    struct OlderSegment: Decodable { var id: String; var text: String; var words: [TimedWord] }
    let current = editTranscript([editSegment(["Thanks,"])])
    let result = try #require(try TranscriptWordEdit.editing(editRequest(0, 1, ""), in: current, base: nil))
    let data = try JSONEncoder().encode(result.transcript.segments[0])
    let older = try JSONDecoder().decode(OlderSegment.self, from: data)
    #expect(older.id == "S1" && older.text.isEmpty && older.words.isEmpty)
    #expect(try JSONDecoder().decode(TranscriptSegment.self, from: data) == result.transcript.segments[0])
    let plain = String(decoding: try JSONEncoder().encode(current.segments[0]), as: UTF8.self)
    #expect(!plain.contains("removed"))
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

/// Frames centred in 10.8–11.5 s (words 2 and 3 of M) are echo, the rest local, the predicted echo 20 dB below the
/// microphone (the user's own speech, so the word rule trusts it).
private let editEchoMask: AcousticEchoMask = {
    let count = Int(30 / AcousticEchoMask.hopSeconds)
    let classes = (0..<count).map { frame -> UInt8 in
        let centre = AcousticEchoMask.centre(ofFrame: frame)
        return (centre >= 10.8 && centre < 11.5 ? AcousticEchoMask.FrameClass.echo : .local).rawValue
    }
    return AcousticEchoMask(classes: classes, echoLevels: Array(repeating: -40, count: count))!
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

@Test func aDeletionGoesToTheNeighbourWhoseMarkStaysInTheTurn() throws {
    // "so um cloud now": the turn holds "so um cloud" (words 0–2); "cloud now" is one automatic fix, so the next
    // neighbour would take in "now", another turn's word. "um" deleted: it goes into "so" instead.
    var segment = editSegment(["so", "um", "cloud", "now"])
    segment.fixes = [TranscriptWordFix(first: 2, end: 4, heard: "clod know", kind: .correction, heardWords: 2)]
    let result = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, ""), in: editTranscript([segment]),
                                                             base: nil, editable: { $0 < 3 }))
    #expect(result.labelsMove.replaced == 0..<2 && result.transcript.segments[0].text == "so cloud now")
    // With no previous word in the turn either, it is refused (never across the turn).
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(1, 2, ""), in: editTranscript([segment]), base: nil,
                                       editable: { (1..<3).contains($0) })
    }
}

@Test func aWordRangeThatDoesNotFitItsTextIsDamagedNeverAddedUp() {
    // Decodable, but "now" runs Int.max units on: its range is never added up, and the segment is not edited.
    var segment = editSegment(["ask", "cloud", "now"])
    segment.words[2].utf16Length = Int.max
    #expect(TranscriptWordEdit.isDamaged(segment))
    // Shown text never adds it up: the last word reads to the end of the text, the first as before.
    #expect(TranscriptWordEdit.shownText(of: segment, first: 2, end: 3) == "now")
    #expect(TranscriptWordEdit.shownText(of: segment, first: 0, end: 1) == "ask")
    // A word whose offset is past the text: nothing is read for it.
    segment.words[1].utf16Offset = Int.max
    #expect(TranscriptWordEdit.shownText(of: segment, first: 1, end: 2) == nil)
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 1, "as"), in: editTranscript([segment]), base: nil)
    }
    // Words out of order (one starts before the previous ends): damaged too.
    var unordered = editSegment(["ask", "cloud", "now"])
    unordered.words[2].utf16Offset = 1
    #expect(TranscriptWordEdit.isDamaged(unordered))
}

@Test func aWordBoundaryInsideACharacterIsDamaged() {
    // "hi 😀 there": the emoji is two UTF-16 units (3–4). A word starting at 4 would split it when edited.
    let sound = editRanged("hi 😀 there", [(0, 2), (3, 2), (6, 5)])
    #expect(!TranscriptWordEdit.isDamaged(sound))
    var split = sound
    split.words[1].utf16Length = 1
    #expect(TranscriptWordEdit.isDamaged(split))
    var inside = sound
    inside.words[2].utf16Offset = 4
    inside.words[2].utf16Length = 7
    #expect(TranscriptWordEdit.isDamaged(inside))
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(2, 3, "world"), in: editTranscript([inside]), base: nil)
    }
}

@Test func aFixIsNeverRevertedOntoADamagedUnfixedRevision() async throws {
    let base = editTranscript([editSegment(["ask", "cloud", "now"])])
    let fixed = try await editFixed(base, [Correction(heard: "cloud", meant: "Claude")])
    #expect(fixed.segments[0].text == "ask Claude now")
    // The unfixed revision as read back, damaged: "now" lies past its text. Its words would come back incomplete.
    var damaged = base
    damaged.segments[0].words[2].utf16Offset = Int.max
    #expect(throws: HolosError.self) {
        try WordFixes.reverting(WordRef(segmentID: "S1", word: 1), in: fixed, to: damaged)
    }
    // As written, the revert is made.
    let reverted = try WordFixes.reverting(WordRef(segmentID: "S1", word: 1), in: fixed, to: base)
    #expect(reverted.segments[0].text == "ask cloud now")
}

@Test func aFixIsNeverRevertedWhenASegmentIDRepeats() async throws {
    let base = editTranscript([editSegment(["ask", "cloud", "now"])])
    let fixed = try await editFixed(base, [Correction(heard: "cloud", meant: "Claude")])
    // The unfixed revision as read back holds "S1" twice: which copy the fix came from cannot be told, even when the
    // first one is the right one.
    var repeated = base
    repeated.segments.append(base.segments[0])
    #expect(TranscriptWordEdit.hasRepeatedSegmentIDs(repeated))
    #expect(throws: HolosError.self) {
        try WordFixes.reverting(WordRef(segmentID: "S1", word: 1), in: fixed, to: repeated)
    }
    // The current revision too.
    var current = fixed
    current.segments.append(fixed.segments[0])
    #expect(throws: HolosError.self) {
        try WordFixes.reverting(WordRef(segmentID: "S1", word: 1), in: current, to: base)
    }
    #expect(try WordFixes.reverting(WordRef(segmentID: "S1", word: 1), in: fixed, to: base).segments[0].text
        == "ask cloud now")
}

@Test func anAutomaticFixEditedBackLeavesTheSegmentEditable() async throws {
    // "你好世界 再见", timed as "你好", "世界", "再见"; the word-fix stage made "你好世界" "你好地球" (one word).
    let base = editTranscript([editRanged("你好世界 再见", [(0, 2), (2, 2), (5, 2)])])
    let fixed = try await editFixed(base, [Correction(heard: "你好世界", meant: "你好地球")])
    #expect(fixed.segments[0].text == "你好地球 再见")
    // Edited back in Review: both revisions count the edited words alike, so the next edit is made.
    let back = try #require(try TranscriptWordEdit.editing(editRequest(0, 1, "你好世界"), in: fixed, base: base))
    let edited = try #require(back.base)
    #expect(WordTiming.effectiveWords(of: back.transcript.segments[0]).count
        == WordTiming.effectiveWords(of: edited.segments[0]).count)
    let next = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "拜拜"), in: back.transcript,
                                                           base: edited))
    #expect(next.transcript.segments[0].text == "你好世界 拜拜")
}

@Test func anAutomaticFixEditedBackOverSpacedWordRangesLeavesTheSegmentEditable() async throws {
    // Apple's recognizer: " 你好" carries the space before it. "你好世界" was fixed to "你好地球", then edited back.
    let base = editTranscript([editRanged("ok 你好世界 再见", [(0, 2), (2, 3), (5, 2), (7, 3)])])
    let fixed = try await editFixed(base, [Correction(heard: "你好世界", meant: "你好地球")])
    #expect(fixed.segments[0].text == "ok 你好地球 再见")
    let back = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "你好世界"), in: fixed, base: base))
    let edited = try #require(back.base)
    #expect(WordTiming.effectiveWords(of: back.transcript.segments[0]).count
        == WordTiming.effectiveWords(of: edited.segments[0]).count)
    let next = try #require(try TranscriptWordEdit.editing(editRequest(2, 3, "拜拜"), in: back.transcript,
                                                           base: edited))
    #expect(next.transcript.segments[0].text == "ok 你好世界 拜拜")
}

@Test func aWordThatReadsOtherwiseThanItsTextIsDamaged() {
    // "one two three", with "two" pointing one character on: its range reads "wo ".
    var segment = editRanged("one two three", [(0, 3), (4, 3), (8, 5)])
    #expect(!TranscriptWordEdit.isDamaged(segment))
    segment.words[1].utf16Offset = 5
    #expect(TranscriptWordEdit.isDamaged(segment))
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(1, 2, "four"), in: editTranscript([segment]), base: nil)
    }
}

@Test func wordCountsThatAddUpButPutAFixElsewhereAreDamaged() throws {
    // Base "one two three four"; fixed "Alpha Beta": "one two" made "Alpha", "three four" made "Beta". The recorded
    // counts 3 and 1 add up to the base's four words, but put "Alpha" over "one two three".
    let base = editSegment(["one", "two", "three", "four"])
    var fixed = editSegment(["Alpha", "Beta"])
    let sound = [TranscriptWordFix(first: 0, end: 1, heard: "one two", kind: .correction, heardWords: 2),
                 TranscriptWordFix(first: 1, end: 2, heard: "three four", kind: .correction, heardWords: 2)]
    let wrong = [TranscriptWordFix(first: 0, end: 1, heard: "one two", kind: .correction, heardWords: 3),
                 TranscriptWordFix(first: 1, end: 2, heard: "three four", kind: .correction, heardWords: 1)]
    let current = WordTiming.effectiveWords(of: fixed)
    let baseWords = WordTiming.effectiveWords(of: base)
    let baseText = Array(base.text.utf16)
    #expect(TranscriptWordEdit.baseBounds(fixes: sound, current: current, base: baseWords, baseText: baseText)
        == [0, 2, 4])
    #expect(TranscriptWordEdit.baseBounds(fixes: wrong, current: current, base: baseWords, baseText: baseText) == nil)
    #expect(WordFixes.originalWordRanges(fixes: sound, currentWords: current, originalWords: baseWords,
                                         originalText: baseText) == [0..<2, 2..<4])
    #expect(WordFixes.originalWordRanges(fixes: wrong, currentWords: current, originalWords: baseWords,
                                         originalText: baseText).isEmpty)
    // Reverting "Alpha" with the wrong counts is refused, never restoring "one two three".
    fixed.fixes = wrong
    var fixedTranscript = editTranscript([fixed])
    let baseTranscript = editTranscript([base])
    fixedTranscript.fixedFrom = baseTranscript.id
    #expect(throws: HolosError.self) {
        try WordFixes.reverting(WordRef(segmentID: "S1", word: 0), in: fixedTranscript, to: baseTranscript)
    }
    fixed.fixes = sound
    fixedTranscript.segments = [fixed]
    let reverted = try WordFixes.reverting(WordRef(segmentID: "S1", word: 0), in: fixedTranscript, to: baseTranscript)
    #expect(reverted.segments[0].text == "one two Beta")
}

@Test(.timeLimit(.minutes(1))) func anAutomaticFixsHeardTextIsFoundInOnePass() {
    // A damaged base: one word of 400,000 "a"s, and a fix that says it heard 199,999 "a"s then a "b" there. Looked for
    // at every offset this would be some 10¹¹ comparisons; found in one pass it is not there.
    let long = String(repeating: "a", count: 400_000)
    let words = [EffectiveWord(text: long, start: 0, end: 1, utf16Offset: 0, utf16Length: 400_000, estimated: false)]
    let fix = TranscriptWordFix(first: 0, end: 1, heard: String(repeating: "a", count: 199_999) + "b",
                                kind: .correction, heardWords: 1)
    #expect(!fix.heardFits(words: words, range: 0..<1, text: Array(long.utf16)))
    // As written, it is found: starting in the first word, ending in the last.
    let text = Array("as cloud now".utf16)
    let sound = [EffectiveWord(text: "as", start: 0, end: 1, utf16Offset: 0, utf16Length: 2, estimated: false),
                 EffectiveWord(text: "cloud", start: 1, end: 2, utf16Offset: 3, utf16Length: 5, estimated: false),
                 EffectiveWord(text: "now", start: 2, end: 3, utf16Offset: 9, utf16Length: 3, estimated: false)]
    let cloud = TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .correction, heardWords: 1)
    #expect(cloud.heardFits(words: sound, range: 1..<2, text: text))
    #expect(!cloud.heardFits(words: sound, range: 1..<3, text: text), "It does not reach the last word.")
    #expect(!cloud.heardFits(words: sound, range: 0..<2, text: text), "It does not start in the first word.")
}

@Test func aFixThatMatchedUntimedPunctuationLeavesTheSegmentEditable() throws {
    // "hello. next", timed as "hello" and "next" (the period untimed); "hello." was corrected to "Hi!".
    let base = editTranscript([editRanged("hello. next", [(0, 5), (7, 4)])])
    var fixedSegment = editRanged("Hi! next", [(0, 3), (4, 4)])
    fixedSegment.fixes = [TranscriptWordFix(first: 0, end: 1, heard: "hello.", kind: .correction, heardWords: 1)]
    var fixed = editTranscript([fixedSegment])
    fixed.fixedFrom = base.id
    // What it matched runs past the timed "hello" into the period, never into "next": it fits.
    #expect(fixedSegment.fixes![0].heardFits(words: WordTiming.effectiveWords(of: base.segments[0]), range: 0..<1,
                                             text: Array(base.segments[0].text.utf16)))
    let next = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "then"), in: fixed, base: base))
    #expect(next.transcript.segments[0].text == "Hi! then")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aDamagedSegmentIsNeverMappedByTime() async throws {
    // Labels mapped from a transcript whose second language piece has a mark ending at Int.max (combining pieces would
    // offset it past Int.max): refused, never trapped.
    let temp = try TemporaryDirectory("review", permissions: 0o700)
    defer { temp.remove() }
    let segment = editSegment(["ask", "cloud", "now"])
    let transcript = editTranscript([segment])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 4],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let speaker = SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"])
    let run = DiarizationRun(
        sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1),
        tracks: [TrackDiarization(track: "system", policy: .diarized,
                                  clusters: [ClusterSummary(clusterID: speaker.id, track: "system", speechSeconds: 3)])],
        speakers: [speaker],
        turns: [SpeakerTurn(id: "T1", track: "system", start: 0, end: 3, speakerID: speaker.id, clusterID: speaker.id,
                            spans: [WordSpan(segmentID: "S1", first: 0, end: 3)], overlap: false,
                            otherClusters: [], assignmentScore: 1, timing: .measured)])
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    var damaged = snapshot.transcript
    damaged.id = UUID().uuidString
    damaged.segments[0].fixes = [TranscriptWordFix(first: 1, end: Int.max, heard: "clod", kind: .correction,
                                                   heardWords: 1)]
    #expect(throws: HolosError.self) {
        try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: damaged)
    }
}

@Test func aWordMoveIsReadOnlyAsItIsWritten() {
    #expect(SessionWordEdit.parseRange("3-5") == 3..<5 && SessionWordEdit.parseRange("0-0") == 0..<0)
    for damaged in ["-1-2", "1--2", "3-", "-5", "3-5-7", "+3-5", " 3-5", "3-5 ", "5-3", "3_5", "٣-٥", "",
                    "99999999999999999999-1"] {
        #expect(SessionWordEdit.parseRange(damaged) == nil, "\(damaged)")
    }
    #expect(SessionWordEdit.parseRange(nil) == nil)
}

@Test func twoMarksOverTheSameWordAreDamaged() throws {
    // Each in range on its own, but both over "cloud": damaged, and the segment is not edited.
    var segment = editSegment(["ask", "cloud", "now"])
    segment.fixes = [TranscriptWordFix(first: 0, end: 2, heard: "as cloud", kind: .reviewEdit, heardWords: 2),
                     TranscriptWordFix(first: 1, end: 3, heard: "cloud now", kind: .correction, heardWords: 2)]
    #expect(segment.fixes!.allSatisfy { TranscriptWordEdit.isSound($0, wordCount: 3) })
    #expect(TranscriptWordEdit.isDamaged(segment))
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(0, 1, "as"), in: editTranscript([segment]), base: nil)
    }
    // Side by side (one ends where the next begins): sound.
    segment.fixes = [TranscriptWordFix(first: 0, end: 1, heard: "as", kind: .reviewEdit, heardWords: 1),
                     TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .correction, heardWords: 1)]
    #expect(!TranscriptWordEdit.isDamaged(segment))
}

@Test func aDamagedHeardWordCountIsNeverAddedUp() throws {
    // A valid-looking fix whose recorded count of recognizer words cannot be right.
    for heardWords in [Int.max, 0, -1, 6] {
        let damaged = TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .correction, heardWords: heardWords)
        #expect(damaged.heardWordCount() == nil, "\(heardWords)")
        var segment = editSegment(["ask", "Claude", "now"])
        segment.fixes = [damaged]
        #expect(!TranscriptWordEdit.isSound(damaged, wordCount: 3) && TranscriptWordEdit.isDamaged(segment))
        // No overflow counting it against the base, nor building word origins from it.
        let base = editSegment(["ask", "cloud", "now"])
        #expect(TranscriptWordEdit.baseBounds(fixes: [damaged], current: WordTiming.effectiveWords(of: segment),
                                              base: WordTiming.effectiveWords(of: base),
                                              baseText: Array(base.text.utf16)) == nil)
        #expect(WordFixes.originalWordRanges(fixes: [damaged], currentWords: WordTiming.effectiveWords(of: segment),
                                             originalWords: WordTiming.effectiveWords(of: base),
                                             originalText: Array(base.text.utf16)).isEmpty)
        #expect(throws: HolosError.self) {
            try TranscriptWordEdit.editing(editRequest(0, 1, "as"), in: editTranscript([segment]), base: nil)
        }
    }
    // A sound one: as many words as `heard` can hold, and no more than are left.
    let sound = TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .correction, heardWords: 1)
    #expect(sound.heardWordCount() == 1 && sound.heardWordCount(within: 0) == nil)
}

@Test func anEditOverADamagedMarkIsRefusedNeverRead() throws {
    // A damaged but decodable transcript: a mark with no words, and one running backwards, among the edited words.
    for damaged in [TranscriptWordFix(first: 1, end: 1, heard: "cloud", kind: .correction, heardWords: 1),
                    TranscriptWordFix(first: 2, end: 1, heard: "cloud", kind: .reviewEdit, heardWords: 1)] {
        var segment = editSegment(["ask", "cloud", "now"])
        segment.fixes = [damaged]
        #expect(throws: HolosError.self) {
            try TranscriptWordEdit.editing(editRequest(0, 3, "ask Claude now"), in: editTranscript([segment]),
                                           base: nil)
        }
    }
}
