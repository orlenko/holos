import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// The recorder's pure state machine (docs/meeting-design.md §4.2).

private func warning(_ code: RecorderWarningCode, _ message: String) -> RecorderEffect {
    .warn(RecorderWarning(code: code, message: message, since: RecorderMachine.placeholderDate))
}

/// Fails the start of every epoch the machine asks for, feeding ticks at each retry time, until a retry would come
/// after `until`. Returns the retry delays it saw.
private func failStartsUntil(_ machine: inout RecorderMachine, until: Double) -> [Double] {
    var delays: [Double] = []
    while let retryAt = machine.retryAt, retryAt <= until {
        let effects = machine.handle(recorderTick(retryAt))
        guard case .startCapture(let epoch)? = effects.last else { break }
        for effect in machine.handle(.captureEnded(epoch: epoch, .startFailed(message: "No input device."), at: retryAt)) {
            if case .recordEvent(MeetingEventKind.captureWaiting, let details) = effect,
               let delay = details["retryInSeconds"].flatMap(Double.init) {
                delays.append(delay)
            }
        }
    }
    return delays
}

@Test func pauseResumeTransitions() {
    var machine = recorderRunningMachine()
    let pause = recorderRequest(.pause)
    #expect(machine.handle(.control(pause, at: 5)) == [
        .stopCapture(reason: .paused),
        .recordEvent(kind: MeetingEventKind.paused, details: ["at": "5.0"]),
        .holdPowerAssertion(false),
        recorderAck(pause, .applied),
    ])
    #expect(machine.phase == .paused)
    let again = recorderRequest(.pause)
    #expect(machine.handle(.control(again, at: 6)) == [recorderAck(again, .ignored, "Already paused.")])
    let resume = recorderRequest(.resume)
    #expect(machine.handle(.control(resume, at: 8)) == [
        .recordEvent(kind: MeetingEventKind.resumed, details: ["at": "8.0", "epoch": "1"]),
        .holdPowerAssertion(true),
        .startCapture(epoch: 1),
        recorderAck(resume, .applied),
    ])
    #expect(machine.phase == .recording)
    #expect(machine.epoch == 1)
}

@Test func stopIsIdempotent() {
    var machine = recorderRunningMachine()
    let first = recorderRequest(.stop)
    let second = recorderRequest(.stop)
    #expect(machine.handle(.control(first, at: 1)) == [recorderAck(first, .applied), .finish(.requested)])
    #expect(machine.handle(.control(second, at: 1)) == [recorderAck(second, .ignored, "The recorder is already stopping.")])
    #expect(machine.phase == .stopping)
    #expect(machine.stopReason == .requested)
    #expect(machine.handle(recorderTick(2)).isEmpty, "After finish, other inputs are ignored.")
    #expect(machine.handle(.signal(at: 3)).isEmpty)
}

@Test func markerWhilePausedIsApplied() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.control(recorderRequest(.pause), at: 10))
    let marker = recorderRequest(.marker, label: "Vote")
    #expect(machine.handle(.control(marker, at: 12.5)) == [
        .recordEvent(kind: MeetingEventKind.marker, details: ["at": "12.5", "requestID": marker.id, "label": "Vote"]),
        recorderAck(marker, .applied),
    ])
    #expect(machine.markers == 1)
    #expect(machine.phase == .paused)
}

@Test func configurationChangeStopsThenRestarts() {
    var machine = recorderRunningMachine()
    #expect(machine.handle(.captureEnded(epoch: 0, .configurationChanged, at: 3)) == [
        .recordEvent(kind: MeetingEventKind.deviceChanged,
                     details: ["track": "mic", "at": "3.0", "reason": "configurationChanged"]),
        warning(.deviceChanged, "Audio restarted after a device change; the gap is marked."),
        .stopCapture(reason: .deviceChanged),
        .startCapture(epoch: 1),
    ])
    #expect(machine.phase == .recording)
}

@Test func staleEpochEndIsIgnored() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.captureEnded(epoch: 0, .configurationChanged, at: 1))
    _ = machine.handle(.captureEnded(epoch: 1, .configurationChanged, at: 2))
    #expect(machine.epoch == 2)
    let before = machine
    #expect(machine.handle(.captureEnded(epoch: 1, .failed(message: "Late."), at: 3)).isEmpty)
    #expect(machine.handle(.captureRunning(epoch: 1, at: 3)).isEmpty)
    #expect(machine == before)
    #expect(machine.handle(.captureEnded(epoch: 2, .requested, at: 3)).isEmpty, "An end after stopCapture changes nothing.")
}

