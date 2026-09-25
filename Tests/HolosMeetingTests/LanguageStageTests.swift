import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// The post-processor's `languages` stage and `voiceislocal session languages` (docs/meeting-design.md §4.14), on
// generated audio with scripted speech and a scripted language scorer; no speech assets.
//
// The fixture meeting is 20 s long: English for 9 s, then French for 9 s. The recording's transcript is English
// (the live language), so its French part is English words with low confidence; the French pass hears the English
// part as English-looking words with middling confidence. Words are spelled "<spoken>-<n>@<model>", and the scorer
// reads a word as the language its spelling starts with.

// MARK: - Helpers

private let languageStageEnglish = "en-CA"
private let languageStageFrench = "fr-CA"
private let languageStageSpanish = "es-ES"

/// What `model` hears of [start, start + seconds) spoken in `spoken`: a word every 0.5 s, confident only in its own
/// language.
private func languageStagePassage(_ spoken: String, heardBy model: String, from start: Double, seconds: Double,
                                  id: String) -> TranscriptSegment {
    let count = Int((seconds / 0.5).rounded())
    let words = (0..<count).map { "\(spoken)-\(Int(start * 2) + $0)@\(model)" }
    var segment = SessionFixtures.segment(words, track: "mic", start: start, id: id)
    let confidence = model == spoken ? 0.9 : (model == "fr" ? 0.6 : 0.2)
    segment.words = segment.words.map { word in
        var scored = word
        scored.confidence = confidence
        return scored
    }
    return segment
}

/// The meeting as the model of `code` transcribes it; segment IDs are `<prefix>1` and `<prefix>2`.
private func languageStageHeard(by code: String, prefix: String) -> [TranscriptSegment] {
    [languageStagePassage("en", heardBy: code, from: 0, seconds: 9, id: "\(prefix)1"),
     languageStagePassage("fr", heardBy: code, from: 9, seconds: 9, id: "\(prefix)2")]
}

/// The share of each candidate language's code among the text's tokens (uniform when none matches).
private func languageStageScorer(_ text: String, _ languages: [String]) -> [String: Double] {
    let tokens = text.split(separator: " ")
    var counts: [String: Double] = [:]
    for language in languages {
        counts[language] = Double(tokens.filter { $0.hasPrefix(language.prefix(2)) }.count)
    }
    let total = counts.values.reduce(0, +)
    guard total > 0 else {
        return Dictionary(uniqueKeysWithValues: languages.map { ($0, 1 / Double(languages.count)) })
    }
    return counts.mapValues { $0 / total }
}

/// Speech that answers per language: each locale's script, the same for every session made for it. Records the
/// locales asked for, in order.
private final class LanguageStageSpeech: Sendable {
    private let scripts: [String: FakeSpeechScript]
    private let calls = SharedValue<[String]>([])

    init(_ scripts: [String: FakeSpeechScript]) { self.scripts = scripts }

    /// French and Spanish passes of the fixture meeting; English too (for a transcript that must be made again).
    static func standard() -> LanguageStageSpeech {
        LanguageStageSpeech([
            languageStageEnglish: FakeSpeechScript(segments: languageStageHeard(by: "en", prefix: "P")),
            languageStageFrench: FakeSpeechScript(segments: languageStageHeard(by: "fr", prefix: "F")),
            languageStageSpanish: FakeSpeechScript(segments: languageStageHeard(by: "es", prefix: "S")),
        ])
    }

    var factory: LiveSpeechFactory {
        { locale, backend, contextualStrings, onUpdate in
            self.calls.update { $0.append(locale) }
            let script = self.scripts[locale] ?? FakeSpeechScript()
            if let error = script.makeError { throw error }
            return FakeSpeech(locale: locale, backend: backend, contextualStrings: contextualStrings, script: script,
                              onUpdate: onUpdate)
        }
    }

    var locales: [String] { calls.value }
}

private func languageStageDependencies(_ speech: LanguageStageSpeech,
                                       installed: SharedValue<Set<String>> = SharedValue([
                                           languageStageEnglish, languageStageFrench, languageStageSpanish,
                                       ])) -> LanguageDetectionDependencies {
    LanguageDetectionDependencies(
        makeSpeech: speech.factory,
        modelStatus: { locale, _ in installed.value.contains(locale) ? "installed" : "supported" },
        makeScorer: { languageStageScorer }, timeouts: nil)
}

/// A finished in-person session in `root`: 20 s of quiet microphone audio, meeting.json with `languages`, the English
/// recording's transcript as current, finished as `status`.
private func languageStageSession(in root: URL, languages: [String]? = [languageStageEnglish, languageStageFrench],
                                  status: String = ArchiveStatus.complete) async throws -> (URL, Transcript) {
    let archive = try SessionArchive.create(root: root, name: "Bilingual meeting", source: .microphone,
                                            locale: languageStageEnglish, backend: .speech)
    try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: .inPerson, othersInRoom: false,
                                         createdAt: SessionFixtures.date, languages: languages),
                             to: SessionPaths.meetingInfo(archive.directory))
    let writer = AudioChunkWriter(archive: archive)
    let samples = (0..<(20 * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.01 }
    try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(samples: samples, sampleRate: 16_000,
                                                                            channels: 1, startTime: 0)))
    try await writer.finish()
    let transcript = SessionFixtures.transcript(languageStageHeard(by: "en", prefix: "E"))
    try await archive.saveTranscript(transcript, writeLegacyExports: false)
    try await archive.finish(status: status)
    return (archive.directory, transcript)
}

