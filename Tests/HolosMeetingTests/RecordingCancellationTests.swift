import Foundation
import HolosAudio
import HolosCore
import HolosMeeting
import HolosStorage
import Testing

// Cancelling the task that runs `RecordingWorkflow.run` at each await point: the run always rethrows
// `CancellationError`, finishes the archive, releases its locks, and never returns an outcome.

// MARK: - Helpers

/// A speech session whose `finish()` ignores task cancellation: it returns only after `cancel()` (then throws
/// `CancellationError`), or after `limit` with no segments.
private actor HangingFinishSpeech: LiveSpeechSession {
    private let finishStarted: SharedValue<Bool>
    private let cancelledFlag: SharedValue<Bool>
    private let limit: Duration

    init(finishStarted: SharedValue<Bool>, cancelled: SharedValue<Bool>, limit: Duration = .seconds(20)) {
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

// MARK: - Before capture starts

/// Cancelled while a live speech session is being created: the factory either ignores the cancellation and
/// returns a session, or throws `CancellationError`. Either way capture never starts.
@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func cancelWhileCreatingLiveSpeechNeverStartsCapture(factoryThrows: Bool) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let makeStarted = SharedValue(false)
    let sessionCancelled = SharedValue(false)
    let speech: LiveSpeechFactory = { _, _, _, _ in
        makeStarted.set(true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !Task.isCancelled, clock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        if factoryThrows { throw CancellationError() }
        return QuietSpeech(cancelled: sessionCancelled)
    }
    let captures = threeFrames()
    let reporter = CollectingReporter()
    let dependencies = RecordingDependencies(makeCapture: { captures.make() }, makeSpeech: speech,
                                             stop: ManualStopSource(), reporter: reporter, postProcess: nil)
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    #expect(await eventually { makeStarted.value })
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

/// A stop was requested, then the run was cancelled while capture was stopping.
@Test(.timeLimit(.minutes(1))) @MainActor
func cancelWhileCaptureStopsPublishesNoTranscript() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3), stopDelay: .seconds(10))])
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url),
                                        dependencies: .testing(captures: captures, stop: stop))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    #expect(await eventually { (captures.captures.first?.stopCalls ?? 0) >= 1 })
    run.cancel()
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

/// Cancelled while the live speech session finishes, with a session that ignores task cancellation.
@Test(.timeLimit(.minutes(1))) @MainActor
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
                                             reporter: CollectingReporter(), postProcess: nil)
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    #expect(await eventually { finishStarted.value })
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    run.cancel()
    await expectCancellation(run)
    #expect(cancelledAt.duration(to: clock.now) < .seconds(5), "The cancel must not wait for the speech session.")
    #expect(sessionCancelled.value)
    #expect(calls.value == 1, "A cancelled run replays nothing.")
    let directory = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.transcriptionIncomplete)
    #expect(try SessionArchive.currentTranscriptID(at: directory) == nil, "No partial transcript is published.")
    try expectReleased(directory)
}

/// Cancelled while replaying saved audio (live speech was unavailable), with a session that ignores task
/// cancellation.
@Test(.timeLimit(.minutes(1))) @MainActor
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
                                             reporter: CollectingReporter(), postProcess: nil)
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    #expect(await eventually { finishStarted.value })
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    run.cancel()
    await expectCancellation(run)
    #expect(cancelledAt.duration(to: clock.now) < .seconds(5), "The cancel must not wait for the replay session.")
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
@Test(.timeLimit(.minutes(1))) @MainActor
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
    let reporter = CollectingReporter()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: .testing(captures: captures, postProcess: hook, stop: stop, reporter: reporter))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    let directory = try #require(sessionFolders(in: temp.url).first)
    // Held here so the run waits for it (it retries for 1 s), then released once the run is cancelled.
    let other = try SessionArchive.acquireProcessingLease(at: directory)
    stop.requestStop()
    #expect(await eventually { reporter.messages.contains { $0.hasPrefix("Audio saved.") } })
    try await Task.sleep(for: .milliseconds(300))
    run.cancel()
    other.release()
    await expectCancellation(run)
    #expect(hookCalls.value == 0, "A cancelled run does not start post-processing.")
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.audioOnly)
    try expectReleased(directory)
}

/// Cancelled while the hook runs: the hook ends on its own terms, and the run still rethrows the cancellation.
@Test(.timeLimit(.minutes(1))) @MainActor
func cancelDuringTheHookRethrowsCancellation() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let hookStarted = SharedValue(false)
    let hookSawCancel = SharedValue(false)
    let hook: PostProcessHook = { session, _, _ in
        hookStarted.set(true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
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
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    #expect(await eventually { hookStarted.value })
    run.cancel()
    await expectCancellation(run)
    #expect(hookSawCancel.value, "The hook runs in the cancelled task.")
    let directory = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.complete,
            "The archive was finished before the hook; its transcript stays.")
    #expect(try SessionArchive.currentTranscriptID(at: directory) != nil)
    try expectReleased(directory)
}
