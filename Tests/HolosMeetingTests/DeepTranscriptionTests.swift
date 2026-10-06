import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// The deep transcription pass (docs/meeting-design.md §4.16) with a scripted transcriber: no model is downloaded or
// loaded, no speech assets are used. Every sentence is invented.

// MARK: - Helpers

/// A transcriber that answers every piece with `script(request)`, in seconds from the piece's start, and counts calls.
private final class ScriptedTranscriber: DeepTranscriber, Sendable {
    let engine: String
    let calls = SharedValue(0)
    let requests = SharedValue<[(language: String?, prompt: String, seconds: Double)]>([])
    let recordedWords = SharedValue<[[Double]]>([])
    let script: @Sendable (DeepTranscriptionRequest) throws -> [DeepTranscribedSegment]

    init(engine: String = "whisper:test", script: @escaping @Sendable (DeepTranscriptionRequest) throws
            -> [DeepTranscribedSegment]) {
        self.engine = engine; self.script = script
    }

    /// One token per word or punctuation-separated piece: enough to exercise the budget.
    func promptTokenCount(_ text: String) async throws -> Int { deepTokens(text) }

    func transcribe(_ request: DeepTranscriptionRequest,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [DeepTranscribedSegment] {
        calls.update { $0 += 1 }
        requests.update { $0.append((request.language, request.prompt, Double(request.samples.count) / 16_000)) }
        recordedWords.update { $0.append(request.recordedWords) }
        progress(1)
        return try script(request)
    }
}

private func deepTokens(_ text: String) -> Int {
    text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." }).count
}

/// A segment of `words` from `start`, `wordSeconds` each, as Whisper writes them (leading spaces).
private func heard(_ text: String, at start: Double, wordSeconds: Double = 0.4) -> DeepTranscribedSegment {
    let words = text.split(separator: " ").enumerated().map { index, word in
        DeepTranscribedWord(text: " " + word, start: start + Double(index) * wordSeconds,
                            end: start + Double(index) * wordSeconds + wordSeconds * 0.8, probability: 0.9)
    }
    return DeepTranscribedSegment(text: text, start: start, end: words.last?.end ?? start, words: words)
}

/// The recorded (Apple) transcript: four passages on the microphone of an in-person meeting.
private func recordedPassages() -> [TranscriptSegment] {
    [
        SessionFixtures.segment("yesterday I asked cloud to refactor the parser".split(separator: " ").map(String.init),
                                track: "mic", start: 0.5, wordSeconds: 0.4, id: "A"),
        SessionFixtures.segment("we moved the backups to the cloud".split(separator: " ").map(String.init),
                                track: "mic", start: 5.5, wordSeconds: 0.4, id: "B"),
        SessionFixtures.segment("the a bundu box runs fine".split(separator: " ").map(String.init),
                                track: "mic", start: 10.5, wordSeconds: 0.4, id: "C"),
        SessionFixtures.segment("Cloud wrote the commit message".split(separator: " ").map(String.init),
                                track: "mic", start: 15.5, wordSeconds: 0.4, id: "D"),
    ]
}

/// What the scripted model hears in the 20 s meeting: the four passages better, a repetition loop of the third,
/// and "Thank you." at the end where the recorded transcript has nothing.
private func scriptedHearing(_ request: DeepTranscriptionRequest) -> [DeepTranscribedSegment] {
    [
        heard("Yesterday I asked Claude to refactor the parser.", at: 0.5),
        heard("We moved the backups to the cloud.", at: 5.5),
        heard("The Ubuntu box runs fine.", at: 10.5),
        heard("The Ubuntu box runs fine.", at: 11.6),
        heard("The Ubuntu box runs fine.", at: 12.7),
        heard("The Ubuntu box runs fine.", at: 13.8),
        heard("Claude wrote the commit message.", at: 15.5),
        heard("Thank you.", at: 19.0),
    ]
}

/// A finished in-person meeting whose audio is digital silence (`tone: 0`), so every passage counts as near-silent
/// and only the recorded transcript's words keep it.
private func deepSession(in root: URL, name: String = "Weekly engineering sync",
                         languages: [String]? = nil) async throws -> (URL, Transcript) {
    let transcript = SessionFixtures.transcript(recordedPassages())
    let session = try await SessionFixtures.makeSession(in: root, name: name, mode: .inPerson,
                                                        transcript: transcript, tone: 0)
    if let languages {
        let manifest = try SessionArchive.readManifest(at: session)
        try AtomicFile.writeJSON(MeetingInfo(sessionID: manifest.id, mode: .inPerson, othersInRoom: false,
                                             createdAt: SessionFixtures.date, languages: languages),
                                 to: SessionPaths.meetingInfo(session))
    }
    return (session, transcript)
}

private func deepDependencies(_ transcriber: ScriptedTranscriber, status: DeepModelStatus = .installed,
                              wordList: [String] = ["Claude", "Ubuntu"],
                              names: [String] = ["Davin"]) -> DeepTranscriptionDependencies {
    DeepTranscriptionDependencies(engine: transcriber.engine, modelStatus: { status },
                                  makeTranscriber: { transcriber }, wordList: { wordList }, names: { names })
}

private let noSpeech = LanguageDetectionDependencies(
    makeSpeech: { _, _, _, _ in throw HolosError.unavailable("No speech in these tests.") },
    modelStatus: { _, _ in "unsupported" }, makeScorer: { { _, _ in [:] } }, timeouts: nil)

private func deepRun(_ session: URL, _ dependencies: DeepTranscriptionDependencies, force: Bool = false,
                     wordFixes: WordFixDependencies = .none,
                     diarizer: (any SpeakerDiarizer)? = FakeDiarizer(
                         outputs: ["mic": SessionFixtures.alternatingOutput()]))
    async throws -> SessionDeepTranscribeCommand.Outcome {
    try await SessionDeepTranscribeCommand.run(
        SessionDeepTranscribeCommand.Request(session: session, force: force), voiceSamples: .none, diarizer: diarizer,
        freeSpace: FixedFreeSpace(.max), languages: noSpeech, wordFixes: wordFixes,
        deepTranscription: dependencies)
}

private func currentTranscript(_ session: URL) throws -> Transcript {
    let id = try #require(try SessionArchive.currentTranscriptID(at: session))
    return try SessionFiles.transcript(id: id, session: session)
}

private func deepEvents(_ session: URL) throws -> [ArchiveEvent] {
    try SessionArchive.readEvents(at: session).events.filter { $0.kind == MeetingEventKind.deepTranscribed }
}

private func deepStage(_ record: PostProcessingRecord) -> StageOutcome? {
    record.stages.last { $0.stage == .deepTranscription }
}

// MARK: - Prompt

@Test func promptCandidatesPutTheMeetingsVocabularyFirst() {
    let candidates = DeepTranscriptionPrompt.candidates(
        vocabulary: ["strick", "Not in the list", "JBLM"], wordList: ["Davin", "JBLM", "Strick", "  Husky   bus "],
        names: ["Chase", "davin", "Fab"])
    #expect(candidates == ["Strick", "JBLM", "Davin", "Husky bus", "Chase", "Fab"])
}

@Test func promptIsCappedToTheTokenBudget() async throws {
    let terms = (1...100).map { "Term\($0)" }
    let prompt = try await DeepTranscriptionPrompt.build(meetingName: "Board meeting", candidates: terms, budget: 12,
                                                        tokenCount: { deepTokens($0) })
    #expect(prompt.text == "Board meeting. Term1, Term2, Term3, Term4, Term5, Term6, Term7, Term8, Term9, Term10.")
    #expect(prompt.tokens == 12 && prompt.terms.count == 10 && prompt.leftOut == 90)
    // A long term that does not fit is skipped, and a shorter one after it still goes in.
    let skipping = try await DeepTranscriptionPrompt.build(
        meetingName: nil, candidates: ["Alpha", "a very long phrase that cannot fit", "Beta"], budget: 3,
        tokenCount: { deepTokens($0) })
    #expect(skipping.text == "Alpha, Beta." && skipping.leftOut == 1)
    // A meeting name over the budget alone is left out.
    let unnamed = try await DeepTranscriptionPrompt.build(meetingName: "one two three four", candidates: ["Alpha"],
                                                         budget: 2, tokenCount: { deepTokens($0) })
    #expect(unnamed.text == "Alpha.")
    let empty = try await DeepTranscriptionPrompt.build(meetingName: nil, candidates: [], tokenCount: { deepTokens($0) })
    #expect(empty.text.isEmpty && empty.tokens == 0)
}

// MARK: - Audio, time mapping, segments

@Test func piecesEndAtTheQuietestMomentOfTheirLastStretch() {
    var samples = [Float](repeating: 0.5, count: 16_000 * 4)
    // A quiet 0.1 s at 3.0 s.
    for index in 48_000..<49_600 { samples[index] = 0.001 }
    let cut = DeepAudio.quietestCut(samples, searchFrom: 16_000 * 2)
    #expect(cut == 48_000 + 800)
    #expect(DeepAudio.levelDB(samples[0..<100]) > -7 && DeepAudio.levelDB(samples[48_000..<49_600]) < -59)
    #expect(DeepAudio.levelDB([Float](repeating: 0, count: 10)[...]) == DeepAudio.silenceDB)
}

@Test func segmentsMapBackToSessionTimeThroughTheRender() {
    // 10 s of session audio at 100 s, a shortened gap (5 s of render silence), then audio from 400 s.
    let map = [RenderSpan(renderStart: 0, sessionStart: 100, duration: 10),
               RenderSpan(renderStart: 15, sessionStart: 400, duration: 30)]
    var piece = [Float](repeating: 0, count: 16_000 * 25)
    for index in (16_000 * 5)..<(16_000 * 7) { piece[index] = 0.1 }
    let mapped = DeepAudio.sessionSegments(
        [heard("first words here", at: 2), heard("after the gap", at: 5), heard(" ", at: 1),
         DeepTranscribedSegment(text: "Untimed passage.", start: 3, end: 6)],
        piece: piece, pieceStart: 15, track: "system", timeMap: map)
    #expect(mapped.count == 3, "A segment without text is left out.")
    #expect(abs(mapped[0].start - 402) < 1e-9 && abs(mapped[0].words[1].start - 402.4) < 1e-9)
    #expect(mapped[0].track == "system")
    #expect(mapped[0].levelDB == DeepAudio.silenceDB, "Its audio, 2–3.2 s into the piece, is silent.")
    #expect(mapped[1].levelDB > -25, "Its audio, 5–6.2 s into the piece, holds the tone.")
    #expect(mapped[2].words.isEmpty && abs(mapped[2].start - 403) < 1e-9)
}

@Test func outputOverInsertedGapSilenceIsDiscarded() {
    // 10 s of session audio at 100 s, a shortened gap (render 10–15 s is inserted silence), then audio from 400 s.
    let map = [RenderSpan(renderStart: 0, sessionStart: 100, duration: 10),
               RenderSpan(renderStart: 15, sessionStart: 400, duration: 30)]
    let piece = [Float](repeating: 0, count: 16_000 * 30)
    // A passage the model wrote over the inserted silence (render 11–12.2 s): never snapped to 110–400 s.
    #expect(DeepAudio.sessionSegments([heard("in the gap", at: 11)], piece: piece, pieceStart: 0, track: "mic",
                                      timeMap: map).isEmpty)
    // A passage straddling the gap: its words before it and after it become two passages; the word inside it goes.
    let straddling = DeepTranscribedSegment(text: " one two gap three", start: 9, end: 15.8, words: [
        DeepTranscribedWord(text: " one", start: 9.0, end: 9.3), DeepTranscribedWord(text: " two", start: 9.4, end: 9.8),
        DeepTranscribedWord(text: " gap", start: 12, end: 12.4), DeepTranscribedWord(text: " three", start: 15.2, end: 15.6),
    ])
    let split = DeepAudio.sessionSegments([straddling], piece: piece, pieceStart: 0, track: "mic", timeMap: map)
    #expect(split.map(\.text) == [" one two", " three"])
    #expect(abs(split[0].start - 109) < 1e-9 && abs(split[0].end - 109.8) < 1e-9)
    #expect(abs(split[1].start - 400.2) < 1e-9 && abs(split[1].end - 400.6) < 1e-9)
    // An untimed passage and an empty stretch keep only their part inside session audio.
    let untimed = DeepAudio.sessionSegments([DeepTranscribedSegment(text: "Untimed.", start: 8, end: 13)],
                                            piece: piece, pieceStart: 0, track: "mic", timeMap: map)
    #expect(untimed.count == 1 && abs(untimed[0].start - 108) < 1e-9 && abs(untimed[0].end - 110) < 1e-9)
    let empty = DeepAudio.sessionSegments([DeepTranscribedSegment(text: "", start: 11, end: 14, unheard: true)],
                                          piece: piece, pieceStart: 0, track: "mic", timeMap: map)
    #expect(empty.isEmpty, "Inserted silence is not audio the model left empty.")
}

