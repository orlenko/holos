import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// Capture epochs and the session timeline (docs/meeting-design.md §2.3, §4.2, §4.3).

@Test(.timeLimit(.minutes(1))) @MainActor
func epochsRecordDiscontinuityWithReason() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let clock = ManualSessionClock(0)
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 10)),
                                       FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: recorderDependencies(captures: captures, stop: stop, clock: clock))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 10 })
    let session = try #require(await recorderSession(in: temp.url))
    clock.set(1)
    #expect(try await recorderSend(.pause, to: session)?.result == .applied)
    #expect(try RecorderChannel.readStatus(session: session)?.phase == .paused)
    // The answer goes out before capture stops (acknowledgements come first).
    #expect(await eventually { captures.captures.first?.stopCalls == 1 }, "Pausing stops capture.")
    clock.set(5)
    #expect(try await recorderSend(.resume, to: session)?.result == .applied)
    #expect(await eventually { captures.captures.count == 2 && (captures.captures[1].consumedFrames) >= 2 })
    stop.requestStop()
    let outcome = try await run.value
    #expect(captures.requests.map(\.timelineOffset) == [0, 5])
    let chunks = try SessionArchive.readManifest(at: outcome.directory).chunks.sorted { $0.start < $1.start }
    #expect(chunks.count == 2)
    #expect(chunks.map(\.start) == [0, 5])
    let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
    #expect(gaps.count == 1)
    #expect(gaps.first?.details["reason"] == GapReason.paused.rawValue)
    #expect(try recorderEvents(outcome.directory, MeetingEventKind.paused).first?.details["at"] == "1.0")
    let resumed = try #require(try recorderEvents(outcome.directory, MeetingEventKind.resumed).first)
    #expect(resumed.details["at"] == "5.0")
    #expect(resumed.details["epoch"] == "1")
}

/// The gap reasons in events are the `GapReason` raw values: pause, device change, restart, and overflow.
@Test(.timeLimit(.minutes(1)))
func discontinuityReasonsUseGapReasonStrings() async throws {
    // The machine closes chunks with these reasons…
    var paused = recorderRunningMachine()
    #expect(paused.handle(.control(recorderRequest(.pause), at: 1)).first == .stopCapture(reason: .paused))
    var changed = recorderRunningMachine()
    #expect(changed.handle(.captureEnded(epoch: 0, .configurationChanged, at: 1)).contains(.stopCapture(reason: .deviceChanged)))
    var failed = recorderRunningMachine()
    #expect(failed.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 1)).contains(.stopCapture(reason: .captureRestarted)))
    // …and the writer records exactly those strings, plus `overflow` for audio the pump dropped.
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Reasons", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    let writer = AudioChunkWriter(archive: archive)
    let pump = ChunkWriterPump(writer: writer, capacitySeconds: 1)
    let running = Task { try await pump.run() }
    var start = 0.0
    func push(_ count: Int) throws -> [Bool] {
        try (0..<count).map { _ in
            defer { start += 0.1 }
            return pump.push(try FakeFrame(start: start).captured(offset: 0))
        }
    }
    for reason in [GapReason.paused, .deviceChanged, .captureRestarted] {
        _ = try push(2)
        try await pump.closeAll(expectingGap: reason)
        start += 1
    }
    // Overflow: the writer is busy with a full second of audio while more arrives.
    _ = try push(2)
    pump.noteGap(track: "mic", reason: .overflow)
    start += 1
    _ = try push(2)
    pump.finish()
    try await running.value
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let reasons = try recorderEvents(archive.directory, MeetingEventKind.audioDiscontinuity).compactMap { $0.details["reason"] }
    #expect(reasons == ["paused", "deviceChanged", "captureRestarted", "overflow"])
    let known = [GapReason.paused, .sleep, .deviceChanged, .captureRestarted, .audioUnavailable, .overflow].map(\.rawValue)
    #expect(reasons.allSatisfy { known.contains($0) })
}

