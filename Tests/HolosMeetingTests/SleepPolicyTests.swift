import Foundation
@testable import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// Sleep, wake, lid, power, and the environment events that retry a waiting recorder
// (docs/meeting-design.md §4.2, §4.4).

private func warning(_ code: RecorderWarningCode, _ message: String) -> RecorderEffect {
    .warn(RecorderWarning(code: code, message: message, since: RecorderMachine.placeholderDate))
}

private func willSleepEvent(_ at: String, _ phase: String) -> RecorderEffect {
    .recordEvent(kind: MeetingEventKind.systemWillSleep, details: ["at": at, "phaseBeforeSleep": phase])
}

private func didWakeEvent(_ at: String, slept: String, _ action: String) -> RecorderEffect {
    .recordEvent(kind: MeetingEventKind.didWake, details: ["at": at, "sleptSeconds": slept, "action": action])
}

private func isStart(_ effect: RecorderEffect) -> Bool {
    if case .startCapture = effect { return true }
    return false
}

private func isFinish(_ effect: RecorderEffect) -> Bool {
    if case .finish = effect { return true }
    return false
}

/// A machine waiting for audio: epoch 0 failed, and its immediate restart failed to start.
private func waitingMachine(at: Double) -> RecorderMachine {
    var machine = recorderRunningMachine()
    _ = machine.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: at))
    _ = machine.handle(.captureEnded(epoch: 1, .startFailed(message: "Gone."), at: at))
    return machine
}

// MARK: - The machine

@Test func sleepUnderFifteenMinutesResumes() {
    var machine = recorderRunningMachine()
    #expect(machine.handle(.willSleep(at: 100)) == [
        .stopCapture(reason: .sleep),
        willSleepEvent("100.0", "recording"),
        .allowSleep,
    ])
    #expect(machine.phase == .sleeping)
    #expect(machine.handle(.didWake(at: 700, lidOpen: true)) == [
        .startCapture(epoch: 1),
        warning(.resumedAfterSleep, "Resumed after 10 min of sleep; the gap is marked."),
        didWakeEvent("700.0", slept: "600.0", "resume"),
    ])
    #expect(machine.phase == .recording)
    #expect(machine.stopReason == nil)
}

@Test func sleepOverFifteenMinutesFinalizes() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.willSleep(at: 100))
    let effects = machine.handle(.didWake(at: 1_001, lidOpen: true))
    #expect(effects == [didWakeEvent("1001.0", slept: "901.0", "finalize"), .finish(.sleepTimeout)])
    #expect(!effects.contains(where: isStart))
    #expect(machine.stopReason == .sleepTimeout)
}

@Test func wakeWithLidClosedWaitsThenFinalizes() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.willSleep(at: 100))
    #expect(machine.handle(.didWake(at: 160, lidOpen: false)) == [didWakeEvent("160.0", slept: "60.0", "wait")])
    #expect(machine.phase == .sleeping)
    #expect(machine.handle(.tick(at: 999, lidOpen: false, freeBytes: nil, lastFrameAt: [:])).isEmpty)
    #expect(machine.phase == .sleeping)
    #expect(machine.handle(.tick(at: 1_000, lidOpen: false, freeBytes: nil, lastFrameAt: [:])) == [
        didWakeEvent("1000.0", slept: "900.0", "finalize"),
        .finish(.sleepTimeout),
    ])
}

/// Clamshell or a dark wake, then the lid opens before 15 minutes: the next tick resumes the recording.
@Test func lidOpenedAfterAClosedWakeResumes() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.willSleep(at: 100))
    _ = machine.handle(.didWake(at: 160, lidOpen: false))
    #expect(machine.handle(.tick(at: 161, lidOpen: false, freeBytes: nil, lastFrameAt: [:])).isEmpty)
    #expect(machine.handle(.tick(at: 400, lidOpen: true, freeBytes: nil, lastFrameAt: [:])) == [
        .startCapture(epoch: 1),
        warning(.resumedAfterSleep, "Resumed after 5 min of sleep; the gap is marked."),
        didWakeEvent("400.0", slept: "300.0", "resume"),
    ])
    #expect(machine.phase == .recording)
}

