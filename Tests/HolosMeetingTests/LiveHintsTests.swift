import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

private func hint(_ segment: TranscriptSegment, words: Range<Int>, action: LiveHint.Action,
                  id: String = UUID().uuidString) -> LiveHint {
    let effective = WordTiming.effectiveWords(of: segment)
    let heard = effective[words].map(\.text).joined(separator: " ")
    return LiveHint(id: id, at: SessionFixtures.date, segmentID: segment.id, track: segment.track ?? "mic",
                    firstWord: words.lowerBound, endWord: words.upperBound,
                    start: effective[words.lowerBound].start, end: effective[words.upperBound - 1].end,
                    heard: heard, action: action)
}

@Test func liveTextHintUsesTheFinalSegmentIDAndKeepsWordTimes() {
    let segment = SessionFixtures.segment(["please", "send", "the", "deck"], track: "system", start: 4, id: "live")
    let original = SessionFixtures.transcript([segment], id: "original")
    let outcome = LiveHints.applyingText([
        hint(segment, words: 1..<4, action: .replaceText("share the doc"), id: "H1"),
    ], to: original, now: SessionFixtures.date.addingTimeInterval(1))

    #expect(outcome.applied == 1)
    #expect(outcome.unmatched == 0)
    #expect(outcome.transcript.id != original.id)
    #expect(outcome.transcript.liveCorrectedFrom == original.id)
    #expect(outcome.transcript.segments[0].text == "please share the doc")
    #expect(outcome.transcript.segments[0].words[1].start == segment.words[1].start)
    #expect(outcome.transcript.segments[0].words.last?.end == segment.words.last?.end)
    #expect(outcome.transcript.segments[0].fixes?.last?.kind == .liveCorrection)
    #expect(outcome.transcript.segments[0].fixes?.last?.heardWords == 3, "The words it replaced are recorded.")
}

@Test func aLiveCorrectionRecordsTheWordsItReplacedNotTheSpacesInWhatWasHeard() {
    // "say hello — there now", timed as "say", "hello", "there", "now": the dash is no word.
    let text = "say hello — there now"
    let ranges = [(0, 3), (4, 5), (12, 5), (18, 3)]
    let utf16 = Array(text.utf16)
    let segment = TranscriptSegment(id: "dash", start: 0, end: 4, text: text, words: ranges.enumerated().map { index, range in
        TimedWord(text: String(decoding: utf16[range.0..<(range.0 + range.1)], as: UTF16.self),
                  start: Double(index), end: Double(index) + 0.8, utf16Offset: range.0, utf16Length: range.1)
    }, track: "mic")
    let live = LiveHint(id: "H-dash", at: SessionFixtures.date, segmentID: "dash", track: "mic", firstWord: 1,
                        endWord: 3, start: 1, end: 2.8, heard: "hello — there", action: .replaceText("hi there"))
    let outcome = LiveHints.applyingText([live], to: SessionFixtures.transcript([segment]))
    #expect(outcome.applied == 1)
    #expect(outcome.transcript.segments[0].text == "say hi there now")
    let fix = outcome.transcript.segments[0].fixes?.first
    #expect(fix?.kind == .liveCorrection && fix?.heard == "hello — there")
    #expect(fix?.heardWords == 2, "Two words, though what was heard has three tokens.")
}

@Test func aReplayedLiveHintNeverChangesOrMarksWordsEditedInReview() {
    // Live: "send" → "share". Later edited in Review too (the mark is the person's newer choice), then the hint is
    // replayed (recovery): it finds "share" shown, and would have marked it as its own.
    let live = SessionFixtures.segment(["please", "send", "the", "deck"], track: "system", start: 4, id: "live")
    var edited = SessionFixtures.segment(["please", "share", "the", "deck"], track: "system", start: 4, id: "live")
    edited.fixes = [TranscriptWordFix(first: 1, end: 2, heard: "send", kind: .reviewEdit, heardWords: 1)]
    let one = LiveHints.applyingText([hint(live, words: 1..<2, action: .replaceText("share"))],
                                     to: SessionFixtures.transcript([edited]))
    #expect(one.applied == 0)
    #expect(one.transcript.segments == [edited], "The Review edit stays as it is.")

    // Across language pieces: "send the latest deck" → "share this doc.", with "doc." edited in Review since.
    let sentence = SessionFixtures.segment(["please", "send", "the", "latest", "deck"], track: "mic", start: 2,
                                           id: "sentence")
    let liveHint = hint(sentence, words: 1..<5, action: .replaceText("share this doc."), id: "H1")
    let first = LanguageMerge.piece(of: sentence, first: 0, end: 3, language: "en-CA")
    let second = LanguageMerge.piece(of: sentence, first: 3, end: 5, language: "fr-CA")
    let applied = LiveHints.applyingText([liveHint], to: SessionFixtures.transcript([first, second])).transcript
    var reviewed = applied
    reviewed.segments[1].fixes = [TranscriptWordFix(first: 0, end: 1, heard: "latest deck", kind: .reviewEdit,
                                                    heardWords: 2)]
    reviewed.segments[0].fixes = nil
    let replayed = LiveHints.applyingText([liveHint], to: reviewed)
    #expect(replayed.applied == 0)
    #expect(replayed.transcript.segments == reviewed.segments, "Neither piece is marked or changed.")
}

/// A fix reverted in Review (`reviewRevert`: the person took "share" back to the recognizer's "send") is the person's
/// newer choice too: a live hint replayed later neither changes nor marks it.
@Test func aReplayedLiveHintNeverChangesOrMarksWordsRevertedInReview() {
    let live = SessionFixtures.segment(["please", "send", "the", "deck"], track: "system", start: 4, id: "live")
    var reverted = live
    reverted.fixes = [TranscriptWordFix(first: 1, end: 2, heard: "share", kind: .reviewRevert, heardWords: 1)]
    let replayed = LiveHints.applyingText([hint(live, words: 1..<2, action: .replaceText("share"))],
                                          to: SessionFixtures.transcript([reverted]))
    #expect(replayed.applied == 0)
    #expect(replayed.transcript.segments == [reverted], "The Review revert stays as it is.")
    // Without the revert, the same hint is made.
    #expect(LiveHints.applyingText([hint(live, words: 1..<2, action: .replaceText("share"))],
                                   to: SessionFixtures.transcript([live])).applied == 1)
}