private func languageStageProcessor(_ speech: LanguageStageSpeech, options: PostProcessingOptions = .init(),
                                    diarizer: (any SpeakerDiarizer)? = FakeDiarizer(
                                        outputs: ["mic": SessionFixtures.alternatingOutput()]),
                                    installed: SharedValue<Set<String>> = SharedValue([
                                        languageStageEnglish, languageStageFrench, languageStageSpanish,
                                    ])) -> MeetingPostProcessor {
    MeetingPostProcessor(diarizer: diarizer, options: options, freeSpace: FixedFreeSpace(.max),
                         languages: languageStageDependencies(speech, installed: installed))
}

private func languageStageCurrent(_ session: URL) throws -> Transcript {
    let id = try #require(try SessionArchive.currentTranscriptID(at: session))
    return try SessionFiles.transcript(id: id, session: session)
}

private func languageStageEvents(_ session: URL, _ kind: String) throws -> [ArchiveEvent] {
    try SessionArchive.readEvents(at: session).events.filter { $0.kind == kind }
}

private func languageStageOutcome(_ record: PostProcessingRecord) -> StageOutcome? {
    record.stages.last { $0.stage == .languages }
}

// MARK: - After a recording

@Test(.timeLimit(.minutes(1)))
func twoLanguagesAreTranscribedMergedAndLabelled() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, recorded) = try await languageStageSession(in: temp.url)
    let speech = LanguageStageSpeech.standard()
    let progress = SharedValue<[PostProcessingProgress]>([])
    let record = try await languageStageProcessor(speech).run(session: session, lease: nil) { report in
        progress.update { $0.append(report) }
    }

    #expect(record.state == .succeeded)
    #expect(record.stages.map(\.stage) == [.transcript, .languages, .render, .diarize, .align, .export])
    let stage = try #require(languageStageOutcome(record))
    #expect(stage.result == .succeeded)
    #expect(stage.message == "Kept English (Canada) in 50 % of the passages and French (Canada) in 50 %, with 1 switch.")
    #expect(record.message?.hasPrefix("Transcribed in English (Canada) and French (Canada). Labelled 2 speakers") == true)
    #expect(speech.locales == [languageStageEnglish, languageStageFrench],
            "Every language is transcribed again from the saved audio, the recording's own too.")

    // The merged transcript is current; the transcriptions are kept beside it, never current.
    let merged = try languageStageCurrent(session)
    #expect(merged.id != recorded.id)
    #expect(record.transcriptID == merged.id)
    #expect(merged.languages == [languageStageEnglish, languageStageFrench])
    #expect(merged.locale == languageStageEnglish)
    #expect(merged.segments.map(\.id) == ["P1", "F2"])
    #expect(merged.segments.map(\.language) == [languageStageEnglish, languageStageFrench])
    let passes = try languageStageEvents(session, MeetingEventKind.languagePass)
    #expect(passes.map { $0.details["language"] } == [languageStageEnglish, languageStageFrench])
    #expect(passes.allSatisfy { $0.details["tracks"] == "mic" })
    let englishID = try #require(passes.first?.details["transcriptID"])
    let frenchID = try #require(passes.last?.details["transcriptID"])
    let french = try SessionFiles.transcript(id: frenchID, session: session)
    #expect(french.locale == languageStageFrench)
    #expect(french.languages == nil)
    #expect(french.segments.map(\.id) == ["F1", "F2"])
    let detected = try #require(try languageStageEvents(session, MeetingEventKind.languagesDetected).first)
    #expect(detected.details["transcriptID"] == merged.id)
    #expect(detected.details["base"] == recorded.id)
    #expect(detected.details["languages"] == "en-CA,fr-CA")
    #expect(detected.details["requested"] == "en-CA,fr-CA")
    #expect(detected.details["source.en-CA"] == englishID)
    #expect(detected.details["source.fr-CA"] == frenchID)
    #expect(detected.details["switches"] == "1")
    #expect(try SessionFiles.transcript(id: recorded.id, session: session) == recorded, "Revisions are immutable.")

    // Speakers are labelled on the merged transcript, and the exports show it.
    let runID = try #require(record.runID)
    #expect(try SessionSpeakerStore.readRun(id: runID, session: session).transcriptID == merged.id)
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.contains("- Languages: English (Canada), French (Canada)\n"))
    #expect(markdown.contains("fr-18@fr"))
    #expect(!markdown.contains("fr-18@en"))
    let frenchProgress = progress.value.filter { $0.message == "Transcribing the meeting in French (Canada)…" }
        .compactMap(\.fraction)
    #expect(frenchProgress.count > 1)
    // At most once per whole percent, not once per audio buffer.
    #expect(frenchProgress.allSatisfy { abs(($0 * 100).rounded() - $0 * 100) < 1e-9 })
    #expect(zip(frenchProgress.dropFirst(), frenchProgress.dropFirst(2)).allSatisfy { $0 < $1 })
    #expect(try !SessionArchive.isActive(at: session), "The writer lock is let go after each save.")
}

