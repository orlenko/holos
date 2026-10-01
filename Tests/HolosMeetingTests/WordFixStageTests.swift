import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// The post-processor's `wordFixes` stage and `voiceislocal session fix-words` (docs/design.md "Meeting word fixes"),
// with corrections and a word list given in memory and a scripted model; no user files, no speech or language
// assets. Every sentence is invented.

// MARK: - Helpers

/// The meeting: four passages on the microphone of an in-person meeting, one per 5 s turn of the fake diarizer.
private func wordFixPassages() -> [TranscriptSegment] {
    [
        SessionFixtures.segment("yesterday I asked cloud to refactor the parser in the terminal".split(separator: " ")
            .map(String.init), track: "mic", start: 0.5, wordSeconds: 0.4, id: "A"),
        SessionFixtures.segment("we moved the backups to the cloud last year".split(separator: " ").map(String.init),
                                track: "mic", start: 5.5, wordSeconds: 0.4, id: "B"),
        SessionFixtures.segment("the a bundu box runs fine".split(separator: " ").map(String.init),
                                track: "mic", start: 10.5, wordSeconds: 0.4, id: "C"),
        SessionFixtures.segment("Cloud wrote the commit message".split(separator: " ").map(String.init),
                                track: "mic", start: 15.5, wordSeconds: 0.4, id: "D"),
    ]
}

private func wordFixSession(in root: URL) async throws -> (URL, Transcript) {
    let transcript = SessionFixtures.transcript(wordFixPassages())
    let session = try await SessionFixtures.makeSession(in: root, name: "Weekly engineering sync", mode: .inPerson,
                                                        transcript: transcript)
    return (session, transcript)
}

/// A model that says the term when the words right after the marked place are about writing code, else the word as
/// written. Counts its questions.
private final class WordFixModel: Sendable {
    let questions = SharedValue(0)
    let titles = SharedValue<[String]>([])

    var model: TranscriptFixer.Model {
        { _, prompt in
            self.questions.update { $0 += 1 }
            let title = prompt.split(separator: "\n").first.map { String($0.dropFirst("Meeting title: ".count)) } ?? ""
            self.titles.update { $0.append(title) }
            guard let mark = prompt.range(of: "]] ") else { return "?" }
            let after = prompt[mark.upperBound...].prefix(30)
            let heard = prompt.components(separatedBy: "[[").dropFirst().first?.components(separatedBy: "]]").first ?? ""
            return after.contains("refactor") || after.contains("wrote") ? "Claude" : heard
        }
    }
}

private let wordFixCorrections = CorrectionList(entries: [Correction(heard: "a bundu", meant: "ubuntu")])

private func wordFixList(_ heardAs: [String] = ["cloud"]) -> WordList {
    var list = WordList()
    list.add("Claude", at: SessionFixtures.date)
    list.addHeardAs(heardAs, to: "Claude")
    return list
}

private func wordFixDependencies(corrections: CorrectionList = wordFixCorrections, list: WordList = wordFixList(),
                                 model: WordFixDependencies.Model) -> WordFixDependencies {
    WordFixDependencies(corrections: { corrections }, wordList: { list }, model: { _ in model })
}

private func wordFixProcessor(_ dependencies: WordFixDependencies, options: PostProcessingOptions = .init(),
                              diarizer: (any SpeakerDiarizer)? = FakeDiarizer(
                                  outputs: ["mic": SessionFixtures.alternatingOutput()])) -> MeetingPostProcessor {
    MeetingPostProcessor(diarizer: diarizer, options: options, freeSpace: FixedFreeSpace(.max),
                         languages: LanguageDetectionDependencies(
                             makeSpeech: { _, _, _, _ in throw HolosError.unavailable("No speech in these tests.") },
                             modelStatus: { _, _ in "unsupported" }, makeScorer: { { _, _ in [:] } },
                             timeouts: nil),
                         wordFixes: dependencies)
}

private func wordFixCurrent(_ session: URL) throws -> Transcript {
    let id = try #require(try SessionArchive.currentTranscriptID(at: session))
    return try SessionFiles.transcript(id: id, session: session)
}

