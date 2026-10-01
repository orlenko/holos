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

@Test func alreadyAppliedLiveTextHintDoesNotMakeAnotherRevision() {
    let live = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 2, id: "live")
    let corrected = SessionFixtures.segment(["share", "the", "doc"], track: "system", start: 2, id: "final")
    let transcript = SessionFixtures.transcript([corrected], id: "current")
    let outcome = LiveHints.applyingText([
        hint(live, words: 0..<3, action: .replaceText("share the doc"), id: "H4"),
    ], to: transcript)

    #expect(outcome.applied == 0)
    #expect(outcome.alreadyApplied == 1)
    #expect(outcome.transcript.id == "current")
}

@Test func repeatedEditOfOneLivePhraseKeepsTheOriginalProvenance() {
    let segment = SessionFixtures.segment(["send", "the", "deck"], track: "system", start: 2, id: "live")
    let first = hint(segment, words: 0..<3, action: .replaceText("share the doc"), id: "H1")
    var second = first
    second.id = "H2"
    second.heard = "share the doc"
    second.action = .replaceText("share this document")
    let transcript = SessionFixtures.transcript([segment])
    let outcome = LiveHints.applyingText([first, second], to: transcript)

    #expect(outcome.applied == 1)
    #expect(outcome.transcript.segments[0].text == "share this document")
    #expect(outcome.transcript.segments[0].fixes == [
        TranscriptWordFix(first: 0, end: 3, heard: "send the deck", kind: .liveCorrection),
    ])
}

@Test func liveHintStorePreservesHintsAndBindsThemToTheSession() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript([])
    let session = try await SessionFixtures.makeSession(in: temp.url, transcript: transcript)
    let segment = SessionFixtures.segment(["hello"], track: "mic", start: 1, id: "S1")
    let first = hint(segment, words: 0..<1, action: .replaceText("hullo"), id: "H1")
    let second = hint(segment, words: 0..<1, action: .nameSpeaker("Ada"), id: "H2")

    try LiveHintStore.append(first, session: session)
    try LiveHintStore.append(second, session: session)
    #expect(try LiveHintStore.read(session: session).hints == [first, second])

    var copied = try LiveHintStore.read(session: session)
    copied.sessionID = "ANOTHER-SESSION"
    try AtomicFile.writeJSON(copied, to: SessionPaths.liveHints(session))
    #expect(throws: HolosError.self) { try LiveHintStore.read(session: session) }
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

    let record = try await MeetingPostProcessor(
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
    let processor = MeetingPostProcessor(
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
    let record = try await MeetingPostProcessor(diarizer: diarizer, freeSpace: FixedFreeSpace(.max),
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
