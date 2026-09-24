import Darwin
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// The app's and the CLI's side of the recorder protocol (docs/meeting-design.md §4.1).

private func channelStatus(_ sessionID: String, phase: RecorderPhase, updatedAt: Date = Date(),
                           pid: Int32 = getpid()) -> RecorderStatus {
    RecorderStatus(sessionID: sessionID, name: "Council", pid: pid, phase: phase, sequence: 7,
                   startedAt: updatedAt.addingTimeInterval(-60), updatedAt: updatedAt, source: .microphone)
}

/// A session whose recorder died while recording: the manifest says recording and no lock is held.
private func deadRecordingSession(in root: URL) throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    return archive.directory
    // The archive is released here, which lets its writer lock go without finishing it.
}

@Test func channelSendRefusesWithoutManifest() throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let id = UUID().uuidString
    let session = temp.url.appendingPathComponent("\(id).holos", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    do {
        try RecorderChannel.send(.stop, session: session, sessionID: id, sender: "cli")
        Issue.record("A session without a manifest must refuse requests.")
    } catch HolosError.unavailable(let message) {
        #expect(message.contains("SIGTERM"))
    }
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.controlDirectory(session).path))
}

@Test func sendPublishesARequestTheRecorderReads() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let before = RecorderChannel.continuousNanoseconds()
    let request = try RecorderChannel.send(.marker, label: "Vote", session: archive.directory,
                                           sessionID: archive.id, sender: "cli")
    #expect((request.sentAtNanos ?? 0) >= before)
    var info = stat()
    #expect(lstat(SessionPaths.controlDirectory(archive.directory).path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o700)
    var inbox = ControlInbox(session: archive.directory, sessionID: archive.id)
    let items = inbox.poll()
    // JSON dates have one-second precision; everything else arrives as sent.
    guard items.count == 1, case .request(let read) = items[0] else {
        Issue.record("Expected one request, got \(items).")
        return
    }
    #expect(read.id == request.id)
    #expect(read.command == .marker)
    #expect(read.label == "Vote")
    #expect(read.sentAtNanos == request.sentAtNanos)
    #expect(read.sender == "cli")
    #expect(abs(read.createdAt.timeIntervalSince(request.createdAt)) < 1)
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test func sendRefusesAnExitedRecorder() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .exited), to: SessionPaths.status(archive.directory))
    #expect(throws: HolosError.self) {
        try RecorderChannel.send(.pause, session: archive.directory, sessionID: archive.id, sender: "cli")
    }
}

/// The request files in `control/`.
private func controlFiles(_ session: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: SessionPaths.controlDirectory(session).path)) ?? []
}

@Test func sendRefusesWhenOnlyMaintenanceHoldsTheSession() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let stale = Date().addingTimeInterval(-60)
    // (a) Recovery holds the writer lock of a recorder that died: its status names a process that is gone.
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .recording, updatedAt: stale, pid: Int32.max),
                             to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .maintenance)
    #expect(RecorderChannel.maintenanceOnly(session: session))
    // `holos record stop` and `stop --no-wait` both publish through `send` first.
    for command in [ControlCommand.stop, .pause, .marker] {
        do {
            try RecorderChannel.send(command, session: session, sessionID: archive.id, sender: "cli")
            Issue.record("\(command) must be refused while only maintenance holds the session.")
        } catch HolosError.unavailable(let message) {
            #expect(message.contains("No recorder is running"))
        }
    }
    #expect(controlFiles(session).isEmpty, "No request is left behind for a recorder that does not exist.")
    // (b) `session diarize` holds the processing lease; no status was ever written.
    try await archive.finish(status: ArchiveStatus.complete)
    try FileManager.default.removeItem(at: SessionPaths.status(session))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    #expect(RecorderChannel.liveness(session: session) == .maintenance)
    #expect(throws: HolosError.self) {
        try RecorderChannel.send(.stop, session: session, sessionID: archive.id, sender: "cli")
    }
    #expect(controlFiles(session).isEmpty)
}