@Test(.timeLimit(.minutes(1)))
func oneLanguageRecordsNoLanguageStage() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, recorded) = try await languageStageSession(in: temp.url, languages: nil)
    let speech = LanguageStageSpeech.standard()
    let record = try await languageStageProcessor(speech).run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.stages.map(\.stage) == [.transcript, .render, .diarize, .align, .export])
    #expect(speech.locales.isEmpty)
    #expect(try languageStageCurrent(session) == recorded)
}

@Test(.timeLimit(.minutes(1)))
func mergedTranscriptIsKeptOnTheNextRun() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, _) = try await languageStageSession(in: temp.url)
    let speech = LanguageStageSpeech.standard()
    _ = try await languageStageProcessor(speech).run(session: session, lease: nil)
    let merged = try languageStageCurrent(session)

    // Labelling again (as Label Speakers or an automatic relabel does) keeps it and transcribes nothing.
    let again = try await languageStageProcessor(speech, options: PostProcessingOptions(force: true))
        .run(session: session, lease: nil)
    #expect(again.state == .succeeded)
    #expect(languageStageOutcome(again) == nil)
    #expect(try languageStageCurrent(session).id == merged.id)
    #expect(speech.locales == [languageStageEnglish, languageStageFrench])
    #expect(try languageStageEvents(session, MeetingEventKind.languagesDetected).count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aSavedPassIsReusedWhenDetectionResumes() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, _) = try await languageStageSession(in: temp.url)
    // An earlier run saved the French pass, then stopped before merging.
    let pass = Transcript(source: session.path, locale: languageStageFrench, backend: .speech,
                          segments: languageStageHeard(by: "fr", prefix: "R"))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
    try await archive.saveTranscriptRevision(pass)
    try await archive.recordEvent(kind: MeetingEventKind.languagePass,
                                  details: ["transcriptID": pass.id, "language": languageStageFrench, "tracks": "mic"])
    await archive.releaseLock()
    lease.release()

    let speech = LanguageStageSpeech.standard()
    let record = try await languageStageProcessor(speech).run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(speech.locales == [languageStageEnglish], "The saved French pass is reused.")
    #expect(try languageStageCurrent(session).segments.map(\.id) == ["P1", "R2"])
}

@Test(.timeLimit(.minutes(1)))
func missingSpeechModelKeepsTheTranscriptAndSaysWhy() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, recorded) = try await languageStageSession(in: temp.url)
    let speech = LanguageStageSpeech.standard()
    let record = try await languageStageProcessor(speech, installed: SharedValue([languageStageEnglish]))
        .run(session: session, lease: nil)

    #expect(record.state == .partial)
    let stage = try #require(languageStageOutcome(record))
    #expect(stage.result == .failed)
    let reason = "French (Canada) was not transcribed: its speech model is not installed. Install it from the meeting "
        + "start panel or with voiceislocal setup --locale fr-CA, then choose Label Speakers in Meetings to detect the "
        + "languages again."
    #expect(stage.message == "Kept the transcript as it was. " + reason)
    #expect(record.message?.hasPrefix("Kept the transcript as it was. " + reason + " Labelled 2 speakers") == true)
    #expect(speech.locales.isEmpty, "Nothing is transcribed when no merge could be made.")
    #expect(try languageStageCurrent(session) == recorded)
    let runID = try #require(record.runID)
    #expect(try SessionSpeakerStore.readRun(id: runID, session: session).transcriptID == recorded.id,
            "Speakers are still labelled, on the recording's transcript.")
}

@Test(.timeLimit(.minutes(1)))
func failedPassKeepsTheTranscript() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, recorded) = try await languageStageSession(in: temp.url)
    let speech = LanguageStageSpeech([
        languageStageEnglish: FakeSpeechScript(segments: languageStageHeard(by: "en", prefix: "P")),
        languageStageFrench: FakeSpeechScript(makeError: .unavailable("The speech service is busy.")),
    ])
    let record = try await languageStageProcessor(speech, diarizer: nil).run(session: session, lease: nil)
    #expect(record.state == .partial)
    #expect(languageStageOutcome(record)?.message
        == "Kept the transcript as it was. French (Canada) was not transcribed: The speech service is busy.")
    #expect(try languageStageCurrent(session) == recorded)
    #expect(try languageStageEvents(session, MeetingEventKind.languagePass).map { $0.details["language"] }
        == [languageStageEnglish], "The English transcription is kept for the next try.")
    #expect(SessionFixtures.exists(SessionPaths.export("md", in: session)), "The exports are still written.")
}

