import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// The stall watchdog (docs/meeting-design.md §4.2).

private func warning(_ code: RecorderWarningCode, _ message: String) -> RecorderEffect {
    .warn(RecorderWarning(code: code, message: message, since: RecorderMachine.placeholderDate))
}

private func tick(_ at: Double, _ lastFrameAt: [String: Double]) -> RecorderInput {
    .tick(at: at, lidOpen: true, freeBytes: nil, lastFrameAt: lastFrameAt)
}

/// A machine recording `tracks` whose epoch 0 started at 0 and delivered its first frame at 0.1.
private func watchedMachine(_ tracks: [String]) -> RecorderMachine {
    var machine = RecorderMachine(tracks: tracks)
    _ = machine.handle(.captureStarted(epoch: 0, tracks: tracks, at: 0))
    _ = machine.handle(.captureRunning(epoch: 0, at: 0.1))
    return machine
}

@Test func watchdogFlagsAfterThreeSecondsAndClears() {
    var watchdog = TrackWatchdog()
    watchdog.startEpoch(at: 0, tracks: ["mic"])
    #expect(watchdog.evaluate(lastFrameAt: ["mic": 10.0], now: 12.9) == ([], [], []))
    #expect(watchdog.evaluate(lastFrameAt: ["mic": 10.0], now: 13.1) == (["mic"], [], []))
    #expect(watchdog.stalledTracks == ["mic"])
    #expect(watchdog.evaluate(lastFrameAt: ["mic": 10.0], now: 13.2) == ([], [], []), "Reported once.")
    #expect(watchdog.evaluate(lastFrameAt: ["mic": 13.5], now: 13.6) == ([], ["mic"], []))
    #expect(watchdog.stalledTracks.isEmpty)
}

@Test func stallTimerStartsAtTheEpochStart() {
    var watchdog = TrackWatchdog()
    // Frames from the previous epoch arrived long ago; the new epoch's timer starts at its own start.
    watchdog.startEpoch(at: 100, tracks: ["mic", "system"])
    #expect(watchdog.evaluate(lastFrameAt: ["mic": 20, "system": 20], now: 102.9) == ([], [], []))
    #expect(watchdog.evaluate(lastFrameAt: ["mic": 20, "system": 20], now: 103) == (["mic", "system"], [], []))
    #expect(watchdog.silentSeconds("mic", now: 104) == 4)
    // A track the epoch does not record is not watched.
    watchdog.startEpoch(at: 110, tracks: ["system"])
    #expect(watchdog.stalledTracks == ["system"], "Still stalled until it delivers.")
    #expect(watchdog.silentSeconds("mic", now: 111) == nil)
}

@Test func stalledMicRestartsInNewEpoch() {
    var machine = watchedMachine(["mic"])
    for second in 11...12 {
        #expect(machine.handle(tick(Double(second), ["mic": 10.0])).isEmpty)
    }
    #expect(machine.handle(tick(13, ["mic": 10.0])) == [
        .recordEvent(kind: MeetingEventKind.trackStalled, details: ["track": "mic", "silentSeconds": "3.0"]),
        warning(.trackStalled, "No audio from the microphone for more than 3 s."),
    ])
    #expect(machine.stalledTracks == ["mic"])
    for second in 14...19 {
        #expect(machine.handle(tick(Double(second), ["mic": 10.0])).isEmpty)
    }
    #expect(machine.handle(tick(20, ["mic": 10.0]))
        == [.stopCapture(reason: .captureRestarted), .startCapture(epoch: 1)])
    #expect(machine.phase == .recording)
    #expect(machine.handle(tick(20.5, ["mic": 10.0])).isEmpty, "Not watched while the new epoch starts.")
    // The new epoch starts; the microphone is still reported stalled until it delivers.
    #expect(machine.handle(.captureStarted(epoch: 1, tracks: ["mic"], at: 21)).isEmpty)
    #expect(machine.handle(tick(22, ["mic": 21.5])) == [
        .recordEvent(kind: MeetingEventKind.trackResumed, details: ["track": "mic"]),
        .clearWarning(.trackStalled),
    ])
    #expect(machine.stalledTracks.isEmpty)
}

