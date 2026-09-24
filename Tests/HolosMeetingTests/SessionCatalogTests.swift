import Darwin
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// SessionCatalog (docs/meeting-design.md §5.6 PR3): state mapping, sizes, and speaker-label state.

// MARK: - Helpers

/// The recording rate of the fixture audio.
private let catalogRate = 16_000.0

private func catalogStatus(_ sessionID: String, phase: RecorderPhase, updatedAt: Date = Date(),
                           pid: Int32 = getpid()) -> RecorderStatus {
    RecorderStatus(sessionID: sessionID, name: "Council", pid: pid, phase: phase, sequence: 9,
                   startedAt: updatedAt.addingTimeInterval(-60), updatedAt: updatedAt, source: .microphone)
}

/// Appends `seconds` of quiet audio at `catalogRate` to `track` from `start`, one frame per 30 s chunk.
private func catalogAudio(_ writer: AudioChunkWriter, track: String, from start: Double, seconds: Double) async throws {
    var at = start
    while start + seconds - at > 1e-9 {
        let length = min(30, start + seconds - at)
        let samples = [Float](repeating: 0.01, count: Int((length * catalogRate).rounded()))
        try await writer.append(CapturedAudio(track: track, frame: try PCMFrame(samples: samples, sampleRate: catalogRate,
                                                                              channels: 1, startTime: at)))
        at += length
    }
}

/// A recorder that died while recording: the manifest says recording and no lock is held.
private func catalogDeadRecording(in root: URL) throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    return archive.directory
    // The archive is released here, which lets its writer lock go without finishing it.
}

/// Rewrites the manifest's creation date (the catalog orders by it).
private func catalogSetCreated(_ session: URL, _ date: Date) throws {
    var manifest = try SessionArchive.readManifest(at: session)
    manifest.createdAt = date
    try AtomicFile.writeJSON(manifest, to: SessionPaths.manifest(session))
}

// MARK: - State

@Test func catalogMarksDeadRecorderInterrupted() throws {
    let temp = try TemporaryDirectory("catalog")
    defer { temp.remove() }
    let session = try catalogDeadRecording(in: temp.url)
    let id = session.deletingPathExtension().lastPathComponent
    try AtomicFile.writeJSON(catalogStatus(id, phase: .recording, updatedAt: Date().addingTimeInterval(-60)),
                             to: SessionPaths.status(session))
    let summary = SessionCatalog.summary(session: session)
    #expect(summary.state == .interrupted)
    #expect(summary.manifestStatus == ArchiveStatus.recording)
    #expect(summary.liveness == .dead)
    #expect(summary.phase == nil && summary.pid == nil, "A dead recorder's stale phase is not reported.")
    #expect(summary.id == id)
    #expect(summary.name == "Council")
    #expect(summary.speakerState == .none)
    #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent(".processing.lock").path),
            "Reading the catalog creates no lock file.")
}

@Test func catalogShowsMaintenanceAsProcessing() async throws {
    let temp = try TemporaryDirectory("catalog")
    defer { temp.remove() }
    // A maintenance command holds the writer lock of a `processing` archive; status.json is a minute old.
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    try await archive.setStatus(ArchiveStatus.processing)
    try AtomicFile.writeJSON(catalogStatus(archive.id, phase: .transcribing, updatedAt: Date().addingTimeInterval(-60)),
                             to: SessionPaths.status(archive.directory))
    let summary = SessionCatalog.summary(session: archive.directory)
    #expect(summary.state == .processing)
    #expect(summary.liveness == .maintenance)
    #expect(summary.phase == nil)

    // With a fresh status the same archive is being recorded.
    try AtomicFile.writeJSON(catalogStatus(archive.id, phase: .recording), to: SessionPaths.status(archive.directory))
    let live = SessionCatalog.summary(session: archive.directory)
    #expect(live.state == .recording)
    #expect(live.phase == .recording && live.pid == getpid())
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test func catalogStateMapping() {
    let all: [RecorderLiveness] = [.capturing, .processing, .maintenance, .exited, .dead]
    for status in [ArchiveStatus.recording, ArchiveStatus.processing] {
        #expect(all.map { SessionCatalog.state(manifestStatus: status, liveness: $0) }
            == [.recording, .processing, .processing, .interrupted, .interrupted])
    }
    let direct: [(String, SessionState)] = [
        (ArchiveStatus.complete, .complete), (ArchiveStatus.audioOnly, .audioOnly),
        (ArchiveStatus.transcriptionIncomplete, .transcriptionIncomplete), (ArchiveStatus.incomplete, .incomplete),
        (ArchiveStatus.failed, .failed), (ArchiveStatus.interrupted, .interrupted),
        (ArchiveStatus.recovered, .recovered), ("somethingNewer", .incomplete),
    ]
    for (status, state) in direct {
        #expect(all.allSatisfy { SessionCatalog.state(manifestStatus: status, liveness: $0) == state })
    }
}

