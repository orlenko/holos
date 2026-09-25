import Foundation
@testable import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// Which microphone a meeting records (decision 9, docs/meeting-design.md §4.12).

private func hasWarning(_ session: URL, _ code: RecorderWarningCode) -> Bool {
    recorderStatus(session)?.warnings.contains { $0.code == code } == true
}

/// A capture that delivers `audio` when started and ends when the test says so, with the error it gives.
@MainActor
private final class MicrophoneTestCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    private let continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    private let audio: [FakeFrame]
    private(set) var request: CaptureRequest?

    init(_ audio: [FakeFrame]) {
        (frames, continuation) = AsyncThrowingStream<CapturedAudio, Error>.makeStream()
        self.audio = audio
    }

    var hostTimeOrigin: Double { 1_000 }

    func start(_ request: CaptureRequest) async throws {
        self.request = request
        for frame in audio { continuation.yield(try frame.captured(offset: request.timelineOffset)) }
    }

    func stop() async throws { continuation.finish() }

    /// Ends the stream as a failing capture or a device change would.
    nonisolated func end(throwing error: Error) { continuation.finish(throwing: error) }
}

/// Epoch 0 is `first`; later epochs come from `captures`.
@MainActor
private func firstThen(_ first: MicrophoneTestCapture, _ captures: FakeCaptureFactory)
    -> @MainActor @Sendable () -> any MeetingCapture {
    let made = SharedValue(0)
    return {
        let index = made.update { count -> Int in defer { count += 1 }; return count }
        return index == 0 ? first : captures.make()
    }
}

@Test func optionsChooseTheMicrophoneFromTheSource() throws {
    let root = URL(fileURLWithPath: "/tmp")
    #expect(RecordingOptions.testing(root: root, source: .microphone).microphone == .builtIn)
    #expect(RecordingOptions.testing(root: root, source: .microphoneAndSystem).microphone == .systemDefault)
    #expect(RecordingOptions.testing(root: root, source: .system).microphone == .systemDefault)
}

/// The machine's side of a call without an input device: a warning while the microphone is missing, a restart with it
/// on the next device-list change (not on other retries), and the warning cleared when it is back.
@Test func missingCallMicrophoneWarnsAndReturnsOnDeviceChange() {
    var machine = RecorderMachine(tracks: ["mic", "system"])
    let message = "Microphone unavailable; recording call audio only."
    #expect(machine.handle(.captureStarted(epoch: 0, tracks: ["system"], at: 0)) == [
        .warn(RecorderWarning(code: .microphoneUnavailable, message: message, since: RecorderMachine.placeholderDate)),
    ])
    #expect(machine.microphoneMissing)
    _ = machine.handle(.captureRunning(epoch: 0, at: 0.1))
    #expect(machine.handle(.retryNow(reason: AudioEnvironmentEvents.screenUnlocked, at: 5)).isEmpty)
    #expect(machine.handle(.retryNow(reason: AudioEnvironmentEvents.audioDevicesChanged, at: 6)) == [
        .recordEvent(kind: MeetingEventKind.deviceChanged,
                     details: ["track": "mic", "at": "6.0", "reason": AudioEnvironmentEvents.audioDevicesChanged]),
        .stopCapture(reason: .deviceChanged),
        .startCapture(epoch: 1),
    ])
    #expect(machine.handle(.retryNow(reason: AudioEnvironmentEvents.audioDevicesChanged, at: 6.1)).isEmpty,
            "Not again while the restart is in flight.")
    #expect(machine.handle(.captureStarted(epoch: 1, tracks: ["mic", "system"], at: 6.5))
        == [.clearWarning(.microphoneUnavailable)])
    #expect(!machine.microphoneMissing)
    #expect(machine.handle(.retryNow(reason: AudioEnvironmentEvents.audioDevicesChanged, at: 9)).isEmpty,
            "With the microphone, a device-list change needs no restart.")
}

/// A call epoch 0 without the microphone may deliver nothing while nothing plays, so the machine is still `starting`:
/// a device-list change restarts it with the microphone all the same.
@Test func missingCallMicrophoneReturnsBeforeTheFirstFrame() {
    var machine = RecorderMachine(tracks: ["mic", "system"])
    _ = machine.handle(.captureStarted(epoch: 0, tracks: ["system"], at: 0))
    #expect(machine.phase == .starting)
    #expect(machine.handle(.retryNow(reason: AudioEnvironmentEvents.screenUnlocked, at: 5)).isEmpty)
    #expect(machine.handle(.retryNow(reason: AudioEnvironmentEvents.audioDevicesChanged, at: 6)).suffix(2)
        == [.stopCapture(reason: .deviceChanged), .startCapture(epoch: 1)])
    #expect(machine.phase == .recording)
    #expect(machine.stopReason == nil)
    // Before capture has started, nothing restarts.
    var unstarted = RecorderMachine(tracks: ["mic", "system"])
    #expect(unstarted.handle(.retryNow(reason: AudioEnvironmentEvents.audioDevicesChanged, at: 1)).isEmpty)
}

