import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// Cancelling the task that runs `RecordingWorkflow.run` at each await point: the run always rethrows
// `CancellationError`, finishes the archive, releases its locks, and never returns an outcome.

// MARK: - Helpers

/// Waits for conditions under load: far longer than any of them takes, well inside the tests' time limits.
private let patience: Duration = .seconds(60)

/// How long the fakes below hang when nothing cancels them, and the speech time limit of the tests that use them:
/// longer than `promptly`, so a run that waited for either instead of cancelling fails that bound.
private let hang: Duration = .seconds(120)

/// A cancelled run returns within this, however loaded the machine (10x what an idle one needs).
private let promptly: Duration = .seconds(50)

/// A speech session whose `finish()` ignores task cancellation: it returns only after `cancel()` (then throws
/// `CancellationError`), or after `limit` with no segments.
private actor HangingFinishSpeech: LiveSpeechSession {
    private let finishStarted: SharedValue<Bool>
    private let cancelledFlag: SharedValue<Bool>
    private let limit: Duration

    init(finishStarted: SharedValue<Bool>, cancelled: SharedValue<Bool>, limit: Duration = hang) {
        self.finishStarted = finishStarted; self.cancelledFlag = cancelled; self.limit = limit
    }

    func append(_ frame: PCMFrame) async throws {
        if cancelledFlag.value { throw CancellationError() }
    }

    func finish() async throws -> [TranscriptSegment] {
        finishStarted.set(true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while !cancelledFlag.value, clock.now < deadline {
            // `try?`: a cancelled task does not end the wait, only `cancel()` does. In a cancelled task the
            // sleep returns at once, so yield too.
            try? await Task.sleep(for: .milliseconds(2))
            await Task.yield()
        }
        if cancelledFlag.value { throw CancellationError() }
        return []
    }

    /// Nonisolated, so it is never queued behind the hanging `finish()`.
    nonisolated func cancel() async { cancelledFlag.set(true) }
}

/// A plain speech session that finishes at once with no segments.
private actor QuietSpeech: LiveSpeechSession {
    let cancelledFlag: SharedValue<Bool>
    init(cancelled: SharedValue<Bool>) { cancelledFlag = cancelled }
    func append(_ frame: PCMFrame) async throws {}
    func finish() async throws -> [TranscriptSegment] { [] }
    func cancel() async { cancelledFlag.set(true) }
}

/// Awaits `run` and checks that it threw `CancellationError`.
private func expectCancellation<T: Sendable>(_ run: Task<T, Error>,
                                             sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        _ = try await run.value
        Issue.record("A cancelled recording must throw CancellationError, not return an outcome.",
                     sourceLocation: sourceLocation)
    } catch is CancellationError {
    } catch {
        Issue.record("Expected CancellationError, got \(error).", sourceLocation: sourceLocation)
    }
}

private func cancellationRecord(_ session: URL) -> PostProcessingRecord {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    return PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: .succeeded,
                                pid: 1, startedAt: date, updatedAt: date, message: nil)
}

private func events(_ directory: URL) throws -> [ArchiveEvent] {
    try SessionArchive.readEvents(at: directory).events
}

/// The session is finished and unlocked: no writer lock, no processing lease, no control file.
private func expectReleased(_ directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(try !SessionArchive.isActive(at: directory), sourceLocation: sourceLocation)
    #expect(try !SessionArchive.isProcessing(at: directory), sourceLocation: sourceLocation)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.json").path),
            sourceLocation: sourceLocation)
}

@MainActor
private func threeFrames() -> FakeCaptureFactory {
    FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
}

/// A fake capture whose `stop()` does not return (or end the stream) until the test opens `gate`.
@MainActor
private final class GatedStopCapture: MeetingCapture {
    let inner: FakeCapture
    let stopStarted = SharedValue(false)
    let gate = SharedValue(false)

    init(_ inner: FakeCapture) { self.inner = inner }

    nonisolated var frames: AsyncThrowingStream<CapturedAudio, Error> { inner.frames }
    var hostTimeOrigin: Double { inner.hostTimeOrigin }
    func start(_ request: CaptureRequest) async throws { try await inner.start(request) }

    func stop() async throws {
        stopStarted.set(true)
        while !gate.value { try? await Task.sleep(for: .milliseconds(2)) }
        try await inner.stop()
    }
}

// MARK: - Before capture starts