@Test(.timeLimit(.minutes(1)))
func recordedTranscriptStandsInWhenItsLanguageCannotBeTranscribedAgain() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, _) = try await languageStageSession(in: temp.url)
    let speech = LanguageStageSpeech([
        languageStageEnglish: FakeSpeechScript(makeError: .unavailable("The speech service is busy.")),
        languageStageFrench: FakeSpeechScript(segments: languageStageHeard(by: "fr", prefix: "F")),
    ])
    let record = try await languageStageProcessor(speech, diarizer: nil).run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(try languageStageCurrent(session).segments.map(\.id) == ["E1", "F2"])
    let detected = try #require(try languageStageEvents(session, MeetingEventKind.languagesDetected).first)
    #expect(detected.details["source.en-CA"] == detected.details["base"])
    // The stand-in is said and journaled, not hidden.
    let standIn = "English (Canada) was not transcribed: The speech service is busy. " + LanguageStage.standsIn
    #expect(detected.details["fallback"] == languageStageEnglish)
    #expect(languageStageOutcome(record)?.message?.hasSuffix(standIn) == true)
    #expect(record.message?.hasPrefix("Transcribed in English (Canada) and French (Canada). " + standIn) == true)

    // Still unavailable: nothing new, the merge stands.
    let unchanged = try await languageStageProcessor(speech, diarizer: nil).run(session: session, lease: nil)
    #expect(languageStageOutcome(unchanged)?.message == standIn)
    #expect(try languageStageEvents(session, MeetingEventKind.languagesDetected).count == 1)

    // Once English can be transcribed again, the next run does it and the stand-in goes.
    let recovered = LanguageStageSpeech.standard()
    let again = try await languageStageProcessor(recovered, diarizer: nil).run(session: session, lease: nil)
    #expect(again.state == .succeeded)
    #expect(recovered.locales == [languageStageEnglish], "The saved French transcription is reused.")
    #expect(try languageStageCurrent(session).segments.map(\.id) == ["P1", "F2"])
    let redone = try #require(try languageStageEvents(session, MeetingEventKind.languagesDetected).last)
    #expect(redone.details["fallback"] == nil)
    #expect(redone.details["base"] == detected.details["base"])
}

@Test(.timeLimit(.minutes(1)))
func incompleteRecordedTranscriptNeverStandsIn() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, recorded) = try await languageStageSession(in: temp.url,
                                                             status: ArchiveStatus.transcriptionIncomplete)
    let speech = LanguageStageSpeech([
        languageStageEnglish: FakeSpeechScript(makeError: .unavailable("The speech service is busy.")),
        languageStageFrench: FakeSpeechScript(segments: languageStageHeard(by: "fr", prefix: "F")),
    ])
    let record = try await languageStageProcessor(speech, diarizer: nil).run(session: session, lease: nil)
    #expect(record.state == .partial)
    #expect(languageStageOutcome(record)?.message
        == "Kept the transcript as it was. English (Canada) was not transcribed: The speech service is busy.")
    #expect(try languageStageCurrent(session) == recorded)
}

@Test(.timeLimit(.minutes(1)))
func automaticDetectionAddsALanguageOnceItsModelIsInstalled() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let languages = [languageStageEnglish, languageStageFrench, languageStageSpanish]
    let (session, _) = try await languageStageSession(in: temp.url, languages: languages)
    let speech = LanguageStageSpeech.standard()
    let installed = SharedValue<Set<String>>([languageStageEnglish, languageStageFrench])
    let first = try await languageStageProcessor(speech, diarizer: nil, installed: installed)
        .run(session: session, lease: nil)
    #expect(first.state == .partial, "Spanish is missing.")
    #expect(languageStageOutcome(first)?.result == .succeeded, "English and French were merged.")
    #expect(try languageStageCurrent(session).languages == [languageStageEnglish, languageStageFrench])

    installed.update { $0.insert(languageStageSpanish) }
    let second = try await languageStageProcessor(speech, diarizer: nil, installed: installed)
        .run(session: session, lease: nil)
    #expect(second.state == .succeeded)
    #expect(speech.locales == [languageStageEnglish, languageStageFrench, languageStageSpanish],
            "The English and French transcriptions are reused.")
    let merged = try languageStageCurrent(session)
    #expect(merged.languages == languages)
    #expect(merged.segments.map(\.id) == ["P1", "F2"])
}