/// Review finding (PR14): epoch 0's capture starts but no frame ever arrives, so the machine stays `starting`. The
/// watchdog still runs there: the microphone is flagged after 3 s and restarted in a new epoch after 10 s.
@Test func firstFrameStallWarnsThenRestarts() {
    var machine = RecorderMachine(tracks: ["mic"])
    #expect(machine.handle(tick(5, [:])).isEmpty, "Nothing is watched before capture has started.")
    #expect(machine.handle(.captureStarted(epoch: 0, tracks: ["mic"], at: 10)).isEmpty)
    #expect(machine.phase == .starting)
    for second in 11...12 {
        #expect(machine.handle(tick(Double(second), [:])).isEmpty)
    }
    #expect(machine.handle(tick(13, [:])) == [
        .recordEvent(kind: MeetingEventKind.trackStalled, details: ["track": "mic", "silentSeconds": "3.0"]),
        warning(.trackStalled, "No audio from the microphone for more than 3 s."),
    ])
    #expect(machine.phase == .starting)
    for second in 14...19 {
        #expect(machine.handle(tick(Double(second), [:])).isEmpty)
    }
    #expect(machine.handle(tick(20, [:])) == [.stopCapture(reason: .captureRestarted), .startCapture(epoch: 1)])
    #expect(machine.phase == .recording)
    #expect(machine.stopReason == nil)
    // The new epoch delivers: the stall clears, and the late end of epoch 0 changes nothing.
    #expect(machine.handle(.captureEnded(epoch: 0, .requested, at: 20.1)).isEmpty)
    _ = machine.handle(.captureStarted(epoch: 1, tracks: ["mic"], at: 20.5))
    _ = machine.handle(.captureRunning(epoch: 1, at: 20.6))
    #expect(machine.handle(tick(21, ["mic": 20.6])) == [
        .recordEvent(kind: MeetingEventKind.trackResumed, details: ["track": "mic"]),
        .clearWarning(.trackStalled),
    ])
    #expect(machine.handle(tick(31, ["mic": 30.9])) == [.clearWarning(.audioUnavailable)],
            "Ten seconds of audio: the restart attempts reset.")
}

/// A microphone that never delivers a frame, in any epoch, is restarted with backoff and the recording ends after
/// 10 minutes without audio instead of staying stuck.
@Test func firstFrameNeverArrivingEndsAfterTenMinutes() {
    var machine = RecorderMachine(tracks: ["mic"])
    _ = machine.handle(.captureStarted(epoch: 0, tracks: ["mic"], at: 0))
    var restarts: [Double] = []
    var at = 0.0
    while machine.stopReason == nil, at < 2_000 {
        at += 1
        if machine.handle(tick(at, [:])).contains(.stopCapture(reason: .captureRestarted)) {
            restarts.append(at)
            _ = machine.handle(.captureStarted(epoch: machine.epoch, tracks: ["mic"], at: at))
        }
    }
    #expect(restarts == [10, 30, 70, 150, 310])
    #expect(machine.stopReason == .captureFailed)
    #expect(at == 610, "600 s after the first restart of a frameless epoch.")
}

/// A microphone that stays silent after a restart is restarted after 20 s, then 40 s, not every 10 s.
@Test func silentMicrophoneRestartsLessOften() {
    var machine = watchedMachine(["mic"])
    var restarts: [Double] = []
    for second in 1...200 {
        let now = Double(second)
        if machine.handle(tick(now, [:])).contains(.stopCapture(reason: .captureRestarted)) {
            restarts.append(now)
            // The new epoch starts at once and stays silent too.
            _ = machine.handle(.captureStarted(epoch: machine.epoch, tracks: ["mic"], at: now))
        }
    }
    #expect(restarts == [10, 30, 70, 150])
}