/// Cancelled while a live speech session is being created: the factory either ignores the cancellation and
/// returns a session, or throws `CancellationError`. Either way capture never starts.
@Test(.timeLimit(.minutes(3)), arguments: [false, true]) @MainActor
func cancelWhileCreatingLiveSpeechNeverStartsCapture(factoryThrows: Bool) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let makeStarted = SharedValue(false)
    let sessionCancelled = SharedValue(false)
    let speech: LiveSpeechFactory = { _, _, _, _ in
        makeStarted.set(true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: hang)
        while !Task.isCancelled, clock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        if factoryThrows { throw CancellationError() }
        return QuietSpeech(cancelled: sessionCancelled)
    }
    let captures = threeFrames()
    let reporter = CollectingReporter()
    let dependencies = RecordingDependencies(makeCapture: { captures.make() }, makeSpeech: speech,
                                             stop: ManualStopSource(), reporter: reporter, postProcess: nil)
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    #expect(await eventually(timeout: patience) { makeStarted.value })
    run.cancel()
    await expectCancellation(run)
    #expect(captures.requests.isEmpty, "A cancelled run must not open the microphone.")
    #expect(!reporter.messages.contains { $0.hasPrefix("Live mic transcription unavailable") })
    if !factoryThrows { #expect(sessionCancelled.value, "The live session created during the cancel is cancelled.") }
    let directory = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.failed)
    let started = try events(directory).first { $0.kind == MeetingEventKind.startFailed }
    #expect(started?.details["cancelled"] == "true")
    try expectReleased(directory)
}

// MARK: - While stopping

/// A stop was requested, then the run was cancelled while capture was stopping: the capture's stop returns only
/// once the run is cancelled, so the cancellation always lands inside it.
@Test(.timeLimit(.minutes(3))) @MainActor
func cancelWhileCaptureStopsPublishesNoTranscript() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    let gated = SharedValue<GatedStopCapture?>(nil)
    let stop = ManualStopSource()
    // The capture-stop limit is longer than the test waits, so the stop is never abandoned for taking too long.
    let dependencies = RecordingDependencies(
        makeCapture: {
            let capture = GatedStopCapture(captures.make() as! FakeCapture)
            gated.set(capture)
            return capture
        }, makeSpeech: FakeSpeechFactory().factory, stop: stop, reporter: CollectingReporter(), postProcess: nil,
        timeouts: StopTimeouts(captureStop: hang))
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    #expect(await eventually(timeout: patience) { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    #expect(await eventually(timeout: patience) { gated.value?.stopStarted.value == true })
    run.cancel()
    gated.value?.gate.set(true)
    await expectCancellation(run)
    let directory = try #require(sessionFolders(in: temp.url).first)
    let manifest = try SessionArchive.readManifest(at: directory)
    #expect(manifest.status == ArchiveStatus.transcriptionIncomplete)
    #expect(manifest.chunks.count == 1, "The saved audio is kept.")
    #expect(try SessionArchive.currentTranscriptID(at: directory) == nil)
    #expect(try events(directory).first { $0.kind == MeetingEventKind.captureStopped }?.details["cancelled"] == "true")
    try expectReleased(directory)
}

// MARK: - While transcribing

/// Cancelled while the live speech session finishes, with a session that ignores task cancellation. Neither the
/// session nor the speech time limit ends the wait before `promptly`: only the cancellation can.
@Test(.timeLimit(.minutes(3))) @MainActor
func cancelWhileLiveSpeechFinishesCancelsTheSession() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let finishStarted = SharedValue(false)
    let sessionCancelled = SharedValue(false)
    let calls = SharedValue(0)
    let speech: LiveSpeechFactory = { _, _, _, _ in
        calls.update { $0 += 1 }
        return HangingFinishSpeech(finishStarted: finishStarted, cancelled: sessionCancelled)
    }
    let captures = threeFrames()
    let stop = ManualStopSource()
    let dependencies = RecordingDependencies(makeCapture: { captures.make() }, makeSpeech: speech, stop: stop,
                                             reporter: CollectingReporter(), postProcess: nil,
                                             timeouts: StopTimeouts(speechFinishBase: hang))
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    #expect(await eventually(timeout: patience) { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    #expect(await eventually(timeout: patience) { finishStarted.value })
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    run.cancel()
    await expectCancellation(run)
    #expect(cancelledAt.duration(to: clock.now) < promptly, "The cancel must not wait for the speech session.")
    #expect(sessionCancelled.value)
    #expect(calls.value == 1, "A cancelled run replays nothing.")
    let directory = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.transcriptionIncomplete)
    #expect(try SessionArchive.currentTranscriptID(at: directory) == nil, "No partial transcript is published.")
    try expectReleased(directory)
}

