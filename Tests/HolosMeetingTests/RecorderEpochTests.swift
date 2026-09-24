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
    #expect(captures.captures.first?.stopCalls == 1, "Pausing stops capture.")
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

@Test(.timeLimit(.minutes(1))) @MainActor
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
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: recorderDependencies(captures: captures, stop: stop, clock: clock))
    }
    #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 3 })
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
