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

/// The recorder exits between `send`'s checks and its publish: its last inbox poll and its removal of leftover
/// requests are over, so nothing would ever read the request. `send` reads status.json again, withdraws the request,
/// and refuses, so `--no-wait` never reports it as sent.
@Test func sendWithdrawsARequestWhenTheRecorderExitsWhileItPublishes() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .recording), to: SessionPaths.status(session))
    for command in [ControlCommand.stop, .pause, .marker] {
        do {
            _ = try RecorderChannel.send(command, label: command == .marker ? "Vote" : nil, session: session,
                                         sessionID: archive.id, sender: "cli", afterPublish: {
                // The recorder's exit, after the publish: status says exited; its leftover sweep already ran.
                #expect(controlFiles(session).count == 1)
                try AtomicFile.writeJSON(channelStatus(archive.id, phase: .exited), to: SessionPaths.status(session))
            })
            Issue.record("\(command) must be refused once the recorder has exited.")
        } catch HolosError.unavailable(let message) {
            #expect(message.contains("already exited"))
        }
        #expect(controlFiles(session).isEmpty, "The request (and any marker label) is withdrawn.")
        try AtomicFile.writeJSON(channelStatus(archive.id, phase: .recording), to: SessionPaths.status(session))
    }
    try await archive.finish(status: ArchiveStatus.complete)
}

/// A recorder that read the request and acknowledged it on its way out has answered it: `send` succeeds.
@Test func sendKeepsARequestTheExitingRecorderAcknowledged() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .stopping), to: SessionPaths.status(session))
    let request = try RecorderChannel.send(.pause, session: session, sessionID: archive.id, sender: "cli",
                                           afterPublish: {
        // The recorder's last poll takes the request and answers it, then status says exited.
        var inbox = ControlInbox(session: session, sessionID: archive.id)
        guard case .request(let taken) = inbox.poll().first else {
            Issue.record("The recorder should find the request.")
            return
        }
        var status = channelStatus(archive.id, phase: .exited)
        status.handledRequests = [ControlAck(id: taken.id, command: taken.command, result: .ignored,
                                             message: RecorderMachine.alreadyStopping, handledAt: Date())]
        try AtomicFile.writeJSON(status, to: SessionPaths.status(session))
    })
    #expect(await RecorderChannel.waitForAck(request, session: session, timeout: .seconds(1))?.result == .ignored)
    try await archive.finish(status: ArchiveStatus.complete)
}

/// The recorder exits after `send` returned but without reading the request: the waiting sender withdraws it.
@Test func waitForAckWithdrawsARequestTheRecorderExitedWithout() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .recording), to: SessionPaths.status(session))
    let request = try RecorderChannel.send(.marker, label: "Motion", session: session, sessionID: archive.id,
                                           sender: "cli")
    #expect(controlFiles(session) == ["\(request.id).json"])
    try AtomicFile.writeJSON(channelStatus(archive.id, phase: .exited), to: SessionPaths.status(session))
    #expect(await RecorderChannel.waitForAck(request, session: session, timeout: .seconds(1)) == nil)
    #expect(controlFiles(session).isEmpty, "Nothing is left behind for a recorder that is gone.")
    try await archive.finish(status: ArchiveStatus.complete)
}

/// Rewrites status.json in place, without a temporary file or fsync: the interleaving test writes it thousands of
/// times, and nothing reads it concurrently there.
private func writeStatusUnsynced(_ status: RecorderStatus, session: URL) throws {
    try HolosJSON.encoder().encode(status).write(to: SessionPaths.status(session))
}

/// The exiting recorder's steps, in the order `Recorder.exitStatus` takes them, driven one at a time.
private final class ExitingRecorder {
    enum Step: CaseIterable { case close, poll, answer, exited, sweep, reopen }