/// A device change right after the start (before the first frame) restarts capture instead of failing the start.
@Test func configurationChangeBeforeTheFirstFrameRestarts() {
    var machine = RecorderMachine(tracks: ["mic"])
    _ = machine.handle(.captureStarted(epoch: 0, tracks: ["mic"], at: 0))
    let effects = machine.handle(.captureEnded(epoch: 0, .configurationChanged, at: 0.2))
    #expect(effects.suffix(2) == [.stopCapture(reason: .deviceChanged), .startCapture(epoch: 1)])
    #expect(machine.stopReason == nil)
    // Any other end before the first frame is still a failed start.
    var failing = RecorderMachine(tracks: ["mic"])
    #expect(failing.handle(.captureEnded(epoch: 0, .failed(message: "No input."), at: 0.2)).last
        == .finish(.startFailed))
}

/// Device changes that end every new epoch before its first frame (review finding: a change posted on each start)
/// back off into `waiting` like failures, and give up after 10 minutes without audio.
@Test func repeatedFramelessDeviceChangesBackOff() {
    var machine = RecorderMachine(tracks: ["mic"])
    _ = machine.handle(.captureStarted(epoch: 0, tracks: ["mic"], at: 0))
    #expect(machine.handle(.captureEnded(epoch: 0, .configurationChanged, at: 0.2)).last == .startCapture(epoch: 1))
    _ = machine.handle(.captureStarted(epoch: 1, tracks: ["mic"], at: 0.3))
    let second = machine.handle(.captureEnded(epoch: 1, .configurationChanged, at: 0.4))
    #expect(!second.contains(.startCapture(epoch: 2)), "The second frameless change does not restart at once.")
    #expect(second.contains(.stopCapture(reason: .audioUnavailable)))
    #expect(machine.phase == .waiting)
    var epoch = 1
    var at = 0.4
    // Every retry ends the same way: the waits grow, and the recorder never loops at full speed.
    while machine.stopReason == nil, at < 700 {
        at += 0.5
        let effects = machine.handle(recorderTick(at))
        guard case .startCapture(let next)? = effects.last else { continue }
        epoch = next
        _ = machine.handle(.captureStarted(epoch: epoch, tracks: ["mic"], at: at))
        _ = machine.handle(.captureEnded(epoch: epoch, .configurationChanged, at: at))
        #expect(machine.phase == .waiting)
    }
    #expect(machine.stopReason == .captureFailed)
    #expect(at >= 600.2 && at < 601, "Ends 10 minutes after the first frameless end.")
    #expect(epoch < 40, "Backoff: \(epoch) restarts in 10 minutes.")
}

/// An epoch that delivered audio before a device change restarts at once every time.
@Test func deviceChangesAfterAudioRestartAtOnce() {
    var machine = RecorderMachine(tracks: ["mic"])
    _ = machine.handle(.captureRunning(epoch: 0, at: 0.1))
    for epoch in 0..<5 {
        let at = Double(epoch) + 0.5
        #expect(machine.handle(.captureEnded(epoch: epoch, .configurationChanged, at: at)).last
            == .startCapture(epoch: epoch + 1))
        _ = machine.handle(.captureRunning(epoch: epoch + 1, at: at + 0.1))
    }
    #expect(machine.phase == .recording)
}

@Test func epochPlanFollowsTheDevices() {
    let inPerson = RecordingOptions.testing(root: URL(fileURLWithPath: "/tmp"), source: .microphone)
    let call = RecordingOptions.testing(root: URL(fileURLWithPath: "/tmp"), source: .microphoneAndSystem)
    let both = InputDevices(builtIn: recorderBuiltIn, systemDefault: recorderAirPods)
    #expect(EpochPlan.make(inPerson, devices: both)
        == EpochPlan(source: .microphone, tracks: ["mic"], microphoneName: "MacBook Pro Microphone"))
    #expect(EpochPlan.make(inPerson, devices: InputDevices(builtIn: nil, systemDefault: recorderAirPods)) == nil)
    // Lid closed: the built-in microphone may stay listed while it records silence (review finding).
    #expect(EpochPlan.make(inPerson, devices: both, lidOpen: false) == nil)
    #expect(EpochPlan.make(call, devices: both, lidOpen: false)
        == EpochPlan(source: .microphoneAndSystem, tracks: ["mic", "system"], microphoneName: "AirPods Pro"))
    #expect(EpochPlan.make(call, devices: both)
        == EpochPlan(source: .microphoneAndSystem, tracks: ["mic", "system"], microphoneName: "AirPods Pro"))
    #expect(EpochPlan.make(call, devices: InputDevices(builtIn: recorderBuiltIn, systemDefault: nil))
        == EpochPlan(source: .system, tracks: ["system"], microphoneName: nil))
}