@Test func sendQueuesForALiveRecorderWithAStaleStatus() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    // The recorder (this process) holds the writer lock but has not rewritten status.json for a minute: it is
    // still running and still polls control/, so the request is queued.
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .recording, updatedAt: Date().addingTimeInterval(-60)),
                             to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .maintenance)
    #expect(!RecorderChannel.maintenanceOnly(session: session))
    let request = try RecorderChannel.send(.stop, session: session, sessionID: archive.id, sender: "cli")
    #expect(controlFiles(session) == ["\(request.id).json"])
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test func livenessDistinguishesMaintenance() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    // (a) The writer lock is held and the status is fresh: capturing.
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    #expect(RecorderChannel.liveness(session: session) == .capturing, "No status yet: still starting.")
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .recording), to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .capturing)
    // (b) The writer lock is held but the status is a stale exited one: something else holds it.
    let stale = Date().addingTimeInterval(-60)
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .exited, updatedAt: stale), to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .maintenance)
    // (c) No lock is held and the status is a stale recording one: the recorder died.
    try await archive.finish(status: ArchiveStatus.complete)
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .recording, updatedAt: stale), to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .dead)
    // The recorder's own post-processing, and a finished recorder.
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .postprocessing), to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .processing)
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .postprocessing, updatedAt: stale),
                             to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .maintenance)
    lease.release()
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .exited), to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .exited)
}

@Test func freshStatusFromADeadProcessIsNotFresh() throws {
    // A pid that cannot be alive: a fresh-looking status still counts as stale.
    let status = channelStatus("S", phase: .recording, pid: Int32.max)
    #expect(!RecorderChannel.isFresh(status, now: Date()))
    #expect(RecorderChannel.isFresh(channelStatus("S", phase: .recording), now: Date()))
    #expect(!RecorderChannel.isFresh(channelStatus("S", phase: .recording), now: Date().addingTimeInterval(11)))
}

@Test func deadRecorderStatusIsMarkedExited() throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let session = try deadRecordingSession(in: temp.url)
    let id = session.deletingPathExtension().lastPathComponent
    let stale = Date().addingTimeInterval(-60)
    try AtomicFile.writeJSON(channelStatus(id, phase: .recording, updatedAt: stale), to: SessionPaths.status(session))
    #expect(RecorderChannel.liveness(session: session) == .dead)
    #expect(try RecorderChannel.markDeadRecorderExited(session: session))
    let status = try #require(try RecorderChannel.readStatus(session: session))
    #expect(status.phase == .exited)
    #expect(status.exit?.reason == .interrupted)
    #expect(status.exit?.archiveStatus == ArchiveStatus.recording, "The archive status comes from the manifest.")
    #expect(status.sequence == 8)
    #expect(RecorderChannel.liveness(session: session) == .exited)
    #expect(try !RecorderChannel.markDeadRecorderExited(session: session), "Already exited.")
}

@Test func liveRecorderStatusIsNotMarkedExited() throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let session = try deadRecordingSession(in: temp.url)
    let id = session.deletingPathExtension().lastPathComponent
    // A maintenance command holds the lease while a live recorder (fresh status) labels speakers through it.
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    try AtomicFile.writeJSON(channelStatus(id, phase: .postprocessing), to: SessionPaths.status(session))
    #expect(try !RecorderChannel.markDeadRecorderExited(session: session))
    #expect(try RecorderChannel.readStatus(session: session)?.phase == .postprocessing)
}

@Test func statusFromANewerHolosIsRefused() throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let session = temp.url.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    #expect(try RecorderChannel.readStatus(session: session) == nil)
    try Data(#"{"schemaVersion": 2, "phase": "hovering"}"#.utf8).write(to: SessionPaths.status(session))
    #expect(throws: HolosError.self) { try RecorderChannel.readStatus(session: session) }
}

@Test func waitForAckReturnsTheAnswer() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let session = temp.url.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let request = recorderRequest(.pause)
    var status = channelStatus("S", phase: .recording)
    try AtomicFile.writeJSON(status, to: SessionPaths.status(session))
    #expect(await RecorderChannel.waitForAck(request, session: session, timeout: .milliseconds(120)) == nil)
    status.handledRequests = [ControlAck(id: request.id, command: .pause, result: .applied,
                                         handledAt: Date(timeIntervalSince1970: 1_790_000_000))]
    try AtomicFile.writeJSON(status, to: SessionPaths.status(session))
    #expect(await RecorderChannel.waitForAck(request, session: session, timeout: .seconds(1))?.result == .applied)
}
