import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// A capture stop after the frame stream already ended is cleanup (docs/meeting-design.md §4.2, §4.6 step 1): its
// error never turns a finished recording into a capture failure. A stop of a running capture still reports one.

/// A capture that delivers `audio` when started, then ends its stream with `end` (nil: runs until stopped).
/// `stop()` ends the stream and then throws `stopError`, like ScreenCaptureKit refusing to stop a stopped stream.
@MainActor
private final class RecorderEndingCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    private let continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    private let audio: [CapturedAudio]
    private let end: Error?
    private let stopError: Error?
    private(set) var stopCalls = 0

    init(_ audio: [CapturedAudio], end: Error?, stopError: Error?) {
        (frames, continuation) = AsyncThrowingStream<CapturedAudio, Error>.makeStream()
        self.audio = audio
        self.end = end
        self.stopError = stopError
    }

    var hostTimeOrigin: Double { 1_000 }

    func start(_ request: CaptureRequest) async throws {
        for item in audio { continuation.yield(item) }
        if let end { continuation.finish(throwing: end) }
    }

    func stop() async throws {
        stopCalls += 1
        continuation.finish()
        if let stopError { throw stopError }
    }
}

private let recorderAlreadyStopped = HolosError.io("The stream is not running.")

private func recorderAudio(track: String = "mic", from start: Double = 0, count: Int = 3) throws -> [CapturedAudio] {
    try FakeFrame.run(track: track, from: start, count: count).map { try $0.captured(offset: 0) }
}

/// The user stops sharing: ScreenCaptureKit ends the stream, the recorder's own stop then fails as redundant, and
/// the recording still finishes as a requested stop with its audio saved.
@Test(.timeLimit(.minutes(1))) @MainActor
func stopAfterUserStoppedSharingIsCleanup() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let capture = RecorderEndingCapture(try recorderAudio(track: "system"), end: CaptureInterruption.userStoppedSharing,
                                        stopError: recorderAlreadyStopped)
    let dependencies = recorderDependencies(captures: FakeCaptureFactory(), makeCapture: { capture })
    let outcome = try await RecordingWorkflow.run(.testing(root: temp.url, source: .system, recordOnly: true),
                                                  dependencies: dependencies)
    #expect(capture.stopCalls == 1)
    #expect(outcome.stopReason == .requested)
    #expect(outcome.archiveStatus == ArchiveStatus.audioOnly)
    #expect(try SessionArchive.readManifest(at: outcome.directory).chunks.count == 1)
    #expect(try recorderEvents(outcome.directory, MeetingEventKind.captureFailed).isEmpty)
    let status = try #require(try RecorderChannel.readStatus(session: outcome.directory))
    #expect(status.exit?.archiveStatus == ArchiveStatus.audioOnly)
    #expect(status.exit?.message == nil)
}

/// Epoch 0 ends before any audio and the stop after it fails: the recording is a failed start with the capture's
/// own message, not an incomplete recording blamed on the redundant stop.
@Test(.timeLimit(.minutes(1))) @MainActor
func stopAfterAFailedStartIsCleanup() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let capture = RecorderEndingCapture([], end: HolosError.unavailable("The display went away."),
                                        stopError: recorderAlreadyStopped)
    let dependencies = recorderDependencies(captures: FakeCaptureFactory(), makeCapture: { capture })
    do {
        _ = try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true), dependencies: dependencies)
        Issue.record("A recording without audio must throw.")
    } catch let HolosError.incomplete(message) {
        #expect(message.hasPrefix("Audio capture did not start"))
        #expect(!message.contains(recorderAlreadyStopped.localizedDescription))
    }
    let session = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.failed)
    #expect(try RecorderChannel.readStatus(session: session)?.exit?.reason == .startFailed)
}

/// Capture fails mid-recording and its stop fails too: the restart teardown only logs it, the next epoch records,
/// and the recording ends normally.
@Test(.timeLimit(.minutes(1))) @MainActor
func stopAfterACaptureFailureIsCleanup() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let first = RecorderEndingCapture(try recorderAudio(), end: HolosError.io("Gone."), stopError: recorderAlreadyStopped)
    let second = RecorderEndingCapture(try recorderAudio(from: 1), end: nil, stopError: nil)
    let made = SharedValue(0)
    let stop = ManualStopSource()
    let dependencies = recorderDependencies(captures: FakeCaptureFactory(), stop: stop, makeCapture: {
        let index = made.update { count -> Int in defer { count += 1 }; return count }
        return index == 0 ? first : second
    })
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true), dependencies: dependencies) }
    let session = try #require(await recorderSession(in: temp.url))
    #expect(await eventually { second.stopCalls == 0 && made.value == 2 })
    #expect(await eventually { (try? recorderEvents(session, MeetingEventKind.captureRestarted).count) == 1 })
    stop.requestStop()
    let outcome = try await run.value
    #expect(first.stopCalls == 1)
    #expect(second.stopCalls == 1)
    #expect(outcome.stopReason == .requested)
    #expect(outcome.archiveStatus == ArchiveStatus.audioOnly)
    let failures = try recorderEvents(outcome.directory, MeetingEventKind.captureFailed)
    #expect(failures.map { $0.details["error"] } == ["Gone."], "Only the capture's own failure is journaled.")
}

/// A stop that fails while the capture is still running is a real capture error: the saved audio is kept and the
/// recording is marked incomplete.
@Test(.timeLimit(.minutes(1))) @MainActor
func failedStopOfARunningCaptureIsAnError() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let capture = RecorderEndingCapture(try recorderAudio(), end: nil, stopError: HolosError.io("Stop failed."))
    let stop = ManualStopSource()
    let dependencies = recorderDependencies(captures: FakeCaptureFactory(), stop: stop, makeCapture: { capture })
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true), dependencies: dependencies) }
    let session = try #require(await recorderSession(in: temp.url))
    #expect(await eventually { (try? RecorderChannel.readStatus(session: session))?.phase == .recording })
    stop.requestStop()
    await #expect(throws: HolosError.self) { _ = try await run.value }
    #expect(try SessionArchive.readManifest(at: session).status == ArchiveStatus.incomplete)
}

@Test func epochMonitorSaysWhenAStopIsOnlyCleanup() {
    let monitor = EpochMonitor()
    monitor.begin(epoch: 0)
    monitor.ended(epoch: 0, error: CaptureInterruption.userStoppedSharing, at: 1)
    #expect(monitor.requestStop(epoch: 0), "The stream had already ended.")
    monitor.begin(epoch: 1)
    #expect(!monitor.requestStop(epoch: 1))
    monitor.ended(epoch: 1, error: nil, at: 2)
    #expect(monitor.pendingStopRequests == 0)
    let ends = monitor.drain().compactMap { input -> CaptureEnd? in
        if case .captureEnded(_, let end, _) = input { return end }
        return nil
    }
    #expect(ends == [.userStoppedSharing, .requested])
}
