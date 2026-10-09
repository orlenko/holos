import Foundation
import Testing
import HolosCore
import HolosStorage
@testable import HolosEvaluation
@testable import HolosMeeting
import HolosTestSupport

// EvalCompareCommand, EvalReviewCommand, EvalApplyCommand, EvalDeleteCommand and EvalLocalCommand (what
// `voiceislocal eval compare|review|apply|delete|local` do): the lease, the steps, and what each says, in order. The
// cloud run comes from a fake transport (EvalCloudCommand+ConsentTests.swift); nothing reaches the network.

/// The user's files inside the test folder (none exist until a test writes them).
private func evalFlowFiles(_ temp: TemporaryDirectory) -> EvalUserFiles {
    EvalUserFiles(wordList: WordListStore(url: temp.url.appendingPathComponent("words.json")),
                  corrections: temp.url.appendingPathComponent("corrections.json"),
                  people: SpeakerProfileStore(directory: temp.url.appendingPathComponent("Speakers")))
}

/// A session whose transcript says "hello team we deploy on cube control today", with a finished cloud run that
/// heard "Kubernetes".
private func evalFlowSession(_ temp: TemporaryDirectory) async throws -> (session: URL, run: String) {
    let words = ["hello", "team", "we", "deploy", "on", "cube", "control", "today"]
    let transcript = SessionFixtures.transcript([SessionFixtures.segment(words, track: "mic", start: 0.5)])
    let session = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("sessions"),
                                                        audioSeconds: ["mic": 6], transcript: transcript)
    var request = evalCommandCloudRequest(session, transport: EvalCommandTransport())
    request.options.segmentation.maxSeconds = 300
    let outcome = try await EvalCloudCommand.run(request, interruption: EvalUninterrupted(), consent: { .proceed },
                                                 report: { _ in })
    #expect(outcome == .uploaded(count: 1))
    return (session, try EvalStore.resolveRun(nil, in: session).id)
}

private func evalFlowHeldLease(_ session: URL) throws -> ProcessingLease {
    try SessionArchive.acquireProcessingLease(at: session)
}

// MARK: - Compare

@Test func evalCompareSaysUnreadableVocabularyThenTheSummaryThenThePath() async throws {
    let temp = try TemporaryDirectory("eval-flow")
    defer { temp.remove() }
    let (session, run) = try await evalFlowSession(temp)
    let files = evalFlowFiles(temp)
    try Data("not a word list".utf8).write(to: files.wordList.url)
    let collected = EvalCommandMessages()
    let written = try EvalCompareCommand.run(EvalCompareCommand.Request(session: session, files: files),
                                             report: collected.report)
    let report = try #require(try EvalCompare.readReport(run: run, session: session))
    guard case .note(let first)? = collected.all.first else {
        Issue.record("Expected a note first, got \(collected.all)")
        return
    }
    #expect(first.hasPrefix("Note: the word list could not be read ("))
    #expect(first.hasSuffix("); its terms are not counted."))
    #expect(Array(collected.all.dropFirst()) == EvalCompare.summaryLines(report).map(EvalCommandMessage.note)
        + [.output(written.markdown.path)])
    #expect(written.markdown == EvalPaths.compare(run, in: session).appendingPathComponent("report.md"))

    let lease = try evalFlowHeldLease(session)
    defer { lease.release() }
    #expect(throws: (any Error).self) {
        try EvalCompareCommand.run(EvalCompareCommand.Request(session: session, files: files), report: { _ in })
    }
}

// MARK: - Review