@Test(.timeLimit(.minutes(3))) @MainActor
func epochOffsetNeverOverlaps() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    // Epoch 0's audio clock runs 0.3 s ahead of the session clock: 1.3 s of audio when the clock says 1.0.
    let clock = ManualSessionClock(1)
    let captures = FakeCaptureFactory([
        FakeCaptureScript(frames: FakeFrame.run(count: 13), failAfterFrames: 13, failure: .io("Device lost.")),
        FakeCaptureScript(frames: FakeFrame.run(count: 3)),
    ])
    let stop = ManualStopSource()
    // Nothing here is about timeouts: a loaded machine gets ample time to restart, stop, and close chunks.
    var tuning = recorderFastTuning()
    tuning.restartLimit = .seconds(100)
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: recorderDependencies(captures: captures, stop: stop, clock: clock,
                                               timeouts: StopTimeouts(captureStop: .seconds(50)), tuning: tuning))
    }
    #expect(await eventually(timeout: .seconds(100)) {
        captures.captures.count == 2 && captures.captures[1].consumedFrames >= 3
    })
    stop.requestStop()
    let outcome = try await run.value
    let offsets = captures.requests.map(\.timelineOffset)
    #expect(offsets.count == 2)
    #expect(abs(offsets[1] - 1.31) < 1e-9, "Epoch 1 starts at lastFrameEnd + 0.01, not at the session clock's 1.0.")
    let chunks = try SessionArchive.readManifest(at: outcome.directory).chunks.sorted { $0.start < $1.start }
    #expect(chunks.count == 2)
    #expect(abs(chunks[0].end - 1.3) < 1e-9)
    #expect(chunks[1].start >= chunks[0].end, "Its first chunk starts after epoch 0's last chunk ends.")
    #expect(try recorderEvents(outcome.directory, MeetingEventKind.timestampOverlap).isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func sessionTimeStartsAtFirstCapture() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let order = SharedValue<[String]>([])
    let origins = SharedValue<[Double]>([])
    let clock = ManualSessionClock(0)
    // Startup work (the live speech session) takes a while before capture starts; none of it is on the timeline.
    let slow = FakeSpeechFactory()
    let speech: LiveSpeechFactory = { locale, backend, strings, onUpdate in
        try await Task.sleep(for: .milliseconds(300))
        order.update { $0.append("speech") }
        return try await slow.factory(locale, backend, strings, onUpdate)
    }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    let stop = ManualStopSource()
    var dependencies = recorderDependencies(captures: captures, speech: speech, stop: stop, makeCapture: {
        order.update { $0.append("capture") }
        return captures.make()
    })
    dependencies.makeClock = { origin in
        order.update { $0.append("clock") }
        origins.update { $0.append(origin) }
        return clock
    }
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    let session = try #require(await recorderSession(in: temp.url))
    #expect(await eventually { (try? RecorderChannel.readStatus(session: session)) != nil })
    #expect(try RecorderChannel.readStatus(session: session)?.elapsedSeconds == 0, "No session time before capture.")
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    clock.set(2)
    let marker = try #require(try await recorderSend(.marker, label: "Motion", to: session))
    #expect(marker.result == .applied)
    stop.requestStop()
    let outcome = try await run.value
    #expect(order.value == ["speech", "capture", "clock"], "The clock starts when capture has started.")
    #expect(origins.value == [1_000], "It is anchored at epoch 0's host-time origin.")
    let chunks = try SessionArchive.readManifest(at: outcome.directory).chunks
    #expect(chunks.map(\.start) == [0])
    let event = try #require(try recorderEvents(outcome.directory, MeetingEventKind.marker).first)
    #expect(event.details["at"] == "2.0")
    #expect(event.details["label"] == "Motion")
    #expect(event.details["requestID"] == marker.id)
}

