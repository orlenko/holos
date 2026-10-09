import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing

// `RecorderExitSequence` invariant 2 on the exit paths `exitIsPublishedBeforeTheLastLockIsReleased`
// (StopPathTests) does not reach: the ones that end holding the processing lease, a start cancelled by the
// capture, and an error after the audio was saved.

/// Exit paths, with the lock each one holds last.
enum RecorderLeaseExitPath: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// Post-processing runs and succeeds: the processing lease is the last lock.
    case hookFinishes
    /// The run's task is cancelled while post-processing runs: the processing lease is the last lock.
    case cancelledDuringHook
    /// Capture's start throws `CancellationError`: the writer lock is the last lock.
    case startCancelled
    /// The transcript cannot be saved after the audio was: the writer lock is the last lock.
    case transcriptNotSaved

    var testDescription: String { rawValue }

    var endsWithLease: Bool { self == .hookFinishes || self == .cancelledDuringHook }
}

private struct LocksWhenExited: Sendable {
    var writer: Bool
    var lease: Bool
}

private func exitTestRecord(_ session: URL) -> PostProcessingRecord {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    return PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: .succeeded,
                                pid: 1, startedAt: date, updatedAt: date, message: nil)
}

/// status.json says exited while the recorder still holds the lock it releases last (the processing lease, or the
/// writer lock without one), and nothing is held once the run has ended.
@Test(.timeLimit(.minutes(2)), arguments: RecorderLeaseExitPath.allCases) @MainActor
func exitIsWrittenBeforeTheLastLockGoes(_ path: RecorderLeaseExitPath) async throws {
    let temp = try TemporaryDirectory("meeting", permissions: 0o700)
    defer { temp.remove() }
    let root = temp.url
    // The locks at the moment the exited status was written, seen from the status writer itself.
    let atExit = SharedValue<LocksWhenExited?>(nil)
    let observer: @Sendable (RecorderStatus) -> Void = { status in
        guard status.phase == .exited, let session = sessionFolders(in: root).first else { return }
        atExit.set(LocksWhenExited(writer: (try? SessionArchive.isActive(at: session)) ?? false,
                                   lease: (try? SessionArchive.isProcessing(at: session)) ?? false))
    }
    let hookStarted = SharedValue(false)
    let hook: PostProcessHook = { session, _, _ in
        hookStarted.set(true)
        if path == .cancelledDuringHook {
            var budget = PollBudget(timeout: .seconds(60), interval: .milliseconds(2))
            while !Task.isCancelled, !budget.isSpent { await budget.poll() }
        }
        return exitTestRecord(session)
    }
    let script = path == .startCancelled ? FakeCaptureScript(startCancels: true)
        : FakeCaptureScript(frames: FakeFrame.run(count: 3))
    let captures = FakeCaptureFactory([script])
    let stop = ManualStopSource()
    let dependencies = recorderDependencies(captures: captures, postProcess: path.endsWithLease ? hook : nil,
                                            stop: stop, statusObserver: observer)
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: root, recordOnly: path != .transcriptNotSaved),
                                        dependencies: dependencies)
    }
    if path != .startCancelled {
        #expect(await eventually(timeout: .seconds(60)) { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
        if path == .transcriptNotSaved {
            // A folder where the save writes its pending pointer: the transcript save throws.
            let session = try #require(sessionFolders(in: root).first)
            let blocker = SessionPaths.pendingTranscript(session)
            try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))
        }
        stop.requestStop()
    }
    if path == .cancelledDuringHook {
        #expect(await eventually(timeout: .seconds(60)) { hookStarted.value })
        run.cancel()
    }
    let result = await run.result

    switch path {
    case .hookFinishes:
        #expect(try result.get().postProcessing?.state == .succeeded)
    case .cancelledDuringHook, .startCancelled:
        #expect(throws: CancellationError.self) { try result.get() }
    case .transcriptNotSaved:
        #expect(throws: (any Error).self) { try result.get() }
    }
    let locks = try #require(atExit.value, "The recorder wrote an exited status.")
    if path.endsWithLease {
        #expect(locks.lease, "The processing lease is still held when status.json says exited.")
    } else {
        #expect(locks.writer, "The writer lock is still held when status.json says exited.")
    }
    let session = try #require(sessionFolders(in: root).first)
    let status = try #require(try RecorderChannel.readStatus(session: session))
    #expect(status.phase == .exited)
    switch path {
    case .hookFinishes: #expect(status.exit?.postprocessing == .succeeded)
    case .cancelledDuringHook: #expect(status.exit?.message == "Cancelled.")
    case .startCancelled: #expect(status.exit?.reason == .startFailed)
    case .transcriptNotSaved: #expect(status.exit?.archiveStatus == ArchiveStatus.transcriptionIncomplete)
    }
    #expect(RecorderChannel.liveness(session: session) == .exited)
    #expect(try !SessionArchive.isActive(at: session))
    #expect(try !SessionArchive.isProcessing(at: session))
    #expect(!ControlInbox.isPublicationClosed(session: session), "The closed marker is removed after exited.")
}