@Test func failuresBackOffIntoWaiting() {
    var machine = recorderRunningMachine()
    // The first failure restarts at once.
    #expect(machine.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 10)) == [
        .recordEvent(kind: MeetingEventKind.captureFailed, details: ["epoch": "0", "error": "Gone."]),
        .stopCapture(reason: .captureRestarted),
        .startCapture(epoch: 1),
    ])
    // The restart fails: waiting, with a retry half a second later.
    #expect(machine.handle(.captureEnded(epoch: 1, .startFailed(message: "No input device."), at: 10)) == [
        .recordEvent(kind: MeetingEventKind.captureFailed, details: ["epoch": "1", "error": "No input device."]),
        .stopCapture(reason: .audioUnavailable),
        .recordEvent(kind: MeetingEventKind.captureWaiting,
                     details: ["at": "10.0", "reason": "No input device.", "attempt": "1", "retryInSeconds": "0.5"]),
        warning(.audioUnavailable, "Audio is unavailable; retrying. The gap is marked."),
    ])
    #expect(machine.phase == .waiting)
    #expect(machine.handle(recorderTick(10.4)).isEmpty)
    // Three more start failures: 1, 2, and 4 s.
    var delays = [0.5]
    delays += failStartsUntil(&machine, until: 17.5)
    #expect(delays.prefix(4) == [0.5, 1, 2, 4])
    #expect(machine.stopReason == nil)
    #expect(machine.phase == .waiting)
}

@Test func waitingTimesOutAfterTenMinutes() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 100))
    _ = machine.handle(.captureEnded(epoch: 1, .startFailed(message: "No input device."), at: 100))
    let delays = failStartsUntil(&machine, until: 690)
    #expect(delays.last == 30, "Retries back off to every 30 s.")
    #expect(machine.phase == .waiting)
    #expect((machine.retryAt ?? 0) > 700)
    #expect(machine.handle(recorderTick(699)).isEmpty)
    #expect(machine.phase == .waiting)
    #expect(machine.handle(recorderTick(700)) == [.finish(.captureFailed)])
    #expect(machine.stopReason == .captureFailed)
}

@Test func retryNowStartsImmediately() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 0))
    _ = machine.handle(.captureEnded(epoch: 1, .startFailed(message: "No input device."), at: 0))
    _ = failStartsUntil(&machine, until: 3.5)
    #expect(machine.retryAt == 7.5, "The next retry is 4 s away.")
    #expect(machine.handle(.retryNow(reason: "screenUnlocked", at: 4.5)) == [.startCapture(epoch: 5)])
    #expect(machine.phase == .recording)
    #expect(machine.handle(.retryNow(reason: "audioDevicesChanged", at: 4.6)).isEmpty, "Only waiting retries.")
}

@Test func attemptsResetAfterTenSecondsOfAudio() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 5))
    _ = machine.handle(.captureRunning(epoch: 1, at: 5.2))
    #expect(machine.handle(recorderTick(10)).isEmpty, "Not yet 10 s of audio.")
    #expect(machine.handle(recorderTick(15.2)) == [.clearWarning(.audioUnavailable)])
    // The second failure restarts at once again instead of waiting.
    #expect(machine.handle(.captureEnded(epoch: 1, .failed(message: "Gone again."), at: 20)) == [
        .recordEvent(kind: MeetingEventKind.captureFailed, details: ["epoch": "1", "error": "Gone again."]),
        .stopCapture(reason: .captureRestarted),
        .startCapture(epoch: 2),
    ])
}

@Test func fastFailuresWithoutTenSecondsOfAudioWait() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 5))
    _ = machine.handle(.captureRunning(epoch: 1, at: 5.2))
    let effects = machine.handle(.captureEnded(epoch: 1, .failed(message: "Gone again."), at: 6))
    #expect(effects.contains(.stopCapture(reason: .audioUnavailable)))
    #expect(machine.phase == .waiting)
}

@Test func userStoppedSharingStops() {
    var machine = recorderRunningMachine()
    #expect(machine.handle(.captureEnded(epoch: 0, .userStoppedSharing, at: 9)) == [.finish(.requested)])
    #expect(machine.stopReason == .requested)
}

@Test func pauseTimesOutAfterSixHours() {
    var machine = recorderRunningMachine()
    _ = machine.handle(.control(recorderRequest(.pause), at: 100))
    #expect(machine.handle(recorderTick(21_699)).isEmpty)
    #expect(machine.handle(recorderTick(21_700)) == [.finish(.pauseTimeout)])
}