@Test func transcriptSegmentsKeepWordTimingsAndOffsets() throws {
    let segment = try #require(DeepAudio.transcriptSegment(DeepHeardSegment(
        track: "mic", start: 1, end: 3, text: " Hello, café world.",
        words: [DeepTranscribedWord(text: " Hello", start: 1, end: 1.4, probability: 0.8),
                DeepTranscribedWord(text: ",", start: 1.4, end: 1.5),
                DeepTranscribedWord(text: " café", start: 1.6, end: 2.0),
                DeepTranscribedWord(text: " world.", start: 2.1, end: 2.6),
                DeepTranscribedWord(text: "  ", start: 2.6, end: 2.7)],
        levelDB: -20)))
    #expect(segment.text == "Hello, café world.")
    #expect(segment.words.map(\.text) == ["Hello,", "café", "world."])
    let text = segment.text as NSString
    for word in segment.words {
        #expect(text.substring(with: NSRange(location: word.utf16Offset, length: word.utf16Length)) == word.text)
    }
    #expect(segment.words[0].end == 1.5 && segment.words[0].confidence == 0.8)
    #expect(segment.start == 1 && segment.end == 2.6 && segment.track == "mic")
    let untimed = try #require(DeepAudio.transcriptSegment(DeepHeardSegment(
        track: "mic", start: 4, end: 6, text: "  No   timings here ", levelDB: -20)))
    #expect(untimed.text == "No timings here" && untimed.words.isEmpty)
    #expect(DeepAudio.transcriptSegment(DeepHeardSegment(track: "mic", start: 0, end: 1, text: " ", levelDB: 0)) == nil)
}

// MARK: - Guards