@Test func liveTextHintSurvivesReplayChangingTheSegmentID() {
    let live = SessionFixtures.segment(["asked", "cloud", "today"], track: "mic", start: 10, id: "live")
    let replayed = SessionFixtures.segment(["asked", "cloud", "today"], track: "mic", start: 10.08, id: "replayed")
    let transcript = SessionFixtures.transcript([replayed])
    let outcome = LiveHints.applyingText([
        hint(live, words: 0..<3, action: .replaceText("asked Claude today"), id: "H2"),
    ], to: transcript)

    #expect(outcome.applied == 1)
    #expect(outcome.transcript.segments[0].id == "replayed")
    #expect(outcome.transcript.segments[0].text == "asked Claude today")
}

@Test func liveTextHintKeepsWhitespaceWordBoundariesWhenWordsContainPunctuation() {
    let live = SessionFixtures.segment(["a", "real-time", "C++", "demo"], track: "mic", start: 10, id: "live")
    let replayed = SessionFixtures.segment(["a", "real-time", "C++", "demo"], track: "mic", start: 10.1,
                                           id: "replayed")
    let outcome = LiveHints.applyingText([
        hint(live, words: 1..<4, action: .replaceText("live Rust demo")),
    ], to: SessionFixtures.transcript([replayed]))

    #expect(outcome.applied == 1)
    #expect(outcome.transcript.segments[0].text == "a live Rust demo")
}

@Test func standalonePunctuationDoesNotPreventLiveTextMatchingOrIdempotence() {
    let segment = SessionFixtures.segment(["hello", "bright", "world"], track: "mic", start: 10, id: "live")
    let live = hint(segment, words: 0..<3, action: .replaceText("hello — world"), id: "H1")
    let original = SessionFixtures.segment(["research", "development"], track: "mic", start: 20, id: "original")
    let replayed = TranscriptSegment(id: "replayed", start: 20, end: 21, text: "research & development",
                                     track: "mic")
    let replayHint = hint(original, words: 0..<2, action: .replaceText("research and development"), id: "H2")

    let first = LiveHints.applyingText([live], to: SessionFixtures.transcript([segment]))
    let second = LiveHints.applyingText([live], to: first.transcript)
    let replayOutcome = LiveHints.applyingText([replayHint], to: SessionFixtures.transcript([replayed]))

    #expect(first.applied == 1)
    #expect(first.transcript.segments[0].text == "hello — world")
    #expect(second.alreadyApplied == 1)
    #expect(second.unmatched == 0)
    #expect(second.transcript.segments[0].text == "hello — world")
    #expect(replayOutcome.applied == 1)
    #expect(replayOutcome.transcript.segments[0].text == "research and development")
}

@Test func liveTextHintReplacesUntimedPunctuationOnlyOnce() {
    let segment = TranscriptSegment(
        id: "live", start: 2, end: 2.3, text: "Hello.",
        words: [TimedWord(text: "Hello", start: 2, end: 2.3, utf16Offset: 0, utf16Length: 5)],
        track: "mic")
    let live = LiveHint(id: "H1", at: SessionFixtures.date, segmentID: "live", track: "mic",
                        firstWord: 0, endWord: 1, start: 2, end: 2.3, heard: "Hello.",
                        action: .replaceText("Hi."))

    let first = LiveHints.applyingText([live], to: SessionFixtures.transcript([segment]))
    let second = LiveHints.applyingText([live], to: first.transcript)

    #expect(first.transcript.segments[0].text == "Hi.")
    #expect(second.applied == 0)
    #expect(second.alreadyApplied == 1)
    #expect(second.transcript.segments[0].text == "Hi.")

    var replayed = segment
    replayed.id = "replayed"
    replayed.text = "Hello!"
    let changedPunctuation = LiveHints.applyingText([live], to: SessionFixtures.transcript([replayed]))
    #expect(changedPunctuation.transcript.segments[0].text == "Hi.")
}

@Test func liveTextHintUsesTimeToDisambiguateRepeatedWords() {
    let early = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 2, id: "early")
    let live = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 20, id: "live")
    let late = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 20.1, id: "late")
    let transcript = SessionFixtures.transcript([early, late])
    let outcome = LiveHints.applyingText([
        hint(live, words: 0..<3, action: .replaceText("share the doc"), id: "H3"),
    ], to: transcript)

    #expect(outcome.transcript.segments.map(\.text) == ["send the deck", "share the doc"])
}

@Test func exactLiveTextTargetWinsOverNearbyReplacementText() {
    let segment = SessionFixtures.segment(["send", "share"], track: "mic", start: 2, id: "live")
    let outcome = LiveHints.applyingText([
        hint(segment, words: 0..<1, action: .replaceText("share"), id: "H1"),
    ], to: SessionFixtures.transcript([segment]))

    #expect(outcome.applied == 1)
    #expect(outcome.alreadyApplied == 0)
    #expect(outcome.unmatched == 0)
    #expect(outcome.transcript.segments[0].text == "share share")
    #expect(outcome.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 0, end: 1, heard: "send", kind: .liveCorrection, heardWords: 1),
    ])
}

@Test func liveTextHintSurvivesALanguageBoundaryInsideItsPhrase() {
    let live = SessionFixtures.segment(["please", "send", "the", "latest", "deck"],
                                       track: "mic", start: 2, id: "live")
    let first = LanguageMerge.piece(of: live, first: 0, end: 3, language: "en-CA")
    let second = LanguageMerge.piece(of: live, first: 3, end: 5, language: "fr-CA")
    let hint = hint(live, words: 1..<5, action: .replaceText("share this doc."), id: "H1")

    let applied = LiveHints.applyingText([hint], to: SessionFixtures.transcript([first, second]))
    let repeated = LiveHints.applyingText([hint], to: applied.transcript)

    #expect(applied.applied == 1)
    #expect(applied.unmatched == 0)
    #expect(applied.transcript.segments.map(\.id) == ["live/0", "live/3"])
    #expect(applied.transcript.segments.map(\.language) == ["en-CA", "fr-CA"])
    #expect(applied.transcript.segments.map(\.text) == ["please share this ", "doc."])
    #expect(applied.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 1, end: 3, heard: "send the", kind: .liveCorrection, heardWords: 2),
    ])
    #expect(applied.transcript.segments[1].fixes == [
        TranscriptWordFix(first: 0, end: 1, heard: "latest deck", kind: .liveCorrection, heardWords: 2),
    ])
    #expect(repeated.applied == 0)
    #expect(repeated.alreadyApplied == 1)
    #expect(repeated.unmatched == 0)
    #expect(repeated.transcript == applied.transcript)
}

