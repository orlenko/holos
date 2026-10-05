import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

/// Explicitly stepped fake native stream; never opens a microphone, display, or speech model.
@MainActor private final class IndependentNativeCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    private let output: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    var requests: [CaptureRequest] = []
    var stops = 0
    var startError: Error?
    var startGate = false
    var releaseStart = false
    var hostTimeOrigin: Double { 1_000 }
    init() { (frames, output) = AsyncThrowingStream.makeStream() }
    func start(_ request: CaptureRequest) async throws {
        requests.append(request)
        // Intentionally ignores cancellation like a hung platform start, without spinning a cancelled sleep.
        while startGate && !releaseStart {
            await Task.detached { try? await Task.sleep(for: .milliseconds(1)) }.value
        }
        if let startError { throw startError }
    }
    func emit(_ track: String, at: Double) throws {
        output.yield(try FakeFrame(track: track, start: at).captured(offset: 0))
    }
    func fail(_ error: Error = HolosError.io("Display unavailable.")) { output.finish(throwing: error) }
    func stop() async throws { stops += 1; output.finish() }
}

@MainActor private final class IndependentNativeFactory {
    let natives: [IndependentNativeCapture]
    var made = 0
    init(_ natives: [IndependentNativeCapture]) { self.natives = natives }
    func make() -> any MeetingCapture {
        let index = min(made, natives.count - 1)
        made += 1
        return natives[index]
    }
}

@MainActor private func isolatedCapture(_ factory: IndependentNativeFactory) -> IndependentMeetingCapture {
    let capture = IndependentMeetingCapture(makeCapture: { factory.make() })
    capture.retryDelay = .milliseconds(2)
    capture.startLimit = .milliseconds(30)
    capture.stopLimit = .milliseconds(30)
    return capture
}