@Test func captureEndingBeforeItsFirstFrameIsAStartFailure() {
    var machine = RecorderMachine()
    #expect(machine.handle(.captureEnded(epoch: 0, .failed(message: "No display."), at: 0)) == [
        .recordEvent(kind: MeetingEventKind.startFailed, details: ["error": "No display."]),
        .finish(.startFailed),
    ])
}

/// The control table of §4.1 for the phases PR2a reaches.
@Test func controlCommandsFollowTheTable() {
    // starting: stop applies; pause, resume, and marker are rejected.
    var starting = RecorderMachine()
    for command in [ControlCommand.pause, .resume, .marker] {
        let request = recorderRequest(command)
        #expect(starting.handle(.control(request, at: 0)) == [recorderAck(request, .rejected, "The recording is still starting.")])
    }
    let stop = recorderRequest(.stop)
    #expect(starting.handle(.control(stop, at: 0)) == [recorderAck(stop, .applied), .finish(.requested)])

    // waiting: pause applies without stopping capture again; resume is ignored; a marker applies.
    var waiting = recorderRunningMachine()
    _ = waiting.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 1))
    _ = waiting.handle(.captureEnded(epoch: 1, .startFailed(message: "Gone."), at: 1))
    let resume = recorderRequest(.resume)
    #expect(waiting.handle(.control(resume, at: 2)) == [recorderAck(resume, .ignored, "Already restarting audio.")])
    let marker = recorderRequest(.marker)
    #expect(waiting.handle(.control(marker, at: 2)).last == recorderAck(marker, .applied))
    let pause = recorderRequest(.pause)
    let paused = waiting.handle(.control(pause, at: 3))
    #expect(!paused.contains(.stopCapture(reason: .paused)))
    #expect(paused.contains(.clearWarning(.audioUnavailable)))
    #expect(paused.last == recorderAck(pause, .applied))
    #expect(waiting.phase == .paused)
    #expect(waiting.handle(recorderTick(100)).isEmpty, "Retries stop while paused.")

    // recording: resume is ignored; a repeated request ID is ignored.
    var recording = recorderRunningMachine()
    let again = recorderRequest(.resume)
    #expect(recording.handle(.control(again, at: 1)) == [recorderAck(again, .ignored, "Already recording.")])
    #expect(recording.handle(.control(again, at: 2)) == [recorderAck(again, .ignored, "This request was already handled.")])
}

@Test func diskLowTickStopsTheRecording() {
    var machine = recorderRunningMachine()
    #expect(machine.handle(recorderTick(1, freeBytes: 10_000_000_000)).isEmpty)
    let warned = machine.handle(recorderTick(2, freeBytes: 1_900_000_000))
    #expect(warned.first == .recordEvent(kind: MeetingEventKind.diskLow,
                                         details: ["freeBytes": "1900000000", "action": "warn"]))
    #expect(machine.handle(recorderTick(3, freeBytes: 1_800_000_000)).isEmpty, "Warned once.")
    let stopped = machine.handle(recorderTick(4, freeBytes: 400_000_000))
    #expect(stopped.first == .recordEvent(kind: MeetingEventKind.diskLow,
                                          details: ["freeBytes": "400000000", "action": "stop"]))
    #expect(stopped.last == .finish(.diskLow))
}

/// The disk is checked while epoch 0 waits for its first frame and while waiting to retry, not only while recording.
@Test func diskLowIsCheckedWhileStartingAndWaiting() {
    var starting = RecorderMachine(tracks: ["mic"])
    _ = starting.handle(.captureStarted(epoch: 0, tracks: ["mic"], at: 0))
    #expect(starting.phase == .starting)
    #expect(starting.handle(recorderTick(1, freeBytes: 1_900_000_000)).first
        == .recordEvent(kind: MeetingEventKind.diskLow, details: ["freeBytes": "1900000000", "action": "warn"]))
    #expect(starting.handle(recorderTick(2, freeBytes: 400_000_000)).last == .finish(.diskLow))
    #expect(starting.stopReason == .diskLow)

    var waiting = recorderRunningMachine()
    _ = waiting.handle(.captureEnded(epoch: 0, .failed(message: "Gone."), at: 1))
    _ = waiting.handle(.captureEnded(epoch: 1, .startFailed(message: "Gone."), at: 1))
    #expect(waiting.phase == .waiting)
    let effects = waiting.handle(recorderTick(5, freeBytes: 400_000_000))
    #expect(effects.last == .finish(.diskLow))
    #expect(!effects.contains(.startCapture(epoch: 2)), "No retry once the disk is full.")
    #expect(waiting.stopReason == .diskLow)
}