@Test func shorterLiveReplacementCanConsumeAWholeLanguagePiece() {
    let live = SessionFixtures.segment(["turn", "this", "into", "summary"], track: "mic", start: 2, id: "live")
    let first = LanguageMerge.piece(of: live, first: 0, end: 2, language: "en-CA")
    let second = LanguageMerge.piece(of: live, first: 2, end: 4, language: "fr-CA")
    let hint = hint(live, words: 0..<4, action: .replaceText("summary"), id: "H1")

    let applied = LiveHints.applyingText([hint], to: SessionFixtures.transcript([first, second]))
    let repeated = LiveHints.applyingText([hint], to: applied.transcript)

    #expect(applied.applied == 1)
    #expect(applied.unmatched == 0)
    #expect(applied.transcript.segments.map(\.text) == ["summary ", ""])
    #expect(repeated.applied == 0)
    #expect(repeated.alreadyApplied == 1)
    #expect(repeated.transcript == applied.transcript)
}

@Test func aDeletedLanguagePieceRetargetsItsSpeakerSpanToTheCrossPieceReplacement() throws {
    let live = SessionFixtures.segment(["turn", "this", "into", "summary"], track: "mic", start: 2, id: "live")
    let first = LanguageMerge.piece(of: live, first: 0, end: 2, language: "en-CA")
    let second = LanguageMerge.piece(of: live, first: 2, end: 4, language: "fr-CA")
    let original = SessionFixtures.transcript([first, second], id: "original")
    let hint = hint(live, words: 0..<4, action: .replaceText("summary"), id: "H1")

    let corrected = LiveHints.applyingText([hint], to: original).transcript
    let moved = try SpeakerTranscriptRetarget.retargetedSpans(
        [WordSpan(segmentID: second.id, first: 0, end: 2)], from: original, to: corrected)

    #expect(corrected.segments[0].fixes == [
        TranscriptWordFix(first: 0, end: 1, heard: "turn this into summary", kind: .liveCorrection, heardWords: 4),
    ])
    #expect(moved == [WordSpan(segmentID: first.id, first: 0, end: 1)])
}

@Test func punctuationAtALanguageBoundaryStaysInsideTheLiveReplacement() {
    let live = TranscriptSegment(
        id: "live", start: 2, end: 3.1, text: "one two — — three",
        words: [
            TimedWord(text: "one", start: 2, end: 2.3, utf16Offset: 0, utf16Length: 3),
            TimedWord(text: "two", start: 2.4, end: 2.7, utf16Offset: 4, utf16Length: 3),
            TimedWord(text: "three", start: 2.8, end: 3.1, utf16Offset: 12, utf16Length: 5),
        ], track: "mic")
    let first = LanguageMerge.piece(of: live, first: 0, end: 2, language: "en-CA")
    let second = LanguageMerge.piece(of: live, first: 2, end: 3, language: "fr-CA")
    let hint = LiveHint(id: "H1", at: SessionFixtures.date, segmentID: live.id, track: "mic",
                        firstWord: 0, endWord: 3, start: live.start, end: live.end,
                        heard: "one two — — three", action: .replaceText("alpha beta gamma"))

    let applied = LiveHints.applyingText([hint], to: SessionFixtures.transcript([first, second]))
    let repeated = LiveHints.applyingText([hint], to: applied.transcript)

    #expect(applied.applied == 1)
    #expect(applied.unmatched == 0)
    #expect(applied.transcript.segments.map(\.text) == ["alpha beta ", "gamma"])
    #expect(applied.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 0, end: 2, heard: "one two — —", kind: .liveCorrection, heardWords: 2),
    ])
    #expect(repeated.applied == 0)
    #expect(repeated.alreadyApplied == 1)
    #expect(repeated.transcript == applied.transcript)
}

@Test func replayedLiveTextHintMatchesOnlyTheSameWordsNearTheirRecordedTime() {
    let live = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 120, id: "live")
    let nearby = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 121.9, id: "nearby")
    let far = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 5, id: "replayed")
    let liveHint = hint(live, words: 0..<3, action: .replaceText("share the doc"), id: "H3")
    let nearOutcome = LiveHints.applyingText([liveHint], to: SessionFixtures.transcript([nearby]))
    let farOutcome = LiveHints.applyingText([liveHint], to: SessionFixtures.transcript([far]))

    #expect(nearOutcome.applied == 1)
    #expect(nearOutcome.transcript.segments[0].text == "share the doc")
    #expect(farOutcome.applied == 0)
    #expect(farOutcome.unmatched == 1)
    #expect(farOutcome.transcript.segments[0].text == "send the deck")
}

@Test func alreadyVisibleLiveTextHintGetsProvenanceOnceAndBlocksAutomaticFixes() async throws {
    let live = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 2, id: "live")
    let corrected = SessionFixtures.segment(["share", "the", "doc"], track: "system", start: 2, id: "final")
    let transcript = SessionFixtures.transcript([corrected], id: "current")
    let first = LiveHints.applyingText([
        hint(live, words: 0..<3, action: .replaceText("share the doc"), id: "H4"),
    ], to: transcript)
    let second = LiveHints.applyingText([
        hint(live, words: 0..<3, action: .replaceText("share the doc"), id: "H4"),
    ], to: first.transcript)
    let fixed = try await WordFixStage.fix(
        first.transcript, title: "Test",
        corrections: CorrectionList(entries: [.init(heard: "share", meant: "chair")]),
        terms: CorrectionList(), dependencies: .none)

    #expect(first.applied == 1)
    #expect(first.alreadyApplied == 0)
    #expect(first.transcript.id != "current")
    #expect(first.transcript.segments[0].text == "share the doc")
    #expect(first.transcript.segments[0].words == corrected.words)
    #expect(first.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 0, end: 3, heard: "share the doc", kind: .liveCorrection, heardWords: 3),
    ])
    #expect(second.applied == 0)
    #expect(second.alreadyApplied == 1)
    #expect(second.transcript.id == first.transcript.id)
    #expect(fixed.transcript.segments[0].text == "share the doc")
}

@Test func normalizedEquivalentLiveHintIsAlreadyAppliedOnLaterRuns() {
    for (index, example) in [("claude", "Claude"), ("hello", "hello!")].enumerated() {
        let segment = SessionFixtures.segment([example.0, "again"], track: "mic", start: 2,
                                              id: "S\(index)")
        let live = hint(segment, words: 0..<1, action: .replaceText(example.1), id: "H\(index)")
        let first = LiveHints.applyingText([live], to: SessionFixtures.transcript([segment]))
        let second = LiveHints.applyingText([live], to: first.transcript)

        #expect(first.applied == 1)
        #expect(second.applied == 0)
        #expect(second.alreadyApplied == 1)
        #expect(second.unmatched == 0)
        #expect(second.transcript.id == first.transcript.id)
    }
}

