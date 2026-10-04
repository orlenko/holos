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
                   source: .microphone, state: .complete, manifestStatus: "complete", liveness: .exited,
                   nameSource: source,
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

@Test func filesLeftWithTheOldTitleAreRememberedPerMeeting() throws {
    let suite = "holos-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let stale = PendingExports.afterRename(defaults: defaults)
    stale.mark("A")
    #expect(PendingExports.afterRename(defaults: defaults).contains("A"), "Kept for the next launch.")
    // Apart from the files a review could not rewrite.
    #expect(!PendingExports(defaults: defaults).contains("A"))
    stale.clear("A")
    #expect(defaults.object(forKey: PendingExports.renameKey) == nil)
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

@Test func filesAreMarkedOutOfDateUntilARenameSaysOtherwise() throws {
    func outcome(_ code: Int32) -> SessionRenameCommand.Outcome {
        SessionRenameCommand.Outcome(sessionID: "S", status: code == 1 ? .busy : .renamed, message: "m", exitCode: code)
    }
    #expect(!MeetingRenameRun.staysMarked(outcome: outcome(0), wasMarked: true))
    #expect(MeetingRenameRun.staysMarked(outcome: outcome(3), wasMarked: false))
    // Nothing changed: as it was before the run.
    #expect(!MeetingRenameRun.staysMarked(outcome: outcome(1), wasMarked: false))
    #expect(MeetingRenameRun.staysMarked(outcome: outcome(1), wasMarked: true))
    // No result (the command was stopped): what it changed is not known.
    #expect(MeetingRenameRun.staysMarked(outcome: nil, wasMarked: false))
    // The command's JSON is read back.
    var written = outcome(3)
    written.name = "Weekly sync"
    written.nameSource = .user
    let decoded = try HolosJSON.decoder().decode(SessionRenameCommand.Outcome.self,
                                                 from: HolosJSON.encoder().encode(written))
    #expect(decoded == written)
}