/// Epoch 0 fails; epochs 1–5 cannot start; epoch 6 delivers. The recording carries on with one marked gap.
@Test(.timeLimit(.minutes(1))) @MainActor
func failFiveTimesThenRecover() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let clock = ManualSessionClock(0)
    var scripts = [FakeCaptureScript(frames: FakeFrame.run(count: 2), failAfterFrames: 2, failure: .io("Gone."))]
    for _ in 1...5 { scripts.append(FakeCaptureScript(startError: .unavailable("No audio device."))) }
    scripts.append(FakeCaptureScript(frames: FakeFrame.run(count: 2)))
    let captures = FakeCaptureFactory(scripts)
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: recorderDependencies(captures: captures, stop: stop, clock: clock))
    }
    // Move the session clock on so that each retry comes due (0.5, 1, 2, 4, 8 s after each failure).
    let recovered = await eventually(timeout: .seconds(30)) {
        if captures.captures.count == 7, captures.captures[6].consumedFrames >= 2 { return true }
        clock.advance(by: 0.25)
        return false
    }
    #expect(recovered)
    let session = try #require(await recorderSession(in: temp.url))
    // status.json follows within one tick.
    #expect(await eventually { (try? RecorderChannel.readStatus(session: session))?.phase == .recording })
    stop.requestStop()
    let outcome = try await run.value
    #expect(outcome.stopReason == .requested, "The recording did not end while audio was unavailable.")
    let chunks = try SessionArchive.readManifest(at: outcome.directory).chunks
    #expect(chunks.count == 2)
    let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
    #expect(gaps.map { $0.details["reason"] } == [GapReason.audioUnavailable.rawValue])
    #expect(try recorderEvents(outcome.directory, MeetingEventKind.captureWaiting).count == 5)
    #expect(captures.requests.map(\.timelineOffset) == captures.requests.map(\.timelineOffset).sorted())
}

/// A capture that delivers the given audio when started and whose count says one buffer was dropped.
@MainActor
private final class RecorderDroppingCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    private let continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    private let audio: [CapturedAudio]

    init(_ audio: [CapturedAudio]) {
        (frames, continuation) = AsyncThrowingStream<CapturedAudio, Error>.makeStream()
        self.audio = audio
    }

    var hostTimeOrigin: Double { 1_000 }
    var droppedBuffers: Int { 1 }

    func start(_ request: CaptureRequest) async throws {
        for item in audio { continuation.yield(item) }
    }

    func stop() async throws { continuation.finish() }
}

/// The capture queue dropped 30 ms of audio (shorter than the 50 ms jitter tolerance): the gap is marked right
/// before the first frame after the drop, with reason `overflow`, and the recorder warns `audioDropped` (§4.3).
@Test(.timeLimit(.minutes(1))) @MainActor
func captureDropIsMarkedWhereItHappened() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    var audio = try FakeFrame.run(count: 3).map { try $0.captured(offset: 0) }
    let late = try FakeFrame(start: 0.33).captured(offset: 0)
    audio.append(CapturedAudio(track: late.track, frame: late.frame, followsDrop: true))
    audio.append(try FakeFrame(start: 0.43).captured(offset: 0))
    let delivered = audio
    let warned = SharedValue(false)
    let stop = ManualStopSource()
    let dependencies = recorderDependencies(captures: FakeCaptureFactory(), stop: stop,
                                            makeCapture: { RecorderDroppingCapture(delivered) },
                                            statusObserver: { status in
        if status.warnings.contains(where: { $0.code == .audioDropped }) { warned.set(true) }
    })
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true), dependencies: dependencies) }
    #expect(await eventually { warned.value })
    stop.requestStop()
    let outcome = try await run.value
    let chunks = try SessionArchive.readManifest(at: outcome.directory).chunks.sorted { $0.start < $1.start }
    #expect(chunks.count == 2)
    #expect(abs((chunks.first?.end ?? 0) - 0.3) < 1e-9)
    #expect(abs((chunks.last?.start ?? 0) - 0.33) < 1e-9, "The frame after the drop keeps its own time.")
    let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
    #expect(gaps.count == 1)
    #expect(gaps.first?.details["reason"] == GapReason.overflow.rawValue)
    #expect(gaps.first?.details["previousEnd"] == "0.3")
    #expect(gaps.first?.details["nextStart"] == "0.33")
}