/// Cancelled while replaying saved audio (live speech was unavailable), with a session that ignores task
/// cancellation. Neither the session nor the speech time limit ends the wait before `promptly`.
@Test(.timeLimit(.minutes(3))) @MainActor
func cancelWhileReplayFinishesCancelsTheSession() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let finishStarted = SharedValue(false)
    let sessionCancelled = SharedValue(false)
    let calls = SharedValue(0)
    let speech: LiveSpeechFactory = { _, _, _, _ in
        let call = calls.update { count -> Int in count += 1; return count }
        if call == 1 { throw HolosError.unavailable("Speech assets are missing.") }
        return HangingFinishSpeech(finishStarted: finishStarted, cancelled: sessionCancelled)
    }
    let captures = threeFrames()
    let stop = ManualStopSource()
    let dependencies = RecordingDependencies(makeCapture: { captures.make() }, makeSpeech: speech, stop: stop,
                                             reporter: CollectingReporter(), postProcess: nil,
                                             timeouts: StopTimeouts(speechFinishBase: hang))
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    #expect(await eventually(timeout: patience) { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    #expect(await eventually(timeout: patience) { finishStarted.value })
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    run.cancel()
    await expectCancellation(run)
    #expect(cancelledAt.duration(to: clock.now) < promptly, "The cancel must not wait for the replay session.")
    #expect(sessionCancelled.value)
    let directory = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.transcriptionIncomplete)
    #expect(try SessionArchive.currentTranscriptID(at: directory) == nil)
    try expectReleased(directory)
}

/// A replay cancelled before it finishes returns no segments, even for a track with no saved audio.
@Test(.timeLimit(.minutes(1)))
func cancelledReplayThrowsCancellation() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Empty", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    let directory = archive.directory
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hi")])])
    let factory = speech.factory
    let replay = Task { () async throws -> [TranscriptSegment] in
        while !Task.isCancelled { await Task.yield() }
        return try await TrackReplayer.replay(directory: directory, track: "mic", locale: "en-CA",
                                              backend: .speech, makeSpeech: factory)
    }
    replay.cancel()
    await expectCancellation(replay)
}

// MARK: - Post-processing

/// Cancelled while waiting for the processing lease: the hook never runs and the lease is released.
@Test(.timeLimit(.minutes(3))) @MainActor
func cancelWhileTakingTheLeaseSkipsTheHook() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let hookCalls = SharedValue(0)
    let hook: PostProcessHook = { session, _, _ in
        hookCalls.update { $0 += 1 }
        return cancellationRecord(session)
    }
    let captures = threeFrames()
    let stop = ManualStopSource()
    var dependencies = RecordingDependencies.testing(captures: captures, postProcess: hook, stop: stop)
    // The run keeps retrying the lease until the test lets it go, so the cancellation lands while it waits.
    dependencies.tuning.leaseRetry = hang
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true), dependencies: dependencies)
    }
    #expect(await eventually(timeout: patience) { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    let directory = try #require(sessionFolders(in: temp.url).first)
    // Held here so the run waits for it, then released once the run is cancelled.
    let other = try SessionArchive.acquireProcessingLease(at: directory)
    stop.requestStop()
    // The run journals captureStopped right before it asks for the lease, then waits for it until `hang`: the pause
    // only makes it likelier that the cancellation finds it waiting rather than about to ask, and cannot be too long.
    #expect(await eventually(timeout: patience) {
        ((try? events(directory)) ?? []).contains { $0.kind == MeetingEventKind.captureStopped }
    })
    try await Task.sleep(for: .milliseconds(300))
    run.cancel()
    other.release()
    await expectCancellation(run)
    #expect(hookCalls.value == 0, "A cancelled run does not start post-processing.")
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.audioOnly)
    try expectReleased(directory)
}

/// Cancelled while the hook runs: the hook ends on its own terms, and the run still rethrows the cancellation.
@Test(.timeLimit(.minutes(3))) @MainActor
func cancelDuringTheHookRethrowsCancellation() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let hookStarted = SharedValue(false)
    let hookSawCancel = SharedValue(false)
    let hook: PostProcessHook = { session, _, _ in
        hookStarted.set(true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: hang)
        while !Task.isCancelled, clock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        hookSawCancel.set(Task.isCancelled)
        return cancellationRecord(session)
    }
    let captures = threeFrames()
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url),
                                        dependencies: .testing(captures: captures, postProcess: hook, stop: stop))
    }
    #expect(await eventually(timeout: patience) { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    #expect(await eventually(timeout: patience) { hookStarted.value })
    run.cancel()
    await expectCancellation(run)
    #expect(hookSawCancel.value, "The hook runs in the cancelled task.")
    let directory = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.complete,
            "The archive was finished before the hook; its transcript stays.")
    #expect(try SessionArchive.currentTranscriptID(at: directory) != nil)
    try expectReleased(directory)
}