@Test(.timeLimit(.minutes(1)))
func cancelledDetectionPublishesNothing() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, recorded) = try await languageStageSession(in: temp.url)
    let speech = LanguageStageSpeech([languageStageFrench: FakeSpeechScript(finishHangs: true)])
    let processor = languageStageProcessor(speech, diarizer: nil)
    let run = Task { try await processor.run(session: session, lease: nil) }
    var budget = PollBudget(timeout: .seconds(10))
    while speech.locales.isEmpty, !budget.isSpent { await budget.poll() }
    run.cancel()
    await #expect(throws: CancellationError.self) { try await run.value }
    #expect(try languageStageCurrent(session) == recorded)
    #expect(try languageStageEvents(session, MeetingEventKind.languagesDetected).isEmpty)
    let saved = try AtomicFile.readJSON(PostProcessingRecord.self, from: SessionPaths.postprocess(session))
    #expect(saved.state == .failed && saved.message == "Post-processing was cancelled.")
    #expect(try !SessionArchive.isProcessing(at: session))
}

@Test(.timeLimit(.minutes(1)))
func passesBeforeARecoveryAreTranscribedAgain() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, _) = try await languageStageSession(in: temp.url)
    // A French pass saved before a recovery, which may have added audio, is not reused.
    let pass = Transcript(source: session.path, locale: languageStageFrench, backend: .speech,
                          segments: languageStageHeard(by: "fr", prefix: "R"))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
    try await archive.saveTranscriptRevision(pass)
    try await archive.recordEvent(kind: MeetingEventKind.languagePass,
                                  details: ["transcriptID": pass.id, "language": languageStageFrench, "tracks": "mic"])
    try await archive.recordEvent(kind: MeetingEventKind.archiveRecovered, details: [:])
    await archive.releaseLock()
    lease.release()

    let speech = LanguageStageSpeech.standard()
    let record = try await languageStageProcessor(speech, diarizer: nil).run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(speech.locales == [languageStageEnglish, languageStageFrench])
    #expect(try languageStageCurrent(session).segments.map(\.id) == ["P1", "F2"])
}

@Test(.timeLimit(.minutes(1)))
func labelsEditedWhileTranscribingAreKept() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, recorded) = try await languageStageSession(in: temp.url)
    try SessionFixtures.writeHeadRun(session: session, transcript: recorded,
                                     outputs: ["mic": SessionFixtures.alternatingOutput()])
    let head = try #require(try SessionSpeakerStore.readHead(session: session)).runID
    // A speaker is named in Review while the French pass is being made.
    let speech = LanguageStageSpeech.standard()
    let base = speech.factory
    let factory: LiveSpeechFactory = { locale, backend, contextualStrings, onUpdate in
        if locale == languageStageFrench {
            try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Alice")], session: session)
        }
        return try await base(locale, backend, contextualStrings, onUpdate)
    }
    var dependencies = languageStageDependencies(speech)
    dependencies.makeSpeech = factory
    let processor = MeetingPostProcessor(
        diarizer: FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()]),
        freeSpace: FixedFreeSpace(.max), languages: dependencies)
    let record = try await processor.run(session: session, lease: nil)

    #expect(record.state == .partial)
    let stage = try #require(languageStageOutcome(record))
    #expect(stage.result == .skipped)
    #expect(stage.message == LanguageStage.editedHead)
    #expect(try languageStageCurrent(session) == recorded, "The merge is not published.")
    #expect(try languageStageEvents(session, MeetingEventKind.languagesDetected).isEmpty)
    #expect(try languageStageEvents(session, MeetingEventKind.languagePass).count == 2,
            "The transcriptions are kept for a run with --force.")
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == head)
    #expect(try SpeakerSessionSnapshot.load(session: session).projection?.speakers
        .contains { $0.name == "Alice" } == true)
}

@Test(.timeLimit(.minutes(1)))
func nothingNewIsAddedWhileALanguageIsStillMissing() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let languages = [languageStageEnglish, languageStageFrench, languageStageSpanish]
    let (session, _) = try await languageStageSession(in: temp.url, languages: languages)
    let speech = LanguageStageSpeech.standard()
    let installed = SharedValue<Set<String>>([languageStageEnglish, languageStageFrench])
    _ = try await languageStageProcessor(speech, diarizer: nil, installed: installed).run(session: session, lease: nil)
    let merged = try languageStageCurrent(session)

    let again = try await languageStageProcessor(speech, diarizer: nil, installed: installed)
        .run(session: session, lease: nil)
    #expect(again.state == .partial)
    let stage = try #require(languageStageOutcome(again))
    #expect(stage.result == .failed)
    #expect(stage.message?.hasPrefix("Spanish (Spain) was not transcribed: its speech model is not installed.") == true)
    #expect(again.message?.hasPrefix("Spanish (Spain) was not transcribed") == true)
    #expect(try languageStageCurrent(session).id == merged.id)
    #expect(try languageStageEvents(session, MeetingEventKind.languagesDetected).count == 1)
    #expect(speech.locales == [languageStageEnglish, languageStageFrench], "Nothing is transcribed again.")
}