private func wordFixEvents(_ session: URL) throws -> [ArchiveEvent] {
    try SessionArchive.readEvents(at: session).events.filter { $0.kind == MeetingEventKind.wordsFixed }
}

private func wordFixOutcome(_ record: PostProcessingRecord) -> StageOutcome? {
    record.stages.last { $0.stage == .wordFixes }
}

// MARK: - After a recording

@Test(.timeLimit(.minutes(1)))
func misheardWordsAreFixedInANewRevisionBeforeSpeakersAreLabelled() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, recorded) = try await wordFixSession(in: temp.url)
    let model = WordFixModel()
    let record = try await wordFixProcessor(wordFixDependencies(model: .available(model.model)))
        .run(session: session, lease: nil)

    #expect(record.state == .succeeded)
    #expect(record.stages.map(\.stage) == [.transcript, .wordFixes, .render, .diarize, .align, .export])
    let stage = try #require(wordFixOutcome(record))
    #expect(stage.result == .succeeded)
    #expect(stage.message == "Fixed 3 misheard words: 1 by corrections, 2 word-list terms.")
    #expect(record.message?.hasPrefix("Fixed 3 misheard words. Labelled ") == true)
    #expect(model.questions.value == 3, "Each place where \"cloud\" was written is asked about once.")
    #expect(Set(model.titles.value) == ["Weekly engineering sync"])

    // A new current revision; the one before is kept as it was.
    let fixed = try wordFixCurrent(session)
    #expect(fixed.id != recorded.id && fixed.fixedFrom == recorded.id && record.transcriptID == fixed.id)
    #expect(try SessionFiles.transcript(id: recorded.id, session: session) == recorded)
    #expect(fixed.segments.map(\.text) == [
        "yesterday I asked Claude to refactor the parser in the terminal",
        "we moved the backups to the cloud last year",
        "the ubuntu box runs fine",
        "Claude wrote the commit message",
    ])
    #expect(fixed.segments.map(\.id) == recorded.segments.map(\.id))
    #expect(fixed.segments[0].fixes == [TranscriptWordFix(first: 3, end: 4, heard: "cloud", kind: .term)])
    #expect(fixed.segments[1].fixes == nil)
    #expect(fixed.segments[2].fixes == [TranscriptWordFix(first: 1, end: 2, heard: "a bundu", kind: .correction)])
    #expect(fixed.segments[3].fixes == [TranscriptWordFix(first: 0, end: 1, heard: "Cloud", kind: .term)])
    // "ubuntu" took the time of "a bundu".
    #expect(fixed.segments[2].words[1].start == recorded.segments[2].words[1].start)
    #expect(fixed.segments[2].words[1].end == recorded.segments[2].words[2].end)

    let event = try #require(try wordFixEvents(session).first)
    #expect(event.details == ["transcriptID": fixed.id, "base": recorded.id, "corrections": "1", "terms": "2",
                              "asked": "3"])
    // Speakers are labelled on the fixed text, and the exports show it.
    let runID = try #require(record.runID)
    #expect(try SessionSpeakerStore.readRun(id: runID, session: session).transcriptID == fixed.id)
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.contains("asked Claude to refactor") && markdown.contains("the ubuntu box"))
    #expect(markdown.contains("to the cloud last year"))
}

@Test(.timeLimit(.minutes(1)))
func aSecondRunKeepsTheFixedTranscript() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, _) = try await wordFixSession(in: temp.url)
    let model = WordFixModel()
    let dependencies = wordFixDependencies(model: .available(model.model))
    _ = try await wordFixProcessor(dependencies).run(session: session, lease: nil)
    let fixed = try wordFixCurrent(session)

    // Labelling again (Label Speakers, an automatic relabel) fixes nothing new.
    let again = try await wordFixProcessor(dependencies, options: PostProcessingOptions(force: true))
        .run(session: session, lease: nil)
    #expect(again.state == .succeeded)
    #expect(wordFixOutcome(again)?.message
        == "The words were already fixed (3 misheard words: 1 by corrections, 2 word-list terms).")
    #expect(try wordFixCurrent(session).id == fixed.id)
    #expect(try wordFixEvents(session).count == 1)
}

