import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// The pure parts of the meeting word-fix stage (docs/design.md "Meeting word fixes"): replacing phrases while the
// words keep their times, the fixes' marks, the questions put to the model, and the transcript lineage the other
// stages follow. Every sentence is invented.

/// A timed segment: one word every 0.5 s from `start`, each lasting 0.4 s.
private func wordFixSegment(_ text: String, start: Double = 10, id: String = "S1") -> TranscriptSegment {
    SessionFixtures.segment(text.split(separator: " ").map(String.init), track: "mic", start: start, id: id)
}

/// `segment` with `list`'s corrections made, as the stage makes them.
private func corrected(_ segment: TranscriptSegment, _ list: CorrectionList) throws -> TranscriptSegment {
    let working = try #require(WordFixes.Working(segment))
    return WordFixes.finished(WordFixes.applying(WordFixes.corrections(in: working, list: list), to: working),
                              segment: segment)
}

private func pairs(_ entries: [(String, String)]) -> CorrectionList {
    CorrectionList(entries: entries.map { Correction(heard: $0.0, meant: $0.1) })
}

// MARK: - Timings and marks

@Test func aReplacedPhraseTakesTheTimeOfTheWordsItReplaced() throws {
    let segment = wordFixSegment("the a bundu box runs fine")
    let fixed = try corrected(segment, pairs([("a bundu", "ubuntu")]))
    #expect(fixed.text == "the ubuntu box runs fine")
    #expect(fixed.words.map(\.text) == ["the", "ubuntu", "box", "runs", "fine"])
    // "ubuntu" spans "a" (10.5–10.9) and "bundu" (11.0–11.4); the rest keep their times.
    #expect(fixed.words[1].start == segment.words[1].start && fixed.words[1].end == segment.words[2].end)
    #expect(fixed.words[0] == segment.words[0])
    #expect(fixed.words[2].start == segment.words[3].start && fixed.words[4].end == segment.words[5].end)
    // Offsets point into the new text.
    for word in fixed.words {
        let utf16 = Array(fixed.text.utf16)
        #expect(String(decoding: utf16[word.utf16Offset..<(word.utf16Offset + word.utf16Length)], as: UTF16.self)
            == word.text)
    }
    #expect(fixed.fixes == [TranscriptWordFix(first: 1, end: 2, heard: "a bundu", kind: .correction)])
    #expect(fixed.id == segment.id && fixed.start == segment.start && fixed.end == segment.end)
}

@Test func oneWordMayBecomeSeveralSharingItsTime() throws {
    let segment = wordFixSegment("we run onobunto here")
    let fixed = try corrected(segment, pairs([("onobunto", "on Ubuntu")]))
    #expect(fixed.text == "we run on Ubuntu here")
    #expect(fixed.words.map(\.text) == ["we", "run", "on", "Ubuntu", "here"])
    let old = segment.words[2]
    #expect(fixed.words[2].start == old.start && fixed.words[3].end == old.end)
    #expect(abs(fixed.words[2].end - (old.start + old.end) / 2) < 1e-9 && fixed.words[3].start == fixed.words[2].end)
    #expect(fixed.words[4] == TimedWord(text: "here", start: segment.words[3].start, end: segment.words[3].end,
                                        utf16Offset: 17, utf16Length: 4))
    #expect(fixed.fixes == [TranscriptWordFix(first: 2, end: 4, heard: "onobunto", kind: .correction)])
}

@Test func marksAroundAWordStayAndCaseFollowsTheSentence() throws {
    // The recognizer's words carry their marks ("Bundu,"); a sentence start gives the capital.
    let segment = wordFixSegment("Bundu, then bundu.")
    let fixed = try corrected(segment, pairs([("bundu", "ubuntu")]))
    #expect(fixed.text == "Ubuntu, then ubuntu.")
    #expect(fixed.words.map(\.text) == ["Ubuntu,", "then", "ubuntu."])
    #expect(fixed.fixes?.map(\.heard) == ["Bundu", "bundu"])
    #expect(fixed.fixes?.map(\.first) == [0, 2])
}

@Test func anUntimedSegmentIsFixedInItsText() throws {
    let segment = TranscriptSegment(id: "U1", start: 3, end: 6, text: "ask a  bundu box now", track: "system")
    let fixed = try corrected(segment, pairs([("a bundu", "on Ubuntu")]))
    #expect(fixed.text == "ask on Ubuntu box now" && fixed.words.isEmpty)
    // Marks are effective words: the text's whitespace-separated tokens.
    #expect(fixed.fixes == [TranscriptWordFix(first: 1, end: 3, heard: "a  bundu", kind: .correction)])
    #expect(WordTiming.effectiveWords(of: fixed).count == 5)
}

@Test func wordOffsetsThatDoNotFitLeaveTheSegmentAlone() {
    var segment = wordFixSegment("one two three")
    segment.words[2].utf16Offset = 2  // before the previous word's end
    #expect(WordFixes.Working(segment) == nil)
    var past = wordFixSegment("one two")
    past.words[1].utf16Length = 40
    #expect(WordFixes.Working(past) == nil)
}