@Test func silentPassagesAreDroppedOnlyWhereTheRecordedTranscriptHasNoWords() {
    let reference = [SessionFixtures.segment(["kept", "words"], track: "mic", start: 10, wordSeconds: 0.5)]
    let segments = [
        DeepHeardSegment(track: "mic", start: 1, end: 2, text: "Thank you.", levelDB: -70),
        DeepHeardSegment(track: "mic", start: 10, end: 11, text: "Kept words.", levelDB: -70),
        DeepHeardSegment(track: "mic", start: 20, end: 21, text: "Loud enough.", levelDB: -30),
        DeepHeardSegment(track: "system", start: 10, end: 11, text: "Other track.", levelDB: -70),
        DeepHeardSegment(track: "mic", start: 11.4, end: 12, text: "Within the padding.", levelDB: -70),
    ]
    let result = DeepTranscriptGuards.apply(segments, reference: reference)
    #expect(result.kept.map(\.text) == ["Kept words.", "Loud enough.", "Within the padding."])
    #expect(result.droppedSilent == 2 && result.droppedRepeats == 0)
    // Without a recorded transcript, near-silence alone drops a passage.
    #expect(DeepTranscriptGuards.apply(segments, reference: nil).droppedSilent == 4)
    // A segment of an older transcript without a track counts for every track.
    var untracked = reference[0]
    untracked.track = nil
    #expect(DeepTranscriptGuards.apply(segments, reference: [untracked]).droppedSilent == 1)
}

@Test func repetitionLoopsKeepTheirFirstPassage() {
    func segment(_ text: String, _ start: Double, track: String = "mic") -> DeepHeardSegment {
        DeepHeardSegment(track: track, start: start, end: start + 1, text: text, levelDB: -20)
    }
    let segments = [
        segment("We agree.", 0), segment("we agree", 1), segment("We agree!", 2), segment("We agree.", 3),
        segment("Next item.", 4),
        segment("Twice.", 5), segment("Twice.", 6),
        segment("Loop.", 7, track: "system"), segment("Loop.", 8, track: "mic"), segment("Loop.", 9, track: "system"),
        segment("Loop.", 10, track: "system"),
    ]
    // The same short answer said three times minutes apart, with the other track speaking between: not a loop.
    let apart = [segment("Yes.", 60), segment("Yes.", 200), segment("Yes.", 400)]
    #expect(DeepTranscriptGuards.apply(apart, reference: nil).droppedRepeats == 0)
    // A loop must run back to back: a gap of more than `repeatGapSeconds` ends it.
    let broken = [segment("Again.", 0), segment("Again.", 1), segment("Again.", 9), segment("Again.", 10)]
    #expect(DeepTranscriptGuards.apply(broken, reference: nil).droppedRepeats == 0)
    // The same short reply given three times in a few seconds while the other track asks between them: answers.
    let replies = [segment("Yes.", 0), segment("Ready?", 1.2, track: "system"), segment("Yes.", 2.4),
                   segment("Sure?", 3.6, track: "system"), segment("Yes.", 4.8)]
    #expect(DeepTranscriptGuards.apply(replies, reference: nil).droppedRepeats == 0)
    // Other-track speech before or after the loop, not between its passages, does not break it.
    let around = [segment("Hello?", 0, track: "system"), segment("Loop.", 1), segment("Loop.", 2), segment("Loop.", 3),
                  segment("Bye.", 4.5, track: "system")]
    #expect(DeepTranscriptGuards.apply(around, reference: nil).droppedRepeats == 2)
    let result = DeepTranscriptGuards.apply(segments, reference: nil)
    #expect(result.droppedRepeats == 5)
    #expect(result.kept.map { "\($0.track):\($0.text)" } == [
        "mic:We agree.", "mic:Next item.", "mic:Twice.", "mic:Twice.", "system:Loop.", "mic:Loop.",
    ])
}

// MARK: - The pass

@Test(.timeLimit(.minutes(1)))
func theMeetingIsTranscribedAgainInANewRevisionAndRelabelled() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let outcome = try await deepRun(session, deepDependencies(transcriber))

    #expect(outcome.exitCode == 0)
    #expect(outcome.record.state == .succeeded)
    #expect(outcome.record.stages.map(\.stage) == [.transcript, .deepTranscription, .render, .diarize, .align,
                                                    .export])
    let stage = try #require(deepStage(outcome.record))
    #expect(stage.result == .succeeded)
    #expect(stage.message == "Transcribed again with Whisper large-v3 turbo: 4 passages, with 3 vocabulary terms in "
        + "its prompt; left out 1 passage over silence and 3 repeats.")
    #expect(outcome.summary.hasPrefix(stage.message! + " Labelled "))
    #expect(transcriber.calls.value == 1)
    let request = try #require(transcriber.requests.value.first)
    #expect(request.language == "en")
    #expect(request.prompt == "Weekly engineering sync. Claude, Ubuntu, Davin.")
    #expect(abs(request.seconds - 20) < 0.01)

    // A new current revision with word timings; the recorded one is kept as it was.
    let deep = try currentTranscript(session)
    #expect(deep.id != recorded.id && deep.engine == "whisper:test" && deep.fixedFrom == nil)
    #expect(try SessionFiles.transcript(id: recorded.id, session: session) == recorded)
    #expect(deep.segments.map(\.text) == ["Yesterday I asked Claude to refactor the parser.",
                                          "We moved the backups to the cloud.", "The Ubuntu box runs fine.",
                                          "Claude wrote the commit message."])
    #expect(deep.segments.allSatisfy { $0.track == "mic" && !$0.words.isEmpty })
    #expect(abs(deep.segments[1].words[0].start - 5.5) < 1e-6)
    let event = try #require(try deepEvents(session).last)
    #expect(event.details["transcriptID"] == deep.id && event.details["base"] == recorded.id)
    #expect(event.details["droppedSilent"] == "1" && event.details["droppedRepeats"] == "3")
    #expect(event.details["engine"] == "whisper:test" && event.details["segments"] == "4")

    // Speakers were labelled on the new transcript, and the exports written from it.
    let view = try SessionFixtures.view(session)
    #expect(view.transcriptID == deep.id && outcome.record.transcriptID == deep.id)
    let text = try String(contentsOf: SessionPaths.exports(session).appendingPathComponent("transcript.txt"),
                          encoding: .utf8)
    #expect(text.contains("Ubuntu box") && !text.contains("Thank you"))
}

@Test(.timeLimit(.minutes(1)))
func aSecondRunKeepsTheTranscriptAndForceTranscribesAgain() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    _ = try await deepRun(session, deepDependencies(transcriber))
    let first = try currentTranscript(session)
    let head = try SessionSpeakerStore.readHead(session: session)

    let again = try await deepRun(session, deepDependencies(transcriber),
                                  diarizer: FakeDiarizer(outputs: [:], error: .unavailable("Must not relabel.")))
    #expect(again.exitCode == 0)
    #expect(transcriber.calls.value == 1, "The model's own transcript is kept.")
    #expect(deepStage(again.record)?.message == "The meeting was already transcribed with Whisper large-v3 turbo.")
    #expect(try currentTranscript(session).id == first.id)
    #expect(try SessionSpeakerStore.readHead(session: session) == head, "The labels stay as they are.")

    let forced = try await deepRun(session, deepDependencies(transcriber), force: true)
    #expect(forced.exitCode == 0 && transcriber.calls.value == 2)
    let second = try currentTranscript(session)
    #expect(second.id != first.id)
    // Checked against the recorded transcript, not the first deep one.
    #expect(try deepEvents(session).last?.details["base"] == recorded.id)
}