@Test func systemTrackIsNeverRestartedForStall() {
    var machine = watchedMachine(["mic", "system"])
    var all: [RecorderEffect] = []
    for second in 1...30 {
        // The microphone keeps delivering; system audio is silent.
        all += machine.handle(tick(Double(second), ["mic": Double(second) - 0.05]))
    }
    #expect(all == [
        .recordEvent(kind: MeetingEventKind.trackStalled, details: ["track": "system", "silentSeconds": "3.0"]),
        warning(.trackStalled, "No system audio for more than 3 s; nothing may be playing."),
    ])
    #expect(machine.stalledTracks == ["system"])
    #expect(machine.epoch == 0)
}

@Test func pausingClearsAStallWarning() {
    var machine = watchedMachine(["mic"])
    _ = machine.handle(tick(4, [:]))
    #expect(machine.stalledTracks == ["mic"])
    let pause = recorderRequest(.pause)
    let paused = machine.handle(.control(pause, at: 5))
    #expect(paused.contains(.clearWarning(.trackStalled)))
    #expect(machine.stalledTracks.isEmpty)
    #expect(machine.handle(tick(30, [:])).isEmpty, "Nothing is watched while paused.")
    // After resume, the timers start with the new epoch.
    _ = machine.handle(.control(recorderRequest(.resume), at: 40))
    _ = machine.handle(.captureStarted(epoch: 1, tracks: ["mic"], at: 41))
    #expect(machine.handle(tick(43.9, [:])).isEmpty)
    #expect(machine.handle(tick(44, [:])).first
        == .recordEvent(kind: MeetingEventKind.trackStalled, details: ["track": "mic", "silentSeconds": "3.0"]))
}

@Test func stallWarningNamesEveryStalledTrack() {
    var machine = watchedMachine(["mic", "system"])
    #expect(machine.handle(tick(3, ["mic": 2.9])).last
        == warning(.trackStalled, "No system audio for more than 3 s; nothing may be playing."))
    #expect(machine.stalledTracks == ["system"])
    #expect(machine.handle(tick(6, ["mic": 2.9])).last
        == warning(.trackStalled, "No audio from the microphone or system audio for more than 3 s."))
    #expect(machine.stalledTracks == ["mic", "system"])
    // One track back: the warning names the other; both back: it is cleared.
    #expect(machine.handle(tick(7, ["mic": 6.9])).last
        == warning(.trackStalled, "No system audio for more than 3 s; nothing may be playing."))
    #expect(machine.handle(tick(8, ["mic": 7.9, "system": 7.9])).last == .clearWarning(.trackStalled))
}