@Test func repeatedEditOfOneLivePhraseKeepsTheOriginalProvenance() {
    let segment = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 2, id: "live")
    var first = hint(segment, words: 0..<3, action: .replaceText("share the doc"), id: "H1")
    let owned = Correction(heard: "send the deck", meant: "share the doc")
    first.learned = [owned]
    first.owned = [owned]
    var second = first
    second.id = "H2"
    second.heard = "share the doc"
    second.action = .replaceText("share this document")
    second.learned = nil
    second.owned = nil
    let transcript = SessionFixtures.transcript([segment])
    let outcome = LiveHints.applyingText([first, second], to: transcript)

    #expect(outcome.applied == 1)
    #expect(outcome.transcript.segments[0].text == "share this document")
    #expect(outcome.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 0, end: 3, heard: "send the deck", kind: .liveCorrection, heardWords: 3),
    ])
    #expect(LiveHints.originalHeard(for: second, among: [first]) == "send the deck")
    #expect(LiveHints.correctionLearningState(for: second, among: [first])
        == .init(previous: [owned], managed: [owned]))
}

@Test func correctionLearningStateKeepsSharedRulesUntilTheLastPhraseReleasesThem() {
    let firstSegment = SessionFixtures.segment(["send", "the", "deck"], track: "mic", start: 2, id: "S1")
    let secondSegment = SessionFixtures.segment(["send", "the", "deck"], track: "mic", start: 8, id: "S2")
    let shared = Correction(heard: "send the deck", meant: "share the doc")
    var first = hint(firstSegment, words: 0..<3, action: .replaceText("share the doc"), id: "H1")
    first.learned = [shared]
    first.owned = [shared]
    var second = hint(secondSegment, words: 0..<3, action: .replaceText("share the doc"), id: "H2")
    second.learned = [shared]
    second.owned = []

    #expect(LiveHints.correctionLearningState(for: first, among: [first, second])
        == .init(previous: [shared], other: [shared], managed: [shared]))

    var failedFirst = first
    failedFirst.id = "H-failed"
    failedFirst.learned = nil
    failedFirst.owned = nil
    #expect(LiveHints.correctionLearningState(for: first, among: [first, second, failedFirst])
        == .init(previous: [shared], other: [shared], managed: [shared]))

    var releasedFirst = first
    releasedFirst.id = "H3"
    releasedFirst.learned = []
    releasedFirst.owned = []
    #expect(LiveHints.correctionLearningState(for: second, among: [first, second, releasedFirst])
        == .init(previous: [shared], managed: [shared]))
}

@Test func correctionLearningStateRemembersRulesThatPredatedLiveManagement() {
    let firstSegment = SessionFixtures.segment(["send", "the", "deck"], track: "mic", start: 2, id: "S1")
    let secondSegment = SessionFixtures.segment(["send", "the", "deck"], track: "mic", start: 8, id: "S2")
    let existing = Correction(heard: "send the deck", meant: "share the doc")
    let conflict = Correction(heard: "send the deck", meant: "send the document")
    var first = hint(firstSegment, words: 0..<3, action: .replaceText("share the doc"), id: "H1")
    first.learned = [existing]
    first.owned = []
    var second = hint(secondSegment, words: 0..<3, action: .replaceText("send the document"), id: "H2")
    second.learned = [conflict]
    second.owned = [conflict]

    #expect(LiveHints.correctionLearningState(for: second, among: [first, second])
        == .init(previous: [conflict], other: [existing], managed: [conflict], preexisting: [existing]))
}

@Test func correctionLearningStateRemembersAnUnconfirmedRuleAConflictDisplaced() {
    let segment = SessionFixtures.segment(["send", "the", "deck"], track: "mic", start: 2, id: "S1")
    let managed = Correction(heard: "send the deck", meant: "share the doc")
    let displaced = Correction(heard: "send the deck", meant: "send the slides")
    var live = hint(segment, words: 0..<3, action: .replaceText("share the doc"), id: "H1")
    live.learned = [managed]
    live.owned = [managed]
    live.displaced = [displaced]

    #expect(LiveHints.correctionLearningState(for: live, among: [live])
        == .init(previous: [managed], managed: [managed], preexisting: [displaced]))
}

@Test func repeatedLiveEditMapsSpeakerWordsFromTheIntermediateReplay() throws {
    let original = TranscriptSegment(id: "live", start: 2, end: 3, text: "send", track: "system")
    let first = hint(original, words: 0..<1, action: .replaceText("share doc"), id: "H1")
    var second = first
    second.id = "H2"
    second.heard = "share doc"
    second.action = .replaceText("sent")
    let intermediate = TranscriptSegment(id: "live", start: 2, end: 3, text: "share doc", track: "system")

    let outcome = LiveHints.applyingText([first, second], to: SessionFixtures.transcript([intermediate]))

    #expect(outcome.applied == 1)
    #expect(outcome.unmatched == 0)
    #expect(outcome.transcript.segments[0].text == "sent")
    #expect(outcome.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 0, end: 1, heard: "share doc", kind: .liveCorrection, heardWords: 2),
    ])
    #expect(try SpeakerTranscriptRetarget.owners(
        from: intermediate, to: outcome.transcript.segments[0], commonBase: true).count == 1)
}

@Test func anUntimedPriorFixDoesNotMoveToADistantDuplicate() {
    let prior = TranscriptSegment(
        id: "S1", start: 0, end: 6, text: "right one two three four wrong", track: "mic",
        fixes: [.init(first: 0, end: 1, heard: "wrong", kind: .correction)])
    let live = TranscriptSegment(
        id: "S1", start: 0, end: 6, text: "live one two three four wrong", track: "mic",
        fixes: [.init(first: 0, end: 1, heard: "wrong", kind: .liveCorrection)])

    let preserved = WordFixStage.preservingPriorFixes(
        from: SessionFixtures.transcript([prior]), on: SessionFixtures.transcript([live]))

    #expect(preserved.segments == [live])
}

@Test func anUntimedPriorFixFollowsAPrecedingLiveWordInsertion() {
    let prior = TranscriptSegment(
        id: "S1", start: 0, end: 2, text: "alpha right", track: "mic",
        fixes: [.init(first: 1, end: 2, heard: "wrong", kind: .correction)])
    let live = TranscriptSegment(
        id: "S1", start: 0, end: 2, text: "one two three four wrong", track: "mic",
        fixes: [.init(first: 0, end: 4, heard: "alpha", kind: .liveCorrection)])

    let preserved = WordFixStage.preservingPriorFixes(
        from: SessionFixtures.transcript([prior]), on: SessionFixtures.transcript([live]))

    #expect(preserved.segments[0].text == "one two three four right")
    #expect(preserved.segments[0].fixes == [
        .init(first: 0, end: 4, heard: "alpha", kind: .liveCorrection),
        .init(first: 4, end: 5, heard: "wrong", kind: .correction, heardWords: 1),
    ])
}

