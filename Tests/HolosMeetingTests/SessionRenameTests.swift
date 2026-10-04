import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// Renaming a finished meeting (docs/meeting-design.md §4.17): the name the user types as it is saved, the default name
// a meeting gets back with its generated title, what the list's editor asks for, and `voiceislocal session rename` on
// fixture sessions (the manifest, meeting.json's nameSource, the transcript files, refusals). Every name is invented.

// MARK: - Helpers

private let voice = SessionSummarizeCommand.VoiceInputs(names: [:], recognition: true, selfName: "Robin")
private let utc = TimeZone(identifier: "UTC")!

/// A finished meeting with a transcript and meeting.json (default name, `nameSource` `default`).
private func renameSession(in root: URL, name: String = "Meeting 2026-10-03 14:00",
                           legacyExports: Bool = false) async throws -> URL {
    let transcript = SessionFixtures.transcript(
        SessionFixtures.alternatingSegments(track: "mic", turnSeconds: 5, duration: 20))
    let session = try await SessionFixtures.makeSession(in: root, name: name, mode: .inPerson, transcript: transcript,
                                                        legacyExports: legacyExports)
    let manifest = try SessionArchive.readManifest(at: session)
    try AtomicFile.writeJSON(MeetingInfo(sessionID: manifest.id, mode: .inPerson, othersInRoom: false,
                                         createdAt: manifest.createdAt, nameSource: .default),
                             to: SessionPaths.meetingInfo(session))
    return session
}

/// A current summary of the meeting (made with `voice`'s names), and the transcript files written with it.
private func writeSummary(_ session: URL, title: String = "Parser rewrite and release plan") throws {
    let manifest = try SessionArchive.readManifest(at: session)
    let key = try #require(MeetingSummaryKey.load(session: session, profileNames: voice.names,
                                                  applyRecognition: voice.recognition, selfName: voice.selfName))
    try MeetingSummaryStore.write(MeetingSummaryRecord(
        sessionID: manifest.id, transcriptID: key.transcriptID, title: title,
        summary: "The team agreed to rewrite the parser before the release.", model: "fake",
        namesDigest: key.namesDigest), session: session)
    try SessionArchive.withSpeakerLock(at: session) {
        _ = try SessionExports.regenerateLocked(session: session, profileNames: voice.names,
                                                applyRecognition: voice.recognition, selfName: voice.selfName)
    }
}

private func rename(_ session: URL, _ name: String?, lock: URL? = nil) async -> SessionRenameCommand.Outcome {
    let lockURL = lock ?? session.deletingLastPathComponent().appendingPathComponent("jobs.lock")
    return await SessionRenameCommand.run(SessionRenameCommand.Request(
        session: session, name: name, voiceInputs: { voice }, jobLock: lockURL, timeZone: utc))
}

private func meetingJSON(_ session: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: SessionPaths.meetingInfo(session))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func editedExports(_ session: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: SessionPaths.exports(session).path)
        .filter { $0.hasPrefix("edited-") }
}

// MARK: - The name as it is saved

@Test func aTypedNameIsOneLineWithoutControlCharacters() {
    #expect(MeetingNaming.cleanUserName("  Weekly\tsync\n with  Alex ") == "Weekly sync with Alex")
    #expect(MeetingNaming.cleanUserName("Budget\u{0007} review") == "Budget review")
    #expect(MeetingNaming.cleanUserName("Q3 / Café — “Plan” #1 <b>&amp; 50% 🎉") == "Q3 / Café — “Plan” #1 <b>&amp; 50% 🎉")
    // Empty means "use the generated title".
    #expect(MeetingNaming.cleanUserName("") == nil)
    #expect(MeetingNaming.cleanUserName(" \n\t ") == nil)
}

@Test func aLongNameIsCutAsTitlesAre() throws {
    let words = Array(repeating: "planning", count: 12).joined(separator: " ")
    let cut = try #require(MeetingNaming.cleanUserName(words))
    #expect(cut.count <= MeetingNaming.maximumUserNameCharacters)
    #expect(cut.hasSuffix("planning"), "Cut at a space")
    let spaceless = String(repeating: "会", count: 100)
    #expect(MeetingNaming.cleanUserName(spaceless) == String(repeating: "会", count: 60))
    // A character carrying many combining marks counts once, but its bytes are bounded.
    let marked = String(repeating: "e" + String(repeating: "\u{0301}", count: 20), count: 20)
    let bounded = try #require(MeetingNaming.cleanUserName(marked))
    #expect(bounded.utf8.count <= MeetingNaming.maximumUserNameBytes)
    #expect(!bounded.isEmpty)
}

@Test func theDefaultNameComesBackWithTheGeneratedTitle() {
    let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13 UTC
    #expect(MeetingNaming.defaultName(current: "Weekly sync", currentSource: .user, createdAt: start,
                                      origin: .recorded, importedFileName: nil, timeZone: utc)
        == "Meeting 2026-09-21 14:13")
    // A name Voice is Local made up is kept.
    #expect(MeetingNaming.defaultName(current: "Meeting 2026-09-21 09:00", currentSource: .default, createdAt: start,
                                      origin: .recorded, importedFileName: nil, timeZone: utc)
        == "Meeting 2026-09-21 09:00")
    // A name the user typed that looks like a default one is the user's: the default is made from the start.
    #expect(MeetingNaming.defaultName(current: "Meeting 2026-01-01 09:00", currentSource: .user, createdAt: start,
                                      origin: .recorded, importedFileName: nil, timeZone: utc)
        == "Meeting 2026-09-21 14:13")
    #expect(MeetingNaming.defaultName(current: "Weekly sync", currentSource: .user, createdAt: start,
                                      origin: .imported, importedFileName: "board call.m4a", timeZone: utc)
        == "board call")
    #expect(MeetingNaming.defaultName(current: "board call", currentSource: .default, createdAt: start,
                                      origin: .imported, importedFileName: "board call.m4a", timeZone: utc)
        == "board call")
    #expect(MeetingNaming.defaultName(current: "Weekly sync", currentSource: .user, createdAt: start,
                                      origin: .imported, importedFileName: nil, timeZone: utc) == "Imported meeting")
}

// MARK: - The list's editor

private func listed(name: String, source: MeetingNameSource, generated: String?) -> SessionSummary {
    SessionSummary(id: "S", directory: URL(fileURLWithPath: "/tmp/S.holos"), name: name, createdAt: Date(),
                   source: .microphone, state: .complete, manifestStatus: "complete", transcriptID: "T",
                   liveness: .exited, nameSource: source,
                   generatedSummary: generated.map {
                       MeetingSummaryRecord(sessionID: "S", transcriptID: "T", title: $0, summary: "s", model: "fake")
                   })
}

@Test func theEditorAsksForARenameOnlyWhenWhatIsShownChanges() {
    let generated = listed(name: "Meeting 2026-10-03 14:00", source: .default, generated: "Parser plan")
    #expect(MeetingRenameRequest.name(typed: "Parser plan", summary: generated) == nil, "Left as shown")
    #expect(MeetingRenameRequest.name(typed: "", summary: generated) == nil, "Already the generated title")
    #expect(MeetingRenameRequest.name(typed: " Parser  plan v2 ", summary: generated) == .user("Parser plan v2"))
    let named = listed(name: "Weekly sync", source: .user, generated: "Parser plan")
    #expect(MeetingRenameRequest.name(typed: "Weekly sync", summary: named) == nil)
    #expect(MeetingRenameRequest.name(typed: "  ", summary: named) == .generated)
    #expect(MeetingRenameRequest.name(typed: "Parser plan", summary: named) == .user("Parser plan"))
    #expect(MeetingRenameRequest.generated.typedName == nil)
    #expect(MeetingRenameRequest.user("A").typedName == "A")
}

@Test func aNameLeftAsItWasIsNeverRewritten() {
    // Saved before names were cut: longer than 60 characters, with runs of spaces.
    let legacy = String(repeating: "Quarterly roadmap review  ", count: 4)
    let named = listed(name: legacy, source: .user, generated: "Parser plan")
    #expect(MeetingRenameRequest.name(typed: legacy, summary: named) == nil)
    // A long default import name shown as it is does not become the user's either.
    let imported = listed(name: String(repeating: "board call recording ", count: 5), source: .default,
                          generated: nil)
    #expect(MeetingRenameRequest.name(typed: imported.name, summary: imported) == nil)
    // An edit is cleaned as any name is.
    #expect(MeetingRenameRequest.name(typed: legacy + "x", summary: named)
        == MeetingNaming.cleanUserName(legacy + "x").map(MeetingRenameRequest.user))
}