/// The meeting as one segment per transcription: English for 9 s, then French for 9 s, as `code`'s model hears it,
/// so the merge cuts it in two.
private func languageStageOneSegment(heardBy code: String, id: String) -> TranscriptSegment {
    let spoken = (0..<36).map { $0 < 18 ? "en" : "fr" }
    var segment = SessionFixtures.segment(spoken.enumerated().map { "\($0.element)-\($0.offset)@\(code)" },
                                          track: "mic", start: 0, id: id)
    segment.words = zip(segment.words, spoken).map { word, language in
        var scored = word
        scored.confidence = language == code ? 0.9 : (code == "fr" ? 0.6 : 0.2)
        return scored
    }
    return segment
}

@Test(.timeLimit(.minutes(1)))
func cutPassagesAreLabelledAndExported() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, _) = try await languageStageSession(in: temp.url)
    let speech = LanguageStageSpeech([
        languageStageEnglish: FakeSpeechScript(segments: [languageStageOneSegment(heardBy: "en", id: "P")]),
        languageStageFrench: FakeSpeechScript(segments: [languageStageOneSegment(heardBy: "fr", id: "F")]),
    ])
    let record = try await languageStageProcessor(speech).run(session: session, lease: nil)
    #expect(record.state == .succeeded)

    let merged = try languageStageCurrent(session)
    #expect(merged.segments.map(\.id) == ["P/0", "F/18"])
    #expect(merged.segments.map(\.language) == [languageStageEnglish, languageStageFrench])
    #expect(merged.segments.first?.text.trimmingCharacters(in: .whitespaces)
        == (0..<18).map { "en-\($0)@en" }.joined(separator: " "))
    #expect(merged.segments.last?.text == (18..<36).map { "fr-\($0)@fr" }.joined(separator: " "))

    // The run is built on the cut pieces, and its turns name only them.
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let run = try #require(snapshot.run)
    #expect(run.id == record.runID)
    #expect(run.transcriptID == merged.id)
    #expect(snapshot.projection != nil)
    let ids = Set(merged.segments.map(\.id))
    #expect(!run.turns.isEmpty)
    #expect(run.turns.allSatisfy { turn in turn.spans.allSatisfy { ids.contains($0.segmentID) } })
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.contains("en-0@en") && markdown.contains("fr-35@fr"))
    #expect(!markdown.contains("fr-18@en") && !markdown.contains("en-17@fr"))
    let json = try #require(try JSONSerialization.jsonObject(
        with: Data(contentsOf: SessionPaths.export("json", in: session))) as? [String: Any])
    #expect(json["languages"] as? [String] == [languageStageEnglish, languageStageFrench])
    let turnLanguages = (json["turns"] as? [[String: Any]] ?? []).compactMap { $0["languages"] as? [String] }
    #expect(turnLanguages.contains([languageStageEnglish]) && turnLanguages.contains([languageStageFrench]))
}

/// Speech whose sessions answer per language and, within one, per track in the order they are made (the microphone,
/// then the system track). Records the locales asked for.
private final class LanguageStageTrackSpeech: Sendable {
    private let scripts: [String: [FakeSpeechScript]]
    private let calls = SharedValue<[String]>([])

    init(_ scripts: [String: [FakeSpeechScript]]) { self.scripts = scripts }