@Test func evalReviewComparesFirstThenOpensThePageUnderTheLease() async throws {
    let temp = try TemporaryDirectory("eval-flow")
    defer { temp.remove() }
    let (session, _) = try await evalFlowSession(temp)
    let collected = EvalCommandMessages()
    let opened = SharedValue<[URL]>([])
    let outcome = try await EvalReviewCommand.run(
        EvalReviewCommand.Request(session: session, files: evalFlowFiles(temp)), interruption: EvalUninterrupted(),
        open: { page in
            opened.update { $0.append(page) }
            #expect(throws: (any Error).self, "The page opens while the command still holds the session.") {
                try SessionArchive.acquireProcessingLease(at: session).release()
            }
        }, report: collected.report)
    let built = try #require(outcome.page)
    #expect(outcome.toReview == 1)
    #expect(opened.value == [built])
    #expect(collected.all.first == .note("Comparing with the current transcript first…"))
    #expect(collected.all.last == .output(built.path))
    let counted = collected.all.dropLast().last
    #expect(counted == .note("1 passages to review.")
        || counted.map { if case .note(let text) = $0 { text.hasPrefix("1 passages to review (") } else { false } }
        == true)

    // Not opened with --no-open; the comparison is current now, so it is not made again.
    let again = EvalCommandMessages()
    try await EvalReviewCommand.run(EvalReviewCommand.Request(session: session, files: evalFlowFiles(temp)),
                                    interruption: EvalUninterrupted(), open: nil, report: again.report)
    #expect(!again.all.contains(.note("Comparing with the current transcript first…")))
    #expect(opened.value.count == 1)
}

// MARK: - Apply

@Test func evalApplyWritesTheGoldSaysWhatItProposesAndAddsWhatWasAsked() async throws {
    let temp = try TemporaryDirectory("eval-flow")
    defer { temp.remove() }
    let (session, run) = try await evalFlowSession(temp)
    let files = evalFlowFiles(temp)
    try EvalCompareCommand.run(EvalCompareCommand.Request(session: session, files: files), report: { _ in })
    let report = try #require(try EvalCompare.readReport(run: run, session: session))
    let passage = try #require(report.passages.first { $0.group == .namesAndTerms })
    let decisions = ReviewDecisions(sessionID: report.sessionID, run: run, transcriptID: report.transcriptID,
                                    decisions: [.init(id: passage.id, choice: .edited, text: "Kubernetes")],
                                    terms: ["Kubernetes"])
    let decisionsFile = temp.url.appendingPathComponent("decisions.json")
    try JSONEncoder().encode(decisions).write(to: decisionsFile)

    let collected = EvalCommandMessages()
    let outcome = try EvalApplyCommand.run(
        EvalApplyCommand.Request(session: session, decisions: decisionsFile, addCorrections: true,
                                 addVocabulary: true, files: files),
        isDictionaryWord: { _ in false }, report: collected.report)
    #expect(outcome.exitCode == 0)
    #expect(outcome.gold == EvalPaths.gold(run, in: session))
    #expect(collected.all == [
        .note("Reference transcript: 1 reviewed passages."),
        .output(outcome.gold.path),
        .note("Proposed corrections (heard → meant):"),
        .note("  cube control → Kubernetes"),
        .note("Marked terms: Kubernetes"),
        .note("Added 1 corrections to \(files.corrections.path); Voice is Local's Corrections pane shows them."),
        .note("Added: Kubernetes."),
        .note("The word list has 1 term."),
    ])
    #expect(try CorrectionList.load(from: files.corrections).entries
        == [Correction(heard: "cube control", meant: "Kubernetes")])
    #expect(try files.wordList.load().terms == ["Kubernetes"])

    let missing = temp.url.appendingPathComponent("missing.json")
    #expect {
        _ = try EvalApplyCommand.run(EvalApplyCommand.Request(session: session, decisions: missing, files: files),
                                     report: { _ in })
    } throws: { error in
        guard case HolosError.invalidInput(let message)? = error as? HolosError else { return false }
        return message == "There is no file at \(missing.path)."
    }
}

// MARK: - Delete

@Test func evalDeleteSaysWhetherItDeletedAndWaitsForTheLease() async throws {
    let temp = try TemporaryDirectory("eval-flow")
    defer { temp.remove() }
    let (session, run) = try await evalFlowSession(temp)
    let lease = try evalFlowHeldLease(session)
    #expect(throws: (any Error).self) {
        _ = try EvalDeleteCommand.run(EvalDeleteCommand.Request(session: session, runID: run))
    }
    lease.release()
    #expect(SessionFixtures.exists(EvalPaths.cloudRun(run, in: session)))
    let deleted = try EvalDeleteCommand.run(EvalDeleteCommand.Request(session: session, runID: run))
    #expect(deleted.removed && deleted.message == "Deleted.")
    #expect(!SessionFixtures.exists(EvalPaths.cloudRun(run, in: session)))
    #expect(try EvalDeleteCommand.run(EvalDeleteCommand.Request(session: session, runID: nil)).removed)
    let nothing = try EvalDeleteCommand.run(EvalDeleteCommand.Request(session: session, runID: nil))
    #expect(!nothing.removed && nothing.message == "Nothing to delete.")
}