@Test func anUntimedAcceptedTermFollowsAPrecedingLiveWordInsertion() {
    let prior = TranscriptSegment(
        id: "S1", start: 0, end: 2, text: "alpha Claude", track: "mic",
        fixes: [.init(first: 1, end: 2, heard: "cloud", kind: .term)])
    let live = TranscriptSegment(
        id: "S1", start: 0, end: 2, text: "one two three four cloud", track: "mic",
        fixes: [.init(first: 0, end: 4, heard: "alpha", kind: .liveCorrection)])

    let preserved = WordFixStage.preservingPriorFixes(
        from: SessionFixtures.transcript([prior]), on: SessionFixtures.transcript([live]))

    #expect(preserved.segments[0].text == "one two three four Claude")
    #expect(preserved.segments[0].fixes?.last ==
        .init(first: 4, end: 5, heard: "cloud", kind: .term, heardWords: 1))
}

@Test func anUntimedReviewRevertFollowsAPrecedingLiveWordInsertion() {
    let prior = TranscriptSegment(
        id: "S1", start: 0, end: 2, text: "alpha wrong", track: "mic",
        fixes: [.init(first: 1, end: 2, heard: "right", kind: .reviewRevert)])
    let live = TranscriptSegment(
        id: "S1", start: 0, end: 2, text: "one two three four wrong", track: "mic",
        fixes: [.init(first: 0, end: 4, heard: "alpha", kind: .liveCorrection)])

    let preserved = WordFixStage.preservingPriorFixes(
        from: SessionFixtures.transcript([prior]), on: SessionFixtures.transcript([live]))

    #expect(preserved.segments[0].text == live.text)
    #expect(preserved.segments[0].fixes?.last ==
        .init(first: 4, end: 5, heard: "right", kind: .reviewRevert))
}

@Test func revertingAnAutomaticFixBesideALongerLiveCorrectionUsesTheLiveBase() throws {
    let segment = SessionFixtures.segment(["alpha", "beta", "wrong"], track: "mic", start: 2, id: "S1")
    let original = SessionFixtures.transcript([segment], id: "original")
    let live = LiveHints.applyingText([
        hint(segment, words: 0..<2, action: .replaceText("one two three")),
    ], to: original).transcript
    var working = try #require(WordFixes.Working(live.segments[0], preservingExistingFixes: true))
    working = WordFixes.applying(WordFixes.corrections(
        in: working, list: CorrectionList(entries: [.init(heard: "wrong", meant: "right")])),
        to: working)
    let fixedSegment = WordFixes.finished(working, segment: live.segments[0])
    var fixed = SessionFixtures.transcript([fixedSegment], id: "fixed")
    fixed.fixedFrom = live.id
    fixed.liveCorrectedFrom = original.id

    let reverted = try WordFixes.reverting(WordRef(segmentID: "S1", word: 3), in: fixed, to: live)

    #expect(reverted.segments[0].text == "one two three wrong")
    #expect(reverted.segments[0].fixes?.contains { $0.kind == .liveCorrection } == true)
}

@Test func liveHintStorePreservesHintsAndBindsThemToTheSession() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript([])
    let session = try await SessionFixtures.makeSession(in: temp.url, transcript: transcript)
    let segment = SessionFixtures.segment(["hello"], track: "mic", start: 1, id: "S1")
    var first = hint(segment, words: 0..<1, action: .replaceText("hullo"), id: "H1")
    let second = hint(segment, words: 0..<1, action: .nameSpeaker("Ada"), id: "H2")
    let owned = Correction(heard: "hello", meant: "hullo")

    try LiveHintStore.append(first, session: session)
    let displaced = Correction(heard: "hello", meant: "hello there")
    try LiveHintStore.recordLearning([owned], owned: [owned], displaced: [displaced],
                                     for: first.id, session: session)
    first.learned = [owned]
    first.owned = [owned]
    first.displaced = [displaced]
    let saved = try LiveHintStore.append(second, session: session)
    #expect(saved.hints == [first, second])
    #expect(try LiveHintStore.read(session: session).hints == [first, second])

    let consumed = try LiveHintStore.sealAndRead(session: session)
    #expect(consumed.hints == [first, second])
    #expect(consumed.sealed == true)
    #expect(throws: HolosError.self) { try LiveHintStore.append(first, session: session) }

    var copied = try LiveHintStore.read(session: session)
    copied.sessionID = "ANOTHER-SESSION"
    try AtomicFile.writeJSON(copied, to: SessionPaths.liveHints(session))
    #expect(throws: HolosError.self) { try LiveHintStore.read(session: session) }
}

@Test func appendingARepeatedEditReturnsItsPriorLearningWithoutAReaderRefresh() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(
        in: temp.url, transcript: SessionFixtures.transcript([]))
    let segment = SessionFixtures.segment(["wrong"], track: "mic", start: 1, id: "S1")
    var first = hint(segment, words: 0..<1, action: .replaceText("right"), id: "H1")
    let owned = Correction(heard: "wrong", meant: "right")
    let displaced = Correction(heard: "wrong", meant: "write")
    try LiveHintStore.append(first, session: session)
    try LiveHintStore.recordLearning([owned], owned: [owned], displaced: [displaced],
                                     for: first.id, session: session)
    first.learned = [owned]
    first.owned = [owned]
    first.displaced = [displaced]
    var second = first
    second.id = "H2"
    second.heard = "right"
    second.action = .replaceText("correct")
    second.learned = nil
    second.owned = nil
    second.displaced = nil

    let saved = try LiveHintStore.append(second, session: session)

    #expect(saved.hints == [first, second])
    #expect(LiveHints.originalHeard(for: second, among: saved.hints) == "wrong")
    #expect(LiveHints.correctionLearningState(for: second, among: saved.hints)
        == .init(previous: [owned], managed: [owned], preexisting: [displaced]))
}

@Test func liveHintStoreRejectsATextReplacementWithNoWords() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, transcript: SessionFixtures.transcript([]))
    let segment = SessionFixtures.segment(["aside"], track: "mic", start: 1, id: "S1")

    #expect(throws: HolosError.self) {
        try LiveHintStore.append(hint(segment, words: 0..<1, action: .replaceText("—")), session: session)
    }
    #expect(try LiveHintStore.read(session: session).hints.isEmpty)
}