/// Ticks between the sleep acknowledgement and the actual sleep never resume capture, even with the lid open.
@Test func ticksBeforeTheSleepDoNotResume() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.willSleep(at: 100))
    #expect(machine.handle(.tick(at: 100.5, lidOpen: true, freeBytes: nil, lastFrameAt: [:])).isEmpty)
    #expect(machine.phase == .sleeping)
}

@Test func darkWakeKeepsSleepStart() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.willSleep(at: 0))
    #expect(machine.handle(.didWake(at: 600, lidOpen: false)) == [didWakeEvent("600.0", slept: "600.0", "wait")])
    // Back to sleep from a dark wake: allowed, and the sleep still counts from 0.
    #expect(machine.handle(.willSleep(at: 601)) == [.allowSleep])
    #expect(machine.handle(.didWake(at: 1_200, lidOpen: true)) == [
        didWakeEvent("1200.0", slept: "1200.0", "finalize"),
        .finish(.sleepTimeout),
    ])
}

@Test func pausedStaysPausedThroughDarkWake() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.control(recorderRequest(.pause), at: 5))
    #expect(machine.handle(.willSleep(at: 10)) == [willSleepEvent("10.0", "paused"), .allowSleep],
            "Capture is already stopped while paused.")
    #expect(machine.handle(.didWake(at: 20, lidOpen: false)) == [didWakeEvent("20.0", slept: "10.0", "wait")])
    #expect(machine.phase == .paused)
    #expect(machine.handle(.willSleep(at: 21)) == [willSleepEvent("21.0", "paused"), .allowSleep])
    let woke = machine.handle(.didWake(at: 321, lidOpen: true))
    #expect(woke == [didWakeEvent("321.0", slept: "300.0", "wait")])
    #expect(!woke.contains(where: isStart))
    #expect(machine.phase == .paused)
}

@Test func pausedSleepOverFifteenMinutesStaysPaused() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.control(recorderRequest(.pause), at: 50))
    _ = machine.handle(.willSleep(at: 100))
    let woke = machine.handle(.didWake(at: 2_000, lidOpen: true))
    #expect(!woke.contains(where: isFinish))
    #expect(machine.phase == .paused)
    #expect(machine.stopReason == nil)
    // Resume works as after any pause, and the 6 h pause limit still counts from the pause.
    let resume = recorderRequest(.resume)
    #expect(machine.handle(.control(resume, at: 2_010)).contains(.startCapture(epoch: 1)))
    var paused = recorderRunningMachine()
    _ = paused.handle(.control(recorderRequest(.pause), at: 50))
    _ = paused.handle(.willSleep(at: 100))
    _ = paused.handle(.didWake(at: 21_000, lidOpen: true))
    #expect(paused.handle(recorderTick(21_649)).isEmpty)
    #expect(paused.handle(recorderTick(21_650)) == [.finish(.pauseTimeout)])
}

@Test func sleepWhileWaitingRetriesOnWake() {
    var machine = waitingMachine(at: 5)
    #expect(machine.phase == .waiting)
    #expect(machine.handle(.willSleep(at: 10)) == [willSleepEvent("10.0", "waiting"), .allowSleep],
            "Capture is not running while waiting.")
    #expect(machine.handle(recorderTick(10.5)).isEmpty, "No retries while asleep.")
    let woke = machine.handle(.didWake(at: 70, lidOpen: true))
    #expect(woke.first == .startCapture(epoch: 2))
    #expect(woke.last == didWakeEvent("70.0", slept: "60.0", "resume"))
    #expect(machine.phase == .recording)
    // The 10 minutes without audio count from the wake, not from the failure before the sleep.
    #expect(machine.handle(recorderTick(609)).isEmpty)
    #expect(machine.handle(recorderTick(670)) == [.finish(.captureFailed)])
}

@Test func wakeThenStartFailureRetries() {
    var machine = recorderRunningMachine()
    // A restart before the sleep used up the immediate retry.
    _ = machine.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 50))
    _ = machine.handle(.captureRunning(epoch: 1, at: 50.2))
    _ = machine.handle(.willSleep(at: 100))
    #expect(machine.handle(.didWake(at: 200, lidOpen: true)).first == .startCapture(epoch: 2))
    let first = machine.handle(.captureEnded(epoch: 2, .startFailed(message: "No input device."), at: 200))
    #expect(first.suffix(2) == [.stopCapture(reason: .captureRestarted), .startCapture(epoch: 3)],
            "The first failure after a wake restarts at once.")
    let second = machine.handle(.captureEnded(epoch: 3, .startFailed(message: "No input device."), at: 200))
    #expect(second.contains(.recordEvent(kind: MeetingEventKind.captureWaiting, details: [
        "at": "200.0", "reason": "No input device.", "attempt": "1", "retryInSeconds": "0.5",
    ])))
    #expect(machine.phase == .waiting)
    #expect(!second.contains(where: isFinish))
    #expect(machine.handle(recorderTick(200.5)) == [.startCapture(epoch: 4)])
}