@Test(.timeLimit(.minutes(1)))
func newCorrectionsFixAgainFromTheTranscriptBeforeAnyFix() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, recorded) = try await wordFixSession(in: temp.url)
    let model = WordFixModel()
    _ = try await wordFixProcessor(wordFixDependencies(model: .available(model.model))).run(session: session, lease: nil)
    let first = try wordFixCurrent(session)

    // A correction learned since: the fixes are made again from the recorded transcript, never on top of the first.
    var more = wordFixCorrections
    more.add(Correction(heard: "the parser", meant: "the lexer"))
    _ = try await wordFixProcessor(wordFixDependencies(corrections: more, model: .available(model.model)))
        .run(session: session, lease: nil)
    let second = try wordFixCurrent(session)
    #expect(second.id != first.id && second.fixedFrom == recorded.id)
    #expect(second.segments[0].text == "yesterday I asked Claude to refactor the lexer in the terminal")
    #expect(second.segments[0].fixes?.count == 2)
    #expect(try SessionFiles.transcript(id: first.id, session: session) == first, "Every revision is kept.")

    // No corrections and no terms any more: the earlier fixes are undone, still as a new revision.
    let none = try await wordFixProcessor(wordFixDependencies(corrections: CorrectionList(), list: WordList(),
                                                              model: .available(model.model)))
        .run(session: session, lease: nil)
    #expect(wordFixOutcome(none)?.message == "No misheard words to fix; the earlier fixes were undone.")
    let undone = try wordFixCurrent(session)
    #expect(undone.fixedFrom == recorded.id && undone.segments == recorded.segments)
    #expect(try wordFixEvents(session).count == 3)
}

@Test(.timeLimit(.minutes(1)))
func withoutTheModelOnlyCorrectionsAreMade() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, _) = try await wordFixSession(in: temp.url)
    let off = wordFixDependencies(model: .unavailable("Fix misheard words with Apple Intelligence is off in Settings"))
    let record = try await wordFixProcessor(off).run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(wordFixOutcome(record)?.message == "Fixed 1 misheard word: 1 by corrections. The word list's "
        + "often-heard-as phrases were not checked: Fix misheard words with Apple Intelligence is off in Settings.")
    let fixed = try wordFixCurrent(session)
    #expect(fixed.segments.map(\.text)[0] == "yesterday I asked cloud to refactor the parser in the terminal")
    #expect(fixed.segments.map(\.text)[2] == "the ubuntu box runs fine")
}

@Test(.timeLimit(.minutes(1)))
func termsTheModelChoseAreKeptWhileItIsUnavailable() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, _) = try await wordFixSession(in: temp.url)
    let model = WordFixModel()
    _ = try await wordFixProcessor(wordFixDependencies(model: .available(model.model))).run(session: session, lease: nil)
    let fixed = try wordFixCurrent(session)

    let later = try await wordFixProcessor(wordFixDependencies(model: .unavailable("the model is still downloading")),
                                           options: PostProcessingOptions(force: true))
        .run(session: session, lease: nil)
    let stage = try #require(wordFixOutcome(later))
    #expect(stage.result == .skipped)
    #expect(stage.message == "Kept the words fixed before: Apple Intelligence cannot check the word list's "
        + "often-heard-as phrases now (the model is still downloading).")
    #expect(later.state == .succeeded)
    #expect(try wordFixCurrent(session).id == fixed.id)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func termsTheModelChoseAreKeptWhenARerunFailsOrTimesOut(timesOut: Bool) async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, _) = try await wordFixSession(in: temp.url)
    let model = WordFixModel()
    _ = try await wordFixProcessor(wordFixDependencies(model: .available(model.model))).run(session: session, lease: nil)
    let fixed = try wordFixCurrent(session)

    let broken = WordFixDependencies(corrections: { wordFixCorrections }, wordList: { wordFixList() }, model: { _ in
        .available({ _, _ in
            if timesOut { try await Task.sleep(for: .seconds(3600)) }
            throw HolosError.unavailable("The model stopped answering.")
        })
    }, timeout: .milliseconds(20))
    let later = try await wordFixProcessor(broken, options: PostProcessingOptions(force: true))
        .run(session: session, lease: nil)
    let stage = try #require(wordFixOutcome(later))
    #expect(stage.result == .skipped)
    #expect(stage.message?.hasPrefix("Kept the words fixed before: Apple Intelligence did not finish checking") == true)
    #expect(try wordFixCurrent(session).id == fixed.id)
    #expect(try wordFixEvents(session).count == 1, "An incomplete rerun publishes no replacement revision.")
}