// MARK: - Sizes and speakers

@Test func catalogReportsSavedDurationSizeAndSpeakerState() async throws {
    let temp = try TemporaryDirectory("catalog")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphoneAndSystem,
                                            locale: "en-CA", backend: .speech)
    let session = archive.directory
    try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: .call, othersInRoom: false),
                             to: SessionPaths.meetingInfo(session))
    let writer = AudioChunkWriter(archive: archive)
    try await catalogAudio(writer, track: "mic", from: 0, seconds: 60)
    try await catalogAudio(writer, track: "system", from: 0, seconds: 30)
    try await writer.finish()
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "system", duration: 30))
    try await archive.saveTranscript(transcript, writeLegacyExports: false)
    try await archive.finish(status: ArchiveStatus.complete)
    let run = try SessionFixtures.writeHeadRun(
        session: session, transcript: transcript,
        outputs: ["system": SessionFixtures.alternatingOutput(duration: 30)])

    let summary = SessionCatalog.summary(session: session)
    #expect(summary.chunkCount == 3)
    let chunks = try SessionArchive.readManifest(at: session).chunks
    let spans: [String] = chunks.map { "\($0.track) \($0.start)-\($0.end)" }.sorted()
    #expect(spans == ["mic 0.0-30.0", "mic 30.0-60.0", "system 0.0-30.0"])
    #expect(summary.savedSeconds == 60)
    #expect(summary.state == .complete)
    #expect(summary.source == .microphoneAndSystem)
    #expect(summary.origin == .recorded)
    #expect(summary.transcriptID == transcript.id)
    #expect(summary.speakerState == .labelled, "A head run without a post-processing record is labelled.")
    #expect(summary.runID == run.id)
    #expect(!summary.hasSpeakerEdits)
    #expect(summary.bytes > Int64(3 * 30 * catalogRate * 2), "Three 30 s chunks of 16-bit audio, and the rest.")
    #expect(summary.derivedBytes == 0)
    #expect(!summary.audioDeleted)
    #expect(summary.liveness == .exited || summary.liveness == .dead)

    // A render left in derived/ is counted on its own too.
    try AtomicFile.ensurePrivateDirectory(SessionPaths.derived(session))
    try Data(repeating: 1, count: 5_000).write(to: SessionPaths.render(track: "system", in: session))
    let withRender = SessionCatalog.summary(session: session)
    #expect(withRender.derivedBytes == 5_000)
    #expect(withRender.bytes == summary.bytes + 5_000)

    // An edit makes the labels edited.
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Jim")], session: session)
    #expect(SessionCatalog.summary(session: session).hasSpeakerEdits)
}