@Test func controlWhileAsleepFollowsTheTable() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.willSleep(at: 1))
    let pause = recorderRequest(.pause)
    #expect(machine.handle(.control(pause, at: 2)) == [recorderAck(pause, .rejected, "The computer is asleep.")])
    let resume = recorderRequest(.resume)
    #expect(machine.handle(.control(resume, at: 2)) == [recorderAck(resume, .rejected, "The computer is asleep.")])
    let marker = recorderRequest(.marker)
    #expect(machine.handle(.control(marker, at: 3)).last == recorderAck(marker, .applied))
    let stop = recorderRequest(.stop)
    #expect(machine.handle(.control(stop, at: 4)) == [recorderAck(stop, .applied), .finish(.requested)])
}

@Test func retryNowOnlyRetriesAWaitingRecorder() {
    var waiting = waitingMachine(at: 0)
    #expect(waiting.handle(.retryNow(reason: "lidOpened", at: 0.1)) == [.startCapture(epoch: 2)])
    var asleep = recorderRunningMachine()
    _ = asleep.handle(.willSleep(at: 1))
    #expect(asleep.handle(.retryNow(reason: AudioEnvironmentEvents.screenUnlocked, at: 2)).isEmpty)
    var paused = recorderRunningMachine()
    _ = paused.handle(.control(recorderRequest(.pause), at: 1))
    #expect(paused.handle(.retryNow(reason: AudioEnvironmentEvents.audioDevicesChanged, at: 2)).isEmpty)
}

// MARK: - The power monitor

@Test func monitorAcknowledgesWhenDetached() {
    let acknowledged = SharedValue<[Int]>([])
    let monitor = SystemPowerMonitor(acknowledge: { token in acknowledged.update { $0.append(token) } })
    // Detached (no recorder loop): the monitor lets the Mac sleep at once, and nothing is queued.
    monitor.deliver(SystemPowerMonitor.systemWillSleep, argument: 7)
    #expect(acknowledged.value == [7])
    monitor.deliver(SystemPowerMonitor.systemHasPoweredOn, argument: 0)
    #expect(monitor.pendingEvents().isEmpty)
    // Attached: the loop gets the event and acknowledges it, once.
    monitor.attach()
    monitor.deliver(SystemPowerMonitor.systemWillSleep, argument: 8)
    #expect(acknowledged.value == [7])
    #expect(monitor.pendingEvents() == [.willSleep(token: 8)])
    monitor.allowPowerChange(token: 8)
    monitor.allowPowerChange(token: 8)
    #expect(acknowledged.value == [7, 8])
    monitor.deliver(SystemPowerMonitor.systemHasPoweredOn, argument: 0)
    #expect(monitor.pendingEvents() == [.didWake])
    // "Can sleep" is always allowed at once.
    monitor.deliver(SystemPowerMonitor.canSystemSleep, argument: 9)
    #expect(acknowledged.value == [7, 8, 9])
    // Detaching acknowledges what the loop has not, and drops queued events.
    monitor.deliver(SystemPowerMonitor.systemWillSleep, argument: 10)
    monitor.detach()
    #expect(acknowledged.value == [7, 8, 9, 10])
    #expect(monitor.pendingEvents().isEmpty)
    monitor.allowPowerChange(token: 10)
    #expect(acknowledged.value == [7, 8, 9, 10], "A late acknowledgement from the loop is not sent twice.")
    monitor.stop()
}

// MARK: - The recorder loop