@Test func renameIsOfferedForFinishedMeetingsNotHeldElsewhere() {
    func summary(state: SessionState, status: String, liveness: RecorderLiveness = .exited) -> SessionSummary {
        SessionSummary(id: "S", directory: URL(fileURLWithPath: "/tmp/S.holos"), name: "M", createdAt: Date(),
                       source: .microphone, state: state, manifestStatus: status, liveness: liveness)
    }
    #expect(MeetingActionPolicy.enabled(summary(state: .complete, status: "complete"), inUse: false, hasExport: false)
        .contains(.rename))
    #expect(!MeetingActionPolicy.enabled(summary(state: .complete, status: "complete"), inUse: true, hasExport: false)
        .contains(.rename))
    #expect(!MeetingActionPolicy.enabled(summary(state: .recording, status: "recording", liveness: .capturing),
                                         inUse: false, hasExport: false).contains(.rename))
    // An interrupted recording is recovered first (also one interrupted after capture stopped); a damaged one
    // cannot be.
    #expect(!MeetingActionPolicy.renames(summary(state: .interrupted, status: "recording", liveness: .dead)))
    #expect(!MeetingActionPolicy.renames(summary(state: .interrupted, status: "processing", liveness: .dead)))
    #expect(!MeetingActionPolicy.renames(summary(state: .damaged, status: "")))
    #expect(!MeetingActionPolicy.renames(summary(state: .failed, status: "failed")))
    #expect(MeetingActionPolicy.renames(summary(state: .recovered, status: "recovered")))
    #expect(MeetingActionPolicy.renames(summary(state: .audioOnly, status: "audioOnly")))
}

// MARK: - The command

@Test func aRenameIsTheUsersAndHeadsTheTranscriptFiles() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).hasPrefix("# Parser rewrite and release plan\n"))
    // A field a newer build added to meeting.json is kept.
    var object = try meetingJSON(session)
    object["futureField"] = "kept"
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.meetingInfo(session))

    let outcome = await rename(session, "  Weekly engineering sync ")
    #expect(outcome.status == .renamed)
    #expect(outcome.exitCode == 0)
    #expect(outcome.exportsUpdated)
    #expect(outcome.name == "Weekly engineering sync")
    #expect(outcome.nameSource == .user)
    #expect(outcome.title == "Weekly engineering sync")
    #expect(try SessionArchive.readManifest(at: session).name == "Weekly engineering sync")
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.complete)
    let json = try meetingJSON(session)
    #expect(json["nameSource"] as? String == "user")
    #expect(json["futureField"] as? String == "kept")
    #expect(json["mode"] as? String == "inPerson")
    #expect(SessionFixtures.mode(SessionPaths.meetingInfo(session)) == 0o600)
    let catalog = SessionCatalog.summary(session: session)
    #expect(catalog.nameSource == .user)
    #expect(catalog.displayTitle == "Weekly engineering sync")
    #expect(MeetingNaming.currentTitle(session: session) == "Weekly engineering sync")
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.hasPrefix("# Weekly engineering sync\n"))
    // The summary stays in the files, without the model.
    #expect(markdown.contains("## Summary"))
    #expect(MeetingListFormat.matches(catalog, people: [], query: "engineering"))
    let events = try SessionArchive.readEvents(at: session).events
    #expect(events.last?.kind == MeetingEventKind.renamed)
    #expect(events.last?.details["nameSource"] == "user")

    let again = await rename(session, "Weekly engineering sync")
    #expect(again.status == .unchanged)
    #expect(again.exitCode == 0)
}

@Test func theGeneratedTitleComesBack() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, name: "Weekly sync")
    try writeSummary(session)
    _ = await rename(session, "Weekly sync, renamed")
    let outcome = await rename(session, nil)
    #expect(outcome.status == .renamed)
    #expect(outcome.exitCode == 0)
    #expect(outcome.nameSource == .default)
    #expect(outcome.title == "Parser rewrite and release plan")
    let manifest = try SessionArchive.readManifest(at: session)
    #expect(manifest.name == MeetingStartSettings.defaultName(now: manifest.createdAt, timeZone: utc))
    #expect(try meetingJSON(session)["nameSource"] as? String == "default")
    let catalog = SessionCatalog.summary(session: session)
    #expect(catalog.displayTitle == "Parser rewrite and release plan")
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).hasPrefix("# Parser rewrite and release plan\n"))
    // An empty name asks for the same.
    #expect(await rename(session, "  ").status == .unchanged)
}

@Test func aSpecialOrLongNameIsSavedAsItIsShown() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let special = "Q3 / Café — “Plan” #1 *draft* <b> 🎉"
    let outcome = await rename(session, special)
    #expect(outcome.status == .renamed)
    #expect(try SessionArchive.readManifest(at: session).name == special)
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.hasPrefix("# Q3 / Café — “Plan” #1 "))
    #expect(markdown.contains("🎉"))

    let long = String(repeating: "Quarterly roadmap review ", count: 10)
    let cut = await rename(session, long)
    let name = try #require(cut.name)
    #expect(name.count <= MeetingNaming.maximumUserNameCharacters)
    #expect(name.hasPrefix("Quarterly roadmap review"))
    #expect(try SessionArchive.readManifest(at: session).name == name)
}

@Test func filesWrittenBeforeAnyWereGeneratedAreNotMovedAside() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, legacyExports: true)
    #expect(!SessionFixtures.exists(SessionPaths.generatedExports(session)))
    let outcome = await rename(session, "Design review")
    #expect(outcome.exitCode == 0)
    #expect(try editedExports(session).isEmpty)
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).hasPrefix("# Design review\n"))
}

@Test func aMeetingWithoutTranscriptIsRenamedWithoutFiles() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, transcript: nil)
    let outcome = await rename(session, "Hallway chat")
    #expect(outcome.status == .renamed)
    #expect(!outcome.exportsUpdated)
    #expect(outcome.exitCode == 0)
    // No meeting.json before: one is written with the inferred settings.
    #expect(try meetingJSON(session)["nameSource"] as? String == "user")
    #expect(SessionCatalog.summary(session: session).displayTitle == "Hallway chat")
}

@Test func aRenameIsRefusedWhileTheMeetingIsHeld() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let id = try SessionArchive.readManifest(at: session).id
    func unchanged() throws {
        #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
        #expect(try meetingJSON(session)["nameSource"] as? String == "default")
    }

    // Another command holds it.
    do {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        let outcome = await rename(session, "Weekly sync")
        #expect(outcome.status == .busy)
        #expect(outcome.exitCode == 1)
        #expect(outcome.message.contains("Another Voice is Local command"))
        try unchanged()
    }

    // A summary or final transcript of it is being made.
    let lock = temp.url.appendingPathComponent("jobs.lock")
    do {
        let held = try #require(try DeepTranscriptionLock.take(
            DeepTranscriptionLock.Holder(pid: getpid(), sessionID: id, force: false,
                                         kind: DeepTranscriptionLock.Holder.summaryKind), at: lock))
        defer { held.release() }
        let outcome = await rename(session, "Weekly sync", lock: lock)
        #expect(outcome.status == .busy)
        #expect(outcome.message.contains("summary of this meeting"))
        try unchanged()
    }
    do {
        let held = try #require(try DeepTranscriptionLock.take(
            DeepTranscriptionLock.Holder(pid: getpid(), sessionID: id, force: false), at: lock))
        defer { held.release() }
        #expect(await rename(session, "Weekly sync", lock: lock).message.contains("final transcript of this meeting"))
        try unchanged()
    }
    // A job on another meeting does not hold this one.
    do {
        let held = try #require(try DeepTranscriptionLock.take(
            DeepTranscriptionLock.Holder(pid: getpid(), sessionID: UUID().uuidString, force: false), at: lock))
        defer { held.release() }
        #expect(await rename(session, "Weekly sync", lock: lock).status == .renamed)
    }
}

@Test func aRecordingIsRenamedOnlyOnceSaved() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Meeting 2026-10-03 14:00", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    let recording = await rename(archive.directory, "Weekly sync")
    #expect(recording.status == .busy)
    #expect(recording.message.contains("being recorded"))
    // The recorder died without saving it: Recover first.
    await archive.releaseLock()
    let interrupted = await rename(archive.directory, "Weekly sync")
    #expect(interrupted.status == .failed)
    #expect(interrupted.message.contains("recover"))
    #expect(try SessionArchive.readManifest(at: archive.directory).name == "Meeting 2026-10-03 14:00")
}

@Test func aMeetingJSONThatCannotBeReadIsNotRewritten() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    var object = try meetingJSON(session)
    object["schemaVersion"] = 2
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.meetingInfo(session))
    let outcome = await rename(session, "Weekly sync")
    #expect(outcome.status == .failed)
    #expect(outcome.exitCode == 1)
    #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
}