@Test(.timeLimit(.minutes(1)))
func nothingIsRecordedWithoutCorrectionsOrTerms() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, recorded) = try await wordFixSession(in: temp.url)
    let empty = WordFixDependencies(corrections: { CorrectionList() }, wordList: { WordList() },
                                    model: { _ in .unavailable("unused") })
    let record = try await wordFixProcessor(empty).run(session: session, lease: nil)
    #expect(record.stages.map(\.stage) == [.transcript, .render, .diarize, .align, .export])
    let defaults = try await wordFixProcessor(.none, options: PostProcessingOptions(force: true))
        .run(session: session, lease: nil)
    #expect(wordFixOutcome(defaults) == nil)
    #expect(try wordFixCurrent(session) == recorded)

    // A relabel that keeps the transcript (the review window's) never fixes words.
    let model = WordFixModel()
    let kept = try await wordFixProcessor(wordFixDependencies(model: .available(model.model)),
                                          options: PostProcessingOptions(force: true, keepTranscript: true))
        .run(session: session, lease: nil)
    #expect(wordFixOutcome(kept) == nil && model.questions.value == 0)
    #expect(try wordFixCurrent(session) == recorded)
}

@Test(.timeLimit(.minutes(1)))
func aDamagedListKeepsTheTranscriptAndSaysWhy() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, recorded) = try await wordFixSession(in: temp.url)
    let damaged = WordFixDependencies(
        corrections: { wordFixCorrections },
        wordList: { throw HolosError.invalidInput("words.json is damaged or was not written by Voice is Local.") },
        model: { _ in .unavailable("unused") })
    let record = try await wordFixProcessor(damaged).run(session: session, lease: nil)
    #expect(record.state == .partial)
    #expect(wordFixOutcome(record)?.result == .failed)
    #expect(record.message?.hasPrefix("Kept the transcript as it was: words.json is damaged") == true)
    #expect(try wordFixCurrent(session) == recorded)
}

// MARK: - Edited labels

@Test(.timeLimit(.minutes(1)))
func editedSpeakerLabelsKeepTheTranscriptUnlessFixWordsIsForced() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, recorded) = try await wordFixSession(in: temp.url)
    _ = try await wordFixProcessor(.none).run(session: session, lease: nil)
    try SessionFixtures.appendEdits([.rename(speakerID: "mic:S1", name: "Alice")], session: session)
    let model = WordFixModel()
    let dependencies = wordFixDependencies(model: .available(model.model))

    // An automatic run (Label Speakers) and fix-words without --force keep the edited labels and the transcript.
    let automatic = try await wordFixProcessor(dependencies).run(session: session, lease: nil)
    #expect(automatic.state == .partial)
    #expect(wordFixOutcome(automatic)?.result == .skipped)
    #expect(wordFixOutcome(automatic)?.message == WordFixStage.editedHead)
    #expect(try wordFixCurrent(session) == recorded)
    #expect(model.questions.value == 0, "An automatic run does no model work it cannot publish.")
    let unforced = try await SessionWordFixesCommand.run(
        SessionWordFixesCommand.Request(session: session), diarizer: FakeDiarizer(
            outputs: ["mic": SessionFixtures.alternatingOutput()]), freeSpace: FixedFreeSpace(.max),
        wordFixes: dependencies)
    #expect(unforced.exitCode == 3)
    #expect(unforced.summary.hasPrefix(WordFixStage.editedHead))
    #expect(try wordFixCurrent(session) == recorded)
    #expect(try SessionFixtures.view(session).speakers.contains { $0.name == "Alice" })
    #expect(model.questions.value == 0, "An unforced fix-words does no model work it cannot publish.")

    // With --force the words are fixed, speakers labelled again on them, and the name carries over.
    let forced = try await SessionWordFixesCommand.run(
        SessionWordFixesCommand.Request(session: session, force: true), diarizer: FakeDiarizer(
            outputs: ["mic": SessionFixtures.alternatingOutput()]), freeSpace: FixedFreeSpace(.max),
        wordFixes: dependencies)
    #expect(forced.exitCode == 0)
    #expect(forced.summary.hasPrefix("Fixed 3 misheard words: 1 by corrections, 2 word-list terms. Labelled "))
    let fixed = try wordFixCurrent(session)
    #expect(fixed.fixedFrom == recorded.id)
    let view = try SessionFixtures.view(session)
    #expect(view.transcriptID == fixed.id)
    #expect(view.speakers.contains { $0.name == "Alice" })
}

