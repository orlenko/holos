import Foundation
import HolosAudio
import HolosCore
@testable import HolosEvaluation
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import HolosTestSupport
import Testing

// `voiceislocal eval local --backend whisper` (docs/reference-evaluation.md) with a scripted transcriber: no model is
// downloaded or loaded, no speech assets are used. Every sentence is invented. The helpers are those of
// HolosMeetingTests/DeepTranscriptionTests.swift, where these tests were.

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

private func currentTranscript(_ session: URL) throws -> Transcript {
    let id = try #require(try SessionArchive.currentTranscriptID(at: session))
    return try SessionFiles.transcript(id: id, session: session)
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