@Test(.timeLimit(.minutes(1)))
func deepEditedSpeakerLabelsAreKeptUnlessForced() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()]),
                                       freeSpace: FixedFreeSpace(.max), languages: noSpeech)
        .run(session: session, lease: nil)
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Alice")], session: session)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)

    let refused = try await deepRun(session, deepDependencies(transcriber))
    #expect(refused.exitCode == 3)
    #expect(deepStage(refused.record)?.result == .skipped)
    #expect(deepStage(refused.record)?.message == DeepTranscriptionStage.editedHead)
    #expect(transcriber.calls.value == 0, "Nothing is transcribed for a result that cannot be published.")
    #expect(try currentTranscript(session).id == recorded.id)
    #expect(try SessionFixtures.view(session).speakers.contains { $0.name == "Alice" })

    let forced = try await deepRun(session, deepDependencies(transcriber), force: true)
    #expect(forced.exitCode == 0)
    #expect(try currentTranscript(session).engine == "whisper:test")
    let view = try SessionFixtures.view(session)
    #expect(view.transcriptID == (try currentTranscript(session)).id)
    #expect(view.speakers.contains { $0.name == "Alice" }, "Names carry over to the new labels.")
}

@Test(.timeLimit(.minutes(1)))
func deepWordsEditedInReviewAreKeptUnlessForced() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()]),
                                       freeSpace: FixedFreeSpace(.max), languages: noSpeech)
        .run(session: session, lease: nil)
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    let edited = try #require(try await SessionWordEdit.run(
        session: session,
        request: TranscriptWordEdit.Request(segmentID: recorded.segments[0].id, first: 0, end: 1, text: "Edited"),
        expectedTranscriptID: recorded.id, expectedRunID: runID))
    let transcriber = ScriptedTranscriber(script: scriptedHearing)

    let refused = try await deepRun(session, deepDependencies(transcriber))
    #expect(deepStage(refused.record)?.result == .skipped)
    #expect(deepStage(refused.record)?.message == DeepTranscriptionStage.editedWords)
    #expect(transcriber.calls.value == 0)
    #expect(try currentTranscript(session).id == edited.transcriptID, "The words edited in Review stay.")

    let forced = try await deepRun(session, deepDependencies(transcriber), force: true)
    #expect(forced.exitCode == 0)
    #expect(try currentTranscript(session).engine == "whisper:test")
}

@Test(.timeLimit(.minutes(1)))
func deepLabelsEditedWhileTranscribingAreKept() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()]),
                                       freeSpace: FixedFreeSpace(.max), languages: noSpeech)
        .run(session: session, lease: nil)
    let transcriber = ScriptedTranscriber { request in
        // The person renames a speaker while the model works.
        try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Alice")], session: session)
        return scriptedHearing(request)
    }
    let outcome = try await deepRun(session, deepDependencies(transcriber))
    #expect(outcome.exitCode == 3)
    #expect(deepStage(outcome.record)?.message == DeepTranscriptionStage.editedHead)
    #expect(try currentTranscript(session).id == recorded.id)
    #expect(try deepEvents(session).isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func wordFixesRunOnTheNewTranscript() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, _) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let fixes = WordFixDependencies(corrections: { CorrectionList(entries: [Correction(heard: "parser", meant: "lexer")]) },
                                    wordList: { WordList() }, model: { _ in .unavailable("No model.") })
    let outcome = try await deepRun(session, deepDependencies(transcriber), wordFixes: fixes)
    #expect(outcome.exitCode == 0)
    #expect(outcome.record.stages.map(\.stage).prefix(3) == [.transcript, .deepTranscription, .wordFixes])
    let current = try currentTranscript(session)
    let deepID = try #require(try deepEvents(session).last?.details["transcriptID"])
    #expect(current.fixedFrom == deepID && current.engine == "whisper:test")
    #expect(current.segments[0].text == "Yesterday I asked Claude to refactor the lexer.")
    #expect(try SessionFixtures.view(session).transcriptID == current.id)
}

@Test(.timeLimit(.minutes(1)))
func liveCorrectionsApplyToTheNewTranscript() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    // While recording, the person changed "cloud" in the second passage (its seventh word) to "Azure".
    let passage = recorded.segments[1]
    let word = WordTiming.effectiveWords(of: passage)[6]
    try LiveHintStore.append(LiveHint(at: SessionFixtures.date, segmentID: passage.id, track: "mic", firstWord: 6,
                                      endWord: 7, start: word.start, end: word.end, heard: "cloud",
                                      action: .replaceText("Azure")), session: session)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let outcome = try await deepRun(session, deepDependencies(transcriber))
    #expect(outcome.exitCode == 0)
    let current = try currentTranscript(session)
    let deepID = try #require(try deepEvents(session).last?.details["transcriptID"])
    #expect(current.id != deepID && current.liveCorrectedFrom == deepID && current.engine == "whisper:test")
    #expect(current.segments[1].text.hasPrefix("We moved the backups to the Azure"))
    #expect(outcome.record.message?.contains("Applied 1 live text correction.") == true)
}

@Test(.timeLimit(.minutes(1)))
func microphoneEchoOfACallIsStillDropped() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let words = "the quarterly numbers look good to everyone here".split(separator: " ").map(String.init)
    let recorded = SessionFixtures.transcript([
        SessionFixtures.segment(words, track: "system", start: 1, wordSeconds: 0.4),
        SessionFixtures.segment(words, track: "mic", start: 1.15, wordSeconds: 0.4),
    ])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 10, "system": 10], mode: .call,
                                                        transcript: recorded)
    // The model hears the far end on the system track and, a moment later, its echo on the microphone. The stage
    // transcribes the tracks in order, the microphone first.
    let order = SharedValue(0)
    let transcriber = ScriptedTranscriber { _ in
        let call = order.value
        order.update { $0 += 1 }
        return [heard("The quarterly numbers look good to everyone here.", at: call == 0 ? 1.15 : 1)]
    }
    let outcome = try await deepRun(session, deepDependencies(transcriber), diarizer: FakeDiarizer(
        outputs: ["system": FakeDiarizer.alternating(speakers: ["S1"], turnSeconds: 10, duration: 10)]))
    #expect(outcome.exitCode == 0)
    let deep = try currentTranscript(session)
    #expect(deep.engine == "whisper:test" && Set(deep.segments.compactMap(\.track)) == ["mic", "system"])
    let run = try #require(try SpeakerSessionSnapshot.load(session: session).run)
    #expect(run.transcriptID == deep.id)
    let echo = run.droppedWords.filter { $0.reason == EchoFilter.reason }.flatMap(\.spans)
    let micSegment = try #require(deep.segments.first { $0.track == "mic" })
    #expect(echo.contains { $0.segmentID == micSegment.id }, "The microphone copy is dropped as echo.")
}

@Test(.timeLimit(.minutes(1)))
func deepFailedTranscriptionKeepsTheTranscript() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber { _ in throw HolosError.io("The Neural Engine is busy.") }
    let outcome = try await deepRun(session, deepDependencies(transcriber))
    #expect(outcome.exitCode == 3)
    #expect(deepStage(outcome.record)?.result == .failed)
    #expect(outcome.record.message?.hasPrefix("Kept the transcript as it was. The meeting could not be transcribed "
        + "again: The Neural Engine is busy.") == true)
    #expect(try currentTranscript(session).id == recorded.id)
    // Speakers are still labelled on the recorded transcript.
    #expect(try SessionFixtures.view(session).transcriptID == recorded.id)

    let silent = ScriptedTranscriber { _ in [] }
    let empty = try await deepRun(session, deepDependencies(silent))
    #expect(empty.exitCode == 3)
    #expect(deepStage(empty.record)?.message == "Kept the transcript as it was. No words were recognized when the "
        + "meeting was transcribed again.")
    #expect(try currentTranscript(session).id == recorded.id)
}