/// End-to-end regression through the real recorder, format converter, and chunk writer.
/// A failed system stream + failed restart cannot create a microphone discontinuity or a new mic instance.
@Test(.timeLimit(.minutes(1))) @MainActor
func systemFailureKeepsMicrophoneContinuous() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let mic = IndependentNativeCapture(), first = IndependentNativeCapture()
    let unavailable = IndependentNativeCapture(), resumed = IndependentNativeCapture()
    unavailable.startError = HolosError.unavailable("Display locked.")
    let native = IndependentNativeFactory([mic, first, unavailable, resumed])
    let capture = isolatedCapture(native)
    let stop = ManualStopSource()
    let clock = ManualSessionClock(0)
    let statuses = SharedValue<[RecorderStatus]>([])
    let dependencies = recorderDependencies(captures: FakeCaptureFactory(), stop: stop, clock: clock,
        makeCapture: { capture }, statusObserver: { status in statuses.update { $0.append(status) } })
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, source: .microphoneAndSystem,
                                                             recordOnly: true), dependencies: dependencies) }
    #expect(await eventually { first.requests.count == 1 })
    #expect(mic.requests.first?.source == .microphone)
    #expect(first.requests.first?.source == .system)
    #expect(first.requests.first?.offsetHostTime == mic.hostTimeOrigin)
    try mic.emit("mic", at: 0)
    try first.emit("system", at: 0)
    #expect(await eventually { capture.unavailableTracks.isEmpty })
    first.fail()
    #expect(await eventually { resumed.requests.count == 1 })
    #expect(mic.requests.count == 1)
    #expect(mic.stops == 0)
    try mic.emit("mic", at: 0.1)
    try mic.emit("mic", at: 0.2)
    #expect(await eventually {
        statuses.value.contains { $0.warnings.contains { $0.code.rawValue == "systemAudioUnavailable" } }
    })
    try resumed.emit("system", at: 0.3)
    try mic.emit("mic", at: 0.3)
    #expect(await eventually {
        let latest = statuses.value.last
        return (latest?.tracks.first(where: { $0.track == "mic" })?.lastFrameSeconds ?? 0) >= 0.4
            && capture.unavailableTracks.isEmpty
            && latest?.warnings.contains(where: { $0.code.rawValue == "systemAudioUnavailable" }) == false
    })
    stop.requestStop()
    let outcome = try await run.value
    let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
    #expect(!gaps.contains { $0.details["track"] == "mic" })
    #expect(gaps.contains { $0.details["track"] == "system" && $0.details["reason"] == "captureRestarted" })
    let chunks = try SessionArchive.readManifest(at: outcome.directory).chunks
    #expect(chunks.filter { $0.track == "mic" }.map { $0.end - $0.start } == [0.4])
    #expect(mic.stops == 1)
    #expect(resumed.stops == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func slowSystemStartDoesNotBlockMicrophoneAndLateStartIsStopped() async throws {
    let mic = IndependentNativeCapture(), system = IndependentNativeCapture()
    system.startGate = true
    let factory = IndependentNativeFactory([mic, system])
    let capture = isolatedCapture(factory)
    let heard = SharedValue<[String]>([])
    let consumer = Task {
        do { for try await audio in capture.frames { heard.update { $0.append(audio.track) } } }
        catch { Issue.record("Unexpected error: \(error)") }
    }
    try await capture.start(CaptureRequest(source: .microphoneAndSystem))
    #expect(await eventually { system.requests.count == 1 })
    try mic.emit("mic", at: 0)
    #expect(await eventually { heard.value == ["mic"] })
    try await capture.stop()
    let stopsBeforeReturn = system.stops
    system.releaseStart = true
    #expect(await eventually { system.stops > stopsBeforeReturn })
    await consumer.value
    #expect(mic.stops == 1)
    #expect(factory.made == 2, "No retry can be created after stop.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func deliberateStopSharingStillEndsTheMeeting() async throws {
    let mic = IndependentNativeCapture(), system = IndependentNativeCapture()
    let factory = IndependentNativeFactory([mic, system])
    let capture = isolatedCapture(factory)
    let end = Task { () -> CaptureInterruption? in
        do { for try await _ in capture.frames {} } catch { return error as? CaptureInterruption }
        return nil
    }
    try await capture.start(CaptureRequest(source: .microphoneAndSystem))
    #expect(await eventually { system.requests.count == 1 })
    system.fail(CaptureInterruption.userStoppedSharing)
    #expect(await end.value == .userStoppedSharing)
    try await capture.stop()
    #expect(mic.stops == 1)
    #expect(factory.made == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aDroppedRecoveryFrameRetainsItsSystemOnlyBoundary() async throws {
    let mic = IndependentNativeCapture(), first = IndependentNativeCapture(), resumed = IndependentNativeCapture()
    let factory = IndependentNativeFactory([mic, first, resumed])
    let capture = IndependentMeetingCapture(bufferCapacity: 1, makeCapture: { factory.make() })
    capture.retryDelay = .milliseconds(2)
    var iterator = capture.frames.makeAsyncIterator()
    try await capture.start(CaptureRequest(source: .microphoneAndSystem))
    #expect(await eventually { first.requests.count == 1 })
    try first.emit("system", at: 0)
    #expect(try await iterator.next()?.track == "system")
    // Fill the merged queue with mic; a second mic frame confirms the queue is full.
    try mic.emit("mic", at: 0)
    try mic.emit("mic", at: 0.1)
    #expect(await eventually { capture.droppedBuffers >= 1 })
    first.fail()
    #expect(await eventually { resumed.requests.count == 1 })
    try resumed.emit("system", at: 0.3)
    #expect(await eventually { capture.droppedBuffers >= 2 })
    let queuedMic = try #require(try await iterator.next())
    #expect(queuedMic.track == "mic" && queuedMic.discontinuity == nil)
    try resumed.emit("system", at: 0.4)
    let recovered = try #require(try await iterator.next())
    #expect(recovered.track == "system")
    #expect(recovered.discontinuity == .captureRestarted && recovered.followsDrop)
    try await capture.stop()
}