extension RecorderEnvironmentLoopTests {
    /// Before a sleep the loop stops capture (a hung platform stop is abandoned after the capture-stop limit), closes
    /// the chunks, and only then lets the Mac sleep.
    @Test(.timeLimit(.minutes(1)))
    func loopAcknowledgesAfterClosingChunks() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let session = SharedValue<URL?>(nil)
        let chunksAtAllow = SharedValue<Int?>(nil)
        let power = RecorderFakePower(onAllow: { _ in
            let chunks = session.value.flatMap { try? SessionArchive.readManifest(at: $0).chunks.count }
            chunksAtAllow.set(chunks)
        })
        let hangingStop = FakeCaptureScript(frames: FakeFrame.run(count: 3), continuous: FakeFrame(start: 0),
                                            stopDelay: .seconds(30))
        let captures = FakeCaptureFactory([hangingStop])
        let stop = ManualStopSource()
        let timeouts = StopTimeouts(captureStop: .milliseconds(300))
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0),
                                                timeouts: timeouts)
        dependencies.power = power
        let run = recorderRecordOnly(temp.url, dependencies)
        session.set(await recorderSession(in: temp.url))
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 && power.attached })
        let clock = ContinuousClock()
        let asked = clock.now
        power.post(.willSleep(token: 42))
        #expect(await eventually { power.allowed == [42] })
        let waited = asked.duration(to: clock.now)
        #expect(waited >= .milliseconds(300), "The loop waited for the capture stop, up to its limit.")
        #expect(waited < .seconds(3), "…and no longer: the Mac is not held awake by a hung stop.")
        #expect(chunksAtAllow.value == 1, "The chunk was closed and saved before the sleep was allowed.")
        let directory = try #require(session.value)
        #expect(await eventually { recorderStatus(directory)?.phase == .sleeping })
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        let slept = try #require(try recorderEvents(outcome.directory, MeetingEventKind.systemWillSleep).first)
        #expect(slept.details["phaseBeforeSleep"] == "recording")
        #expect(try recorderEvents(outcome.directory, MeetingEventKind.captureFailed).first?.details["error"]?
            .hasPrefix("Capture did not stop within") == true)
        #expect(!power.attached, "The loop detaches when it ends, so later sleeps are not delayed.")
    }

    /// Lid closed on power for 2 minutes (H5): capture resumes in the same session, the gap is marked `sleep`, and the
    /// resume warning is shown.
    @Test(.timeLimit(.minutes(1)))
    func sleepAndWakeResumeInTheSameSession() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let power = RecorderFakePower()
        let clock = ManualSessionClock(0)
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 10)),
                                           FakeCaptureScript(frames: FakeFrame.run(count: 5))])
        let stop = ManualStopSource()
        let resumed = SharedValue(false)
        let observer: @Sendable (RecorderStatus) -> Void = { status in
            if status.warnings.contains(where: { $0.code == .resumedAfterSleep }) { resumed.set(true) }
        }
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: clock, statusObserver: observer)
        dependencies.power = power
        let run = recorderRecordOnly(temp.url, dependencies)
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 10 && power.attached })
        clock.set(1)
        power.post(.willSleep(token: 1))
        #expect(await eventually { power.allowed == [1] })
        clock.set(121)
        power.post(.didWake)
        #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 5 })
        #expect(await eventually { resumed.value })
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        #expect(captures.requests.map(\.timelineOffset) == [0, 121])
        let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
        #expect(gaps.map { $0.details["reason"] } == [GapReason.sleep.rawValue])
        let woke = try #require(try recorderEvents(outcome.directory, MeetingEventKind.didWake).first)
        #expect(woke.details == ["at": "121.0", "sleptSeconds": "120.0", "action": "resume"])
        let restarted = try #require(try recorderEvents(outcome.directory, MeetingEventKind.captureRestarted).first)
        #expect(restarted.details["reason"] == GapReason.sleep.rawValue)
        let timeline = try SessionTimelineReader.read(session: outcome.directory)
        #expect(timeline.gaps.map(\.reason) == [.sleep])
    }

    /// Asleep for 15 minutes or more: the recording ends at the sleep point with its audio saved.
    @Test(.timeLimit(.minutes(1)))
    func longSleepEndsTheRecordingAtTheSleepPoint() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let power = RecorderFakePower()
        let clock = ManualSessionClock(0)
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 10))])
        var dependencies = recorderDependencies(captures: captures, clock: clock)
        dependencies.power = power
        let run = recorderRecordOnly(temp.url, dependencies)
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 10 && power.attached })
        clock.set(1)
        power.post(.willSleep(token: 5))
        #expect(await eventually { power.allowed == [5] })
        clock.set(1_201)
        power.post(.didWake)
        let outcome = try await run.value
        #expect(outcome.stopReason == .sleepTimeout)
        #expect(captures.captures.count == 1, "No capture after the sleep.")
        let chunks = try SessionArchive.readManifest(at: outcome.directory).chunks
        #expect(chunks.map(\.end) == [1.0], "The audio before the sleep is saved.")
        #expect(try recorderEvents(outcome.directory, MeetingEventKind.didWake).first?.details["action"] == "finalize")
        #expect(recorderStatus(outcome.directory)?.exit?.reason == .sleepTimeout)
    }

    /// The idle-sleep assertion is taken at start, let go while paused, and taken again on resume.
    @Test(.timeLimit(.minutes(1)))
    func powerAssertionFollowsPause() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let names = SharedValue<[String]>([])
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3)),
                                           FakeCaptureScript(frames: FakeFrame.run(count: 3))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.makePowerAssertion = { name in
            names.update { $0.append(name) }
            return nil
        }
        let run = recorderRecordOnly(temp.url, dependencies)
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
        #expect(names.value == ["Holos meeting recording"])
        let session = try #require(await recorderSession(in: temp.url))
        #expect(try await recorderSend(.pause, to: session)?.result == .applied)
        #expect(names.value.count == 1, "Paused: no assertion is taken.")
        #expect(try await recorderSend(.resume, to: session)?.result == .applied)
        #expect(await eventually { names.value.count == 2 })
        stop.requestStop()
        _ = try await run.value
        #expect(names.value.count == 2, "Held through the stop path; not taken again.")
    }

    /// A waiting recorder retries at once when the screen unlocks or the audio device list changes.
    @Test(.timeLimit(.minutes(1)))
    func retryOnScreenUnlockAndDeviceChange() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let environment = AudioEnvironmentEvents.silent()
        let captures = FakeCaptureFactory([
            FakeCaptureScript(frames: FakeFrame.run(count: 2), failAfterFrames: 2, failure: .io("Gone.")),
            FakeCaptureScript(startError: .unavailable("Screen locked.")),
            FakeCaptureScript(frames: FakeFrame.run(count: 2), failAfterFrames: 2, failure: .io("Gone again.")),
            FakeCaptureScript(frames: FakeFrame.run(count: 2)),
        ])
        let stop = ManualStopSource()
        // The session clock stands still, so no scheduled retry comes due: only the environment can restart capture.
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.environmentEvents = environment
        let run = recorderRecordOnly(temp.url, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        func waits() -> Int { (try? recorderEvents(session, MeetingEventKind.captureWaiting).count) ?? 0 }
        #expect(await eventually { waits() == 1 })
        #expect(captures.captures.count == 2)
        environment.post(AudioEnvironmentEvents.screenUnlocked)
        #expect(await eventually { captures.captures.count >= 3 }, "retryNow → startCapture")
        // Epoch 2 fails too; the recorder waits again until the device list changes.
        #expect(await eventually { waits() == 2 })
        #expect(captures.captures.count == 3)
        environment.post(AudioEnvironmentEvents.audioDevicesChanged)
        #expect(await eventually { captures.captures.count == 4 && captures.captures[3].consumedFrames >= 2 })
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        #expect(try recorderEvents(outcome.directory, MeetingEventKind.captureWaiting).count == 2)
    }

    /// The lid opening while the recorder waits for audio retries at once.
    @Test(.timeLimit(.minutes(1)))
    func lidOpeningRetriesAWaitingRecorder() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let power = RecorderFakePower(lidOpen: false)
        let captures = FakeCaptureFactory([
            FakeCaptureScript(frames: FakeFrame.run(count: 2), failAfterFrames: 2, failure: .io("Gone.")),
            FakeCaptureScript(startError: .unavailable("No audio device.")),
            FakeCaptureScript(frames: FakeFrame.run(count: 2)),
        ])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.power = power
        let run = recorderRecordOnly(temp.url, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { (try? recorderEvents(session, MeetingEventKind.captureWaiting).count) == 1 })
        #expect(captures.captures.count == 2)
        power.setLid(open: true)
        #expect(await eventually { captures.captures.count == 3 && captures.captures[2].consumedFrames >= 2 })
        stop.requestStop()
        #expect(try await run.value.stopReason == .requested)
    }
}