@Test func liveParagraphShowsSavedTextAndSpeakerName() {
    let segment = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 3, id: "S1")
    let text = hint(segment, words: 0..<3, action: .replaceText("share the doc"), id: "H1")
    let speaker = hint(segment, words: 0..<3, action: .nameSpeaker(" Ada "), id: "H2")
    let paragraphs = LiveTranscript.paragraphs(finals: [segment], volatile: [:], echo: nil,
                                               hints: [text, speaker])

    #expect(paragraphs.count == 1)
    #expect(paragraphs[0].speakerName == "Ada")
    #expect(paragraphs[0].runs[0].text == "share the doc")
    #expect(paragraphs[0].runs[0].firstWord == 0)
    #expect(paragraphs[0].runs[0].endWord == 3)
}

@Test func speakerHintNamesTheMachineSpeakerAtItsWords() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let segment = fixture.transcript.segments[0]
    let live = hint(segment, words: 0..<segment.words.count, action: .nameSpeaker("Ada"), id: "H1")
    let projection = try SessionFixtures.view(fixture.session)
    let speakerID = try #require(fixture.run.turns[0].speakerID)

    #expect(LiveHints.speakerActions([live], projection: projection, transcript: fixture.transcript)
        == [.rename(speakerID: speakerID, name: "Ada")])
}

@Test func unmatchedSpeakerHintsStayPendingWhenAnotherNameApplies() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let segment = fixture.transcript.segments[0]
    let matched = hint(segment, words: 0..<segment.words.count, action: .nameSpeaker("Ada"), id: "matched")
    let absentSegment = SessionFixtures.segment(["absent"], track: "system", start: 100, id: "absent")
    let unmatched = hint(absentSegment, words: 0..<1, action: .nameSpeaker("Grace"), id: "unmatched")
    try LiveHintStore.append(matched, session: fixture.session)
    try LiveHintStore.append(unmatched, session: fixture.session)

    let first = LiveHintStage.applySpeakers([matched, unmatched], session: fixture.session,
                                            transcript: fixture.transcript, profiles: nil)
    let speakerID = try #require(fixture.run.turns[0].speakerID)
    let projection = try SessionFixtures.view(fixture.session)

    #expect(first.note == "Applied 1 live speaker name.")
    #expect(first.problem == "1 live speaker name could not be matched to the final speaker labels.")
    #expect(projection.speakers.first(where: { $0.id == speakerID })?.name == "Ada")
    #expect(LiveHintStage.hasPendingWork(session: fixture.session, transcript: fixture.transcript))

    let retry = LiveHintStage.applySpeakers([matched, unmatched], session: fixture.session,
                                            transcript: fixture.transcript, profiles: nil)
    #expect(retry.note == nil)
    #expect(retry.problem == first.problem)
}

@Test func laterExplicitSpeakerRenameWinsOverALiveHint() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let segment = fixture.transcript.segments[0]
    let live = hint(segment, words: 0..<segment.words.count, action: .nameSpeaker("Ada"), id: "H1")
    let first = LiveHintStage.applySpeakers([live], session: fixture.session,
                                            transcript: fixture.transcript, profiles: nil)
    #expect(first.problem == nil)
    let speakerID = try #require(fixture.run.turns[0].speakerID)
    try SpeakerEditor.apply([.rename(speakerID: speakerID, name: "Grace")],
                            view: SessionFixtures.view(fixture.session), session: fixture.session,
                            source: "app", regenerateExports: false)

    let second = LiveHintStage.applySpeakers([live], session: fixture.session,
                                             transcript: fixture.transcript, profiles: nil)
    #expect(second.problem == nil)
    let final = try SessionFixtures.view(fixture.session)
    #expect(final.speakers.first(where: { $0.id == speakerID })?.name == "Grace")
}

@Test(.timeLimit(.minutes(1)))
func liveTextCorrectionKeepsEditedLabelsOnUntimedWords() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let segment = TranscriptSegment(id: "S1", start: 0.5, end: 4.5, text: "send the deck",
                                    track: "mic")
    let transcript = SessionFixtures.transcript([segment], id: "original")
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    let run = try SessionFixtures.writeHeadRun(
        session: session, transcript: transcript,
        outputs: ["mic": FakeDiarizer.alternating(speakers: ["S1"], turnSeconds: 5, duration: 5)])
    let speakerID = try #require(run.turns.first?.speakerID)
    try SessionFixtures.appendEdits([.rename(speakerID: speakerID, name: "Ada")], session: session)
    try LiveHintStore.append(hint(segment, words: 0..<3, action: .replaceText("share the doc")),
                             session: session)

    let record = try await MeetingPostProcessor(voiceSamples: .none, 
        diarizer: FakeDiarizer(outputs: [:], error: .unavailable("Speaker labelling must not run.")),
        freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)

    let currentID = try #require(try SessionArchive.currentTranscriptID(at: session))
    let current = try SessionFiles.transcript(id: currentID, session: session)
    let view = try SessionFixtures.view(session)
    #expect(record.state == .succeeded)
    #expect(current.segments[0].text == "share the doc")
    #expect(view.transcriptID == current.id)
    #expect(view.speakers.first(where: { $0.id == speakerID })?.name == "Ada")
}

@Test(.timeLimit(.minutes(1)))
func aLaterPassRepairsLiveTextWhoseSpeakerHeadWasNotPublished() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, track: "mic")
    let speakerID = try #require(fixture.run.turns.first?.speakerID)
    try SessionFixtures.appendEdits([.rename(speakerID: speakerID, name: "Ada")], session: fixture.session)
    let before = try #require(try SessionSpeakerStore.readHead(session: fixture.session))
    let segment = fixture.transcript.segments[0]
    try LiveHintStore.append(hint(segment, words: 0..<segment.words.count,
                                  action: .replaceText("corrected words for this turn")),
                             session: fixture.session)
    let processor = MeetingPostProcessor(voiceSamples: .none, 
        diarizer: FakeDiarizer(outputs: [:], error: .unavailable("Speaker labelling must not run.")),
        freeSpace: FixedFreeSpace(.max))

    let failed = try await SpeakerTranscriptRetarget.$beforePublishHead.withValue({
        throw HolosError.io("head is read-only")
    }) {
        try await processor.run(session: fixture.session, lease: nil)
    }
    let correctedID = try #require(try SessionArchive.currentTranscriptID(at: fixture.session))
    #expect(failed.state == .partial)
    #expect(correctedID != fixture.transcript.id)
    #expect(try SessionSpeakerStore.readHead(session: fixture.session) == before)
    #expect(failed.stages.last { $0.stage == .align }?.result == .skipped)
    #expect(failed.stages.last { $0.stage == .export }?.result == .skipped)

    let repaired = try await processor.run(session: fixture.session, lease: nil)
    let after = try #require(try SessionSpeakerStore.readHead(session: fixture.session))
    let view = try SessionFixtures.view(fixture.session)
    #expect(repaired.state == .succeeded)
    #expect(after.runID != before.runID)
    #expect(view.transcriptID == correctedID)
    #expect(view.speakers.first(where: { $0.id == speakerID })?.name == "Ada")
}