extension RecorderEnvironmentLoopTests {
    @Test(.timeLimit(.minutes(1)))
    func inPersonPinsBuiltInMicrophone() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        // AirPods are connected and are the default input; in person still records the built-in microphone.
        dependencies.findInputDevices = RecorderDevices().lookup
        let run = recorderRecordOnly(temp.url, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
        #expect(recorderStatus(session)?.microphoneName == "MacBook Pro Microphone")
        #expect(recorderStatus(session)?.microphoneIsSystemDefault == false)
        stop.requestStop()
        _ = try await run.value
        #expect(captures.requests.map(\.microphone) == [.builtIn])
        #expect(captures.requests.map(\.source) == [.microphone])
        #expect(recorderStatus(session)?.microphoneName == "MacBook Pro Microphone")
    }

    @Test(.timeLimit(.minutes(1)))
    func callUsesSystemDefault() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: recorderCallFrames(count: 3))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        let run = recorderRecordOnly(temp.url, source: .microphoneAndSystem, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 6 })
        stop.requestStop()
        _ = try await run.value
        #expect(captures.requests.map(\.microphone) == [.systemDefault])
        #expect(captures.requests.map(\.source) == [.microphoneAndSystem])
        #expect(recorderStatus(session)?.microphoneName == "AirPods Pro")
    }

    @Test(.timeLimit(.minutes(1)))
    func inPersonRefusesWithoutBuiltIn() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory()
        var dependencies = recorderDependencies(captures: captures, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices(builtIn: nil, systemDefault: recorderAirPods).lookup
        var message: String?
        do {
            _ = try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies)
        } catch HolosError.unavailable(let text) {
            message = text
        }
        #expect(message == "The built-in microphone is unavailable. Open the lid and try again.")
        #expect(sessionFolders(in: temp.url).isEmpty, "No session folder.")
        #expect(captures.captures.isEmpty)
    }

    /// In person with the lid closed: refused even when the built-in microphone is still listed.
    @Test(.timeLimit(.minutes(1)))
    func inPersonRefusesWithTheLidClosed() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory()
        var dependencies = recorderDependencies(captures: captures, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        dependencies.power = RecorderFakePower(lidOpen: false)
        var message: String?
        do {
            _ = try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies)
        } catch HolosError.unavailable(let text) {
            message = text
        }
        #expect(message == BuiltInMicrophone.unavailableMessage)
        #expect(sessionFolders(in: temp.url).isEmpty, "No session folder.")
        #expect(captures.captures.isEmpty)
    }

    /// The capture's own lookup of the built-in microphone fails (the lid closed after the plan was made): the
    /// recorder still says how to continue.
    @Test(.timeLimit(.minutes(1)))
    func captureLookupFailureSaysToOpenTheLid() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([
            FakeCaptureScript(frames: FakeFrame.run(count: 2), failAfterFrames: 2, failure: .io("Gone.")),
            FakeCaptureScript(startError: .unavailable(BuiltInMicrophone.unavailableMessage)),
            FakeCaptureScript(startError: .unavailable(BuiltInMicrophone.unavailableMessage)),
        ])
        let stop = ManualStopSource()
        let dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        let run = recorderRecordOnly(temp.url, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { recorderStatus(session)?.phase == .waiting })
        let warning = recorderStatus(session)?.warnings.first { $0.code == .audioUnavailable }
        #expect(warning?.message == RecorderMachine.builtInMicrophoneOff)
        stop.requestStop()
        #expect(try await run.value.stopReason == .requested)
    }

    /// A call does not need the built-in microphone (review finding P4).
    @Test(.timeLimit(.minutes(1)))
    func callStartAllowedWithoutBuiltInMic() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: recorderCallFrames(count: 2))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices(builtIn: nil, systemDefault: recorderAirPods).lookup
        let run = recorderRecordOnly(temp.url, source: .microphoneAndSystem, dependencies)
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 4 })
        stop.requestStop()
        #expect(try await run.value.stopReason == .requested)
        #expect(captures.requests.map(\.source) == [.microphoneAndSystem])
    }

    /// The call's microphone disappears (no input device left): capture restarts with system audio alone and warns; when
    /// a device is back, the device-list change restarts capture with the microphone.
    @Test(.timeLimit(.minutes(1)))
    func callWithoutAnyInputRecordsSystemOnly() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let devices = RecorderDevices(builtIn: nil, systemDefault: recorderAirPods)
        let environment = AudioEnvironmentEvents.silent()
        let clock = ManualSessionClock(0)
        let first = MicrophoneTestCapture(recorderCallFrames(count: 2))
        let captures = FakeCaptureFactory([
            FakeCaptureScript(frames: FakeFrame.run(track: "system", from: 0, count: 3)),
            FakeCaptureScript(frames: recorderCallFrames(count: 2)),
        ])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: clock,
                                                makeCapture: firstThen(first, captures))
        dependencies.findInputDevices = devices.lookup
        dependencies.environmentEvents = environment
        let run = recorderRecordOnly(temp.url, source: .microphoneAndSystem, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { recorderStatus(session)?.tracks.allSatisfy { $0.lastFrameSeconds != nil } == true })
        #expect(first.request?.source == .microphoneAndSystem)
        #expect(recorderStatus(session)?.microphoneName == "AirPods Pro")
        // The headset goes away and capture fails: the restart finds no input device at all.
        devices.set(builtIn: nil, systemDefault: nil)
        first.end(throwing: HolosError.io("Headset gone."))
        #expect(await eventually { captures.captures.count == 1 && captures.captures[0].consumedFrames >= 3 })
        #expect(captures.requests[0].source == .system, "Capture starts without the microphone.")
        #expect(await eventually { hasWarning(session, .microphoneUnavailable) })
        #expect(recorderStatus(session)?.warnings.first { $0.code == .microphoneUnavailable }?.message
            == "Microphone unavailable; recording call audio only.")
        #expect(await eventually { recorderStatus(session)?.microphoneName == nil })
        // A device-list change without an input device changes nothing.
        environment.post(AudioEnvironmentEvents.audioDevicesChanged)
        try await Task.sleep(for: .milliseconds(200))
        #expect(captures.captures.count == 1)
        // The headset is back.
        devices.set(builtIn: nil, systemDefault: recorderAirPods)
        clock.set(2)
        environment.post(AudioEnvironmentEvents.audioDevicesChanged)
        #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 4 })
        #expect(captures.requests[1].source == .microphoneAndSystem)
        #expect(await eventually { !hasWarning(session, .microphoneUnavailable) })
        #expect(recorderStatus(session)?.microphoneName == "AirPods Pro")
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        let changes = try recorderEvents(outcome.directory, MeetingEventKind.deviceChanged)
        #expect(changes.map { $0.details["reason"] } == [AudioEnvironmentEvents.audioDevicesChanged])
        let tracks = Set(try SessionArchive.readManifest(at: outcome.directory).chunks.map(\.track))
        #expect(tracks == ["mic", "system"])
    }

    /// In person, the built-in microphone goes away mid-recording (lid closed with an external display): the recorder
    /// waits, says how to continue, and resumes when the lid opens.
    @Test(.timeLimit(.minutes(1)))
    func inPersonWaitsForTheBuiltInMicrophone() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let devices = RecorderDevices(builtIn: recorderBuiltIn, systemDefault: recorderBuiltIn)
        let power = RecorderFakePower()
        let first = MicrophoneTestCapture(FakeFrame.run(count: 2))
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0),
                                                makeCapture: firstThen(first, captures))
        dependencies.findInputDevices = devices.lookup
        dependencies.power = power
        let run = recorderRecordOnly(temp.url, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { power.attached && recorderStatus(session)?.phase == .recording })
        // The lid closes; the built-in microphone disappears, and AVAudioEngine reports a configuration change.
        power.setLid(open: false)
        #expect(await eventually { power.lidSeen })
        devices.set(builtIn: nil, systemDefault: nil)
        first.end(throwing: CaptureInterruption.configurationChanged)
        #expect(await eventually { recorderStatus(session)?.phase == .waiting })
        let warning = recorderStatus(session)?.warnings.first { $0.code == .audioUnavailable }
        #expect(warning?.message == "The built-in microphone is off. Open the lid to continue recording.")
        #expect(captures.captures.isEmpty, "No capture is attempted without the built-in microphone.")
        // The lid opens and the microphone is back.
        devices.set(builtIn: recorderBuiltIn, systemDefault: recorderBuiltIn)
        power.setLid(open: true)
        #expect(await eventually { captures.captures.count == 1 && captures.captures[0].consumedFrames >= 3 })
        #expect(first.request?.microphone == .builtIn)
        #expect(captures.requests.map(\.microphone) == [.builtIn])
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        let waiting = try #require(try recorderEvents(outcome.directory, MeetingEventKind.captureWaiting).first)
        #expect(waiting.details["reason"] == "The built-in microphone is off. Open the lid to continue recording.")
        #expect(try recorderEvents(outcome.directory, MeetingEventKind.deviceChanged).count == 1)
    }
}