    var factory: LiveSpeechFactory {
        { locale, backend, contextualStrings, onUpdate in
            let index = self.calls.update { calls -> Int in
                let index = calls.filter { $0 == locale }.count
                calls.append(locale)
                return index
            }
            let list = self.scripts[locale] ?? []
            let script = index < list.count ? list[index] : FakeSpeechScript()
            return FakeSpeech(locale: locale, backend: backend, contextualStrings: contextualStrings, script: script,
                              onUpdate: onUpdate)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func echoInACallStaysEchoAcrossLanguages() async throws {
    // A call in French: the user speaks French on the microphone (0–6 s, 9–18 s); the far end says one English
    // phrase (6–9 s), which the laptop speakers play back into the microphone 0.1 s later.
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    func mic(heardBy code: String) -> [TranscriptSegment] {
        [languageStagePassage("fr", heardBy: code, from: 0, seconds: 6, id: "\(code)-m1"),
         languageStagePassage("en", heardBy: code, from: 6.1, seconds: 3, id: "\(code)-echo"),
         languageStagePassage("fr", heardBy: code, from: 9, seconds: 9, id: "\(code)-m2")]
    }
    func system(heardBy code: String) -> [TranscriptSegment] {
        var far = languageStagePassage("en", heardBy: code, from: 6, seconds: 3, id: "\(code)-s1")
        far.track = "system"
        return [far]
    }
    let recorded = SessionFixtures.transcript(mic(heardBy: "fr") + system(heardBy: "fr"))
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 20, "system": 20], mode: .call,
                                                        transcript: recorded)
    let manifest = try SessionArchive.readManifest(at: session)
    try AtomicFile.writeJSON(MeetingInfo(sessionID: manifest.id, mode: .call, othersInRoom: false,
                                         createdAt: SessionFixtures.date,
                                         languages: [languageStageFrench, languageStageEnglish]),
                             to: SessionPaths.meetingInfo(session))
    let speech = LanguageStageTrackSpeech([
        languageStageFrench: [FakeSpeechScript(segments: mic(heardBy: "fr")),
                              FakeSpeechScript(segments: system(heardBy: "fr"))],
        languageStageEnglish: [FakeSpeechScript(segments: mic(heardBy: "en")),
                               FakeSpeechScript(segments: system(heardBy: "en"))],
    ])
    var dependencies = languageStageDependencies(LanguageStageSpeech.standard())
    dependencies.makeSpeech = speech.factory
    let processor = MeetingPostProcessor(
        diarizer: FakeDiarizer(outputs: ["system": SessionFixtures.alternatingOutput()]),
        freeSpace: FixedFreeSpace(.max), languages: dependencies)
    let record = try await processor.run(session: session, lease: nil)
    #expect(record.state == .succeeded)

    // The echoed window keeps the English words the system track keeps, though it lies between French windows.
    let merged = try languageStageCurrent(session)
    #expect(merged.segments.filter { $0.track == "mic" }.map(\.id) == ["fr-m1", "en-echo", "fr-m2"])
    #expect(merged.segments.filter { $0.track == "system" }.map(\.id) == ["en-s1"])

    // So the speaker stages still find the echo and leave it out of every turn.
    let run = try #require(try SpeakerSessionSnapshot.load(session: session).run)
    let echo = run.droppedWords.filter { $0.reason == EchoFilter.reason }.flatMap(\.spans)
    #expect(echo.map(\.segmentID) == ["en-echo"])
    #expect(echo.reduce(0) { $0 + $1.end - $1.first } == 6)
    #expect(!run.turns.contains { turn in turn.spans.contains { $0.segmentID == "en-echo" } })
}

// MARK: - voiceislocal session languages

private func languageStageCommand(_ session: URL, _ languages: [String], force: Bool = false,
                                  speech: LanguageStageSpeech,
                                  diarizer: (any SpeakerDiarizer)? = nil) async throws -> SessionLanguagesCommand.Outcome {
    try await SessionLanguagesCommand.run(
        SessionLanguagesCommand.Request(session: session, languages: languages, force: force), diarizer: diarizer,
        freeSpace: FixedFreeSpace(.max), languages: languageStageDependencies(speech))
}

@Test(.timeLimit(.minutes(1)))
func languagesCommandDetectsLanguagesOfASingleLanguageSession() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, _) = try await languageStageSession(in: temp.url, languages: nil)
    let speech = LanguageStageSpeech.standard()
    let outcome = try await languageStageCommand(session, ["en_CA", "fr-CA"], speech: speech)
    #expect(outcome.exitCode == 0)
    #expect(outcome.record.state == .succeeded)
    #expect(outcome.summary.hasPrefix("Kept English (Canada) in 50 % of the passages and French (Canada) in 50 %, "
        + "with 1 switch. "))
    #expect(outcome.summary.contains("Exports: \(SessionPaths.exports(session).path)"))
    #expect(!outcome.summary.contains("Transcribed in"), "The stage's message already names the languages.")
    #expect(outcome.record.message?.hasPrefix("Transcribed in English (Canada) and French (Canada). ") == true)
    #expect(try languageStageCurrent(session).languages == [languageStageEnglish, languageStageFrench])

    // The same languages again: nothing to do.
    let again = try await languageStageCommand(session, ["en-CA", "fr-CA"], speech: speech)
    #expect(again.exitCode == 0)
    #expect(languageStageOutcome(again.record)?.message
        == "The transcript was already made from English (Canada) and French (Canada).")
    #expect(speech.locales == [languageStageEnglish, languageStageFrench])

    // Another order prefers French on a tie; both transcriptions are reused.
    let reordered = try await languageStageCommand(session, ["fr-CA", "en-CA"], speech: speech)
    #expect(reordered.exitCode == 0)
    #expect(speech.locales == [languageStageEnglish, languageStageFrench])
    #expect(try languageStageCurrent(session).languages == [languageStageFrench, languageStageEnglish])
}

@Test(.timeLimit(.minutes(1)))
func languagesAskedForByNameSurviveLaterRelabels() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, _) = try await languageStageSession(in: temp.url)
    let speech = LanguageStageSpeech.standard()
    // One language: the transcript becomes the French one alone.
    let outcome = try await languageStageCommand(session, ["fr-CA"], speech: speech)
    #expect(outcome.exitCode == 0)
    let french = try languageStageCurrent(session)
    #expect(french.languages == [languageStageFrench])
    #expect(french.segments.map(\.id) == ["F1", "F2"])

    // A later relabel does not go back to meeting.json's languages.
    let record = try await languageStageProcessor(speech, diarizer: nil).run(session: session, lease: nil)
    #expect(languageStageOutcome(record) == nil)
    #expect(try languageStageCurrent(session).id == french.id)
}