    let session: URL
    let sessionID: String
    /// For each step, the send slot after which it runs (0: before `send`; 1…5: after each `SendStep`; 6: after).
    let placement: [Int]
    private var inbox: ControlInbox
    private(set) var taken: [ControlRequest] = []
    private var done = 0

    init(session: URL, sessionID: String, placement: [Int]) {
        self.session = session; self.sessionID = sessionID; self.placement = placement
        inbox = ControlInbox(session: session, sessionID: sessionID)
    }

    static func slot(_ step: RecorderChannel.SendStep) -> Int {
        switch step {
        case .checked: 1
        case .published: 2
        case .checkedPublication: 3
        case .checkedStatus: 4
        case .withdrew: 5
        }
    }

    /// Runs every step placed at or before `slot` that has not run yet.
    func run(through slot: Int) throws {
        let steps = Step.allCases
        while done < steps.count, placement[done] <= slot {
            switch steps[done] {
            case .close:
                #expect(ControlInbox.closePublication(session: session))
            case .poll:
                for item in inbox.poll() { if case .request(let request) = item { taken.append(request) } }
            case .answer:
                var status = try #require(try RecorderChannel.readStatus(session: session))
                status.handledRequests += taken.map {
                    ControlAck(id: $0.id, command: $0.command, result: .ignored, message: RecorderMachine.alreadyStopping,
                               handledAt: Date())
                }
                try writeStatusUnsynced(status, session: session)
            case .exited:
                var status = try #require(try RecorderChannel.readStatus(session: session))
                status.phase = .exited
                try writeStatusUnsynced(status, session: session)
            case .sweep:
                ControlInbox.removeLeftovers(session: session)
            case .reopen:
                ControlInbox.removeClosedMarker(session: session)
            }
            done += 1
        }
    }
}

/// Every way to place the recorder's exit steps (close requests, last poll, answers, exited, leftover sweep, marker
/// removal) around `send`'s steps: a send that succeeds is answered by the recorder, a refused one is never handled,
/// and nothing is left in `control/` (docs/meeting-design.md §4.6).
@Test func sendAndRecorderExitAgreeInEveryInterleaving() async throws {
    let temp = try TemporaryDirectory("channel")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let session = archive.directory
    let stepCount = ExitingRecorder.Step.allCases.count
    var placements: [[Int]] = [[]]
    for _ in 0..<stepCount {
        placements = placements.flatMap { prefix in ((prefix.last ?? 0)...6).map { prefix + [$0] } }
    }
    #expect(placements.count == 924)
    var sent = 0
    var refused = 0
    for placement in placements {
        // Emptied, not removed: making control/ again would fsync the session folder every time.
        ControlInbox.removeLeftovers(session: session)
        ControlInbox.removeClosedMarker(session: session)
        try writeStatusUnsynced(channelStatus(archive.id, phase: .stopping), session: session)
        let recorder = ExitingRecorder(session: session, sessionID: archive.id, placement: placement)
        try recorder.run(through: 0)
        let outcome = Result {
            try RecorderChannel.send(.pause, session: session, sessionID: archive.id, sender: "cli", step: { step in
                try recorder.run(through: ExitingRecorder.slot(step))
            })
        }
        try recorder.run(through: 6)
        let status = try #require(try RecorderChannel.readStatus(session: session))
        #expect(status.phase == .exited)
        switch outcome {
        case .success(let request):
            sent += 1
            #expect(recorder.taken.map(\.id) == [request.id], "Sent, so the last poll took it: \(placement)")
            #expect(status.handledRequests.map(\.id) == [request.id], "Sent, so it was answered: \(placement)")
        case .failure(let error):
            refused += 1
            #expect(error is HolosError, "\(placement): \(error)")
            #expect(recorder.taken.isEmpty, "Refused, so the recorder never handled it: \(placement)")
            #expect(status.handledRequests.isEmpty, "\(placement)")
        }
        #expect(controlFiles(session).isEmpty, "Nothing is left in control/: \(placement)")
    }
    #expect(sent > 0 && refused > 0)
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
