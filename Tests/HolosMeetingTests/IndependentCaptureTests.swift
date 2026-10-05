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
    var gatedStopFrom = Int.max
    var releaseStop = false
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
    func stop() async throws {
        stops += 1
        output.finish()
        while stops >= gatedStopFrom && !releaseStop {
            await Task.detached { try? await Task.sleep(for: .milliseconds(1)) }.value
        }
    }
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
func aTimedOutSystemStartDoesNotAccumulateNativeCaptures() async throws {
    let mic = IndependentNativeCapture(), system = IndependentNativeCapture()
    system.startGate = true
    let factory = IndependentNativeFactory([mic, system])
    let capture = isolatedCapture(factory)
    let heard = SharedValue<Int>(0)
    let consumer = Task {
        do { for try await audio in capture.frames {
            if audio.track == "mic" { heard.update { $0 += 1 } }
        } } catch { Issue.record("Unexpected error: \(error)") }
    }
    try await capture.start(CaptureRequest(source: .microphoneAndSystem))
    #expect(await eventually { capture.unavailableTracks == ["system"] })
    try mic.emit("mic", at: 0)
    try mic.emit("mic", at: 0.1)
    #expect(await eventually { heard.value == 2 })
    #expect(factory.made == 2, "A hung start must not create more streams on each retry.")
    try await capture.stop()
    let stopsBeforeReturn = system.stops
    system.releaseStart = true
    #expect(await eventually { system.stops > stopsBeforeReturn })
    await consumer.value
    #expect(factory.made == 2)
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
func lateSystemStartMustFinishCleanupBeforeRetrying() async throws {
    let mic = IndependentNativeCapture(), system = IndependentNativeCapture(), later = IndependentNativeCapture()
    system.startGate = true
    system.gatedStopFrom = 2
    let factory = IndependentNativeFactory([mic, system, later])
    let capture = isolatedCapture(factory)
    let heard = SharedValue<Int>(0)
    let consumer = Task {
        do { for try await audio in capture.frames {
            if audio.track == "mic" { heard.update { $0 += 1 } }
        } } catch { Issue.record("Unexpected error: \(error)") }
    }
    try await capture.start(CaptureRequest(source: .microphoneAndSystem))
    #expect(await eventually { system.stops == 1 })
    system.releaseStart = true
    #expect(await eventually { system.stops == 2 })
    try mic.emit("mic", at: 0)
    #expect(await eventually { heard.value == 1 })
    #expect(factory.made == 2, "No new native stream while late cleanup is unresolved.")
    // Stop must share the same unresolved cleanup rather than call native stop concurrently.
    do { try await capture.stop() } catch { /* The gated native stop intentionally exceeds the stop budget. */ }
    #expect(system.stops == 2)
    system.releaseStop = true
    await consumer.value
    #expect(factory.made == 2, "Finishing cleanup after Stop cannot restart capture.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func consecutiveSystemStartTimeoutsPreserveBackoff() async throws {
    let mic = IndependentNativeCapture(), first = IndependentNativeCapture()
    let second = IndependentNativeCapture(), third = IndependentNativeCapture()
    first.startGate = true
    second.startGate = true
    let factory = IndependentNativeFactory([mic, first, second, third])
    let capture = isolatedCapture(factory)
    try await capture.start(CaptureRequest(source: .microphoneAndSystem))
    #expect(await eventually { first.stops >= 1 })
    first.releaseStart = true
    #expect(await eventually { second.stops >= 1 })
    #expect(capture.systemRetryAttempt == 1)
    second.releaseStart = true
    #expect(await eventually { third.requests.count == 1 })
    #expect(capture.systemRetryAttempt == 2)
    #expect(IndependentMeetingCapture.retryWait(attempt: 2, base: .milliseconds(500)) == .seconds(2))
    #expect(IndependentMeetingCapture.retryWait(attempt: 6, base: .milliseconds(500)) == .seconds(30))
    try await capture.stop()
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

@Test(.timeLimit(.minutes(1))) @MainActor
func successfulDelayedSystemStartRecordsItsLeadingGapWithoutAWarning() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let mic = IndependentNativeCapture(), system = IndependentNativeCapture()
    system.startGate = true
    let capture = isolatedCapture(IndependentNativeFactory([mic, system]))
    // The gate is released explicitly, not by a wall-clock timing assertion.
    capture.startLimit = .seconds(30)
    let stop = ManualStopSource(), clock = ManualSessionClock(0)
    let statuses = SharedValue<[RecorderStatus]>([])
    let dependencies = recorderDependencies(captures: FakeCaptureFactory(), stop: stop, clock: clock,
        makeCapture: { capture }, statusObserver: { status in statuses.update { $0.append(status) } })
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, source: .microphoneAndSystem,
                                                             recordOnly: true), dependencies: dependencies) }
    #expect(await eventually { system.requests.count == 1 })
    try mic.emit("mic", at: 0)
    #expect(await eventually {
        statuses.value.last?.tracks.first(where: { $0.track == "mic" })?.lastFrameSeconds != nil
    })
    #expect(capture.unavailableTracks.isEmpty)
    clock.set(1)
    system.releaseStart = true
    try system.emit("system", at: 1)
    #expect(await eventually {
        statuses.value.last?.tracks.first(where: { $0.track == "system" })?.lastFrameSeconds != nil
    })
    stop.requestStop()
    let outcome = try await run.value
    #expect(!statuses.value.contains { $0.warnings.contains { $0.code.rawValue == "systemAudioUnavailable" } })
    let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
    #expect(!gaps.contains { $0.details["track"] == "mic" })
    #expect(gaps.contains {
        $0.details["track"] == "system" && Double($0.details["previousEnd"] ?? "") == 0
            && Double($0.details["nextStart"] ?? "") == 1
            && $0.details["reason"] == "audioUnavailable"
    })
}

