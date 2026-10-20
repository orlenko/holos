import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing

@Test(.timeLimit(.minutes(1))) func namingLockContentionReturnsBusyWithTheKnownSessionID() async throws {
    let temp = try TemporaryDirectory("rename-lock-busy")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: nil)
    let id = try SessionArchive.readManifest(at: session).id
    try await SessionArchive.withSpeakerLockAsync(at: session) {
        let outcome = await SessionRenameCommand.run(.init(session: session, name: "Generated blocked title"))
        #expect(outcome.status == .busy)
        #expect(outcome.sessionID == id)
        #expect(outcome.exitCode == 1)
        #expect(!outcome.renamed)
        #expect(SessionCatalog.summary(session: session).name != "Generated blocked title")
    }
}

@Test func anInterruptedRecordingWithoutSettingsCanBeNamed() async throws {
    let temp = try TemporaryDirectory("rename-interrupted-start")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Generated initial title", source: .microphone,
                                           locale: "en-CA", backend: .speech)
    await archive.releaseLock()
    let outcome = await SessionRenameCommand.run(.init(session: archive.directory, name: "Generated saved title"))
    #expect(outcome.exitCode == 0)
    #expect(outcome.renamed)
    #expect(SessionCatalog.summary(session: archive.directory).displayTitle == "Generated saved title")
    #expect(try SessionArchive.readManifest(at: archive.directory).status == ArchiveStatus.recording)
}

@Test func finalTranscriptPublicationKeepsARenameMadeDuringProcessing() async throws {
    let temp = try TemporaryDirectory("rename-final-transcript")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { archive in
        let request = SessionRenameCommand.Request(session: session, name: "Generated processing title",
            voiceInputs: { .init(names: [:], recognition: false, selfName: "Generated person") })
        let renamed = await SessionRenameCommand.run(request)
        #expect(renamed.exitCode == 0)
        #expect(renamed.renamed)
        #expect(try SessionArchive.isProcessing(at: session))
        let final = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic", wordsPerTurn: 8))
        try await archive.saveTranscript(final, writeLegacyExports: false)
        try SessionExports.regenerate(session: session)
        let snapshot = try SpeakerSessionSnapshot.load(session: session)
        #expect(snapshot.sessionName == "Generated processing title")
        #expect(snapshot.transcript.id == final.id)
        #expect(snapshot.exportDocument().metadata.name == "Generated processing title")
        #expect(SessionCatalog.summary(session: session).displayTitle == "Generated processing title")
        #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).hasPrefix("# Generated processing title\n"))
    }
}

@Test func optionalManifestCopyReadsTheLatestCanonicalName() async throws {
    let temp = try TemporaryDirectory("rename-copy-latest")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: nil)
    var request = SessionRenameCommand.Request(session: session, name: "Generated first title")
    request.beforeStep = { step in
        guard step == "manifest" else { return }
        do {
            let manifest = try SessionArchive.readManifest(at: session)
            let meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
            // The mirror holds the speaker lock here; model another canonical commit before its read.
            try SessionRenameCommand.writeNaming(name: "Generated latest title", source: .user,
                                                 session: session, meeting: meeting)
        } catch { Issue.record(error) }
    }
    #expect(await SessionRenameCommand.run(request).exitCode == 0)
    #expect(try SessionArchive.readManifest(at: session).name == "Generated latest title")
    #expect(SessionCatalog.summary(session: session).displayTitle == "Generated latest title")
}
