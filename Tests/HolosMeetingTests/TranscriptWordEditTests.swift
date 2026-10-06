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
    #expect(segment.fixes == [TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit)])
    #expect(result.transcript.id != current.id && result.transcript.fixedFrom == nil)
    #expect(result.transcript.liveCorrectedFrom == current.id, "An unfixed transcript stays its own word space.")
    #expect(result.base == nil)
    #expect(result.heard == "cloud" && result.meant == "Claude" && result.shown == "cloud" && !result.deletion)
    #expect(result.before == "ask" && result.after == "now")
    #expect(TranscriptWordEdit.hasReviewEdits(result.transcript) && !TranscriptWordEdit.hasReviewEdits(current))
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
    #expect(more.transcript.segments[0].fixes == [TranscriptWordFix(first: 1, end: 3, heard: "cloud", kind: .reviewEdit)])

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
    #expect(segment.fixes == [TranscriptWordFix(first: 1, end: 2, heard: "um think", kind: .reviewEdit)])
    #expect(next.deletion && next.heard == "um think" && next.meant == "think")

    let last = try #require(try TranscriptWordEdit.editing(editRequest(2, 3, " "), in: current, base: nil))
    #expect(last.transcript.segments[0].text == "I um")
    #expect(last.transcript.segments[0].fixes == [TranscriptWordFix(first: 1, end: 2, heard: "um think",
                                                                    kind: .reviewEdit)])
    // Not past a word another turn shows: the previous word is taken instead.
    let fenced = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, ""), in: current, base: nil,
                                                              editable: { $0 < 2 }))
    #expect(fenced.transcript.segments[0].text == "I think")
    #expect(fenced.transcript.segments[0].fixes == [TranscriptWordFix(first: 0, end: 1, heard: "I um",
                                                                      kind: .reviewEdit)])
    // A segment never loses all its words.
    let lone = editTranscript([editSegment(["um"])])
    #expect(throws: HolosError.self) { try TranscriptWordEdit.editing(editRequest(0, 1, ""), in: lone, base: nil) }
}

@Test func anEditOfAFixedTranscriptIsMadeInItsBaseTooSoWordFixesKeepIt() async throws {
    let base = editTranscript([editSegment(["ask", "cloud", "now", "please"])])
    let corrections = [Correction(heard: "cloud", meant: "Claude"), Correction(heard: "please", meant: "pls")]
    let fixed = try await editFixed(base, corrections)
    #expect(fixed.segments[0].text == "ask Claude now pls")

    let result = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "Claudia"), in: fixed, base: base))
    let newBase = try #require(result.base)
    #expect(newBase.segments[0].text == "ask Claudia now please")
    #expect(newBase.segments[0].fixes == [TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit)])
    #expect(newBase.fixedFrom == nil && newBase.liveCorrectedFrom == base.id)
    #expect(result.transcript.segments[0].text == "ask Claudia now pls")
    #expect(result.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit),
        TranscriptWordFix(first: 3, end: 4, heard: "please", kind: .correction),
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
                                                                      kind: .reviewEdit)])
    #expect(result.base?.segments[0].text == "we New Yorkshire here")
    #expect(result.shown == "New York" && result.meant == "New Yorkshire" && result.heard == "knew work")
    // Edited again: still what the recognizer wrote, not the first edit's text.
    let twice = try #require(try TranscriptWordEdit.editing(editRequest(1, 3, "Newark"), in: result.transcript,
                                                             base: result.base))
    #expect(twice.transcript.segments[0].fixes == [TranscriptWordFix(first: 1, end: 2, heard: "knew work",
                                                                     kind: .reviewEdit)])
    #expect(twice.base?.segments[0].text == "we Newark here")
}

@Test func anUntimedSegmentKeepsEstimatedTiming() throws {
    let untimed = TranscriptSegment(id: "S1", start: 0, end: 3, text: "one two three", track: "system")
    let current = editTranscript([untimed])
    let result = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "2 and a half"), in: current,
                                                              base: nil))
    let segment = result.transcript.segments[0]
    #expect(segment.words.isEmpty && segment.text == "one 2 and a half three")
    #expect(segment.start == 0 && segment.end == 3)
    #expect(segment.fixes == [TranscriptWordFix(first: 1, end: 5, heard: "two", kind: .reviewEdit)])
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
    #expect(result.transcript.segments[0].fixes == [TranscriptWordFix(first: 4, end: 5, heard: "Mw4", kind: .reviewEdit)])
    // Shown words 2 and 3 of the list are stored words 1 and 4, with the hidden echo between: never one edit.
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(editRequest(1, 5, "x", segment: "M"), in: transcript, base: nil,
                                       editable: editable)
    }
    // A deletion next to hidden echo merges into the shown word on the other side.
    let deleted = try #require(try TranscriptWordEdit.editing(editRequest(1, 2, "", segment: "M"), in: transcript,
                                                               base: nil, editable: editable))
    #expect(deleted.transcript.segments[0].fixes == [TranscriptWordFix(first: 0, end: 1, heard: "Mw0 Mw1",
                                                                       kind: .reviewEdit)])
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