private final class IndependentDisplayAssertion: PowerAssertionHandle {
    let releases: SharedValue<Int>
    init(_ releases: SharedValue<Int>) { self.releases = releases }
    func release() { releases.update { $0 += 1 } }
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false]) @MainActor
func initialSystemFailureMarksOnlyTheMissingSystemInterval(recovers: Bool) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let mic = IndependentNativeCapture(), failed = IndependentNativeCapture(), later = IndependentNativeCapture()
    failed.startError = HolosError.unavailable("Display unavailable.")
    if !recovers { later.startError = HolosError.unavailable("Still unavailable.") }
    let factory = IndependentNativeFactory([mic, failed, later])
    let capture = isolatedCapture(factory)
    let stop = ManualStopSource(), clock = ManualSessionClock(0)
    let statuses = SharedValue<[RecorderStatus]>([])
    let dependencies = recorderDependencies(captures: FakeCaptureFactory(), stop: stop, clock: clock,
        makeCapture: { capture }, statusObserver: { status in statuses.update { $0.append(status) } })
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, source: .microphoneAndSystem,
                                                             recordOnly: true), dependencies: dependencies) }
    #expect(await eventually { later.requests.count >= 1 })
    try mic.emit("mic", at: 0)
    try mic.emit("mic", at: 0.1)
    try mic.emit("mic", at: 0.2)
    #expect(await eventually {
        statuses.value.last?.warnings.contains { $0.code.rawValue == "systemAudioUnavailable" } == true
    })
    #expect(mic.stops == 0)
    if recovers {
        clock.set(1)
        try later.emit("system", at: 1)
        #expect(await eventually {
            statuses.value.last?.tracks.first(where: { $0.track == "system" })?.lastFrameSeconds != nil
                && capture.unavailableTracks.isEmpty
        })
    }
    clock.set(2)
    stop.requestStop()
    let outcome = try await run.value
    let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
    #expect(!gaps.contains { $0.details["track"] == "mic" })
    #expect(gaps.contains {
        $0.details["track"] == "system" && $0.details["previousEnd"] == "0.0"
            && Double($0.details["nextStart"] ?? "") == (recovers ? 1 : 2)
            && $0.details["reason"] == "audioUnavailable"
    })
    #expect(mic.requests.count == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func displayAssertionEndsOnPauseAndStop() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let takes = SharedValue<Int>(0), releases = SharedValue<Int>(0)
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3)),
                                      FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    let stop = ManualStopSource()
    var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
    dependencies.makeDisplayAssertion = { _ in
        takes.update { $0 += 1 }
        return IndependentDisplayAssertion(releases)
    }
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
                                                     dependencies: dependencies) }
    #expect(await eventually { takes.value == 1 })
    let session = try #require(await recorderSession(in: temp.url))
    #expect(try await recorderSend(.pause, to: session)?.result == .applied)
    #expect(releases.value == 1)
    #expect(try await recorderSend(.resume, to: session)?.result == .applied)
    #expect(await eventually { takes.value == 2 })
    stop.requestStop()
    _ = try await run.value
    #expect(releases.value == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func displayAssertionReleasesBeforeForcedSleepIsAllowed() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let releases = SharedValue<Int>(0)
    let releasedWhenAllowed = SharedValue<Int>(0)
    let power = RecorderFakePower(onAllow: { _ in releasedWhenAllowed.set(releases.value) })
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3)),
                                      FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    let stop = ManualStopSource()
    let clock = ManualSessionClock(0)
    var dependencies = recorderDependencies(captures: captures, stop: stop, clock: clock)
    dependencies.power = power
    dependencies.makeDisplayAssertion = { _ in IndependentDisplayAssertion(releases) }
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
                                                     dependencies: dependencies) }
    #expect(await eventually { power.attached })
    power.post(.willSleep(token: 42))
    #expect(await eventually { power.allowed == [42] })
    #expect(releasedWhenAllowed.value == 1)
    clock.set(1)
    power.post(.didWake)
    #expect(await eventually { captures.captures.count == 2 })
    stop.requestStop()
    _ = try await run.value
    #expect(releases.value == 2)
}
