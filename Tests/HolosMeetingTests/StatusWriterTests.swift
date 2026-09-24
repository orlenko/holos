import Darwin
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// status.json (docs/meeting-design.md §4.1, §4.6).

private func initialStatus(_ sessionID: String) -> RecorderStatus {
    RecorderStatus(sessionID: sessionID, name: "Council", pid: getpid(), phase: .starting, sequence: 0,
                   startedAt: Date(), updatedAt: Date(), source: .microphone)
}

private func statusSession() throws -> (TemporaryDirectory, URL, String) {
    let temp = try TemporaryDirectory("status")
    let id = UUID().uuidString
    let session = temp.url.appendingPathComponent("\(id).holos", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return (temp, session, id)
}

@Test(.timeLimit(.minutes(1))) func heartbeatKeepsStatusFresh() async throws {
    let (temp, session, id) = try statusSession()
    defer { temp.remove() }
    let writer = try StatusWriter(session: session, initial: initialStatus(id), heartbeat: .seconds(1))
    let first = try #require(try RecorderChannel.readStatus(session: session))
    #expect(first.sequence == 1)
    try await Task.sleep(for: .milliseconds(2_500))
    var later = try #require(try RecorderChannel.readStatus(session: session))
    // Beats are due at 1 s and 2 s, with nothing else writing; a loaded machine may run them late, so wait for the
    // second one for up to 30 s.
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while later.sequence < 3, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
        later = try #require(try RecorderChannel.readStatus(session: session))
    }
    #expect(later.sequence >= 3)
    #expect(later.updatedAt > first.updatedAt)
    #expect(later.phase == .starting)
    try await writer.finish(exit: RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested))
}

@Test func updatesAfterExitAreIgnored() async throws {
    let (temp, session, id) = try statusSession()
    defer { temp.remove() }
    let writer = try StatusWriter(session: session, initial: initialStatus(id), heartbeat: .milliseconds(20))
    try await writer.update { $0.phase = .recording; $0.markers = 2 }
    try await writer.finish(exit: RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested))
    let exited = try #require(try RecorderChannel.readStatus(session: session))
    #expect(exited.phase == .exited)
    #expect(exited.exit?.reason == .requested)
    #expect(exited.markers == 2)
    try await writer.update { $0.phase = .postprocessing }
    try await Task.sleep(for: .milliseconds(100))
    let after = try #require(try RecorderChannel.readStatus(session: session))
    #expect(after == exited, "Neither an update nor the heartbeat writes after exit.")
    #expect(await writer.current().phase == .exited)
}

@Test func onlyFinishWritesExited() async throws {
    let (temp, session, id) = try statusSession()
    defer { temp.remove() }
    let writer = try StatusWriter(session: session, initial: initialStatus(id), heartbeat: .seconds(60))
    try await writer.update { $0.phase = .recording }
    try await writer.update { $0.phase = .exited }
    #expect(try RecorderChannel.readStatus(session: session)?.phase == .recording)
    try await writer.finish(exit: RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested))
}

/// An atomic write that fails for phase `exited` while `failing` says so (a count of failures left; `.max` fails
/// always), and counts the failures.
private func exitedWriteFailing(_ failing: SharedValue<Int>, failures: SharedValue<Int>) -> StatusWriter.FileWrite {
    { status, url in
        if status.phase == .exited, failing.update({ left -> Bool in
            guard left > 0 else { return false }
            if left != .max { left -= 1 }
            return true
        }) {
            failures.update { $0 += 1 }
            throw HolosError.io("No space left on device.")
        }
        try AtomicFile.writeJSON(status, to: url)
    }
}

/// A final write that fails twice is retried, and the writer is finished only once it lands.
@Test(.timeLimit(.minutes(1))) func finishRetriesAFailedFinalWrite() async throws {
    let (temp, session, id) = try statusSession()
    defer { temp.remove() }
    let failures = SharedValue(0)
    let writer = try StatusWriter(session: session, initial: initialStatus(id), heartbeat: .seconds(60), observer: nil,
                                  write: exitedWriteFailing(SharedValue(2), failures: failures))
    try await writer.update { $0.phase = .stopping }
    try await writer.finish(exit: RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested))
    #expect(failures.value == 2)
    let exited = try #require(try RecorderChannel.readStatus(session: session))
    #expect(exited.phase == .exited)
    #expect(exited.sequence == 3, "Failed attempts use no sequence number.")
}

/// A final write that keeps failing leaves the writer retryable: the file keeps its last phase, the heartbeat keeps it
/// fresh, updates still land, and a later `finish` writes exited.
@Test(.timeLimit(.minutes(1))) func finishThatCannotWriteStaysRetryable() async throws {
    let (temp, session, id) = try statusSession()
    defer { temp.remove() }
    let failing = SharedValue(Int.max)
    let failures = SharedValue(0)
    let writer = try StatusWriter(session: session, initial: initialStatus(id), heartbeat: .milliseconds(20),
                                  observer: nil, write: exitedWriteFailing(failing, failures: failures))
    try await writer.update { $0.phase = .postprocessing }
    await #expect(throws: HolosError.self) {
        try await writer.finish(exit: RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested))
    }
    #expect(failures.value == StatusWriter.finishAttempts)
    #expect(await writer.current().phase == .postprocessing)
    let after = try #require(try RecorderChannel.readStatus(session: session))
    #expect(after.phase == .postprocessing)
    // The heartbeat runs again.
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    var later = after
    while later.sequence <= after.sequence, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
        later = try #require(try RecorderChannel.readStatus(session: session))
    }
    #expect(later.sequence > after.sequence)
    #expect(later.phase == .postprocessing)
    try await writer.update { $0.markers = 4 }
    #expect(try RecorderChannel.readStatus(session: session)?.markers == 4)
    failing.set(0)
    try await writer.finish(exit: RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested))
    let exited = try #require(try RecorderChannel.readStatus(session: session))
    #expect(exited.phase == .exited)
    #expect(exited.markers == 4)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try RecorderChannel.readStatus(session: session) == exited, "The heartbeat stops at exit.")
}