@Test(.timeLimit(.minutes(1))) func postProcessorAppliesLiveTextAndSpeakerHintsBeforeExport() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let segments = SessionFixtures.alternatingSegments(track: "mic")
    let transcript = SessionFixtures.transcript(segments)
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    let first = segments[0]
    let corrected = first.words.indices.map { $0 == 1 ? "corrected" : first.words[$0].text }
        .joined(separator: " ")
    try LiveHintStore.append(hint(first, words: first.words.indices,
                                  action: .replaceText(corrected), id: "text"), session: session)
    try LiveHintStore.append(hint(first, words: first.words.indices,
                                  action: .nameSpeaker("Ada"), id: "speaker"), session: session)
    let diarizer = FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()])
    // The app learns this pair at save time. Live text must become the base before ordinary corrections, so the
    // same rule does not stack another revision or erase the live provenance.
    let automaticHeard = segments[1].words[0].text
    let wordFixes = WordFixDependencies(
        corrections: { CorrectionList(entries: [
            .init(heard: first.text, meant: corrected),
            .init(heard: automaticHeard, meant: "automatic"),
        ]) },
        wordList: { WordList() }, model: { _ in .unavailable("off") })
    let record = try await MeetingPostProcessor(voiceSamples: .none, diarizer: diarizer, freeSpace: FixedFreeSpace(.max),
                                                wordFixes: wordFixes)
        .run(session: session, lease: nil)

    let currentID = try #require(try SessionArchive.currentTranscriptID(at: session))
    let current = try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(currentID, in: session))
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let firstSpeaker = snapshot.projection?.turns.first?.speakerID
    #expect(record.state == .succeeded)
    #expect(current.segments[0].text == corrected)
    #expect(current.segments[0].fixes?.first?.kind == .liveCorrection)
    #expect(current.segments[1].text.hasPrefix("automatic "))
    #expect(current.segments[1].fixes?.first?.kind == .correction)
    #expect(snapshot.projection?.speakers.first(where: { $0.id == firstSpeaker })?.name == "Ada")
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).contains("Ada"))
    #expect(try SessionArchive.readEvents(at: session).events.contains { $0.kind == MeetingEventKind.liveHintsApplied })
}

@Test(.timeLimit(.minutes(1))) func retryRebasesLiveHintsBeforeExistingAutomaticFixes() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let segment = SessionFixtures.segment(["alpha", "beta", "wrong"], track: "mic", start: 2, id: "S1")
    let original = SessionFixtures.transcript([segment], id: "original")
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: original)
    try AtomicFile.write(Data("damaged".utf8), to: SessionPaths.liveHints(session))
    let dependencies = WordFixDependencies(
        corrections: { CorrectionList(entries: [.init(heard: "wrong", meant: "right")]) },
        wordList: { WordList() }, model: { _ in .unavailable("off") })
    let processor = MeetingPostProcessor(voiceSamples: .none, freeSpace: FixedFreeSpace(.max), wordFixes: dependencies)

    let first = try await processor.run(session: session, lease: nil)
    let fixedID = try #require(try SessionArchive.currentTranscriptID(at: session))
    let fixed = try SessionFiles.transcript(id: fixedID, session: session)
    #expect(first.state == .partial)
    #expect(fixed.fixedFrom == original.id)
    #expect(fixed.segments[0].text == "alpha beta right")

    let live = hint(segment, words: 0..<2, action: .replaceText("one two three"), id: "late")
    let sessionID = try SessionArchive.readManifest(at: session).id
    try AtomicFile.writeJSON(LiveHintFile(sessionID: sessionID, hints: [live]),
                             to: SessionPaths.liveHints(session))
    let second = try await processor.run(session: session, lease: nil)
    let finalID = try #require(try SessionArchive.currentTranscriptID(at: session))
    let final = try SessionFiles.transcript(id: finalID, session: session)

    #expect(second.state == .succeeded)
    #expect(final.segments[0].text == "one two three right")
    #expect(final.fixedFrom != fixed.id)
    #expect(final.segments[0].fixes?.contains { $0.kind == .liveCorrection } == true)
    #expect(final.segments[0].fixes?.contains { $0.kind == .correction } == true)
    let events = try SessionArchive.readEvents(at: session).events
    #expect(WordFixStage.unfixedID(final.id, events: events) == original.id)
}