private enum MissingSystemStop: CaseIterable, Sendable { case pause, sleep, pauseAndResume }

@Test(.timeLimit(.minutes(1)), arguments: [GapReason.paused, .sleep, .captureRestarted, .deviceChanged], [true, false])
@MainActor
func resumedSystemPreservesOutageStateAndRecorderBoundary(reason: GapReason, unavailable: Bool) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let mic = IndependentNativeCapture(), system = IndependentNativeCapture(), failed = IndependentNativeCapture()
    failed.startError = HolosError.unavailable("Display unavailable.")
    let capture = isolatedCapture(IndependentNativeFactory([mic, system, failed]))
    let nextMic = IndependentNativeCapture(), nextSystem = IndependentNativeCapture()
    nextSystem.startGate = true
    let next = isolatedCapture(IndependentNativeFactory([nextMic, nextSystem]))
    next.startLimit = .seconds(30)
    let made = SharedValue<Int>(0), statuses = SharedValue<[RecorderStatus]>([])
    let stop = ManualStopSource(), clock = ManualSessionClock(0), power = RecorderFakePower()
    var dependencies = recorderDependencies(captures: FakeCaptureFactory(), stop: stop, clock: clock,
        makeCapture: { made.update { $0 += 1 }; return made.value == 1 ? capture : next },
        statusObserver: { status in statuses.update { $0.append(status) } })
    dependencies.power = power
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, source: .microphoneAndSystem,
                                                             recordOnly: true), dependencies: dependencies) }
    #expect(await eventually { system.requests.count == 1 })
    try mic.emit("mic", at: 0)
    try system.emit("system", at: 0)
    #expect(await eventually {
        statuses.value.last?.tracks.allSatisfy { $0.lastFrameSeconds != nil } == true
    })
    if unavailable {
        system.fail()
        #expect(await eventually {
            statuses.value.last?.warnings.contains { $0.code.rawValue == "systemAudioUnavailable" } == true
        })
    }
    clock.set(1)
    let session = try #require(await recorderSession(in: temp.url))
    switch reason {
    case .paused:
        #expect(try await recorderSend(.pause, to: session)?.result == .applied)
        clock.set(2)
        #expect(try await recorderSend(.resume, to: session)?.result == .applied)
    case .sleep:
        power.post(.willSleep(token: 42))
        #expect(await eventually { power.allowed == [42] })
        clock.set(2)
        power.post(.didWake)
    case .deviceChanged: mic.fail(CaptureInterruption.configurationChanged)
    default: mic.fail(HolosError.io("Microphone ended unexpectedly."))
    }
    #expect(await eventually { nextSystem.requests.count == 1 })
    #expect(nextMic.requests.first?.boundaryReason == reason)
    #expect(nextMic.requests.first?.initialSystemUnavailable == unavailable)
    clock.set(2)
    try nextMic.emit("mic", at: 2)
    #expect(await eventually {
        (statuses.value.last?.tracks.first(where: { $0.track == "mic" })?.lastFrameSeconds ?? 0) > 2
    })
    #expect(next.unavailableTracks.contains("system") == unavailable)
    #expect(statuses.value.last?.warnings.contains { $0.code.rawValue == "systemAudioUnavailable" } == unavailable)
    #expect(!(try recorderEvents(session, MeetingEventKind.captureRestarted)).contains { $0.details["track"] == "system" },
            "Microphone startup cannot journal system recovery before a system frame.")
    nextSystem.releaseStart = true
    try nextSystem.emit("system", at: 2)
    #expect(await eventually {
        (statuses.value.last?.tracks.first(where: { $0.track == "system" })?.lastFrameSeconds ?? 0) > 2
            && statuses.value.last?.warnings.contains { $0.code.rawValue == "systemAudioUnavailable" } == false
    })
    stop.requestStop()
    let outcome = try await run.value
    let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
    for track in ["mic", "system"] {
        #expect(gaps.last(where: { $0.details["track"] == track })?.details["reason"] == reason.rawValue)
    }
    let recovered = try recorderEvents(outcome.directory, MeetingEventKind.captureRestarted)
        .filter { $0.details["track"] == "system" }
    #expect(recovered.count == (unavailable ? 1 : 0))
}