/// A recorder that cannot write `exited` keeps the session's last lock (the writer lock, or the processing lease
/// with post-processing) while the exited status is not written, so liveness never reads it as dead while it shuts
/// down.
@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func recorderKeepsItsLastLockWhenExitCannotBeWritten(postProcess: Bool) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let failures = SharedValue(0)
    let hook: PostProcessHook = { session, _, _ in
        PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: .succeeded,
                             pid: getpid(), startedAt: Date(), updatedAt: Date())
    }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let stop = ManualStopSource()
    var dependencies = recorderDependencies(captures: captures, postProcess: postProcess ? hook : nil, stop: stop)
    dependencies.statusWrite = exitedWriteFailing(SharedValue(Int.max), failures: failures)
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true), dependencies: dependencies) }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    stop.requestStop()
    let outcome = try await run.value
    #expect(outcome.archiveStatus == ArchiveStatus.audioOnly)
    #expect(failures.value >= StatusWriter.finishAttempts)
    #expect(try RecorderChannel.readStatus(session: outcome.directory)?.phase != .exited)
    let held = postProcess ? try SessionArchive.isProcessing(at: outcome.directory)
        : try SessionArchive.isActive(at: outcome.directory)
    #expect(held, "The last lock is not released while status.json does not say exited.")
    #expect(RecorderChannel.liveness(session: outcome.directory) != .dead)
    // Requests stay closed: nothing would answer one.
    #expect(throws: HolosError.self) {
        try RecorderChannel.send(.pause, session: outcome.directory, sessionID: outcome.sessionID, sender: "cli")
    }
}

/// An in-process recorder runs inside the app, which does not exit after the meeting: once the exited status can be
/// written again, it is written in the background, requests are cleaned up, and the held locks are released, so the
/// meeting does not stay busy until Holos quits.
@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func recorderReleasesItsLocksOnceALaterExitWriteLands(postProcess: Bool) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let failing = SharedValue(Int.max)
    let failures = SharedValue(0)
    let hook: PostProcessHook = { session, _, _ in
        PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: .succeeded,
                             pid: getpid(), startedAt: Date(), updatedAt: Date())
    }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let stop = ManualStopSource()
    var dependencies = recorderDependencies(captures: captures, postProcess: postProcess ? hook : nil, stop: stop)
    dependencies.statusWrite = exitedWriteFailing(failing, failures: failures)
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true), dependencies: dependencies) }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    stop.requestStop()
    let outcome = try await run.value
    let session = outcome.directory
    func held() throws -> Bool {
        try postProcess ? SessionArchive.isProcessing(at: session) : SessionArchive.isActive(at: session)
    }
    #expect(try held(), "Held while status.json does not say exited.")
    #expect(ControlInbox.isPublicationClosed(session: session))
    // The disk has room again.
    failing.set(0)
    #expect(await eventually(timeout: .seconds(30)) {
        (try? RecorderChannel.readStatus(session: session))??.phase == .exited
    })
    #expect(await eventually(timeout: .seconds(30)) { (try? held()) == false }, "The last lock is released.")
    #expect(try !SessionArchive.isActive(at: session))
    #expect(try !SessionArchive.isProcessing(at: session))
    #expect(!ControlInbox.isPublicationClosed(session: session), "The closed marker is removed after exited.")
    #expect(RecorderChannel.liveness(session: session) == .exited)
}

/// Progress from post-processing reaches status.json in order, and nothing follows `exited` (§4.6 step 7).
@Test(.timeLimit(.minutes(1))) @MainActor
func progressIsMirroredInOrder() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let written = SharedValue<[RecorderStatus]>([])
    let hook: PostProcessHook = { session, _, progress in
        for step in 1...200 {
            progress(PostProcessingProgress(stage: .render, track: "mic", fraction: Double(step) / 200,
                                            message: "Preparing audio…"))
        }
        return PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: .succeeded,
                                    pid: getpid(), startedAt: Date(), updatedAt: Date())
    }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: recorderDependencies(captures: captures, postProcess: hook, stop: stop,
                                               statusObserver: { status in written.update { $0.append(status) } }))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    stop.requestStop()
    _ = try await run.value
    let statuses = written.value
    #expect(statuses.map(\.sequence) == Array(1...statuses.count), "Every write is seen, in sequence.")
    let exitIndex = try #require(statuses.firstIndex { $0.phase == .exited })
    #expect(exitIndex == statuses.count - 1, "Nothing is written after exited.")
    let beforeExit = statuses[exitIndex - 1]
    #expect(beforeExit.phase == .postprocessing)
    #expect(beforeExit.progress?.fraction == 1, "The last status before exited shows the last progress value.")
    let fractions = statuses.compactMap { $0.progress?.fraction }
    #expect(fractions == fractions.sorted(), "Progress never goes backwards.")
    #expect(statuses[exitIndex].exit?.postprocessing == .succeeded)
}
