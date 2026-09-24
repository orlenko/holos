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
    try AtomicFile.writeJSON(AudioDeletedRecord(chunkCount: 1, seconds: 1), to: SessionPaths.audioDeleted(session))
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

// MARK: - Diagnostics of every fallback

/// Appends `bytes` to the end of `url` as they are (no newline added).
private func appendBytes(_ bytes: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(bytes.utf8))
}

/// Records one event in a finished session, as a maintenance open does.
private func recordEvent(_ kind: String, _ details: [String: String], in session: URL) async throws {
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
    try await archive.recordEvent(kind: kind, details: details)
    try await archive.finish(status: ArchiveStatus.complete)
}

private struct FallbackCase: Sendable {
    let name: String
    /// Damages a labelled session (`SessionFixtures.labelledSession`) in one way.
    let damage: @Sendable (_ session: URL, _ transcript: Transcript, _ run: DiarizationRun) async throws -> Void
    /// The diagnostics a snapshot of the damaged session must report.
    let expected: @Sendable (_ session: URL) -> SpeakerSnapshotDiagnostics
}

private let damagedLabels = "The speaker labels are missing or damaged."

/// Every condition in which `SpeakerSessionSnapshot.load` falls back or skips data, each reported by exactly one note.
private let fallbackCases: [FallbackCase] = [
    FallbackCase(name: "damaged head.json", damage: { session, _, _ in
        try AtomicFile.write(Data("not json".utf8), to: SessionPaths.head(session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, runProblem: damagedLabels) }),
    FallbackCase(name: "missing head run", damage: { session, _, run in
        try FileManager.default.removeItem(at: SessionPaths.run(run.id, in: session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, runProblem: damagedLabels) }),
    FallbackCase(name: "damaged head run", damage: { session, _, run in
        try AtomicFile.write(Data("{}".utf8), to: SessionPaths.run(run.id, in: session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, runProblem: damagedLabels) }),
    FallbackCase(name: "missing run transcript", damage: { session, transcript, _ in
        let revised = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "system"))
        try await SessionFixtures.saveTranscript(revised, in: session)
        try FileManager.default.removeItem(at: SessionPaths.transcript(transcript.id, in: session))
    }, expected: {
        SpeakerSnapshotDiagnostics(
            session: $0, runProblem: "The transcript the speaker labels were made from is missing or damaged.")
    }),
    FallbackCase(name: "span outside the transcript", damage: { session, transcript, run in
        var bad = SpeakerRunBuilder.build(
            sessionID: run.sessionID, transcript: transcript,
            tracks: [.init(track: "system", policy: .diarized,
                           output: FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds: 5, duration: 20))],
            engine: .fake).run
        bad.turns[1].spans[0].end = 999
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.writeRun(bad, session: session)
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: bad.id), session: session)
        }
    }, expected: {
        SpeakerSnapshotDiagnostics(session: $0, runProblem: "Speaker labels do not match the transcript (turn T2).")
    }),
    FallbackCase(name: "unreadable recognition result", damage: { session, _, run in
        let url = SessionPaths.recognition(run.id, in: session)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data("not json".utf8), to: url)
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, recognitionUnreadable: true) }),
    FallbackCase(name: "damaged meeting.json", damage: { session, _, _ in
        try AtomicFile.write(Data("not json".utf8), to: SessionPaths.meetingInfo(session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, meetingInfoDamaged: true) }),
    FallbackCase(name: "meeting.json of another session", damage: { session, _, _ in
        try AtomicFile.writeJSON(MeetingInfo(sessionID: UUID().uuidString, mode: .call, othersInRoom: false,
                                             createdAt: Date()),
                                 to: SessionPaths.meetingInfo(session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, meetingInfoDamaged: true) }),
    FallbackCase(name: "unreadable journal line", damage: { session, _, _ in
        try AtomicFile.write(Data("not json\n".utf8), to: SessionPaths.edits(session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, unreadableLines: 1) }),
    FallbackCase(name: "torn journal line", damage: { session, _, _ in
        try AtomicFile.write(Data("{\"action\":{\"rename".utf8), to: SessionPaths.edits(session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, tornTail: true) }),
    FallbackCase(name: "stale edit", damage: { session, _, run in
        let edit = SpeakerEdit(baseRunID: run.id, source: "cli", action: .rename(speakerID: "system:S1", name: "X"),
                               expected: "fp1:outdated")
        try SessionArchive.withSpeakerLock(at: session) { try SessionSpeakerStore.appendEdits([edit], session: session) }
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, staleEdits: 1) }),
    FallbackCase(name: "transcript changed", damage: { session, _, _ in
        let revised = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "system"))
        try await SessionFixtures.saveTranscript(revised, in: session)
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, transcriptChanged: true) }),
    FallbackCase(name: "unreadable event line", damage: { session, _, _ in
        try appendBytes("not json\n", to: SessionPaths.events(session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, skippedEvents: 1) }),
    FallbackCase(name: "torn event line", damage: { session, _, _ in
        try appendBytes("{\"kind\":\"mar", to: SessionPaths.events(session))
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, skippedEvents: 1) }),
    FallbackCase(name: "marker with an unreadable time", damage: { session, _, _ in
        try await recordEvent(MeetingEventKind.marker, ["at": "soon", "requestID": UUID().uuidString], in: session)
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, skippedEvents: 1) }),
    FallbackCase(name: "gap with an unreadable time", damage: { session, _, _ in
        try await recordEvent(MeetingEventKind.audioDiscontinuity,
                              ["track": "system", "previousEnd": "x", "nextStart": "12", "reason": "paused"],
                              in: session)
    }, expected: { SpeakerSnapshotDiagnostics(session: $0, skippedEvents: 1) }),
]

@Test(arguments: fallbackCases.indices)
func snapshotReportsEveryFallback(_ index: Int) async throws {
    let condition = fallbackCases[index]
    let temp = try TemporaryDirectory("snapshot")
    defer { temp.remove() }
    let (session, transcript, run) = try await SessionFixtures.labelledSession(in: temp.url)
    #expect(try SpeakerSessionSnapshot.load(session: session).diagnostics.notes == [],
            "\(condition.name): an undamaged session reports nothing")

    try await condition.damage(session, transcript, run)
    let expected = condition.expected(session)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(snapshot.diagnostics == expected, "\(condition.name)")
    #expect(snapshot.diagnostics.notes.count == 1, "\(condition.name): one note")
    // The exports report what they left out too (session export --format and --all).
    #expect(try SessionExports.renderChecked(.txt, session: session).diagnostics == expected, "\(condition.name)")
    #expect(try SessionExports.regenerate(session: session).diagnostics == expected, "\(condition.name)")
    if let problem = expected.runProblem {
        #expect(snapshot.run == nil && snapshot.projection == nil)
        #expect(snapshot.diagnostics.notes == [
            "\(problem) Speaker labels were left out, so the exports show the transcript without speakers. Label "
                + "speakers again with holos session diarize --force \(session.path).",
        ])
    }
}
