import Darwin
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import HolosTestSupport
import Testing

// SpeakerEditCommand (what `voiceislocal speakers rename|merge|assign|split|exclude|undo` do): what it says, in
// order, and what it saves, on fixture sessions. Helpers are prefixed `speakerCommand`; the voice tests in
// SpeakerEditCommand+VoicesTests.swift use them too.

// MARK: - Helpers

/// A people store inside the test's temporary folder.
func speakerCommandStore(_ temp: TemporaryDirectory) -> SpeakerProfileStore {
    SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers", isDirectory: true))
}

/// What one run said and how it ended.
struct SpeakerCommandRun {
    var result: Result<SpeakerEditCommand.Outcome, any Error>
    var messages: [SpeakerEditCommand.Message]

    var outcome: SpeakerEditCommand.Outcome? { try? result.get() }

    /// "incomplete: <message>", "unavailable: <message>", …; nil when the run did not throw a `HolosError`.
    var failure: String? {
        guard case .failure(let error) = result, let error = error as? HolosError else { return nil }
        switch error {
        case .invalidInput(let message): return "invalidInput: \(message)"
        case .unavailable(let message): return "unavailable: \(message)"
        case .permissionDenied(let message): return "permissionDenied: \(message)"
        case .incomplete(let message): return "incomplete: \(message)"
        case .io(let message): return "io: \(message)"
        }
    }
}

/// Loads `session` as the CLI does and runs `change` on it, collecting what it says.
func speakerCommandRun(_ change: SpeakerEditCommand.Change, session: URL, store: SpeakerProfileStore,
                       extractor: (any VoiceSampleExtractor)? = nil) async throws -> SpeakerCommandRun {
    let loaded = try LoadedSpeakers.load(session: session, store: store)
    return await speakerCommandRun(change, loaded: loaded, extractor: extractor)
}

/// Runs `change` on `loaded` (a view that may be outdated by now), collecting what it says.
func speakerCommandRun(_ change: SpeakerEditCommand.Change, loaded: LoadedSpeakers,
                       extractor: (any VoiceSampleExtractor)? = nil) async -> SpeakerCommandRun {
    let messages = SharedValue<[SpeakerEditCommand.Message]>([])
    let result: Result<SpeakerEditCommand.Outcome, any Error>
    do {
        result = .success(try await SpeakerEditCommand.run(
            SpeakerEditCommand.Request(loaded: loaded, change: change), makeExtractor: { _ in extractor },
            report: { message in messages.update { $0.append(message) } }))
    } catch {
        result = .failure(error)
    }
    return SpeakerCommandRun(result: result, messages: messages.value)
}

/// "system:S1 (Speaker 1)": a speaker as the command's sentences name it, on the session's current labels.
func speakerCommandName(_ speakerID: String, in session: URL) throws -> String {
    let speaker = try #require(try SessionFixtures.view(session).speakers.first { $0.id == speakerID })
    return "\(speaker.id) (\(speaker.label))"
}

private func speakerCommandJournal(_ session: URL) throws -> [SpeakerEdit] {
    try SpeakerSessionSnapshot.load(session: session).journal.edits
}

// MARK: - Edits

@Test(.timeLimit(.minutes(1)))
func aSpeakerRenameSaysWhatItChangedAndRewritesTheExports() async throws {
    let temp = try TemporaryDirectory("speaker-command", permissions: 0o700)
    defer { temp.remove() }
    let store = speakerCommandStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let run = try await speakerCommandRun(.edit([.rename(speakerID: "system:S2", name: "Maria")]),
                                          session: fixture.session, store: store)
    #expect(run.failure == nil)
    #expect(run.messages == [.output("Renamed system:S2 to Maria.")])
    #expect(run.outcome?.saved == true)
    #expect(run.outcome?.snapshot?.projection?.speakers.contains { $0.name == "Maria" } == true)
    #expect(try speakerCommandJournal(fixture.session).map(\.source) == ["cli"])
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: fixture.session)).contains("Maria"))
}