// MARK: - Local

private func evalFlowSpeech(_ speech: FakeSpeechFactory) -> EvalLocalCommand.Dependencies {
    EvalLocalCommand.Dependencies(languages: LanguageDetectionDependencies(
        makeSpeech: speech.factory, modelStatus: { _, _ in "installed" },
        makeScorer: { { _, languages in Dictionary(uniqueKeysWithValues: languages.map { ($0, 0.5) }) } },
        timeouts: nil))
}

@Test func evalLocalRunsWithTodaysVocabularyAndSaysWhatIsNext() async throws {
    let temp = try TemporaryDirectory("eval-flow")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript([SessionFixtures.segment(["hello", "team"], track: "mic", start: 0.5)])
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 4],
                                                        transcript: transcript)
    let files = evalFlowFiles(temp)
    _ = try WordListCommand.add(["Kubernetes"], store: files.wordList)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [
        SessionFixtures.segment(["we", "ship", "Kubernetes"], track: nil, start: 0.5),
    ])])
    let collected = EvalCommandMessages()
    let outcome = try await EvalLocalCommand.run(
        EvalLocalCommand.Request(session: session, sessionArgument: "the-session", files: files),
        dependencies: evalFlowSpeech(speech), interruption: EvalUninterrupted(), report: collected.report)
    let record = outcome.record
    #expect(outcome.folder == EvalPaths.localRun(record.id, in: session))
    #expect(record.completedAt != nil)
    #expect(record.vocabulary == ["Kubernetes"])
    #expect(speech.calls.map(\.contextualStrings) == [["Kubernetes"]])
    #expect(Array(collected.all.suffix(2)) == [
        .note("Local run \(record.id) is complete. Next: voiceislocal eval compare the-session --local \(record.id)"),
        .output(EvalPaths.localRun(record.id, in: session).path),
    ])
}

@Test func evalLocalRefusesAnUnreadableVocabularyBeforeTakingTheLease() async throws {
    let temp = try TemporaryDirectory("eval-flow")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 4], transcript: nil)
    let files = evalFlowFiles(temp)
    try Data("not a word list".utf8).write(to: files.wordList.url)
    let lease = try evalFlowHeldLease(session)
    defer { lease.release() }
    let speech = FakeSpeechFactory()
    let request = EvalLocalCommand.Request(session: session, sessionArgument: "s", files: files)
    let error = await #expect(throws: EvalLocalCommand.VocabularyUnreadable.self) {
        _ = try await EvalLocalCommand.run(request, dependencies: evalFlowSpeech(speech),
                                           interruption: EvalUninterrupted(), report: { _ in })
    }
    #expect(error?.message.hasPrefix("Could not read the vocabulary (pass --no-vocabulary to go without): ") == true)

    // Without a vocabulary, the held lease refuses the run before anything is transcribed.
    var plain = request
    plain.noVocabulary = true
    await #expect(throws: (any Error).self) {
        _ = try await EvalLocalCommand.run(plain, dependencies: evalFlowSpeech(speech),
                                           interruption: EvalUninterrupted(), report: { _ in })
    }
    #expect(speech.calls.isEmpty)
}

@Test func evalLocalStoppedSaysWhatIsKept() async throws {
    let temp = try TemporaryDirectory("eval-flow")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 4], transcript: nil)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [
        SessionFixtures.segment(["we", "ship"], track: nil, start: 0.5),
    ])])
    let collected = EvalCommandMessages()
    await #expect(throws: CancellationError.self) {
        _ = try await EvalLocalCommand.run(
            EvalLocalCommand.Request(session: session, sessionArgument: "s", noVocabulary: true,
                                     files: evalFlowFiles(temp)),
            dependencies: evalFlowSpeech(speech), interruption: EvalCommandStopping(stopAfter: 1),
            report: collected.report)
    }
    // The signal came as the run ended: it says so instead of the next step, and the saved run is kept.
    #expect(collected.all.last == .note("Cancelled. What is saved is kept; run the same command again to resume."))
    #expect(!collected.all.contains { if case .output = $0 { true } else { false } })
    #expect(EvalLocal.runIDs(in: session).count == 1)
}
