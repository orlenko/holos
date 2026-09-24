import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// SpeakerSessionSnapshot (docs/meeting-design.md §2.4, §5.5 PR7b).

private func snapshotSession(in root: URL, mode: MeetingMode? = .inPerson) async throws -> (URL, Transcript) {
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: root, mode: mode, transcript: transcript)
    return (session, transcript)
}

@Test func snapshotLoadsRunTranscriptAndFlagsChange() async throws {
    let temp = try TemporaryDirectory("snapshot")
    defer { temp.remove() }
    let (session, first) = try await snapshotSession(in: temp.url)
    let run = try SessionFixtures.writeHeadRun(session: session, transcript: first,
                                               outputs: ["mic": SessionFixtures.alternatingOutput()])
    let unchanged = try SpeakerSessionSnapshot.load(session: session)
    #expect(!unchanged.transcriptChanged)

    let revised = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    try await SessionFixtures.saveTranscript(revised, in: session)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.transcript.id == first.id, "The run's own transcript, not the current one.")
    #expect(snapshot.transcriptChanged)
    #expect(snapshot.run?.id == run.id)
    #expect(snapshot.projection?.runID == run.id)
    #expect(snapshot.runProblem == nil)
    #expect(snapshot.meeting.mode == .inPerson)
    #expect(!snapshot.audioDeleted)
    let document = snapshot.exportDocument(timeZone: TimeZone(identifier: "UTC")!)
    #expect(document.transcript.id == first.id)
    #expect(document.run?.id == run.id)
    #expect(document.metadata.durationSeconds == 20)
    #expect(document.metadata.sessionID == snapshot.manifest.id)
    #expect(!String(describing: snapshot).contains("mict1w1"), "Printing a snapshot shows no transcript text.")
}

@Test func invalidSpanMakesRunUnusable() async throws {
    let temp = try TemporaryDirectory("snapshot")
    defer { temp.remove() }
    let (session, transcript) = try await snapshotSession(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: session)
    var run = SpeakerRunBuilder.build(sessionID: manifest.id, transcript: transcript,
                                      tracks: [.init(track: "mic", policy: .diarized,
                                                     output: SessionFixtures.alternatingOutput())],
                                      engine: .fake).run
    run.turns[1].spans[0].end = 999
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.run == nil)
    #expect(snapshot.projection == nil)
    #expect(snapshot.runProblem?.contains("turn T2") == true)
    #expect(snapshot.transcript.id == transcript.id)
    #expect(!snapshot.transcriptChanged)

    let result = try SessionExports.regenerate(session: session)
    #expect(result.written.count == 3)
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).hasPrefix("Microphone  00:00\n"))

    // A span naming a segment that does not exist is refused too.
    run.turns[1].spans[0] = WordSpan(segmentID: "missing", first: 0, end: 1)
    #expect(SpeakerSessionSnapshot.spanProblem(run: run, transcript: transcript) != nil)
    run.turns[1].spans[0] = WordSpan(segmentID: transcript.segments[1].id, first: 2, end: 2)
    #expect(SpeakerSessionSnapshot.spanProblem(run: run, transcript: transcript) != nil)
}

@Test func snapshotWithoutARunUsesTheCurrentTranscript() async throws {
    let temp = try TemporaryDirectory("snapshot")
    defer { temp.remove() }
    let (session, transcript) = try await snapshotSession(in: temp.url, mode: nil)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.transcript.id == transcript.id)
    #expect(snapshot.run == nil && snapshot.projection == nil && snapshot.runProblem == nil)
    #expect(snapshot.meeting == MeetingInfo.inferred(sessionID: snapshot.manifest.id, source: .microphone,
                                                     createdAt: snapshot.manifest.createdAt))

    let bare = try await SessionFixtures.makeSession(in: temp.url, transcript: nil)
    let error = #expect(throws: HolosError.self) { try SpeakerSessionSnapshot.load(session: bare) }
    guard case .unavailable? = error else {
        Issue.record("Expected unavailable, got \(String(describing: error))")
        return
    }
}

@Test func snapshotReportsAMissingRunAndReadsDeletedAudio() async throws {
    let temp = try TemporaryDirectory("snapshot")
    defer { temp.remove() }
    let (session, transcript) = try await snapshotSession(in: temp.url)
    let run = try SessionFixtures.writeHeadRun(session: session, transcript: transcript,
                                               outputs: ["mic": SessionFixtures.alternatingOutput()])
    try FileManager.default.removeItem(at: SessionPaths.run(run.id, in: session))
    try AtomicFile.writeJSON(["schemaVersion": 1], to: SessionPaths.audioDeleted(session))
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.run == nil)
    #expect(snapshot.runProblem != nil)
    #expect(snapshot.audioDeleted)
}

@Test func snapshotRefusesAHeadFromANewerHolos() async throws {
    let temp = try TemporaryDirectory("snapshot")
    defer { temp.remove() }
    let (session, transcript) = try await snapshotSession(in: temp.url)
    try SessionFixtures.writeHeadRun(session: session, transcript: transcript,
                                     outputs: ["mic": SessionFixtures.alternatingOutput()])
    var head = try #require(try SessionSpeakerStore.readHead(session: session))
    head.schemaVersion = 2
    try AtomicFile.writeJSON(head, to: SessionPaths.head(session))
    let error = #expect(throws: HolosError.self) { try SpeakerSessionSnapshot.load(session: session) }
    guard case .unavailable? = error else {
        Issue.record("Expected unavailable, got \(String(describing: error))")
        return
    }
}