@Test(.timeLimit(.minutes(1)))
func aSpeakerChangeThatChangesNothingIsNotSaved() async throws {
    let temp = try TemporaryDirectory("speaker-command", permissions: 0o700)
    defer { temp.remove() }
    let store = speakerCommandStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    _ = try await speakerCommandRun(.edit([.rename(speakerID: "system:S2", name: "Maria")]),
                                    session: fixture.session, store: store)
    let journal = SessionFixtures.journalBytes(fixture.session)
    let again = try await speakerCommandRun(.edit([.rename(speakerID: "system:S2", name: "Maria")]),
                                            session: fixture.session, store: store)
    #expect(again.failure == nil)
    #expect(again.messages == [.output("Nothing to change; the speaker labels already look like that.")])
    #expect(again.outcome?.saved == false)
    #expect(again.outcome?.snapshot == nil)
    #expect(SessionFixtures.journalBytes(fixture.session) == journal)
}

@Test(.timeLimit(.minutes(1)))
func aSpeakerChangeOnOutdatedLabelsIsRefusedWithoutSayingAnything() async throws {
    let temp = try TemporaryDirectory("speaker-command", permissions: 0o700)
    defer { temp.remove() }
    let store = speakerCommandStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let loaded = try LoadedSpeakers.load(session: fixture.session, store: store)
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Jim")], session: fixture.session)
    let journal = SessionFixtures.journalBytes(fixture.session)
    let run = await speakerCommandRun(.edit([.rename(speakerID: "system:S1", name: "Bob")]), loaded: loaded)
    #expect(run.failure == "unavailable: \(SpeakerEditor.changedMessage)")
    #expect(run.messages.isEmpty)
    #expect(SessionFixtures.journalBytes(fixture.session) == journal)
}

@Test(.timeLimit(.minutes(1)))
func aHandEditedExportIsKeptAndTheCommandSaysWhere() async throws {
    let temp = try TemporaryDirectory("speaker-command", permissions: 0o700)
    defer { temp.remove() }
    let store = speakerCommandStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    try SessionExports.regenerate(session: fixture.session)
    let markdown = SessionPaths.export("md", in: fixture.session)
    #expect(chmod(markdown.path, 0o600) == 0)
    try Data("My own note.\n".utf8).write(to: markdown)
    let run = try await speakerCommandRun(.edit([.rename(speakerID: "system:S2", name: "Maria")]),
                                          session: fixture.session, store: store)
    #expect(run.failure == nil)
    #expect(run.messages.count == 2)
    #expect(run.messages.first == .output("Renamed system:S2 to Maria."))
    guard case .note(let note)? = run.messages.last else {
        Issue.record("Expected a note about the edited export, got \(run.messages)")
        return
    }
    #expect(note.range(of: #"^Your edited transcript\.md was kept as exports/edited-\d{8}-\d{6}\.md\.$"#,
                       options: .regularExpression) != nil)
}

@Test(.timeLimit(.minutes(1)))
func exportsThatCannotBeRewrittenLeaveTheChangeSavedAndSayHowToRewriteThem() async throws {
    let temp = try TemporaryDirectory("speaker-command", permissions: 0o700)
    defer { temp.remove() }
    let store = speakerCommandStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    try SessionExports.regenerate(session: fixture.session)
    // A record from a newer Voice is Local: the exports are refused, never overwritten.
    try FileManager.default.removeItem(at: SessionPaths.generatedExports(fixture.session))
    try Data(#"{"schemaVersion": 99, "files": {}}"#.utf8).write(to: SessionPaths.generatedExports(fixture.session))
    let run = try await speakerCommandRun(.edit([.rename(speakerID: "system:S2", name: "Maria")]),
                                          session: fixture.session, store: store)
    #expect(run.messages == [.output("Renamed system:S2 to Maria.")])
    let failure = try #require(run.failure)
    #expect(failure.hasPrefix("incomplete: The change was saved, but the exports could not be rewritten: "))
    #expect(failure.hasSuffix(" Rewrite them with voiceislocal session export \(fixture.session.path) --all."))
    #expect(try speakerCommandJournal(fixture.session).count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aSessionWithoutSpeakerLabelsIsRefusedWhenLoaded() async throws {
    let temp = try TemporaryDirectory("speaker-command", permissions: 0o700)
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    #expect {
        _ = try LoadedSpeakers.load(session: session, store: speakerCommandStore(temp))
    } throws: { error in
        guard case HolosError.unavailable(let message)? = error as? HolosError else { return false }
        return message == "This meeting has no speaker labels yet. Label them with voiceislocal session diarize "
            + "\(session.path)."
    }
}