@Test func theGeneratedTitleGivesBackTheDefaultNameOfAUserNameThatLooksLikeOne() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, name: "Meeting 2026-01-01 09:00")
    var object = try meetingJSON(session)
    object["nameSource"] = "user"
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.meetingInfo(session))
    let outcome = await rename(session, nil)
    #expect(outcome.status == .renamed)
    let manifest = try SessionArchive.readManifest(at: session)
    #expect(manifest.name == MeetingStartSettings.defaultName(now: manifest.createdAt, timeZone: utc))
    #expect(manifest.name != "Meeting 2026-01-01 09:00")
}

@Test func aMeetingInterruptedAfterCaptureStoppedIsRecoveredFirst() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Meeting 2026-10-03 14:00", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    try await archive.setStatus(ArchiveStatus.processing)
    await archive.releaseLock()
    let outcome = await rename(archive.directory, "Weekly sync")
    #expect(outcome.status == .failed)
    #expect(outcome.message.contains("recover"))
    #expect(try SessionArchive.readManifest(at: archive.directory).name == "Meeting 2026-10-03 14:00")
}

@Test func aTranscriptThatCannotBeReadRefusesTheRename() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let id = try #require(try SessionArchive.currentTranscriptID(at: session))
    let revision = SessionPaths.transcript(id, in: session)
    let original = try Data(contentsOf: revision)
    func unchanged() throws {
        #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
        #expect(try meetingJSON(session)["nameSource"] as? String == "default")
    }

    // Written by a newer build: refused until Voice is Local is updated.
    var newer = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
    newer["schemaVersion"] = 99
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: newer), to: revision)
    let fromNewer = await rename(session, "Weekly sync")
    #expect(fromNewer.status == .failed)
    #expect(fromNewer.message.contains("newer version"))
    try unchanged()

    // Damaged: Recover first.
    try AtomicFile.write(Data("{".utf8), to: revision)
    let damaged = await rename(session, "Weekly sync")
    #expect(damaged.status == .failed)
    #expect(damaged.message.contains("recover"))
    try unchanged()

    // Cannot be read now: tried again later.
    try AtomicFile.write(original, to: revision)
    #expect(chmod(revision.path, 0) == 0)
    let locked = await rename(session, "Weekly sync")
    #expect(chmod(revision.path, 0o600) == 0)
    #expect(locked.status == .unreadable)
    #expect(locked.exitCode == 1)
    try unchanged()

    #expect(await rename(session, "Weekly sync").status == .renamed)
}

@Test func filesThatCannotBePreparedLeaveTheNameAlone() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, legacyExports: true)
    struct Unreadable: Error {}
    let outcome = await SessionRenameCommand.run(SessionRenameCommand.Request(
        session: session, name: "Design review", voiceInputs: { throw Unreadable() },
        jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc))
    #expect(outcome.status == .failed)
    #expect(outcome.exitCode == 1)
    #expect(outcome.message.contains("name was not changed"))
    #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
    #expect(try meetingJSON(session)["nameSource"] as? String == "default")
    #expect(!SessionFixtures.exists(SessionPaths.generatedExports(session)))
    #expect(try editedExports(session).isEmpty)
}

@Test func aRenameWhoseFilesWereNotRewrittenIsFinishedByAskingAgain() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    struct Unreadable: Error {}
    let calls = SharedValue(0)
    let request = SessionRenameCommand.Request(
        session: session, name: "Weekly engineering sync",
        voiceInputs: {
            calls.update { $0 += 1 }
            if calls.value == 1 { throw Unreadable() }
            return voice
        },
        jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    let first = await SessionRenameCommand.run(request)
    #expect(first.status == .renamed)
    #expect(first.exitCode == 3)
    #expect(!first.exportsUpdated)
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).hasPrefix("# Parser rewrite and release plan\n"))

    let again = await SessionRenameCommand.run(request)
    #expect(again.status == .unchanged)
    #expect(again.exitCode == 0)
    #expect(again.exportsUpdated)
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.hasPrefix("# Weekly engineering sync\n"))
    #expect(markdown.contains("## Summary"))
}

// MARK: - Editing in the list, and retrying

@Test func anEditIsComparedWithTheTitleShownWhenItBegan() {
    // The editor opened on the generated title; a new summary finished meanwhile and the list read it.
    let atStart = listed(name: "Meeting 2026-10-03 14:00", source: .default, generated: "Parser plan")
    let edit = MeetingRenameEdit(atStart)
    #expect(edit.text == "Parser plan")
    let refreshed = listed(name: "Meeting 2026-10-03 14:00", source: .default, generated: "Release schedule")
    // Left as it was: nothing, though the meeting now shows another title.
    #expect(edit.request(typed: "Parser plan") == nil)
    #expect(MeetingRenameRequest.name(typed: "Parser plan", summary: refreshed) == .user("Parser plan"),
            "What comparing with the refreshed meeting would have saved")
    #expect(edit.request(typed: "Parser plan v2") == .user("Parser plan v2"))
    #expect(edit.sessionID == "S")
}

@Test func updatingTranscriptFilesAsksForTheSameNameAgain() {
    let named = listed(name: String(repeating: "Quarterly roadmap review ", count: 4), source: .user,
                       generated: "Parser plan")
    #expect(MeetingRenameRequest.retry(named) == .user(named.name))
    let generated = listed(name: "Meeting 2026-10-03 14:00", source: .default, generated: "Parser plan")
    #expect(MeetingRenameRequest.retry(generated) == .generated)
}

@Test func theSameLongNameAskedForAgainIsNotCut() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    // A name given before names were cut, longer than 60 characters.
    let long = String(repeating: "Quarterly roadmap review ", count: 4).trimmingCharacters(in: .whitespaces)
    let session = try await renameSession(in: temp.url, name: long)
    var object = try meetingJSON(session)
    object["nameSource"] = "user"
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.meetingInfo(session))
    let outcome = await rename(session, long)
    #expect(outcome.status == .unchanged)
    #expect(outcome.exportsUpdated)
    #expect(try SessionArchive.readManifest(at: session).name == long)
}

// MARK: - Under the lease, records, failed writes

@Test func whatARenameDecidesFromIsReadUnderTheLease() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, name: "Weekly sync")
    try writeSummary(session)
    let lock = temp.url.appendingPathComponent("jobs.lock")
    // The generated title is asked for; while it waits for the lease, another rename gives the meeting a name.
    var request = SessionRenameCommand.Request(session: session, name: nil, voiceInputs: { voice }, jobLock: lock,
                                               timeZone: utc)
    request.beforeLease = {
        let other = await SessionRenameCommand.run(SessionRenameCommand.Request(
            session: session, name: "Roadmap review", voiceInputs: { voice }, jobLock: lock, timeZone: utc))
        #expect(other.status == .renamed)
    }
    let outcome = await SessionRenameCommand.run(request)
    #expect(outcome.status == .renamed, "Not unchanged: the name the other rename gave is replaced")
    #expect(outcome.nameSource == .default)
    #expect(try meetingJSON(session)["nameSource"] as? String == "default")
    #expect(SessionCatalog.summary(session: session).displayTitle == "Parser rewrite and release plan")
}

@Test func filesWithADamagedRecordAreNotMovedAside() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, legacyExports: true)
    try AtomicFile.write(Data("{".utf8), to: SessionPaths.generatedExports(session))
    let outcome = await rename(session, "Design review")
    #expect(outcome.status == .renamed)
    #expect(outcome.exitCode == 0)
    #expect(try editedExports(session).isEmpty)
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).hasPrefix("# Design review\n"))
}

@Test func aNameSourceThatCannotBeWrittenLeavesTheMeetingAsItWas() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    struct WriteFailed: Error {}
    func failing(_ name: String?) async -> SessionRenameCommand.Outcome {
        var request = SessionRenameCommand.Request(session: session, name: name, voiceInputs: { voice },
                                                   jobLock: temp.url.appendingPathComponent("jobs.lock"),
                                                   timeZone: utc)
        request.nameSourceWriter = { _, _, _ in throw WriteFailed() }
        return await SessionRenameCommand.run(request)
    }
    // A name of the user's: the manifest gets its old name back.
    let named = await failing("Weekly sync")
    #expect(named.status == .failed)
    #expect(named.exitCode == 1)
    #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
    #expect(try meetingJSON(session)["nameSource"] as? String == "default")

    // The generated title back, from a name of the user's: the user's name stays, and a retry does it.
    _ = await rename(session, "Weekly sync")
    let generated = await failing(nil)
    #expect(generated.status == .failed)
    #expect(try SessionArchive.readManifest(at: session).name == "Weekly sync")
    #expect(try meetingJSON(session)["nameSource"] as? String == "user")
    let retried = await rename(session, nil)
    #expect(retried.status == .renamed)
    #expect(try meetingJSON(session)["nameSource"] as? String == "default")
    #expect(try SessionArchive.readManifest(at: session).name != "Weekly sync")
}