@Test(.timeLimit(.minutes(1)))
func fixWordsWithoutSpeakerModelsAndAgain() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, _) = try await wordFixSession(in: temp.url)
    let model = WordFixModel()
    let dependencies = wordFixDependencies(model: .available(model.model))
    let first = try await SessionWordFixesCommand.run(SessionWordFixesCommand.Request(session: session),
                                                      diarizer: nil, freeSpace: FixedFreeSpace(.max),
                                                      wordFixes: dependencies)
    #expect(first.exitCode == 0)
    #expect(first.summary.hasPrefix("Fixed 3 misheard words: 1 by corrections, 2 word-list terms. "))
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).contains("asked Claude to refactor"))

    // Asked for by name with nothing new: the stage is recorded, and the transcript and labels stay.
    let again = try await SessionWordFixesCommand.run(SessionWordFixesCommand.Request(session: session),
                                                      diarizer: nil, freeSpace: FixedFreeSpace(.max),
                                                      wordFixes: dependencies)
    #expect(again.exitCode == 0)
    #expect(again.summary.hasPrefix("The words were already fixed (3 misheard words"))
    #expect(try wordFixEvents(session).count == 1)
}

// MARK: - Cancellation

@Test(.timeLimit(.minutes(1)))
func aCancelledRunPublishesNoFixes() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, recorded) = try await wordFixSession(in: temp.url)
    let asked = SharedValue(false)
    let hanging = wordFixDependencies(model: .available({ _, _ in
        asked.set(true)
        try await Task.sleep(for: .seconds(3600))
        return "Claude"
    }))
    let work = Task { try await wordFixProcessor(hanging).run(session: session, lease: nil) }
    #expect(await eventually { asked.value })
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(try wordFixCurrent(session) == recorded)
    #expect(try wordFixEvents(session).isEmpty)
    let record = try #require(try SessionFiles.postProcessingRecord(session: session,
                                                                    manifest: SessionArchive.readManifest(at: session)))
    #expect(record.state == .failed && record.message == "Post-processing was cancelled.")
}

// MARK: - The review

@MainActor
@Test(.timeLimit(.minutes(1)))
func theReviewShowsWhatEachFixedWordWasHeardAs() async throws {
    let temp = try TemporaryDirectory("word-fixes")
    defer { temp.remove() }
    let (session, _) = try await wordFixSession(in: temp.url)
    let model = WordFixModel()
    _ = try await wordFixProcessor(wordFixDependencies(model: .available(model.model))).run(session: session, lease: nil)
    let review = try await ReviewSession(session: session, profiles: nil, maintenance: nil,
                                         exportDelay: .seconds(60))
    let words = review.projection.turns.flatMap { review.words(of: $0) }
    let fixed = words.filter { $0.fix != nil }
    #expect(fixed.map(\.text) == ["Claude", "ubuntu", "Claude"])
    #expect(fixed.map { $0.fix?.heard } == ["cloud", "a bundu", "Cloud"])
    #expect(fixed.map { $0.fix?.kind } == [.term, .correction, .term])
    await review.close()
}