@Test(.timeLimit(.minutes(1)))
func deepCancelledPassPublishesNothing() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber { _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) {
        _ = try await deepRun(session, deepDependencies(transcriber))
    }
    #expect(try currentTranscript(session).id == recorded.id)
    #expect(try deepEvents(session).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.derived(session).path))
}

@Test(.timeLimit(.minutes(1)))
func theCommandRefusesWhatItCannotDo() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let transcriber = ScriptedTranscriber(script: scriptedHearing)

    // No model: nothing is done (the CLI exits 1).
    let (session, recorded) = try await deepSession(in: temp.url)
    let missing = await #expect(throws: HolosError.self) {
        _ = try await deepRun(session, deepDependencies(transcriber, status: .notInstalled))
    }
    #expect(missing?.localizedDescription == DeepTranscriptionModel.missingModelMessage)
    await #expect(throws: HolosError.self) {
        _ = try await deepRun(session, deepDependencies(transcriber, status: .downloading))
    }
    #expect(try currentTranscript(session).id == recorded.id)
    #expect(try SessionArchive.readEvents(at: session).events.allSatisfy { $0.kind != MeetingEventKind.deepTranscribed })

    // Several languages: not supported yet.
    let (multilingual, _) = try await deepSession(in: temp.url, languages: ["en-CA", "fr-CA"])
    let several = await #expect(throws: HolosError.self) {
        _ = try await deepRun(multilingual, deepDependencies(transcriber))
    }
    #expect(several?.localizedDescription == DeepTranscriptionStage.severalLanguages)
    // Run by the post-processor directly, the stage says so and keeps the transcript.
    let record = try await MeetingPostProcessor(voiceSamples: .none, 
        diarizer: nil, options: PostProcessingOptions(deepTranscribe: true), freeSpace: FixedFreeSpace(.max),
        languages: noSpeech, deepTranscription: deepDependencies(transcriber)).run(session: multilingual, lease: nil)
    #expect(deepStage(record)?.result == .skipped)
    #expect(deepStage(record)?.message == DeepTranscriptionStage.severalLanguages)
    #expect(record.state == .partial)
    #expect(transcriber.calls.value == 0)
}

@Test(.timeLimit(.minutes(1)))
func aSessionWithoutATranscriptGetsItsFirstOne() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    // Recorded with --record-only (or imported with --no-transcribe): audio, no transcript. The quiet tone is above
    // the silence threshold, so with no recorded words to compare, the audio level alone decides.
    let session = try await SessionFixtures.makeSession(in: temp.url, name: "Weekly engineering sync",
                                                        mode: .inPerson, transcript: nil)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let outcome = try await deepRun(session, deepDependencies(transcriber))
    #expect(outcome.exitCode == 0, "\(outcome.summary)")
    #expect(outcome.record.stages.first { $0.stage == .transcript }?.result == .skipped)
    let deep = try currentTranscript(session)
    #expect(deep.engine == "whisper:test" && outcome.record.transcriptID == deep.id)
    #expect(deep.segments.count == 5, "Four passages and the audible \"Thank you.\"; the loop's repeats are left out.")
    #expect(try deepEvents(session).last?.details["base"] == "")
    #expect(try SessionFixtures.view(session).transcriptID == deep.id, "Speakers are labelled on it.")
}

@Test(.timeLimit(.minutes(1)))
func aSilentSessionWithoutATranscriptGetsNone() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: nil, tone: 0)
    let outcome = try await deepRun(session, deepDependencies(ScriptedTranscriber(script: scriptedHearing)))
    #expect(outcome.exitCode == 1)
    #expect(deepStage(outcome.record)?.message == "No transcript was made. No words were recognized when the "
        + "meeting was transcribed again.")
    #expect(try SessionArchive.currentTranscriptID(at: session) == nil)
}

@Test(.timeLimit(.minutes(1)))
func aTranscriptMadeInOneNamedLanguageUsesThatLanguage() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    // What `session languages --languages fr-CA` leaves: a merge of one language.
    var french = recorded
    french.id = UUID().uuidString
    french.locale = "fr-CA"
    french.languages = ["fr-CA"]
    try await SessionFixtures.saveTranscript(french, in: session)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let outcome = try await deepRun(session, deepDependencies(transcriber))
    #expect(outcome.exitCode == 0, "\(outcome.summary)")
    #expect(transcriber.requests.value.first?.language == "fr")
    let deep = try currentTranscript(session)
    #expect(deep.engine == "whisper:test" && deep.locale == "fr-CA")
}

@Test(.timeLimit(.minutes(1)))
func evalLocalWithWhisperUsesTheCurrentTranscriptsLanguage() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    var french = recorded
    french.id = UUID().uuidString
    french.locale = "fr-CA"
    french.languages = ["fr-CA"]
    try await SessionFixtures.saveTranscript(french, in: session)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let record = try await EvalLocal.run(session: session, options: EvalLocal.Options(wordFixes: false,
                                                                                      backend: .whisper),
                                         vocabulary: [], dependencies: noSpeech,
                                         deepTranscription: deepDependencies(transcriber))
    #expect(record.languages == ["fr-CA"], "As the deep transcription pass would transcribe it.")
    #expect(transcriber.requests.value.first?.language == "fr")
}

@Test(.timeLimit(.minutes(1)))
func aResumedWhisperEvalKeepsItsGuardReference() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let recorded = SessionFixtures.transcript([
        SessionFixtures.segment(["hello", "there"], track: "mic", start: 1),
        SessionFixtures.segment(["general", "kenobi"], track: "system", start: 3),
    ])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 10, "system": 10], mode: .call,
                                                        transcript: recorded)
    let calls = SharedValue(0)
    let failing = ScriptedTranscriber { _ in
        calls.update { $0 += 1 }
        // The microphone is transcribed, then the system track fails: the run stops with one part saved.
        if calls.value > 1 { throw HolosError.io("Interrupted.") }
        return [heard("Hello there.", at: 1)]
    }
    let options = EvalLocal.Options(wordFixes: false, backend: .whisper)
    let first = try SessionArchive.acquireProcessingLease(at: session)
    await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: options, vocabulary: [], dependencies: noSpeech,
                                    deepTranscription: deepDependencies(failing))
    }
    first.release()
    // The meeting's transcript changes before the run is resumed.
    var changed = recorded
    changed.id = UUID().uuidString
    try await SessionFixtures.saveTranscript(changed, in: session)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let record = try await EvalLocal.run(session: session, options: options, vocabulary: [], dependencies: noSpeech,
                                         deepTranscription: deepDependencies(ScriptedTranscriber(script: scriptedHearing)))
    #expect(record.referenceTranscriptID == recorded.id, "Both tracks are guarded against the transcript it began with.")
    #expect(record.schemaVersion == 2)
    // A run an older Voice is Local would read as Apple's: its backend is not one that version knows.
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: EvalPaths.localRecord(record.id, in: session)))
        as? [String: Any]
    #expect(raw?["backend"] as? String == "whisper")
    let read = try #require(try EvalLocal.record(record.id, in: session))
    #expect(read.engine == record.engine && read.backend == .speech && read.schemaVersion == 2
        && read.referenceTranscriptID == recorded.id && read.prompt == record.prompt)
}