@Test func theListNoticesTitlesChangedElsewhere() {
    let before = ["S": "Parser plan", "T": "Weekly sync"]
    let renamed = listed(name: "Roadmap review", source: .user, generated: "Parser plan")
    var other = listed(name: "Weekly sync", source: .user, generated: nil)
    other.id = "T"
    var new = listed(name: "Budget", source: .user, generated: nil)
    new.id = "U"
    #expect(MeetingListFormat.titlesChanged(from: before, to: [renamed, other, new]) == ["S"])
    #expect(MeetingListFormat.titlesChanged(from: [:], to: [renamed]).isEmpty)
}

// MARK: - Offering Rename, and running it from the app

@Test func renameIsNotOfferedForATranscriptThatCannotBeRead() {
    var summary = listed(name: "Weekly sync", source: .user, generated: nil)
    #expect(MeetingActionPolicy.renames(summary))
    #expect(MeetingActionPolicy.renameRefusal(summary) == nil)
    summary.transcriptProblem = "transcripts/T.json is damaged or was not written by Voice is Local."
    #expect(!MeetingActionPolicy.renames(summary))
    #expect(!MeetingActionPolicy.enabled(summary, inUse: false, hasExport: true).contains(.rename))
    #expect(MeetingActionPolicy.renameRefusal(summary)?.contains("transcript cannot be read") == true)
    summary.transcriptRefused = true
    summary.transcriptProblem = "transcripts/T.json was written by a newer version of Voice is Local."
    #expect(MeetingActionPolicy.renameRefusal(summary)?.contains("newer version") == true)
    var interrupted = listed(name: "Weekly sync", source: .user, generated: nil)
    interrupted.state = .interrupted
    #expect(MeetingActionPolicy.renameRefusal(interrupted)?.contains("Recover") == true)
}

@Test func theAppRunsTheRenameAsTheCommand() {
    let session = URL(fileURLWithPath: "/tmp/S.holos")
    #expect(MeetingRenameRun.arguments(session: session, request: .user("-v Weekly sync"))
        == ["session", "rename", "--json", "--", "/tmp/S.holos", "-v Weekly sync"])
    #expect(MeetingRenameRun.arguments(session: session, request: .generated)
        == ["session", "rename", "--generated", "--json", "--", "/tmp/S.holos"])
}

@Test func theCommandsResultIsReadBack() throws {
    var written = SessionRenameCommand.Outcome(sessionID: "S", status: .renamed, message: "m", exitCode: 3)
    written.name = "Weekly sync"
    written.nameSource = .user
    let decoded = try HolosJSON.decoder().decode(SessionRenameCommand.Outcome.self,
                                                 from: HolosJSON.encoder().encode(written))
    #expect(decoded == written)
}

// MARK: - One title for the list and the files

@Test func theTitleShownAndTheHeadingFollowOneRule() {
    let current = MeetingSummaryRecord(sessionID: "S", transcriptID: "T2", title: "Parser plan", summary: "s",
                                       model: "fake")
    // The user's name, else the title of a summary of the current transcript, else the name.
    #expect(MeetingNaming.title(name: "Weekly sync", source: .user, summary: current, transcriptID: "T2")
        == "Weekly sync")
    #expect(MeetingNaming.title(name: "Meeting 2026-10-03 14:00", source: .default, summary: current,
                                transcriptID: "T2") == "Parser plan")
    #expect(MeetingNaming.title(name: "Meeting 2026-10-03 14:00", source: .default, summary: current,
                                transcriptID: "T3") == "Meeting 2026-10-03 14:00", "Of an earlier transcript")
    #expect(MeetingNaming.title(name: "Meeting 2026-10-03 14:00", source: .default, summary: nil,
                                transcriptID: "T2") == "Meeting 2026-10-03 14:00")
    var stale = listed(name: "Meeting 2026-10-03 14:00", source: .default, generated: "Parser plan")
    stale.transcriptID = "T-newer"
    #expect(stale.displayTitle == "Meeting 2026-10-03 14:00")
}

@Test func aSummaryOfAnEarlierTranscriptHeadsNeitherTheListNorTheFiles() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, name: "Weekly sync")
    try writeSummary(session)
    _ = await rename(session, "Weekly sync")
    // A final transcript replaces the one the summary was made from.
    let newer = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic", wordsPerTurn: 8))
    try await SessionFixtures.saveTranscript(newer, in: session)
    let outcome = await rename(session, nil)
    #expect(outcome.status == .renamed)
    let manifest = try SessionArchive.readManifest(at: session)
    #expect(outcome.title == manifest.name, "No summary of this transcript yet: the default name")
    #expect(SessionCatalog.summary(session: session).displayTitle == manifest.name)
    #expect(MeetingNaming.currentTitle(session: session) == manifest.name)
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).hasPrefix("# \(manifest.name)\n"))
}

@Test func theTitleOfASummaryMadeWithOtherNamesStillHeadsTheFiles() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    // Speaker names changed since: the summary is left out of the files, but it is of this transcript.
    var record = try #require(try MeetingSummaryStore.read(session: session,
                                                         sessionID: SessionArchive.readManifest(at: session).id))
    record.namesDigest = "other names"
    try MeetingSummaryStore.write(record, session: session)
    let outcome = await rename(session, "Weekly sync")
    #expect(outcome.status == .renamed)
    let back = await rename(session, nil)
    #expect(back.title == "Parser rewrite and release plan")
    #expect(SessionCatalog.summary(session: session).displayTitle == "Parser rewrite and release plan")
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.hasPrefix("# Parser rewrite and release plan\n"))
    #expect(!markdown.contains("## Summary"))
}

@Test func aGeneratedJSONFileAloneIsPreparedToo() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    // Only transcript.json is left, with no record of what was generated.
    for file in [SessionPaths.export("md", in: session), SessionPaths.export("txt", in: session),
                 SessionPaths.generatedExports(session)] {
        try FileManager.default.removeItem(at: file)
    }
    let outcome = await rename(session, "Design review")
    #expect(outcome.exitCode == 0)
    #expect(try editedExports(session).isEmpty)
    #expect(SessionFixtures.text(SessionPaths.export("json", in: session)).contains("Design review"))
}

// MARK: - Offered only as the command would act

@Test func theGeneratedTitleOfferedIsTheOneTheMeetingCanShow() {
    let named = listed(name: "Weekly sync", source: .user, generated: "Parser plan")
    #expect(named.currentGeneratedTitle == "Parser plan")
    var stale = named
    stale.transcriptID = "T-newer"
    #expect(stale.currentGeneratedTitle == nil, "Of an earlier transcript: not offered")
    #expect(listed(name: "Weekly sync", source: .user, generated: nil).currentGeneratedTitle == nil)
}

@Test func aMeetingJSONThatCannotBeReadTurnsRenameOff() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    #expect(SessionCatalog.summary(session: session).metadataProblem == nil)
    #expect(MeetingActionPolicy.renames(SessionCatalog.summary(session: session)))
    try AtomicFile.write(Data("{".utf8), to: SessionPaths.meetingInfo(session))
    let damaged = SessionCatalog.summary(session: session)
    #expect(damaged.metadataProblem != nil)
    #expect(!MeetingActionPolicy.renames(damaged))
    #expect(MeetingActionPolicy.renameRefusal(damaged)?.contains("meeting.json") == true)
    #expect(await rename(session, "Weekly sync").status == .failed, "As the command refuses it")
}

@Test func reviewReadsTheTranscriptAsTheListDoes() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    #expect(MeetingNaming.currentTitle(session: session) == "Parser rewrite and release plan")
    // The revision the summary was made from is damaged: no transcript can be read, so no generated title.
    let id = try #require(try SessionArchive.currentTranscriptID(at: session))
    try AtomicFile.write(Data("{".utf8), to: SessionPaths.transcript(id, in: session))
    let listedTitle = SessionCatalog.summary(session: session).displayTitle
    #expect(listedTitle == "Meeting 2026-10-03 14:00")
    #expect(MeetingNaming.currentTitle(session: session) == listedTitle)
}

