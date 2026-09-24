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
    // Beats are due at 1 s and 2 s; allow a loaded machine a moment for the second write to land.
    for _ in 0..<50 where later.sequence < 3 {
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