/// A capture restart whose start never returns does not hold up the loop: after the restart limit it counts as a
/// failed start, the recorder waits and retries, and the abandoned capture is stopped once its start returns.
@Test(.timeLimit(.minutes(2))) @MainActor
func hungRestartIsAbandoned() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([
        FakeCaptureScript(frames: FakeFrame.run(count: 2), failAfterFrames: 2, failure: .io("Gone.")),
        FakeCaptureScript(frames: FakeFrame.run(count: 2)),
    ])
    let hung = RecorderHungStartCapture()
    let made = SharedValue(0)
    var tuning = recorderFastTuning()
    tuning.restartLimit = .milliseconds(300)
    let stop = ManualStopSource()
    let dependencies = recorderDependencies(captures: captures, stop: stop, tuning: tuning, makeCapture: {
        let index = made.update { count -> Int in defer { count += 1 }; return count }
        return index == 1 ? hung : captures.make()
    })
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true), dependencies: dependencies) }
    #expect(await eventually(timeout: .seconds(40)) { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 2 })
    #expect(await eventually { hung.stopCalls == 1 }, "The abandoned capture is stopped.")
    stop.requestStop()
    let outcome = try await run.value
    #expect(outcome.stopReason == .requested)
    let failures = try recorderEvents(outcome.directory, MeetingEventKind.captureFailed)
    #expect(failures.contains { $0.details["error"] == "Audio capture did not start within 0.3 s." })
    #expect(try recorderEvents(outcome.directory, MeetingEventKind.captureWaiting).count == 1)
}

/// A capture whose `start` waits until it is cancelled.
@MainActor
private final class RecorderHungStartCapture: MeetingCapture {
    nonisolated let frames = AsyncThrowingStream<CapturedAudio, Error> { $0.finish() }
    private(set) var stopCalls = 0

    var hostTimeOrigin: Double { 1_000 }

    func start(_ request: CaptureRequest) async throws {
        try await Task.sleep(for: .seconds(60))
    }

    func stop() async throws { stopCalls += 1 }
}

/// Acknowledgements are written before capture stops or starts, so a sender's 3 s wait never covers them.
@Test func acknowledgementsGoAheadOfCaptureEffects() throws {
    var machine = recorderRunningMachine()
    let pause = recorderRequest(.pause)
    let effects = RecorderMachine.acknowledgingFirst(machine.handle(.control(pause, at: 1)))
    #expect(effects.first == recorderAck(pause, .applied))
    #expect(effects.dropFirst().first == .stopCapture(reason: .paused))
    let resume = recorderRequest(.resume)
    let resumed = RecorderMachine.acknowledgingFirst(machine.handle(.control(resume, at: 2)))
    let ack = try #require(resumed.firstIndex(of: recorderAck(resume, .applied)))
    let start = try #require(resumed.firstIndex(of: .startCapture(epoch: 1)))
    #expect(ack < start)
    // Without a capture effect, the order is unchanged: a marker's event is journaled before its answer.
    let marker = recorderRequest(.marker, label: "Vote")
    let marked = machine.handle(.control(marker, at: 3))
    #expect(RecorderMachine.acknowledgingFirst(marked) == marked)
}

@Test func epochMonitorForgetsStopRequestsOfEndedEpochs() {
    // Hours of restarts (pauses, device changes, retries while waiting) must not pile up per-epoch state.
    let monitor = EpochMonitor()
    for epoch in 0..<500 {
        monitor.begin(epoch: epoch)
        if epoch.isMultiple(of: 2) {
            // Stopped by the loop: the request is matched with the end.
            monitor.requestStop(epoch: epoch)
            monitor.ended(epoch: epoch, error: nil, at: Double(epoch))
        } else {
            // Failed first; the loop's stop comes after the stream already ended.
            monitor.ended(epoch: epoch, error: HolosError.incomplete("Gone."), at: Double(epoch))
            monitor.requestStop(epoch: epoch)
        }
    }
    monitor.begin(epoch: 500)
    #expect(monitor.pendingStopRequests == 0)
    let ends = monitor.drain().compactMap { input -> CaptureEnd? in
        if case .captureEnded(_, let end, _) = input { return end }
        return nil
    }
    #expect(ends.count == 500)
    #expect(ends.enumerated().allSatisfy { index, end in index.isMultiple(of: 2) == (end == .requested) })
}