@Test func theSameNameKeepsItsSourceAsItIs() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, name: "Weekly sync")
    // A source a newer build wrote: the user's to this build, never rewritten.
    var object = try meetingJSON(session)
    object["nameSource"] = "teamDirectory"
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.meetingInfo(session))
    for typed in ["Weekly sync", "  Weekly   sync "] {
        let outcome = await rename(session, typed)
        #expect(outcome.status == .unchanged, "\(typed)")
        #expect(try meetingJSON(session)["nameSource"] as? String == "teamDirectory")
    }
    // A meeting saved before nameSource existed keeps none.
    object["nameSource"] = nil
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.meetingInfo(session))
    #expect(await rename(session, "Weekly sync").status == .unchanged)
    #expect(try meetingJSON(session)["nameSource"] == nil)
}

// MARK: - Export records and orphaned files

@Test func aRecordWithMalformedValuesCountsAsDamaged() async throws {
    for record in [#"{"schemaVersion":1,"files":{"transcript.md":"x"}}"#,
                   #"{"schemaVersion":1,"files":{"notes.md":"\#(String(repeating: "a", count: 64))"}}"#,
                   #"{"schemaVersion":1,"files":{},"pending":{"transcript.md":"\#(String(repeating: "A", count: 64))"}}"#] {
        let temp = try TemporaryDirectory("rename")
        defer { temp.remove() }
        let session = try await renameSession(in: temp.url, legacyExports: true)
        try AtomicFile.write(Data(record.utf8), to: SessionPaths.generatedExports(session))
        #expect(try !SessionExports.hasUsableRecord(session: session), "\(record)")
        let outcome = await rename(session, "Design review")
        #expect(outcome.exitCode == 0)
        #expect(try editedExports(session).isEmpty, "\(record)")
    }
}

@Test func anExportRecordFromANewerBuildTurnsRenameOff() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    #expect(SessionCatalog.summary(session: session).exportsProblem == nil)
    try AtomicFile.write(Data(#"{"schemaVersion":2,"files":{}}"#.utf8), to: SessionPaths.generatedExports(session))
    let listed = SessionCatalog.summary(session: session)
    #expect(listed.exportsProblem != nil)
    #expect(!MeetingActionPolicy.renames(listed))
    #expect(MeetingActionPolicy.renameRefusal(listed)?.contains("newer version") == true)
    let outcome = await rename(session, "Weekly sync")
    #expect(outcome.status == .failed)
    #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
}

@Test func transcriptFilesWithoutATranscriptRefuseTheRename() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    // The transcript is gone (pointer and revisions); its files are not.
    let transcripts = session.appendingPathComponent("transcripts", isDirectory: true)
    for file in try FileManager.default.contentsOfDirectory(atPath: transcripts.path) {
        try FileManager.default.removeItem(at: transcripts.appendingPathComponent(file))
    }
    let listed = SessionCatalog.summary(session: session)
    #expect(listed.transcriptID == nil)
    #expect(MeetingActionPolicy.renameRefusal(listed, hasExport: true)?.contains("transcript is missing") == true)
    #expect(!MeetingActionPolicy.enabled(listed, inUse: false, hasExport: true).contains(.rename))
    #expect(MeetingActionPolicy.renameRefusal(listed, hasExport: false) == nil)
    let outcome = await rename(session, "Weekly sync")
    #expect(outcome.status == .failed)
    #expect(outcome.message.contains("transcript is missing"))
    #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
}

// MARK: - Complete records, the locked folder, partial writes

@Test func anIncompleteRecordCountsAsDamaged() async throws {
    let digest = String(repeating: "a", count: 64)
    for record in [#"{"schemaVersion":1,"files":{}}"#,
                   #"{"schemaVersion":1,"files":{"transcript.md":"\#(digest)","transcript.txt":"\#(digest)"}}"#] {
        let temp = try TemporaryDirectory("rename")
        defer { temp.remove() }
        let session = try await renameSession(in: temp.url, legacyExports: true)
        try AtomicFile.write(Data(record.utf8), to: SessionPaths.generatedExports(session))
        #expect(try !SessionExports.hasUsableRecord(session: session), "\(record)")
    }
    // Complete in files, or in pending (a regeneration interrupted): usable.
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let all = #""transcript.md":"\#(digest)","transcript.json":"\#(digest)","transcript.txt":"\#(digest)""#
    for record in [#"{"schemaVersion":1,"files":{\#(all)}}"#,
                   #"{"schemaVersion":1,"files":{},"pending":{\#(all)}}"#] {
        try AtomicFile.write(Data(record.utf8), to: SessionPaths.generatedExports(session))
        #expect(try SessionExports.hasUsableRecord(session: session), "\(record)")
    }
}

@Test func aFolderReplacedOnceTheLeaseIsTakenIsLeftAlone() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, name: "Weekly sync")
    _ = await rename(session, "Weekly sync")
    let moved = temp.url.appendingPathComponent("moved", isDirectory: true)
    var request = SessionRenameCommand.Request(session: session, name: "Weekly sync", voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"),
                                               timeZone: utc)
    // A sync tool puts a copy in the folder's place after the lease was taken on the original.
    request.afterLease = {
        try? FileManager.default.moveItem(at: session, to: moved)
        try? FileManager.default.copyItem(at: moved, to: session)
    }
    let outcome = await SessionRenameCommand.run(request)
    #expect(outcome.status == .busy)
    #expect(outcome.exitCode == 1)
    #expect(outcome.message.contains("moved or replaced"))
}

@Test func theListChecksEveryTranscriptFile() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    #expect(SessionExports.hasTranscriptFiles(session: session))
    for format in ["md", "txt"] { try FileManager.default.removeItem(at: SessionPaths.export(format, in: session)) }
    #expect(SessionExports.hasTranscriptFiles(session: session), "transcript.json alone")
    var listed = SessionCatalog.summary(session: session)
    listed.transcriptID = nil
    #expect(!MeetingActionPolicy.enabled(listed, inUse: false, hasExport: false, transcriptFiles: true)
        .contains(.rename))
    #expect(MeetingActionPolicy.enabled(listed, inUse: false, hasExport: false, transcriptFiles: false)
        .contains(.rename))
}

@Test func aNameThatCannotBePutBackKeepsTheFilesMarked() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    struct WriteFailed: Error {}
    var request = SessionRenameCommand.Request(session: session, name: "Weekly sync", voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"),
                                               timeZone: utc)
    // The source cannot be written, and then neither can the manifest (the folder turned read-only).
    request.nameSourceWriter = { _, folder, _ in
        _ = chmod(folder.path, 0o500)
        throw WriteFailed()
    }
    let outcome = await SessionRenameCommand.run(request)
    #expect(chmod(session.path, 0o700) == 0)
    #expect(outcome.exitCode == 3, "Partly written: the files may show the old title")
    #expect(outcome.message.contains("without being marked as yours"))
    // The user's name was written first: stopped there, the source is still default, so the meeting shows its
    // generated title, as it did before.
    #expect(try meetingJSON(session)["nameSource"] as? String == "default")
    #expect(SessionCatalog.summary(session: session, jobState: .free).displayTitle == "Parser rewrite and release plan")
}

// MARK: - Jobs elsewhere, each write on the locked folder, people read at the write

@Test func aSummaryOrFinalTranscriptRunningElsewhereTurnsRenameOff() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let id = try SessionArchive.readManifest(at: session).id
    #expect(SessionCatalog.summary(session: session, jobState: .free).jobInProgress == nil)
    let summary = SessionCatalog.summary(
        session: session, jobState: .held(DeepTranscriptionLock.Holder(pid: 1, sessionID: id, force: false,
                                                                       kind: DeepTranscriptionLock.Holder.summaryKind)))
    #expect(summary.jobInProgress?.contains("summary") == true)
    #expect(!MeetingActionPolicy.renames(summary))
    #expect(MeetingActionPolicy.renameRefusal(summary)?.contains("summary") == true)
    let deep = SessionCatalog.summary(
        session: session, jobState: .held(DeepTranscriptionLock.Holder(pid: 1, sessionID: id, force: false)))
    #expect(deep.jobInProgress?.contains("final transcript") == true)
    // Another meeting's job leaves this one alone.
    let other = SessionCatalog.summary(
        session: session, jobState: .held(DeepTranscriptionLock.Holder(pid: 1, sessionID: "OTHER", force: false)))
    #expect(other.jobInProgress == nil)
    #expect(MeetingActionPolicy.renames(other))
}