extension RecorderEnvironmentLoopTests {
    /// A slow startup (here 1.5 s of speech-session setup before capture starts) is not on the session timeline, so it
    /// never looks like a stall: the stall timer starts when epoch 0's capture has started.
    @Test(.timeLimit(.minutes(1)))
    func slowStartIsNotAStall() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let slow = FakeSpeechFactory()
        let speech: LiveSpeechFactory = { locale, backend, strings, onUpdate in
            try await Task.sleep(for: .milliseconds(1_500))
            return try await slow.factory(locale, backend, strings, onUpdate)
        }
        let captures = FakeCaptureFactory([FakeCaptureScript(continuous: FakeFrame(start: 0))])
        let stop = ManualStopSource()
        let stalled = SharedValue(false)
        var tuning = recorderFastTuning()
        // A stall limit shorter than the startup delay: a timer started before capture would fire at the first tick.
        tuning.watchdog = TrackWatchdog(stallSeconds: 1, restartSeconds: 100)
        let observer: @Sendable (RecorderStatus) -> Void = { status in
            if status.warnings.contains(where: { $0.code == .trackStalled }) || status.tracks.contains(where: \.stalled) {
                stalled.set(true)
            }
        }
        // The real-time session clock (made when epoch 0's capture has started).
        let dependencies = recorderDependencies(captures: captures, speech: speech, stop: stop, tuning: tuning,
                                                statusObserver: observer)
        let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 6 })
        stop.requestStop()
        let outcome = try await run.value
        #expect(!stalled.value)
        #expect(try recorderEvents(outcome.directory, MeetingEventKind.trackStalled).isEmpty)
    }

    /// Through the loop: a microphone that stops delivering is flagged, restarted in a new epoch, and cleared when the
    /// new epoch delivers.
    @Test(.timeLimit(.minutes(1)))
    func stalledMicrophoneRestartsThroughTheLoop() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let clock = ManualSessionClock(0)
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3)),
                                           FakeCaptureScript(frames: FakeFrame.run(count: 3))])
        let stop = ManualStopSource()
        let run = Task {
            try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
                dependencies: recorderDependencies(captures: captures, stop: stop, clock: clock))
        }
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
        clock.set(3.5)
        #expect(await eventually { recorderStatus(session)?.warnings.contains { $0.code == .trackStalled } == true })
        #expect(await eventually { recorderStatus(session)?.tracks.first?.stalled == true })
        clock.set(10.5)
        #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 3 })
        clock.set(11)
        #expect(await eventually { recorderStatus(session)?.warnings.contains { $0.code == .trackStalled } == false })
        stop.requestStop()
        let outcome = try await run.value
        let stalls = try recorderEvents(outcome.directory, MeetingEventKind.trackStalled)
        #expect(stalls.map { $0.details["track"] } == ["mic"])
        let resumed = try recorderEvents(outcome.directory, MeetingEventKind.trackResumed)
        #expect(resumed.map { $0.details["track"] } == ["mic"])
        let gaps = try recorderEvents(outcome.directory, MeetingEventKind.audioDiscontinuity)
        #expect(gaps.map { $0.details["reason"] } == [GapReason.captureRestarted.rawValue])
    }

    /// Through the loop (review finding, PR14): epoch 0 starts but never delivers a frame. The recorder stays
    /// `starting`, warns after 3 s, and restarts the microphone in a new epoch after 10 s.
    @Test(.timeLimit(.minutes(1)))
    func firstFrameStallRestartsThroughTheLoop() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let clock = ManualSessionClock(0)
        let captures = FakeCaptureFactory([FakeCaptureScript(), FakeCaptureScript(frames: FakeFrame.run(count: 3))])
        let stop = ManualStopSource()
        let run = Task {
            try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
                dependencies: recorderDependencies(captures: captures, stop: stop, clock: clock))
        }
        #expect(await eventually { captures.captures.count == 1 })
        let session = try #require(await recorderSession(in: temp.url))
        // The loop answers requests only once it runs, after epoch 0's stall timers started at session time 0; the
        // answer also shows the recorder is still starting.
        let marker = try #require(try await recorderSend(.marker, to: session))
        #expect(marker.result == .rejected)
        #expect(marker.message == "The recording is still starting.")
        clock.set(3.5)
        #expect(await eventually { recorderStatus(session)?.warnings.contains { $0.code == .trackStalled } == true })
        #expect(recorderStatus(session)?.phase == .starting)
        clock.set(10.5)
        #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 3 })
        clock.set(11)
        #expect(await eventually { recorderStatus(session)?.phase == .recording })
        #expect(await eventually { recorderStatus(session)?.warnings.contains { $0.code == .trackStalled } == false })
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        let stalls = try recorderEvents(outcome.directory, MeetingEventKind.trackStalled)
        #expect(stalls.map { $0.details["track"] } == ["mic"])
        let resumed = try recorderEvents(outcome.directory, MeetingEventKind.trackResumed)
        #expect(resumed.map { $0.details["track"] } == ["mic"])
        #expect(try recorderEvents(outcome.directory, MeetingEventKind.startFailed).isEmpty)
    }
}