@Test(.timeLimit(.minutes(1)))
func aResumedWhisperEvalKeepsItsLanguage() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let recorded = SessionFixtures.transcript([
        SessionFixtures.segment(["hello", "there"], track: "mic", start: 1),
        SessionFixtures.segment(["general", "kenobi"], track: "system", start: 3),
    ])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 10, "system": 10], mode: .call,
                                                        transcript: recorded)
    let calls = SharedValue(0)
    let failing = ScriptedTranscriber { _ in
        calls.update { $0 += 1 }
        if calls.value > 1 { throw HolosError.io("Interrupted.") }
        return [heard("Hello there.", at: 1)]
    }
    let first = try SessionArchive.acquireProcessingLease(at: session)
    await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: EvalLocal.Options(wordFixes: false, backend: .whisper),
                                    vocabulary: [], dependencies: noSpeech, deepTranscription: deepDependencies(failing))
    }
    first.release()
    let runID = try #require(EvalLocal.runIDs(in: session).last)
    // `session languages` then makes the current transcript a merge of two languages.
    var merged = recorded
    merged.id = UUID().uuidString
    merged.languages = ["en-CA", "fr-CA"]
    try await SessionFixtures.saveTranscript(merged, in: session)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let record = try await EvalLocal.run(
        session: session, options: EvalLocal.Options(runID: runID, wordFixes: false, backend: .whisper),
        vocabulary: [], dependencies: noSpeech, deepTranscription: deepDependencies(transcriber))
    #expect(record.id == runID && record.completedAt != nil)
    #expect(record.languages == ["en-CA"] && record.referenceTranscriptID == recorded.id)
    #expect(transcriber.calls.value == 1, "Only the track still missing is transcribed.")
}

@Test(.timeLimit(.minutes(1)))
func aWhisperEvalOfAMeetingInSeveralLanguagesNeedsALanguage() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    // meeting.json lists two languages; the live transcript is still in one.
    let (session, _) = try await deepSession(in: temp.url, languages: ["en-CA", "fr-CA"])
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let error = await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: EvalLocal.Options(wordFixes: false, backend: .whisper),
                                    vocabulary: [], dependencies: noSpeech, deepTranscription: deepDependencies(transcriber))
    }
    #expect(error?.localizedDescription == EvalLocal.severalLanguages)
    #expect(transcriber.calls.value == 0 && EvalLocal.runIDs(in: session).isEmpty)
    // Named, one of them is evaluated.
    let record = try await EvalLocal.run(
        session: session, options: EvalLocal.Options(language: "fr-CA", wordFixes: false, backend: .whisper),
        vocabulary: [], dependencies: noSpeech, deepTranscription: deepDependencies(transcriber))
    #expect(record.languages == ["fr-CA"] && record.completedAt != nil)
}

@Test(.timeLimit(.minutes(1)))
func aWhisperEvalChecksDiskSpaceBeforeRendering() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, _) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let error = await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: EvalLocal.Options(wordFixes: false, backend: .whisper),
                                    vocabulary: [], dependencies: noSpeech,
                                    deepTranscription: deepDependencies(transcriber), freeSpace: FixedFreeSpace(1_000))
    }
    #expect(error?.localizedDescription == DeepTranscriptionStage.noDiskSpace)
    #expect(transcriber.calls.value == 0)
    let rendered = EvalLocal.runIDs(in: session).flatMap { id in
        ((try? FileManager.default.contentsOfDirectory(atPath: EvalPaths.localRun(id, in: session).path)) ?? [])
            .filter { $0.hasSuffix(".caf") }
    }
    #expect(rendered.isEmpty, "Nothing was rendered.")
}

@Test(.timeLimit(.minutes(1)))
func aWhisperEvalRefusesAnUnreadableTranscript() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    try Data("{ not a transcript".utf8).write(to: SessionPaths.transcript(recorded.id, in: session))
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    await #expect(throws: (any Error).self) {
        _ = try await EvalLocal.run(
            session: session, options: EvalLocal.Options(language: "en-CA", wordFixes: false, backend: .whisper),
            vocabulary: [], dependencies: noSpeech, deepTranscription: deepDependencies(transcriber))
    }
    #expect(transcriber.calls.value == 0, "Never run without the recorded-word guard it should have.")
    for id in EvalLocal.runIDs(in: session) {
        #expect(try EvalLocal.record(id, in: session)?.referenceTranscriptID != LocalRunRecord.noReference)
    }
}

@Test(.timeLimit(.minutes(1)))
func aWhisperEvalBegunWithoutATranscriptStaysUnguarded() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 10, "system": 10], mode: .call,
                                                        transcript: nil)
    let calls = SharedValue(0)
    let failing = ScriptedTranscriber { _ in
        calls.update { $0 += 1 }
        if calls.value > 1 { throw HolosError.io("Interrupted.") }
        return [heard("Hello there.", at: 1)]
    }
    let options = EvalLocal.Options(wordFixes: false, backend: .whisper)
    let first = try SessionArchive.acquireProcessingLease(at: session)
    await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: options, vocabulary: [], dependencies: noSpeech,
                                    deepTranscription: deepDependencies(failing))
    }
    first.release()
    // A transcript appears before the run is resumed: the run keeps having no reference.
    try await SessionFixtures.saveTranscript(SessionFixtures.transcript(recordedPassages()), in: session)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let record = try await EvalLocal.run(session: session, options: options, vocabulary: [], dependencies: noSpeech,
                                         deepTranscription: deepDependencies(ScriptedTranscriber(script: scriptedHearing)))
    #expect(record.referenceTranscriptID == LocalRunRecord.noReference)
}

@Test(.timeLimit(.minutes(1)))
func aLanguageWhisperDoesNotKnowIsRefusedForAWhisperEval() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, _) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let error = await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session,
                                    options: EvalLocal.Options(language: "ga-IE", wordFixes: false, backend: .whisper),
                                    vocabulary: [], dependencies: noSpeech, deepTranscription: deepDependencies(transcriber))
    }
    #expect(error?.localizedDescription.contains("ga-IE") == true)
    #expect(transcriber.calls.value == 0)
}

@Test func aWhisperRunKeepsTheMeetingsBackend() throws {
    let run = LocalRunRecord(id: "local-20260101T000000Z", sessionID: "S", createdAt: SessionFixtures.date,
                             languages: ["en-CA"], backend: .dictation, vocabulary: [], vocabularySource: "none",
                             textSteps: [], tracks: [], engine: "whisper:test")
    let data = try HolosJSON.encoder().encode(run)
    let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(raw?["backend"] as? String == "whisper" && raw?["meetingBackend"] as? String == "dictation")
    #expect(try HolosJSON.decoder().decode(LocalRunRecord.self, from: data).backend == .dictation)
}

@Test(.timeLimit(.minutes(1)))
func aRunWithNothingToDoNeedsNoModel() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, _) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    _ = try await deepRun(session, deepDependencies(transcriber))
    // The model was removed since: the transcript it made is kept without it.
    let again = try await deepRun(session, deepDependencies(transcriber, status: .notInstalled))
    #expect(again.exitCode == 0)
    #expect(deepStage(again.record)?.message == "The meeting was already transcribed with Whisper large-v3 turbo.")
    // Forced, it needs the model.
    await #expect(throws: HolosError.self) {
        _ = try await deepRun(session, deepDependencies(transcriber, status: .notInstalled), force: true)
    }
}