@Test func overlappingAndRefixedPlacesAreLeftOut() throws {
    let segment = wordFixSegment("ask cloud code now")
    var working = try #require(WordFixes.Working(segment))
    working = WordFixes.applying([
        WordFixes.Replacement(range: 4..<14, text: "Claude Code", kind: .correction),
        WordFixes.Replacement(range: 10..<14, text: "Kode", kind: .term),  // inside the first
        WordFixes.Replacement(range: 19..<30, text: "x", kind: .term),  // past the text
        WordFixes.Replacement(range: 0..<3, text: "  ", kind: .term),  // nothing but spaces
    ], to: working)
    #expect(working.text == "ask Claude Code now")
    // A later pass never changes what an earlier one fixed.
    let again = WordFixes.applying([WordFixes.Replacement(range: 4..<10, text: "Clod", kind: .term)], to: working)
    #expect(again == working)
    let fixed = WordFixes.finished(working, segment: segment)
    #expect(fixed.fixes == [TranscriptWordFix(first: 1, end: 3, heard: "cloud code", kind: .correction)])
    #expect(WordFixes.finished(try #require(WordFixes.Working(segment)), segment: segment) == segment,
            "A segment with nothing fixed stays as it was.")
}

@Test func countsAreByKind() {
    var segment = wordFixSegment("a b c")
    segment.fixes = [TranscriptWordFix(first: 0, end: 1, heard: "x", kind: .correction),
                     TranscriptWordFix(first: 2, end: 3, heard: "y", kind: .term)]
    let counts = WordFixes.Counts(SessionFixtures.transcript([segment, wordFixSegment("d", id: "S2")]))
    #expect(counts == WordFixes.Counts(corrections: 1, terms: 1) && counts.total == 2)
    #expect(WordFixStage.summary(WordFixes.Counts(corrections: 9, terms: 3))
        == "12 misheard words: 9 by corrections, 3 word-list terms")
    #expect(WordFixStage.summary(WordFixes.Counts(terms: 1)) == "1 misheard word: 1 word-list term")
    #expect(WordFixStage.note(WordFixes.Counts(corrections: 1)) == "Fixed 1 misheard word.")
}

// MARK: - Asking

@Test(.timeLimit(.minutes(1)))
func aModelThatStopsAnsweringIsNotAskedAgain() async throws {
    let segments = (0..<6).map { wordFixSegment("then I asked cloud to look again", start: Double($0) * 5, id: "S\($0)") }
    let asked = SharedValue(0)
    let dependencies = WordFixDependencies(corrections: { CorrectionList() }, wordList: { WordList() },
                                           model: { _ in .available({ _, _ in
                                               asked.update { $0 += 1 }
                                               try await Task.sleep(for: .seconds(3600))
                                               return "Claude"
                                           }) }, timeout: .milliseconds(20))
    let computed = try await WordFixStage.fix(SessionFixtures.transcript(segments), title: "t",
                                              corrections: CorrectionList(), terms: pairs([("cloud", "Claude")]),
                                              dependencies: dependencies)
    #expect(computed.asked == WordFixStage.maximumTimeoutsInARow && asked.value == WordFixStage.maximumTimeoutsInARow)
    #expect(computed.counts.total == 0)
    #expect(computed.notes == [
        "Apple Intelligence stopped answering, so the last 3 places were not checked.",
        "Apple Intelligence did not answer in time for 3 places, which stay as written.",
    ])
}

// MARK: - Lineage

/// Journal events as `SessionArchive.readEvents` returns them.
private func lineageEvents(_ list: [(String, [String: String])]) throws -> [ArchiveEvent] {
    try list.enumerated().map { index, item in
        let object: [String: Any] = ["sequence": index + 1, "at": "2026-09-30T10:00:00Z", "kind": item.0,
                                     "details": item.1]
        return try HolosJSON.decoder().decode(ArchiveEvent.self,
                                              from: JSONSerialization.data(withJSONObject: object))
    }
}

@Test func aFixedTranscriptStandsForTheOneItWasFixedFrom() throws {
    let events = try lineageEvents([
        (MeetingEventKind.transcriptRebuilt, ["transcriptID": "R", "transcribed": "true"]),
        (MeetingEventKind.wordsFixed, ["transcriptID": "F1", "base": "R"]),
        (MeetingEventKind.languagesDetected, ["transcriptID": "M", "base": "R", "requested": "en-CA,fr-CA"]),
        (MeetingEventKind.wordsFixed, ["transcriptID": "F2", "base": "M"]),
    ])
    #expect(WordFixStage.unfixedID("F1", events: events) == "R")
    #expect(WordFixStage.unfixedID("F2", events: events) == "M")
    #expect(WordFixStage.unfixedID("R", events: events) == "R")
    // The rebuild's bookkeeping and the languages stage see through the fix.
    #expect(TranscriptRebuilder.recordedTranscriptID("F1", events: events) == "R")
    #expect(TranscriptRebuilder.recordedTranscriptID("F2", events: events) == "R")
    #expect(LanguageStage.mergeEvent(of: "F2", events: events)?.details["transcriptID"] == "M")
    #expect(LanguageStage.mergeEvent(of: "F1", events: events) == nil)
    #expect(TranscriptRebuilder.rebuildSaved("F1", events: events))
    // A loop in a damaged journal ends.
    let looped = try lineageEvents([(MeetingEventKind.wordsFixed, ["transcriptID": "A", "base": "B"]),
                                    (MeetingEventKind.wordsFixed, ["transcriptID": "B", "base": "A"])])
    #expect(["A", "B"].contains(WordFixStage.unfixedID("A", events: looped)))
}