@Test func eachWriteChecksTheLockedFolder() async throws {
    for (step, expectedCode) in [("prepare", Int32(1)), ("regenerate", Int32(3)), ("unchanged", Int32(1))] {
        let temp = try TemporaryDirectory("rename")
        defer { temp.remove() }
        let session = try await renameSession(in: temp.url, name: "Weekly sync", legacyExports: step == "prepare")
        if step == "unchanged" { _ = await rename(session, "Weekly sync") }
        let moved = temp.url.appendingPathComponent("moved", isDirectory: true)
        var request = SessionRenameCommand.Request(
            session: session, name: step == "unchanged" ? "Weekly sync" : "Design review", voiceInputs: { voice },
            jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
        request.beforeStep = { reached in
            guard reached == (step == "unchanged" ? "regenerate" : step) else { return }
            try? FileManager.default.moveItem(at: session, to: moved)
            try? FileManager.default.copyItem(at: moved, to: session)
        }
        let outcome = await SessionRenameCommand.run(request)
        #expect(outcome.exitCode == expectedCode, "\(step)")
        #expect(outcome.message.contains("moved or replaced"), "\(step)")
        #expect(!outcome.exportsUpdated, "\(step)")
    }
}

@Test func peopleAreReadWhenTheFilesAreWritten() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let order = SharedValue<[String]>([])
    var request = SessionRenameCommand.Request(
        session: session, name: "Design review",
        voiceInputs: {
            order.update { $0.append("read") }
            return voice
        },
        jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    request.beforeStep = { step in order.update { $0.append(step) } }
    let outcome = await SessionRenameCommand.run(request)
    #expect(outcome.exitCode == 0)
    // Read under the locks at the write, after everything before it, not once up front.
    #expect(order.value.last == "read")
    #expect(order.value.suffix(2) == ["regenerate", "read"])

    // The people store itself, read under its lock (speakers, then profiles) at the write.
    let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("Speakers", isDirectory: true))
    try store.update { $0.profiles.append(SpeakerProfile(displayName: "Robin", isSelf: true)) }
    var stored = SessionRenameCommand.Request(session: session, name: "Roadmap review",
                                              jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    stored.profileStore = store
    #expect(await SessionRenameCommand.run(stored).exitCode == 0)
}

// MARK: - Finishing a partial rename, and noticing files rewritten elsewhere


// MARK: - Transcript files out of date, derived from the files

@Test func theFilesAreCurrentOnlyWhenTheyShowTheTitleAndMatchTheirRecord() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    #expect(SessionExports.filesState(
        session: try await SessionFixtures.makeSession(in: temp.url, transcript: nil), title: "x") == .none)
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    func state() -> SessionExports.FilesState {
        let summary = SessionCatalog.summary(session: session, jobState: .free)
        return SessionExports.filesState(session: session, title: summary.displayTitle, name: summary.name)
    }
    func rewrite() throws {
        try SessionArchive.withSpeakerLock(at: session) {
            _ = try SessionExports.regenerateLocked(session: session, profileNames: voice.names,
                                                    applyRecognition: voice.recognition, selfName: voice.selfName)
        }
    }
    #expect(state() == .current)
    // A rename whose files were not rewritten: the heading is the old title.
    struct Unreadable: Error {}
    let failed = await SessionRenameCommand.run(SessionRenameCommand.Request(
        session: session, name: "Weekly *sync* #2", voiceInputs: { throw Unreadable() },
        jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc))
    #expect(failed.exitCode == 3)
    #expect(state() == .stale)
    // Whoever rewrites them (Review, a summary, a command in Terminal), they are current.
    try rewrite()
    #expect(state() == .current)
    // transcript.json no longer what was recorded (a write cut short, an edit).
    try AtomicFile.write(Data("{}".utf8), to: SessionPaths.export("json", in: session))
    #expect(state() == .stale)
    try rewrite()
    #expect(state() == .current)
    // A damaged record, or one left mid-write (pending), is not trusted.
    let record = try Data(contentsOf: SessionPaths.generatedExports(session))
    try AtomicFile.write(Data("{".utf8), to: SessionPaths.generatedExports(session))
    #expect(state() == .stale)
    var object = try #require(try JSONSerialization.jsonObject(with: record) as? [String: Any])
    object["pending"] = object["files"]
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.generatedExports(session))
    #expect(state() == .stale)
}

@Test func updateTranscriptFilesRewritesThemForTheTitleShown() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    struct Unreadable: Error {}
    _ = await SessionRenameCommand.run(SessionRenameCommand.Request(
        session: session, name: "Weekly sync", voiceInputs: { throw Unreadable() },
        jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc))
    let summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle) == .stale)
    // What the menu runs: the rename the meeting has now, which writes no name and rewrites the files.
    let update = await rename(session, MeetingRenameRequest.retry(summary).typedName)
    #expect(update.status == .unchanged)
    #expect(update.exportsUpdated)
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle) == .current)
}

@Test func filesStateIsCachedUntilAFileOrTheTitleChanges() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    let cache = TranscriptFilesCache()
    var summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(cache.state(of: summary) == .current)
    summary.name = "Weekly sync"
    summary.nameSource = .user
    #expect(cache.state(of: summary) == .stale, "Another title is looked at again")
    try AtomicFile.write(Data("{}".utf8), to: SessionPaths.export("json", in: session))
    #expect(cache.state(of: SessionCatalog.summary(session: session, jobState: .free)) == .stale,
            "A changed file is looked at again")
}

@Test func filesBehindTheSpeakerLabelsAreKnown() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let (session, _, run) = try await SessionFixtures.labelledSession(in: temp.url, track: "mic")
    try SessionExports.regenerate(session: session)
    #expect(SessionExports.filesMatchLabels(session: session, profileNames: [:], applyRecognition: true,
                                            selfName: "Robin"))
    let first = try #require(run.speakers.first)
    try SessionFixtures.appendEdits([.rename(speakerID: first.id, name: "Alex")], session: session)
    #expect(!SessionExports.filesMatchLabels(session: session, profileNames: [:], applyRecognition: true,
                                             selfName: "Robin"))
}

@Test func eachTranscriptFileWriteChecksTheFolder() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let calls = SharedValue(0)
    try SessionArchive.withSpeakerLock(at: session) {
        _ = try SessionExports.regenerateLocked(session: session, selfName: "Robin", check: {
            calls.update { $0 += 1 }
        })
    }
    // Before the pending record, each of the three files, and the final record.
    #expect(calls.value == 5)
    struct Moved: Error {}
    let stopped = SharedValue(0)
    #expect(throws: Moved.self) {
        try SessionArchive.withSpeakerLock(at: session) {
            _ = try SessionExports.regenerateLocked(session: session, selfName: "Robin", check: {
                stopped.update { $0 += 1 }
                if stopped.value == 3 { throw Moved() }
            })
        }
    }
    #expect(stopped.value == 3, "Nothing written after a failed check")
}

@Test func aNameSavedButNotConfirmedIsAPartialRename() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    var request = SessionRenameCommand.Request(session: session, name: "Weekly sync", voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    // The manifest was renamed into place, then its folder could not be synced.
    request.failAfterNameWrite = true
    let outcome = await SessionRenameCommand.run(request)
    #expect(outcome.exitCode == 3)
    #expect(outcome.message.contains("saved"))
    #expect(try SessionArchive.readManifest(at: session).name == "Weekly sync")
    #expect(try meetingJSON(session)["nameSource"] as? String == "user", "The rest is still written")
}

// MARK: - Partial writes show what was asked

@Test func aLeftoverNameIsNotShownForTheGeneratedTitle() {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    // The source says Voice is Local made the name up, but the manifest still has the user's: the made-up one shows.
    #expect(MeetingNaming.fallbackName(name: "Weekly sync", source: .default, createdAt: start, origin: .recorded,
                                       importedFileName: nil, timeZone: utc) == "Meeting 2026-09-21 14:13")
    #expect(MeetingNaming.fallbackName(name: "Meeting 2026-09-21 09:00", source: .default, createdAt: start,
                                       origin: .recorded, importedFileName: nil, timeZone: utc)
        == "Meeting 2026-09-21 09:00")
    #expect(MeetingNaming.fallbackName(name: "board call", source: .default, createdAt: start, origin: .imported,
                                       importedFileName: "board call.m4a", timeZone: utc) == "board call")
    #expect(MeetingNaming.fallbackName(name: "Weekly sync", source: .user, createdAt: start, origin: .recorded,
                                       importedFileName: nil, timeZone: utc) == "Weekly sync")
    #expect(MeetingNaming.title(name: "Weekly sync", source: .default, summary: nil, transcriptID: "T",
                                fallback: "Meeting 2026-09-21 14:13") == "Meeting 2026-09-21 14:13")
    var summary = listed(name: "Weekly sync", source: .default, generated: nil)
    summary.shownName = "Meeting 2026-09-21 14:13"
    #expect(summary.displayTitle == "Meeting 2026-09-21 14:13")
}