@Test(.timeLimit(.minutes(1)))
func aRunWithNothingToDoNeedsNoAudio() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, _) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    _ = try await deepRun(session, deepDependencies(transcriber))
    let deep = try currentTranscript(session)
    // The audio was deleted since (Delete Audio): the transcript the model made is kept without it.
    let manifest = try SessionArchive.readManifest(at: session)
    try AtomicFile.writeJSON(AudioDeletedRecord(sessionID: manifest.id, chunkCount: manifest.chunks.count,
                                                seconds: 20), to: SessionPaths.audioDeleted(session))
    let again = try await deepRun(session, deepDependencies(transcriber), diarizer: nil)
    #expect(deepStage(again.record)?.message == "The meeting was already transcribed with Whisper large-v3 turbo.")
    #expect(again.exitCode != 1, "\(again.summary)")
    #expect(try currentTranscript(session).id == deep.id && transcriber.calls.value == 1)
    // Forced, it needs the audio.
    let forced = await #expect(throws: HolosError.self) {
        _ = try await deepRun(session, deepDependencies(transcriber), force: true, diarizer: nil)
    }
    #expect(forced?.localizedDescription == DeepTranscriptionStage.audioDeleted)
}

@Test(.timeLimit(.minutes(1)))
func aSessionLeftProcessingMustBeRecoveredFirst() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, _) = try await deepSession(in: temp.url)
    var manifest = try SessionArchive.readManifest(at: session)
    manifest.status = ArchiveStatus.processing
    try AtomicFile.writeJSON(manifest, to: SessionPaths.manifest(session))
    let error = await #expect(throws: HolosError.self) {
        _ = try await deepRun(session, deepDependencies(ScriptedTranscriber(script: scriptedHearing)))
    }
    #expect(error?.localizedDescription.contains("session recover") == true)
}

@Test(.timeLimit(.minutes(1)))
func audibleStretchesTheModelLeftEmptyFailThePassWhereWordsWereHeard() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    // The model hears the first two passages, and nothing in an audible stretch where the recorder heard words.
    let missing = ScriptedTranscriber { _ in
        [heard("Yesterday I asked Claude to refactor the parser.", at: 0.5),
         DeepTranscribedSegment(text: "", start: 5, end: 10, unheard: true)]
    }
    let outcome = try await deepRun(session, deepDependencies(missing))
    #expect(outcome.exitCode == 3)
    #expect(deepStage(outcome.record)?.message?.contains("came back without words") == true)
    #expect(try currentTranscript(session).id == recorded.id)
    // Where the recorder heard nothing (music, noise), an empty stretch is fine.
    let quiet = ScriptedTranscriber { _ in
        scriptedHearing(DeepTranscriptionRequest(samples: [], language: nil, prompt: ""))
            + [DeepTranscribedSegment(text: "", start: 18, end: 19.8, unheard: true)]
    }
    let fine = try await deepRun(session, deepDependencies(quiet))
    #expect(fine.exitCode == 0)
}

@Test func adjacentEmptyStretchesCountTheirRecordedWordsTogether() {
    // Three recorded words at 5, 6, and 7 s; a retry split left the stretch as two empty halves of 1 and 2 words.
    let reference = SessionFixtures.transcript([
        SessionFixtures.segment(["one", "two", "three"], track: "mic", start: 5, wordSeconds: 1),
    ])
    func unheard(_ start: Double, _ end: Double, track: String = "mic") -> DeepHeardSegment {
        DeepHeardSegment(track: track, start: start, end: end, text: "", levelDB: -30, unheard: true)
    }
    let split = DeepTranscriptionStage.lost([unheard(5.6, 8), unheard(4.5, 5.6)], reference: reference)
    #expect(split.count == 1 && split.first?.start == 4.5 && split.first?.end == 8, "1 + 2 words are 3 lost words.")
    // Within a second of each other they are one stretch too.
    #expect(DeepTranscriptionStage.lost([unheard(4.5, 5.5), unheard(6.4, 8)], reference: reference).count == 1)
    // Further apart, each is judged alone (1 and 1 word: music or noise).
    #expect(DeepTranscriptionStage.lost([unheard(4.5, 5.5), unheard(6.8, 7.5)], reference: reference).isEmpty)
    // Stretches of different tracks are never joined.
    #expect(DeepTranscriptionStage.lost([unheard(4.5, 5.6), unheard(5.6, 8, track: "system")],
                                        reference: reference).isEmpty)
}

@Test func localesMapToWhisperLanguageTokens() {
    #expect(DeepTranscriptionModel.whisperLanguage("nb-NO") == "no")
    #expect(DeepTranscriptionModel.whisperLanguage("fil-PH") == "tl")
    #expect(DeepTranscriptionModel.whisperLanguage("he-IL") == "he")
    #expect(DeepTranscriptionModel.whisperLanguage("zh-TW") == "zh")
    #expect(DeepTranscriptionModel.whisperLanguage("jv-ID") == "jw")
    #expect(DeepTranscriptionModel.whisperLanguage("en-CA") == "en")
    #expect(DeepTranscriptionModel.whisperLanguage("xx-YY") == nil, "Unknown to Whisper: detected instead.")
}

@Test func aCancellationSaysWhetherTheTranscriptChanged() {
    #expect(SessionDeepTranscribeCommand.cancellationMessage(before: "A", after: "A")
        == "Cancelled. The transcript was kept as it was.")
    #expect(SessionDeepTranscribeCommand.cancellationMessage(before: nil, after: nil)
        == "Cancelled. No transcript was made.")
    let changed = SessionDeepTranscribeCommand.cancellationMessage(before: "A", after: "B")
    #expect(changed.hasPrefix("Cancelled after the new transcript was saved") && changed.contains("session diarize"))
    #expect(SessionDeepTranscribeCommand.cancellationMessage(before: nil, after: "B")
        .hasPrefix("Cancelled after the new transcript was saved"))
}

@Test(.timeLimit(.minutes(1)))
func ordinaryPostProcessingNeverRunsThePass() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let record = try await MeetingPostProcessor(voiceSamples: .none, 
        diarizer: FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()]), freeSpace: FixedFreeSpace(.max),
        languages: noSpeech, deepTranscription: deepDependencies(transcriber)).run(session: session, lease: nil)
    #expect(record.state == .succeeded && deepStage(record) == nil && transcriber.calls.value == 0)
    #expect(try currentTranscript(session).id == recorded.id)

    // After the pass, a relabel keeps the deep transcript.
    _ = try await deepRun(session, deepDependencies(transcriber))
    let deep = try currentTranscript(session)
    let relabel = try await MeetingPostProcessor(voiceSamples: .none, 
        diarizer: FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()]), freeSpace: FixedFreeSpace(.max),
        languages: noSpeech).run(session: session, lease: nil)
    #expect(relabel.state == .succeeded)
    #expect(try currentTranscript(session).id == deep.id)
}

/// An event as the journal holds it.
private func archiveEvent(_ sequence: Int, _ kind: String, _ details: [String: String]) throws -> ArchiveEvent {
    struct Line: Encodable {
        var sequence: Int
        var at: Date
        var kind: String
        var details: [String: String]
    }
    let line = Line(sequence: sequence, at: SessionFixtures.date, kind: kind, details: details)
    return try HolosJSON.decoder().decode(ArchiveEvent.self, from: HolosJSON.encoder().encode(line))
}