@Test(.timeLimit(.minutes(1)))
func editedLabelsNeedForceToDetectLanguages() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, recorded) = try await languageStageSession(in: temp.url, languages: nil)
    try SessionFixtures.writeHeadRun(session: session, transcript: recorded,
                                     outputs: ["mic": SessionFixtures.alternatingOutput()])
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Alice")], session: session)
    let speech = LanguageStageSpeech.standard()
    let diarizer = FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()])

    let head = try #require(try SessionSpeakerStore.readHead(session: session)).runID
    let refused = try await languageStageCommand(session, ["en-CA", "fr-CA"], speech: speech, diarizer: diarizer)
    #expect(refused.exitCode == 3)
    #expect(languageStageOutcome(refused.record)?.result == .skipped)
    #expect(languageStageOutcome(refused.record)?.message == LanguageStage.editedHead)
    #expect(speech.locales.isEmpty)
    #expect(try languageStageCurrent(session) == recorded)
    #expect(refused.record.runID == head, "The edited labels are kept as they are.")
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == head)

    let forced = try await languageStageCommand(session, ["en-CA", "fr-CA"], force: true, speech: speech,
                                                diarizer: diarizer)
    #expect(forced.exitCode == 0)
    #expect(try languageStageCurrent(session).languages == [languageStageEnglish, languageStageFrench])
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.run?.transcriptID == snapshot.transcript.id)
    #expect(snapshot.projection?.speakers.contains { $0.name == "Alice" } == true, "Names carry over.")

    // Named again, then run with the same languages: the transcript is already made, so the labels (and the edit)
    // stay as they are, and the command succeeds without --force.
    let merged = try #require(snapshot.run)
    let alice = try #require(snapshot.projection?.speakers.first { $0.name == "Alice" })
    try SessionFixtures.appendEdits([.rename(speakerID: alice.id, name: "Alice B.")], session: session)
    let again = try await languageStageCommand(session, ["en-CA", "fr-CA"], speech: speech, diarizer: diarizer)
    #expect(again.exitCode == 0)
    #expect(again.record.state == .succeeded)
    #expect(languageStageOutcome(again.record)?.message
        == "The transcript was already made from English (Canada) and French (Canada).")
    #expect(again.record.stages.filter { [.render, .diarize, .align].contains($0.stage) }
        .allSatisfy { $0.result == .skipped && $0.message == SpeakerAnalysis.transcriptUnchanged })
    #expect(again.record.runID == merged.id)
    #expect(again.summary.contains(SpeakerAnalysis.transcriptUnchanged))
    #expect(try SessionSpeakerStore.readHead(session: session)?.runID == merged.id)
    #expect(try SpeakerSessionSnapshot.load(session: session).projection?.speakers
        .contains { $0.name == "Alice B." } == true)
    #expect(speech.locales == [languageStageEnglish, languageStageFrench], "Nothing is transcribed again.")
}

@Test(.timeLimit(.minutes(1)))
func languagesCommandRefusesAListThatIsNotAMeetingsLanguages() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    let (session, _) = try await languageStageSession(in: temp.url, languages: nil)
    let before = SessionFixtures.files(in: session)
    let speech = LanguageStageSpeech.standard()
    for bad in [["fr-CA", "fr-FR"], [], ["en-CA", "fr-CA", "es-ES", "de-DE"]] {
        await #expect(throws: HolosError.self) { try await languageStageCommand(session, bad, speech: speech) }
    }
    #expect(SessionFixtures.files(in: session) == before, "Nothing changed.")
}

@Test(.timeLimit(.minutes(1)))
func importRecordsLanguagesAndMergesThem() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    // A 20 s file: the import transcribes it in English, post-processing adds French.
    let (source, _) = try await languageStageSession(in: temp.url.appendingPathComponent("source"), languages: nil)
    let chunk = try #require(try SessionArchive.readManifest(at: source).chunks.first)
    let file = source.appendingPathComponent(chunk.relativePath)
    let speech = LanguageStageSpeech([
        languageStageEnglish: FakeSpeechScript(segments: languageStageHeard(by: "en", prefix: "E")),
        languageStageFrench: FakeSpeechScript(segments: languageStageHeard(by: "fr", prefix: "F")),
    ])
    let root = temp.url.appendingPathComponent("Sessions", isDirectory: true)
    let outcome = try await SessionImportCommand.run(
        SessionImportCommand.Request(file: file, name: "Imported", root: root, locale: "en-CA", backend: .speech,
                                     languages: ["en-CA", "fr-CA"]),
        diarizer: nil, makeSpeech: speech.factory, freeSpace: FixedFreeSpace(.max),
        languages: languageStageDependencies(speech))
    #expect(outcome.exitCode == 0)
    let info = try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(outcome.session))
    #expect(info.languages == [languageStageEnglish, languageStageFrench])
    #expect(speech.locales == [languageStageEnglish, languageStageEnglish, languageStageFrench],
            "The import's transcription, then one per language.")
    #expect(try languageStageCurrent(outcome.session).segments.map(\.language) == [languageStageEnglish,
                                                                                  languageStageFrench])
}