@Test func aPartialGeneratedRenameAlreadyShowsTheGeneratedTitle() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    _ = await rename(session, "Weekly sync")
    // --generated writes nameSource first; then the folder turns read-only, so the made-up name is not written, and
    // the source cannot be put back.
    var request = SessionRenameCommand.Request(session: session, name: nil, voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    request.nameSourceWriter = { source, folder, meeting in
        try SessionRenameCommand.writeNameSource(source, session: folder, meeting: meeting)
        _ = chmod(folder.path, 0o500)
    }
    let partial = await SessionRenameCommand.run(request)
    #expect(chmod(session.path, 0o700) == 0)
    #expect(partial.exitCode == 3)
    #expect(try meetingJSON(session)["nameSource"] as? String == "default")
    #expect(try SessionArchive.readManifest(at: session).name == "Weekly sync", "Left over")
    // Already shows what was asked, and the files (headed "Weekly sync") read as out of date.
    let summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(summary.displayTitle == "Parser rewrite and release plan")
    #expect(MeetingNaming.currentTitle(session: session) == "Parser rewrite and release plan")
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle) == .stale)
    // Update Transcript Files finishes it as --generated: the made-up name, and the files.
    #expect(MeetingRenameRequest.retry(summary) == .generated)
    let update = await rename(session, nil)
    #expect(update.status == .renamed)
    #expect(update.exitCode == 0)
    let manifest = try SessionArchive.readManifest(at: session)
    #expect(manifest.name == MeetingStartSettings.defaultName(now: manifest.createdAt, timeZone: utc))
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle) == .current)
}

@Test func aPublishedNameSourceIsAPartialRenameNotARollback() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    struct SyncFailed: Error {}
    var request = SessionRenameCommand.Request(session: session, name: "Weekly sync", voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    // meeting.json is in place, then its folder cannot be synced.
    request.nameSourceWriter = { source, folder, meeting in
        try SessionRenameCommand.writeNameSource(source, session: folder, meeting: meeting)
        throw SyncFailed()
    }
    let outcome = await SessionRenameCommand.run(request)
    #expect(outcome.exitCode == 3)
    #expect(outcome.message.contains("saved"))
    #expect(try SessionArchive.readManifest(at: session).name == "Weekly sync", "Not rolled back")
    #expect(try meetingJSON(session)["nameSource"] as? String == "user")
    #expect(SessionCatalog.summary(session: session, jobState: .free).displayTitle == "Weekly sync")
}

@Test func aPendingMapMustBeCompleteWhateverFilesHolds() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let digest = String(repeating: "a", count: 64)
    let all = #""transcript.md":"\#(digest)","transcript.json":"\#(digest)","transcript.txt":"\#(digest)""#
    let record = #"{"schemaVersion":1,"files":{\#(all)},"pending":{"transcript.md":"\#(digest)"}}"#
    try AtomicFile.write(Data(record.utf8), to: SessionPaths.generatedExports(session))
    #expect(try !SessionExports.hasUsableRecord(session: session))
}

// MARK: - Missing files, checks within the pending step, a job not yet named

@Test func aTranscriptWithoutFilesNeedsThemWritten() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    for format in ["md", "json", "txt"] { try FileManager.default.removeItem(at: SessionPaths.export(format, in: session)) }
    try FileManager.default.removeItem(at: SessionPaths.generatedExports(session))
    let summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle) == .stale)
    #expect(TranscriptFilesCache().state(of: summary) == .stale)
    // Update Transcript Files writes them.
    let update = await rename(session, MeetingRenameRequest.retry(summary).typedName)
    #expect(update.exportsUpdated)
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle) == .current)
}

@Test func movingAnEditedFileAsideChecksTheFolderFirst() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try SessionArchive.withSpeakerLock(at: session) { _ = try SessionExports.regenerateLocked(session: session) }
    try AtomicFile.write(Data("edited by hand".utf8), to: SessionPaths.export("txt", in: session))
    let calls = SharedValue(0)
    struct Moved: Error {}
    // The folder moved before the edited file was moved aside: nothing is written.
    #expect(throws: Moved.self) {
        try SessionArchive.withSpeakerLock(at: session) {
            _ = try SessionExports.regenerateLocked(session: session, selfName: "Robin", check: {
                calls.update { $0 += 1 }
                throw Moved()
            })
        }
    }
    #expect(calls.value == 1)
    #expect(try editedExports(session).isEmpty)
    // Otherwise one check more: before the move, the pending record, each file and the final record.
    calls.set(0)
    try SessionArchive.withSpeakerLock(at: session) {
        _ = try SessionExports.regenerateLocked(session: session, selfName: "Robin", check: { calls.update { $0 += 1 } })
    }
    #expect(calls.value == 6)
    #expect(try editedExports(session).count == 1)
}

@Test func aJobNotYetNamedHoldsEveryMeeting() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let summary = SessionCatalog.summary(session: session, jobState: .held(nil))
    #expect(summary.jobInProgress?.contains("background job") == true)
    #expect(!MeetingActionPolicy.renames(summary))
}

// MARK: - The double failure, unreadable records, the name in the files, the preparation reported

@Test func anExportRecordThatCannotBeReadTurnsRenameOff() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    #expect(chmod(SessionPaths.generatedExports(session).path, 0) == 0)
    let listed = SessionCatalog.summary(session: session, jobState: .free)
    let outcome = await rename(session, "Weekly sync")
    #expect(chmod(SessionPaths.generatedExports(session).path, 0o600) == 0)
    #expect(listed.exportsProblem?.contains("cannot be read") == true)
    #expect(!MeetingActionPolicy.renames(listed))
    #expect(MeetingActionPolicy.renameRefusal(listed)?.contains("cannot be read") == true)
    #expect(outcome.status == .unreadable, "As the command refuses it")
}

@Test func theNameInTheFilesIsCheckedToo() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    // The user's name is the generated title, word for word; then the generated title is asked for, and the files
    // cannot be rewritten: the heading is the same, but transcript.json still holds the user's name.
    _ = await rename(session, "Parser rewrite and release plan")
    struct Unreadable: Error {}
    let back = await SessionRenameCommand.run(SessionRenameCommand.Request(
        session: session, name: nil, voiceInputs: { throw Unreadable() },
        jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc))
    #expect(back.exitCode == 3)
    let summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(summary.displayTitle == "Parser rewrite and release plan")
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle, name: summary.name) == .stale)
    #expect(TranscriptFilesCache().state(of: summary) == .stale)
}

@Test func filesRewrittenBeforeAFailedRenameAreReported() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, legacyExports: true)
    struct WriteFailed: Error {}
    var request = SessionRenameCommand.Request(session: session, name: "Design review", voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    request.nameSourceWriter = { _, _, _ in throw WriteFailed() }
    let outcome = await SessionRenameCommand.run(request)
    #expect(outcome.exitCode == 3)
    #expect(outcome.message.contains("rewritten under the old name"))
    #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00", "The name was put back")
}

@Test func filesOfAnEarlierTranscriptAreOutOfDate() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, name: "Weekly sync")
    _ = await rename(session, "Weekly sync")
    var summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle, name: summary.name) == .current)
    // A final transcript (or a recovery) saved a new transcript, then stopped before rewriting the files: the name
    // and heading are the same, but transcript.json is of the earlier revision.
    let newer = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic", wordsPerTurn: 8))
    try await SessionFixtures.saveTranscript(newer, in: session)
    summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle, name: summary.name) == .stale)
    #expect(TranscriptFilesCache().state(of: summary) == .stale)
    _ = await rename(session, "Weekly sync")
    #expect(SessionExports.filesState(session: session, title: summary.displayTitle, name: summary.name) == .current)
}

// MARK: - Renamed or not, newer summaries, pending marks, the shown name

@Test func theAlertSaysWhetherTheMeetingWasRenamed() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    // Prepared under the old name, then the rename failed and was undone: exit 3, not renamed.
    let session = try await renameSession(in: temp.url, legacyExports: true)
    struct WriteFailed: Error {}
    var request = SessionRenameCommand.Request(session: session, name: "Design review", voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    request.nameSourceWriter = { _, _, _ in throw WriteFailed() }
    let notRenamed = await SessionRenameCommand.run(request)
    #expect(notRenamed.exitCode == 3)
    #expect(!notRenamed.renamed)
    #expect(MeetingRenameRun.alert(for: notRenamed, shown: "M", failure: nil)?.title == "Voice is Local could not rename “M”.")
    // Renamed, the files not rewritten: exit 3, renamed.
    struct Unreadable: Error {}
    let renamed = await SessionRenameCommand.run(SessionRenameCommand.Request(
        session: session, name: "Design review", voiceInputs: { throw Unreadable() },
        jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc))
    #expect(renamed.exitCode == 3)
    #expect(renamed.renamed)
    #expect(MeetingRenameRun.alert(for: renamed, shown: "M", failure: nil)?.text.contains("Update Transcript Files")
        == true)
    #expect(MeetingRenameRun.alert(for: SessionRenameCommand.Outcome(sessionID: "S", status: .renamed, message: "m",
                                                                     exitCode: 0), shown: "M", failure: nil) == nil)
    #expect(MeetingRenameRun.alert(for: nil, shown: "M", failure: "stopped")?.text == "stopped")
}