@Test(.timeLimit(.minutes(1)))
func theTranscriberIsToldWhereTheRecordedTranscriptHeardWords() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let outcome = try await deepRun(session, deepDependencies(transcriber))
    #expect(outcome.exitCode == 0, "\(outcome.summary)")
    // The recording starts at session time 0, so the render's time is the session's: every recorded word's start.
    let expected = recorded.segments.flatMap { WordTiming.effectiveWords(of: $0) }.map(\.start).sorted()
    let told = try #require(transcriber.recordedWords.value.first)
    #expect(told.count == expected.count && told.count == 26)
    #expect(zip(told, expected).allSatisfy { abs($0 - $1) < 1e-6 })
}

@Test func recordedWordsFollowTheRendersTimeMap() {
    let reference = SessionFixtures.transcript([
        SessionFixtures.segment(["one", "two"], track: "mic", start: 100, wordSeconds: 1),
        SessionFixtures.segment(["three", "four"], track: "system", start: 101, wordSeconds: 1),
        SessionFixtures.segment(["five", "six"], track: "mic", start: 400, wordSeconds: 1),
    ])
    // 100–200 s of the session is rendered at 0–100 s; after a long gap, 400–500 s at 105–205 s.
    let map = [RenderSpan(renderStart: 0, sessionStart: 100, duration: 100),
               RenderSpan(renderStart: 105, sessionStart: 400, duration: 100)]
    #expect(DeepAudio.recordedWords(reference, track: "mic", timeMap: map, pieceStart: 0, pieceSeconds: 600)
        == [0, 1, 105, 106])
    // A piece from 100 s of the render: the later words only, from its start.
    #expect(DeepAudio.recordedWords(reference, track: "mic", timeMap: map, pieceStart: 100, pieceSeconds: 600)
        == [5, 6])
    #expect(DeepAudio.recordedWords(nil, track: "mic", timeMap: map, pieceStart: 0, pieceSeconds: 600).isEmpty)
}

@Test func aDeepTranscriptStandsForTheRecordedOneInRecovery() throws {
    let events = [
        try archiveEvent(1, MeetingEventKind.transcriptRebuilt, ["transcriptID": "R"]),
        try archiveEvent(2, MeetingEventKind.deepTranscribed, ["transcriptID": "D", "base": "R"]),
        try archiveEvent(3, MeetingEventKind.wordsFixed, ["transcriptID": "F", "base": "D"]),
    ]
    #expect(TranscriptRebuilder.recordedTranscriptID("F", events: events) == "R")
    #expect(TranscriptRebuilder.recordedTranscriptID("D", events: events) == "R")
    // A rebuild R, a one-language `session languages` revision M of it, then a deep transcript D of M.
    let throughMerge = [
        try archiveEvent(1, MeetingEventKind.transcriptRebuilt, ["transcriptID": "R"]),
        try archiveEvent(2, MeetingEventKind.languagesDetected, ["transcriptID": "M", "base": "R",
                                                                  "languages": "fr-CA", "requested": "fr-CA"]),
        try archiveEvent(3, MeetingEventKind.deepTranscribed, ["transcriptID": "D", "base": "M"]),
    ]
    #expect(TranscriptRebuilder.recordedTranscriptID("D", events: throughMerge) == "R")
    // The other order: a deep transcript D of R, then a `session languages` revision M of D (word-fixed to F).
    let mergeOfDeep = [
        try archiveEvent(1, MeetingEventKind.transcriptRebuilt, ["transcriptID": "R"]),
        try archiveEvent(2, MeetingEventKind.deepTranscribed, ["transcriptID": "D", "base": "R"]),
        try archiveEvent(3, MeetingEventKind.languagesDetected, ["transcriptID": "M", "base": "D",
                                                                  "languages": "fr-CA", "requested": "fr-CA"]),
        try archiveEvent(4, MeetingEventKind.wordsFixed, ["transcriptID": "F", "base": "M"]),
    ]
    #expect(TranscriptRebuilder.recordedTranscriptID("M", events: mergeOfDeep) == "R")
    #expect(TranscriptRebuilder.recordedTranscriptID("F", events: mergeOfDeep) == "R")
    // Deep and language revisions stacked several times still lead back to the recording, and a loop ends.
    let stacked = [
        try archiveEvent(1, MeetingEventKind.deepTranscribed, ["transcriptID": "D1", "base": "R"]),
        try archiveEvent(2, MeetingEventKind.languagesDetected, ["transcriptID": "M1", "base": "D1",
                                                                  "languages": "fr-CA", "requested": "fr-CA"]),
        try archiveEvent(3, MeetingEventKind.deepTranscribed, ["transcriptID": "D2", "base": "M1"]),
        try archiveEvent(4, MeetingEventKind.languagesDetected, ["transcriptID": "M2", "base": "D2",
                                                                  "languages": "fr-CA", "requested": "fr-CA"]),
    ]
    #expect(TranscriptRebuilder.recordedTranscriptID("M2", events: stacked) == "R")
    let loop = [
        try archiveEvent(1, MeetingEventKind.deepTranscribed, ["transcriptID": "A", "base": "B"]),
        try archiveEvent(2, MeetingEventKind.languagesDetected, ["transcriptID": "B", "base": "A",
                                                                  "languages": "fr-CA", "requested": "fr-CA"]),
    ]
    let ended = TranscriptRebuilder.recordedTranscriptID("A", events: loop)
    #expect(ended == "A" || ended == "B")
    #expect(TranscriptRebuilder.mergeHoldsAllAudio("F", events: events))
    #expect(!TranscriptRebuilder.mergeHoldsAllAudio("R", events: events))
}

// MARK: - eval local --backend whisper

@Test(.timeLimit(.minutes(1)))
func evalLocalMakesAWhisperCandidateWithoutChangingTheMeeting() async throws {
    let temp = try TemporaryDirectory("deep")
    defer { temp.remove() }
    let (session, recorded) = try await deepSession(in: temp.url)
    let transcriber = ScriptedTranscriber(script: scriptedHearing)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let vocabulary = try EvalLocal.whisperVocabulary(session: session, wordList: ["Claude"], names: ["Davin"])
    let record = try await EvalLocal.run(session: session, options: EvalLocal.Options(wordFixes: false,
                                                                                      backend: .whisper),
                                         vocabulary: vocabulary, dependencies: noSpeech,
                                         deepTranscription: deepDependencies(transcriber))
    #expect(record.engine == "whisper:test" && record.completedAt != nil)
    #expect(record.prompt == "Weekly engineering sync. Claude, Davin.")
    let candidate = try EvalLocal.transcript(of: record, in: session)
    #expect(candidate.engine == "whisper:test" && candidate.segments.count == 4)
    #expect(try currentTranscript(session).id == recorded.id, "The meeting's transcript is never changed.")
    #expect(transcriber.calls.value == 1)
    let resolved = try EvalLocal.resolve("latest", in: session)
    #expect(resolved.id == record.id)
    // Not the Apple candidate: a run with the other backend starts its own.
    await #expect(throws: (any Error).self) {
        _ = try await EvalLocal.run(session: session, options: EvalLocal.Options(runID: record.id, wordFixes: false),
                                    vocabulary: nil, dependencies: noSpeech)
    }
}