@Test(.timeLimit(.minutes(1))) func lateLiveHintKeepsEarlierUntimedFixesWhenEditedLabelsBlockRecomputation() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let segment = TranscriptSegment(id: "S1", start: 0, end: 4, text: "wrong alpha beta tail", track: "mic")
    let original = SessionFixtures.transcript([segment], id: "original")
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: original)
    try AtomicFile.write(Data("damaged".utf8), to: SessionPaths.liveHints(session))
    let dependencies = WordFixDependencies(
        corrections: { CorrectionList(entries: [.init(heard: "wrong", meant: "right")]) },
        wordList: { WordList() }, model: { _ in .unavailable("off") })
    let firstProcessor = MeetingPostProcessor(voiceSamples: .none, freeSpace: FixedFreeSpace(.max), wordFixes: dependencies)

    _ = try await firstProcessor.run(session: session, lease: nil)
    let fixed = try SessionFiles.transcript(
        id: try #require(try SessionArchive.currentTranscriptID(at: session)), session: session)
    let run = try SessionFixtures.writeHeadRun(
        session: session, transcript: fixed,
        outputs: ["mic": FakeDiarizer.alternating(speakers: ["S1"], turnSeconds: 5, duration: 5)])
    let speakerID = try #require(run.turns.first?.speakerID)
    try SessionFixtures.appendEdits([.rename(speakerID: speakerID, name: "Ada")], session: session)

    let live = hint(segment, words: 3..<4,
                    action: .replaceText("live correction adds several extra words here"), id: "late")
    let sessionID = try SessionArchive.readManifest(at: session).id
    try AtomicFile.writeJSON(LiveHintFile(sessionID: sessionID, hints: [live]),
                             to: SessionPaths.liveHints(session))
    let second = try await MeetingPostProcessor(voiceSamples: .none, 
        diarizer: FakeDiarizer(outputs: [:], error: .unavailable("Speaker labelling must not run.")),
        freeSpace: FixedFreeSpace(.max), wordFixes: dependencies).run(session: session, lease: nil)
    let final = try SessionFiles.transcript(
        id: try #require(try SessionArchive.currentTranscriptID(at: session)), session: session)
    let liveBase = try SessionFiles.transcript(id: try #require(final.fixedFrom), session: session)
    let view = try SessionFixtures.view(session)

    #expect(second.state == .partial)
    #expect(final.segments[0].text == "right alpha beta live correction adds several extra words here")
    #expect(final.segments[0].fixes?.contains { $0.kind == .correction } == true)
    #expect(final.segments[0].fixes?.contains { $0.kind == .liveCorrection } == true)
    #expect(liveBase.segments[0].text == "wrong alpha beta live correction adds several extra words here")
    #expect(view.transcriptID == final.id)
    #expect(view.speakers.first(where: { $0.id == speakerID })?.name == "Ada")
}

@Test(.timeLimit(.minutes(1))) func lateLiveHintKeepsAnAcceptedTermWhenTheModelIsUnavailable() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let segment = SessionFixtures.segment(["send", "cloud", "now", "keep", "cloud", "later", "wrong"],
                                          track: "mic", start: 2, id: "S1")
    let original = SessionFixtures.transcript([segment], id: "original")
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: original)
    try AtomicFile.write(Data("damaged".utf8), to: SessionPaths.liveHints(session))
    var list = WordList()
    list.add("Claude", at: SessionFixtures.date)
    list.addHeardAs(["cloud"], to: "Claude")
    let termList = list
    let accepted = WordFixDependencies(
        corrections: { CorrectionList() }, wordList: { termList },
        model: { _ in .available({ _, prompt in prompt.contains("]] now") ? "Claude" : "cloud" }) })

    let first = try await MeetingPostProcessor(voiceSamples: .none, freeSpace: FixedFreeSpace(.max), wordFixes: accepted)
        .run(session: session, lease: nil)
    let fixedID = try #require(try SessionArchive.currentTranscriptID(at: session))
    let fixed = try SessionFiles.transcript(id: fixedID, session: session)
    #expect(first.state == .partial)
    #expect(fixed.segments[0].text == "send Claude now keep cloud later wrong")
    #expect(fixed.segments[0].fixes?.contains { $0.kind == .term } == true)

    let live = hint(segment, words: 6..<7, action: .replaceText("corrected live"), id: "late")
    let sessionID = try SessionArchive.readManifest(at: session).id
    try AtomicFile.writeJSON(LiveHintFile(sessionID: sessionID, hints: [live]),
                             to: SessionPaths.liveHints(session))
    let unavailable = WordFixDependencies(
        corrections: { CorrectionList() }, wordList: { termList },
        model: { _ in .unavailable("the model is still downloading") })
    let second = try await MeetingPostProcessor(voiceSamples: .none, freeSpace: FixedFreeSpace(.max), wordFixes: unavailable)
        .run(session: session, lease: nil)
    let finalID = try #require(try SessionArchive.currentTranscriptID(at: session))
    let final = try SessionFiles.transcript(id: finalID, session: session)

    #expect(second.state == .succeeded)
    #expect(final.id != fixed.id)
    #expect(final.segments[0].text == "send Claude now keep cloud later corrected live")
    #expect(final.segments[0].fixes?.contains { $0.kind == .term } == true)
    #expect(final.segments[0].fixes?.contains { $0.kind == .liveCorrection } == true)

    let recovered = WordFixDependencies(
        corrections: { CorrectionList() }, wordList: { termList },
        model: { _ in .available({ _, _ in "Claude" }) })
    _ = try await MeetingPostProcessor(voiceSamples: .none, freeSpace: FixedFreeSpace(.max), wordFixes: recovered)
        .run(session: session, lease: nil)
    let recomputed = try SessionFiles.transcript(
        id: try #require(try SessionArchive.currentTranscriptID(at: session)), session: session)
    #expect(recomputed.id != final.id)
    #expect(recomputed.segments[0].text == "send Claude now keep Claude later corrected live")
}

@Test(.timeLimit(.minutes(1))) func lateLiveHintKeepsAReviewRevertAndOtherAutomaticFixes() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let segment = SessionFixtures.segment(["bad", "wrong", "tail"], track: "mic", start: 2, id: "S1")
    let original = SessionFixtures.transcript([segment], id: "original")
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: original)
    try AtomicFile.write(Data("damaged".utf8), to: SessionPaths.liveHints(session))
    let dependencies = WordFixDependencies(
        corrections: { CorrectionList(entries: [
            .init(heard: "bad", meant: "good"),
            .init(heard: "wrong", meant: "right"),
        ]) }, wordList: { WordList() }, model: { _ in .unavailable("off") })
    let processor = MeetingPostProcessor(voiceSamples: .none, freeSpace: FixedFreeSpace(.max), wordFixes: dependencies)

    _ = try await processor.run(session: session, lease: nil)
    let fixed = try SessionFiles.transcript(
        id: try #require(try SessionArchive.currentTranscriptID(at: session)), session: session)
    let reverted = try WordFixes.reverting(WordRef(segmentID: "S1", word: 0), in: fixed, to: original)
    try await SessionFixtures.saveTranscript(reverted, in: session)
    #expect(reverted.segments[0].text == "bad right tail")
    #expect(reverted.segments[0].fixes?.contains { $0.kind == .reviewRevert } == true)

    let live = hint(segment, words: 2..<3, action: .replaceText("live tail"), id: "late")
    let sessionID = try SessionArchive.readManifest(at: session).id
    try AtomicFile.writeJSON(LiveHintFile(sessionID: sessionID, hints: [live]),
                             to: SessionPaths.liveHints(session))
    let record = try await processor.run(session: session, lease: nil)
    let final = try SessionFiles.transcript(
        id: try #require(try SessionArchive.currentTranscriptID(at: session)), session: session)

    #expect(record.state == .succeeded)
    #expect(final.segments[0].text == "bad right live tail")
    #expect(final.segments[0].fixes?.contains { $0.kind == .reviewRevert } == true)
    #expect(final.segments[0].fixes?.contains { $0.kind == .correction } == true)
    #expect(final.segments[0].fixes?.contains { $0.kind == .liveCorrection } == true)
}