@Test(.timeLimit(.minutes(1)), arguments: MissingSystemStop.allCases) @MainActor
private func missingSystemTailSurvivesPauseOrSleep(action: MissingSystemStop) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let mic = IndependentNativeCapture(), first = IndependentNativeCapture(), failed = IndependentNativeCapture()
    failed.startError = HolosError.unavailable("Display unavailable.")
    let capture = isolatedCapture(IndependentNativeFactory([mic, first, failed]))
    let resumedMic = IndependentNativeCapture(), resumedSystem = IndependentNativeCapture()
    let resumed = isolatedCapture(IndependentNativeFactory([resumedMic, resumedSystem]))
    let made = SharedValue<Int>(0), statuses = SharedValue<[RecorderStatus]>([])
    let stop = ManualStopSource(), clock = ManualSessionClock(0)
    let power = RecorderFakePower()
    var dependencies = recorderDependencies(captures: FakeCaptureFactory(), stop: stop, clock: clock,
        makeCapture: { made.update { $0 += 1 }; return made.value == 1 ? capture : resumed },
        statusObserver: { status in statuses.update { $0.append(status) } })
    dependencies.power = power
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url, source: .microphoneAndSystem,
                                                             recordOnly: true), dependencies: dependencies) }
    #expect(await eventually { first.requests.count == 1 })
    try mic.emit("mic", at: 0)
    try first.emit("system", at: 0)
    #expect(await eventually {
        statuses.value.last?.tracks.first(where: { $0.track == "system" })?.lastFrameSeconds != nil
    })
    first.fail()
    #expect(await eventually { capture.unavailableTracks == ["system"] })
    clock.set(1)
    let session = try #require(await recorderSession(in: temp.url))
    if action == .sleep {
        power.post(.willSleep(token: 42))
        #expect(await eventually { power.allowed == [42] })
    } else {
        #expect(try await recorderSend(.pause, to: session)?.result == .applied)
    }
    if action == .pauseAndResume {
        clock.set(2)
        #expect(try await recorderSend(.resume, to: session)?.result == .applied)
        #expect(await eventually { resumedSystem.requests.count == 1 })
        try resumedMic.emit("mic", at: 2)
        try resumedSystem.emit("system", at: 2)
        #expect(await eventually {
            (statuses.value.last?.tracks.first(where: { $0.track == "system" })?.lastFrameSeconds ?? 0) > 2
        })
    }
    clock.set(3)
    stop.requestStop()
    let outcome = try await run.value
    let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
        .filter { $0.details["track"] == "system" }
    #expect(gaps.contains {
        abs((Double($0.details["previousEnd"] ?? "") ?? -1) - 0.1) < 0.0001
            && Double($0.details["nextStart"] ?? "") == 1
            && $0.details["reason"] == "audioUnavailable"
    })
    if action == .pauseAndResume {
        #expect(gaps.count == 2)
        #expect(gaps.contains {
            Double($0.details["previousEnd"] ?? "") == 1 && Double($0.details["nextStart"] ?? "") == 2
                && $0.details["reason"] == "paused"
        }, "Resume must not journal the already saved 0.1…1 tail twice.")
    } else {
        #expect(gaps.count == 1, "Final Stop after pause/sleep must preserve, not duplicate, the unavailable tail.")
    }
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