@Test(.timeLimit(.minutes(1)))
func assignMergeSplitAndExcludeSayWhatTheyDid() async throws {
    let temp = try TemporaryDirectory("speaker-command", permissions: 0o700)
    defer { temp.remove() }
    let store = speakerCommandStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3"],
                                                            duration: 30)
    let session = fixture.session

    let s2 = try speakerCommandName("system:S2", in: session)
    let assign = try await speakerCommandRun(.edit([.reassignTurns(turnIDs: ["T1"], to: "system:S2")]),
                                             session: session, store: store)
    #expect(assign.messages == [.output("Assigned T1 to \(s2).")])

    let unknown = try await speakerCommandRun(.edit([.reassignTurns(turnIDs: ["T2", "T5"], to: nil)]),
                                              session: session, store: store)
    #expect(unknown.messages == [.output("Assigned T2 and T5 to Unknown speaker.")])

    let exclude = try await speakerCommandRun(.edit([.excludeFromEnrollment(turnIDs: ["T3", "T4", "T6"])]),
                                              session: session, store: store)
    #expect(exclude.messages == [.output("Excluded T3, T4, and T6 from voice learning.")])

    let created = try await speakerCommandRun(
        .edit([.newSpeaker(speakerID: "user:NEW", name: "Ana", turnIDs: ["T6"])]), session: session, store: store)
    #expect(created.failure == nil)
    let ana = try #require(created.outcome?.snapshot?.projection?.speakers.first { $0.id == "user:NEW" })
    #expect(created.messages == [.output("Assigned T6 to a new speaker, user:NEW (\(ana.label)).")])

    let s1 = try speakerCommandName("system:S1", in: session)
    let s3 = try speakerCommandName("system:S3", in: session)
    let merge = try await speakerCommandRun(.edit([.merge(from: "system:S3", into: "system:S1")]),
                                            session: session, store: store)
    #expect(merge.messages == [.output("Merged \(s3) into \(s1).")])

    let view = try SessionFixtures.view(session)
    let word = try SpeakerSelector.splitWord(turnID: "T1", atWord: 2, at: nil, in: view,
                                             transcript: fixture.transcript)
    let split = try await speakerCommandRun(.edit([.splitTurn(turnID: "T1", at: word)]), session: session,
                                            store: store)
    let part = try #require(try SessionFixtures.view(session).turns.first { $0.id.hasPrefix("T1/") })
    #expect(split.messages == [.output("Split T1 before its word 2; the second part is \(part.id) from "
                                       + "\(TimeFormat.clock(part.start)).")])
    #expect(try speakerCommandJournal(session).count == 6)
}

@Test func longTurnListsAreShortened() {
    #expect(SpeakerEditCommand.turnList([]) == "no turns")
    #expect(SpeakerEditCommand.turnList(["T1", "T2", "T3", "T4", "T5"]) == "T1, T2, T3, T4, and T5")
    #expect(SpeakerEditCommand.turnList((1...12).map { "T\($0)" }) == "12 turns (T1, T2, T3, …)")
}

// MARK: - Undo

@Test(.timeLimit(.minutes(1)))
func undoSaysWhichChangesItTookBack() async throws {
    let temp = try TemporaryDirectory("speaker-command", permissions: 0o700)
    defer { temp.remove() }
    let store = speakerCommandStore(temp)
    let fixture = try await SessionFixtures.labelledSession(in: temp.url)
    let session = fixture.session
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Jim"),
                                     .rename(speakerID: "system:S2", name: "Maria")], session: session)
    _ = try await speakerCommandRun(.edit([.rename(speakerID: "system:S2", name: "Ana")]), session: session,
                                    store: store)

    let one = try await speakerCommandRun(.undo, session: session, store: store)
    #expect(one.failure == nil)
    #expect(one.messages == [.output("Undid: Renamed system:S2 to Ana.")])
    #expect(one.outcome?.saved == true)
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).contains("Maria"))

    let two = try await speakerCommandRun(.undo, session: session, store: store)
    #expect(two.messages == [.output("Undid 2 changes: Renamed system:S1 to Jim. Renamed system:S2 to Maria.")])

    let journal = SessionFixtures.journalBytes(session)
    let none = try await speakerCommandRun(.undo, session: session, store: store)
    #expect(none.failure == "invalidInput: There is no speaker change to undo.")
    #expect(none.messages.isEmpty)
    #expect(SessionFixtures.journalBytes(session) == journal)
}