@Test func catalogCountsATornOrUnreadableEditJournalAsEdited() throws {
    let temp = try TemporaryDirectory("catalog")
    defer { temp.remove() }
    let session = try catalogDeadRecording(in: temp.url)
    #expect(!SessionCatalog.hasSpeakerEdits(session), "No journal: no edits.")
    let journal = SessionPaths.edits(session)
    try AtomicFile.ensurePrivateDirectory(journal.deletingLastPathComponent())
    // A crash cut the first edit short: no complete line, only a partial one.
    try Data(#"{"schemaVersion":1,"id":"E1","#.utf8).write(to: journal)
    let torn = try SessionSpeakerStore.readEdits(session: session)
    #expect(torn.edits.isEmpty && torn.unreadableLines == 0 && torn.tornTail)
    #expect(SessionCatalog.hasSpeakerEdits(session))
    #expect(SessionCatalog.summary(session: session).hasSpeakerEdits)
    // A complete line this build cannot read counts too.
    try Data("not an edit\n".utf8).write(to: journal)
    #expect(SessionCatalog.hasSpeakerEdits(session))
}

@Test(.timeLimit(.minutes(1)))
func catalogReportsNotLabelledWithMessage() async throws {
    let temp = try TemporaryDirectory("catalog")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, mode: .inPerson, transcript: transcript)
    let record = try await MeetingPostProcessor(diarizer: nil, freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    let summary = SessionCatalog.summary(session: session)
    #expect(summary.speakerState == .notLabelled)
    #expect(summary.labelMessage?.contains("holos setup --speakers") == true)
    #expect(summary.runID == nil)
}

@Test func catalogSpeakerStateFollowsThePostProcessingRecord() {
    let running = PostProcessingRecord(sessionID: "S", state: .running,
                                       progress: PostProcessingProgress(stage: .diarize, message: "Labelling speakers…"),
                                       pid: 1, startedAt: Date(), updatedAt: Date())
    var finished = running
    finished.state = .partial
    finished.progress = nil
    finished.runID = "RUN"
    finished.message = "Speaker labels were edited; relabel with --force (names carry over)."
    var failed = running
    failed.state = .failed
    failed.message = "Speaker labelling failed."

    func state(_ record: PostProcessingRecord?, head: String? = nil, _ liveness: RecorderLiveness = .exited)
        -> (SpeakerLabelState, String?, String?) {
        let result = SessionCatalog.speakerState(record: record, headRunID: head, liveness: liveness)
        return (result.state, result.message, result.runID)
    }
    #expect(state(nil) == (.none, nil, nil))
    #expect(state(nil, head: "HEAD") == (.labelled, nil, "HEAD"))
    #expect(state(running, .processing) == (.running, "Labelling speakers…", nil))
    #expect(state(running, .maintenance).0 == .running)
    #expect(state(running, .dead).0 == .interrupted)
    #expect(state(running, .exited).0 == .interrupted)
    #expect(state(failed, head: "HEAD") == (.failed, "Speaker labelling failed.", "HEAD"))
    #expect(state(finished, head: "HEAD") == (.labelled, finished.message, "HEAD"))
    finished.runID = nil
    #expect(state(finished).0 == .notLabelled)
}

@Test(.timeLimit(.minutes(1)))
func catalogReportsDeletedAudio() async throws {
    let temp = try TemporaryDirectory("catalog")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    try AtomicFile.ensurePrivateDirectory(SessionPaths.derived(session))
    try Data(repeating: 1, count: 1_000).write(to: SessionPaths.render(track: "system", in: session))
    let before = SessionCatalog.summary(session: session)
    #expect(!before.audioDeleted && before.derivedBytes == 1_000)

    let lease = try SessionArchive.acquireProcessingLease(at: session)
    try SessionDeletion.deleteAudio(session: session, lease: lease)
    lease.release()
    let after = SessionCatalog.summary(session: session)
    #expect(after.audioDeleted)
    #expect(after.derivedBytes == 0)
    #expect(after.bytes < before.bytes - 20 * 16_000 * 2)
    #expect(after.state == .complete)
    #expect(after.savedSeconds == before.savedSeconds, "The manifest still says what was recorded.")
    #expect(after.speakerState == .labelled)
    #expect(after.transcriptID == before.transcriptID)
    #expect(!(try SessionArchive.inspectRecovery(at: session).needsAttention))
}

// MARK: - Listing

@Test func catalogListsNewestFirstAndReportsDamagedFolders() async throws {
    let temp = try TemporaryDirectory("catalog")
    defer { temp.remove() }
    let root = temp.url
    let older = try await SessionFixtures.makeSession(in: root, name: "Older", audioSeconds: ["mic": 1], transcript: nil)
    let newer = try await SessionFixtures.makeSession(in: root, name: "Newer", audioSeconds: ["mic": 1], transcript: nil)
    try catalogSetCreated(older, Date(timeIntervalSince1970: 1_790_000_000))
    try catalogSetCreated(newer, Date(timeIntervalSince1970: 1_790_000_600))

    // A session folder whose manifest is damaged, and things that are not sessions.
    let damagedID = UUID().uuidString
    let damaged = root.appendingPathComponent("\(damagedID).holos", isDirectory: true)
    try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
    try Data("{ not a manifest".utf8).write(to: SessionPaths.manifest(damaged))
    try Data(repeating: 2, count: 300).write(to: damaged.appendingPathComponent("stray.bin"))
    try Data("x".utf8).write(to: root.appendingPathComponent("file.holos"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.holos"), withDestinationURL: older)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".import-\(UUID().uuidString).holos"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)

    let summaries = SessionCatalog.list(root: root)
    #expect(summaries.map(\.name).filter { $0 != "\(damagedID).holos" } == ["Newer", "Older"])
    #expect(summaries.count == 3)
    let broken = try #require(summaries.first { $0.state == .damaged })
    #expect(broken.id == damagedID)
    #expect(broken.name == "\(damagedID).holos")
    #expect(broken.directory.lastPathComponent == "\(damagedID).holos")
    #expect(broken.manifestStatus == "")
    #expect(broken.bytes == 300 + Int64("{ not a manifest".utf8.count))
    #expect(SessionCatalog.list(root: root.appendingPathComponent("missing")).isEmpty)

    // The JSON form round-trips (`holos session list --json`).
    let decoded = try HolosJSON.decoder().decode([SessionSummary].self, from: HolosJSON.encoder().encode(summaries))
    #expect(decoded.map(\.id) == summaries.map(\.id))
    #expect(decoded.map(\.liveness) == summaries.map(\.liveness))
}