@Test func aSummaryFromANewerBuildRefusesTheRename() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    var object = try #require(try JSONSerialization.jsonObject(
        with: Data(contentsOf: SessionPaths.summary(session))) as? [String: Any])
    object["schemaVersion"] = 2
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.summary(session))
    let before = SessionFixtures.text(SessionPaths.export("md", in: session))
    let outcome = await rename(session, "Weekly sync")
    #expect(outcome.status == .failed)
    #expect(outcome.message.contains("newer version"))
    #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)) == before, "The files keep their summary")
}

@Test func aPendingMarkSetAgainDuringACheckIsKept() throws {
    let suite = "holos-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let pending = PendingExports(defaults: defaults)
    pending.mark("A")
    let seen = pending.generation("A")
    // A review closed meanwhile and could not rewrite the files again.
    pending.mark("A")
    pending.clear("A", ifGeneration: seen)
    #expect(pending.contains("A"), "Set again after the check began")
    pending.clear("A", ifGeneration: pending.generation("A"))
    #expect(!pending.contains("A"))
}

// MARK: - A preparation stopped partway, monotonic marks, unreadable summaries

@Test func aPreparationStoppedAfterItsFirstWriteIsReported() async throws {
    for (failingCheck, expectedCode) in [(1, Int32(1)), (2, Int32(3))] {
        let temp = try TemporaryDirectory("rename")
        defer { temp.remove() }
        let session = try await renameSession(in: temp.url, legacyExports: true)
        struct Full: Error {}
        var request = SessionRenameCommand.Request(session: session, name: "Design review", voiceInputs: { voice },
                                                   jobLock: temp.url.appendingPathComponent("jobs.lock"),
                                                   timeZone: utc)
        // The preparation's writes: a check before each; the n-th fails (the disk filled up, the folder moved).
        request.exportCheck = { call in if call == failingCheck { throw Full() } }
        let outcome = await SessionRenameCommand.run(request)
        #expect(outcome.exitCode == expectedCode, "check \(failingCheck)")
        #expect(outcome.message.contains("partly rewritten") == (expectedCode == 3), "check \(failingCheck)")
        #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
    }
}

@Test func aClearedMarkIsNeverMarkedWithAnOldGeneration() throws {
    let suite = "holos-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let pending = PendingExports(defaults: defaults)
    pending.mark("A")
    let seen = pending.generation("A")
    // Another writer clears it, then a review fails again: a new generation, which a check from before cannot clear.
    pending.clear("A")
    pending.mark("A")
    #expect(pending.generation("A") > seen)
    pending.clear("A", ifGeneration: seen)
    #expect(pending.contains("A"))
}

@Test func aSummaryThatCannotBeReadRefusesTheRename() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    #expect(SessionCatalog.summary(session: session, jobState: .free).summaryProblem == nil)
    #expect(chmod(SessionPaths.summary(session).path, 0) == 0)
    let listed = SessionCatalog.summary(session: session, jobState: .free)
    let outcome = await rename(session, "Weekly sync")
    #expect(chmod(SessionPaths.summary(session).path, 0o600) == 0)
    #expect(listed.summaryProblem?.contains("cannot be read") == true)
    #expect(!MeetingActionPolicy.renames(listed))
    #expect(MeetingActionPolicy.renameRefusal(listed)?.contains("summary") == true)
    #expect(outcome.status == .unreadable)
    #expect(try SessionArchive.readManifest(at: session).name == "Meeting 2026-10-03 14:00")
    // One a newer build wrote: refused for good, and Rename is off.
    var object = try #require(try JSONSerialization.jsonObject(
        with: Data(contentsOf: SessionPaths.summary(session))) as? [String: Any])
    object["schemaVersion"] = 2
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: object), to: SessionPaths.summary(session))
    let newer = SessionCatalog.summary(session: session, jobState: .free)
    #expect(newer.summaryProblem?.contains("newer version") == true)
    #expect(MeetingActionPolicy.renameRefusal(newer)?.contains("newer version") == true)
}

// MARK: - Writes that may land, the event on the locked folder, an unfinished switch, transcript-free meetings

@Test func aFirstWriteThatFailsMayHaveLandedAndIsReported() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url, legacyExports: true)
    let exports = SessionPaths.exports(session)
    var request = SessionRenameCommand.Request(session: session, name: "Design review", voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    // The pending record's write fails (its folder turned read-only); a publication that fails may have landed.
    request.exportCheck = { call in if call == 1 { _ = chmod(exports.path, 0o500) } }
    let outcome = await SessionRenameCommand.run(request)
    #expect(chmod(exports.path, 0o700) == 0)
    #expect(outcome.exitCode == 3)
    #expect(outcome.message.contains("partly rewritten"))
}

@Test func theEventIsWrittenOnlyOnTheLockedFolder() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    let moved = temp.url.appendingPathComponent("moved", isDirectory: true)
    var request = SessionRenameCommand.Request(session: session, name: "Weekly sync", voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    request.beforeStep = { step in
        guard step == "event" else { return }
        try? FileManager.default.moveItem(at: session, to: moved)
        try? FileManager.default.copyItem(at: moved, to: session)
    }
    let outcome = await SessionRenameCommand.run(request)
    #expect(outcome.exitCode == 3)
    #expect(outcome.message.contains("moved or replaced"))
    // Neither folder got the event.
    for folder in [moved, session] {
        #expect(try SessionArchive.readEvents(at: folder).events.last?.kind != MeetingEventKind.renamed)
    }
}

@Test func anUnfinishedSwitchToTheGeneratedTitleIsOutOfDate() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await renameSession(in: temp.url)
    try writeSummary(session)
    // The user's name is the generated title word for word; --generated writes its source, then stops.
    _ = await rename(session, "Parser rewrite and release plan")
    var request = SessionRenameCommand.Request(session: session, name: nil, voiceInputs: { voice },
                                               jobLock: temp.url.appendingPathComponent("jobs.lock"), timeZone: utc)
    request.nameSourceWriter = { source, folder, meeting in
        try SessionRenameCommand.writeNameSource(source, session: folder, meeting: meeting)
        _ = chmod(folder.path, 0o500)
    }
    let partial = await SessionRenameCommand.run(request)
    #expect(chmod(session.path, 0o700) == 0)
    #expect(partial.exitCode == 3)
    let summary = SessionCatalog.summary(session: session, jobState: .free)
    #expect(summary.nameSource == .default)
    #expect(summary.name == "Parser rewrite and release plan", "Left over")
    #expect(summary.displayTitle == "Parser rewrite and release plan", "The title shown is the same")
    // The heading and the name in the files match, but the switch is not done: out of date, for Update.
    #expect(TranscriptFilesCache().state(of: summary) == .stale)
    #expect(MeetingRenameRequest.retry(summary) == .generated)
    #expect(await rename(session, nil).exitCode == 0)
    let done = SessionCatalog.summary(session: session, jobState: .free)
    #expect(done.name == MeetingStartSettings.defaultName(now: done.createdAt, timeZone: utc))
    #expect(TranscriptFilesCache().state(of: done) == .current)
}

@Test func aTranscriptFreeMeetingIsRenamedWhateverItsExportRecord() async throws {
    let temp = try TemporaryDirectory("rename")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, transcript: nil)
    try AtomicFile.write(Data(#"{"schemaVersion":2,"files":{}}"#.utf8), to: SessionPaths.generatedExports(session))
    let listed = SessionCatalog.summary(session: session, jobState: .free)
    #expect(listed.exportsProblem != nil)
    // No transcript and no transcript file: the rename does not touch the files, so the record does not matter.
    #expect(MeetingActionPolicy.renameRefusal(listed, hasExport: false) == nil)
    #expect(MeetingActionPolicy.enabled(listed, inUse: false, hasExport: false, transcriptFiles: false)
        .contains(.rename))
    let outcome = await rename(session, "Hallway chat")
    #expect(outcome.status == .renamed)
}
