import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// The menu bar's meeting state machine (docs/meeting-design.md §5.8 "Reducer rules").

private let reducerStart = Date(timeIntervalSince1970: 1_790_000_000)
private let reducerID = "3F2A9C1E-0000-4000-8000-000000000001"
private let reducerSettings = MeetingStartSettings(name: "Council meeting", source: .microphone)

/// A reducer that was asked to start `reducerID` at `reducerStart` and launched it.
private func startedReducer() -> MeetingReducer {
    var reducer = MeetingReducer()
    _ = reducer.reduce(.startRequested(reducerSettings, sessionID: reducerID, at: reducerStart))
    _ = reducer.reduce(.launched(pid: 4_242, at: reducerStart))
    return reducer
}

/// A fresh status of `reducerID` read `seconds` after the start.
private func read(_ phase: RecorderPhase, after seconds: Double = 10, exit: RecorderExit? = nil,
                  liveness: RecorderLiveness = .capturing) -> MeetingEvent {
    let at = reducerStart.addingTimeInterval(seconds)
    return .statusRead(meetingStatus(reducerID, phase: phase, updatedAt: at, elapsed: seconds, exit: exit),
                       liveness: liveness, at: at)
}

/// A reducer following a recording meeting.
private func activeReducer() -> MeetingReducer {
    var reducer = startedReducer()
    _ = reducer.reduce(read(.recording))
    return reducer
}

private func isFailed(_ state: MeetingState) -> String? {
    if case .failed(_, let message) = state { return message }
    return nil
}

@Test func startLaunchesAndPausesDictation() {
    var reducer = MeetingReducer()
    let effects = reducer.reduce(.startRequested(reducerSettings, sessionID: reducerID, at: reducerStart))
    #expect(reducer.state == .starting(sessionID: reducerID, since: reducerStart, pid: nil))
    #expect(effects == [.launch(reducerSettings, sessionID: reducerID), .setDictationPaused(true)])
    #expect(reducer.dictationShouldPause)
    _ = reducer.reduce(.launched(pid: 4_242, at: reducerStart))
    #expect(reducer.state == .starting(sessionID: reducerID, since: reducerStart, pid: 4_242))
}

@Test func recordingStatusMakesActive() {
    var reducer = startedReducer()
    let event = read(.recording)
    let effects = reducer.reduce(event)
    guard case .statusRead(let status?, _, _) = event else { return }
    #expect(reducer.state == .active(sessionID: reducerID, status: status))
    #expect(effects.isEmpty, "Dictation was already paused while starting.")
    #expect(reducer.dictationShouldPause)
}

@Test func missingFolderWhileStartingIsNotFailure() {
    var reducer = startedReducer()
    let at = reducerStart.addingTimeInterval(3)
    #expect(reducer.reduce(.statusRead(nil, liveness: .dead, at: at)).isEmpty)
    #expect(reducer.reduce(.tick(at: at)).isEmpty)
    #expect(reducer.state == .starting(sessionID: reducerID, since: reducerStart, pid: 4_242))
}

@Test func startingStatusKeepsStartingUntilRecording() {
    // The recorder says `starting` while permission prompts and speech setup run: the start is still pending.
    var reducer = startedReducer()
    #expect(reducer.reduce(read(.starting, after: 4)).isEmpty)
    #expect(reducer.state == .starting(sessionID: reducerID, since: reducerStart, pid: 4_242))
    #expect(reducer.reduce(.tick(at: reducerStart.addingTimeInterval(6))) == [.announce("Waiting for permission…")])
}

@Test func waitingForPermissionHint() {
    var reducer = startedReducer()
    #expect(reducer.reduce(.tick(at: reducerStart.addingTimeInterval(4))).isEmpty)
    #expect(reducer.reduce(.tick(at: reducerStart.addingTimeInterval(6))) == [.announce("Waiting for permission…")])
    #expect(reducer.reduce(.tick(at: reducerStart.addingTimeInterval(7))).isEmpty, "The hint is announced once.")
}

@Test func startTimesOutAfterTwoMinutes() {
    var reducer = startedReducer()
    let effects = reducer.reduce(.tick(at: reducerStart.addingTimeInterval(121)))
    #expect(effects.first == .terminateChild(sessionID: reducerID))
    #expect(effects.contains(.setDictationPaused(false)))
    let message = isFailed(reducer.state)
    #expect(message?.contains("did not start within 2 minutes") == true)
    #expect(message?.contains("~/Library/Logs/Holos/recorder-\(reducerID).log") == true)
    #expect(!reducer.dictationShouldPause)
}

@Test func childExitBeforeRecordingShowsLogTail() {
    var reducer = startedReducer()
    let tail = "The built-in microphone is unavailable. Open the lid and try again."
    let effects = reducer.reduce(.childExited(code: 1, logTail: tail, at: reducerStart.addingTimeInterval(2)))
    #expect(isFailed(reducer.state) == tail)
    #expect(isFailed(reducer.state)?.contains("Recover") == false)
    #expect(effects == [.setDictationPaused(false)])
}

@Test func childExitWithoutLogSaysNothingWasRecorded() {
    var reducer = startedReducer()
    _ = reducer.reduce(.childExited(code: 1, logTail: "  ", at: reducerStart.addingTimeInterval(2)))
    #expect(isFailed(reducer.state) == "The recorder stopped before recording started.")
}

@Test func freshStatusRecoversFromFailed() {
    var reducer = startedReducer()
    _ = reducer.reduce(.childExited(code: 1, logTail: "Slow start", at: reducerStart.addingTimeInterval(2)))
    #expect(isFailed(reducer.state) != nil)
    let event = read(.recording, after: 12)
    let effects = reducer.reduce(event)
    guard case .statusRead(let status?, _, _) = event else { return }
    #expect(reducer.state == .active(sessionID: reducerID, status: status))
    #expect(effects == [.setDictationPaused(true)])
}

@Test func staleOrOtherSessionStatusIsIgnored() {
    var reducer = startedReducer()
    // Written 30 s before it was read: stale.
    let stale = meetingStatus(reducerID, phase: .recording, updatedAt: reducerStart.addingTimeInterval(-20))
    #expect(reducer.reduce(.statusRead(stale, liveness: .capturing, at: reducerStart.addingTimeInterval(10))).isEmpty)
    let other = meetingStatus(UUID().uuidString, phase: .recording, updatedAt: reducerStart.addingTimeInterval(10))
    #expect(reducer.reduce(.statusRead(other, liveness: .capturing, at: reducerStart.addingTimeInterval(10))).isEmpty)
    // Fresh, but no lock is held behind it.
    let fresh = meetingStatus(reducerID, phase: .recording, updatedAt: reducerStart.addingTimeInterval(10))
    #expect(reducer.reduce(.statusRead(fresh, liveness: .maintenance, at: reducerStart.addingTimeInterval(10))).isEmpty)
    #expect(reducer.state == .starting(sessionID: reducerID, since: reducerStart, pid: 4_242))
}

@Test func stopWhileStartingTerminatesChild() {
    var reducer = startedReducer()
    #expect(reducer.reduce(.stopConfirmed) == [
        .terminateChild(sessionID: reducerID),
        .announce("Stopping. If macOS is asking for permission, the recorder stops once you answer the prompt."),
    ])
    #expect(reducer.stoppedWhileStarting)
    #expect(reducer.reduce(.stopConfirmed).isEmpty)
    // The child then ends before recording: the start was stopped, not failed.
    let effects = reducer.reduce(.childExited(code: 0, logTail: nil, at: reducerStart.addingTimeInterval(3)))
    #expect(reducer.state == .idle)
    #expect(effects.contains(.setDictationPaused(false)))
}

@Test func stopWhileWaitingForPermissionDoesNotTimeOut() {
    // The recorder notices the SIGTERM only once its start returns, after the permission prompt is answered: the
    // start timeout must not report a failure the user did not care about.
    var reducer = startedReducer()
    _ = reducer.reduce(.tick(at: reducerStart.addingTimeInterval(6)))
    _ = reducer.reduce(.stopConfirmed)
    #expect(reducer.reduce(.tick(at: reducerStart.addingTimeInterval(121))).isEmpty)
    #expect(reducer.reduce(.tick(at: reducerStart.addingTimeInterval(600))).isEmpty)
    #expect(reducer.state == .starting(sessionID: reducerID, since: reducerStart, pid: 4_242))
}

@Test func stopWhileStartingThenAllowIsAStopBeforeRecording() {
    // The prompt is answered 10 minutes later: the recorder starts capture, notices the SIGTERM in its first loop
    // pass, and stops (reason signal) with a moment of audio. That is what its real exit looks like.
    var reducer = startedReducer()
    _ = reducer.reduce(.stopConfirmed)
    _ = reducer.reduce(read(.recording, after: 600.2))
    guard case .active = reducer.state else {
        Issue.record("Expected active, got \(reducer.state).")
        return
    }
    #expect(reducer.reduce(.stopConfirmed).isEmpty, "The stop is already on its way.")
    _ = reducer.reduce(read(.transcribing, after: 600.4))
    let at = reducerStart.addingTimeInterval(601)
    let status = meetingStatus(reducerID, phase: .exited, updatedAt: at, elapsed: 0.4,
                               exit: RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .signal))
    let effects = reducer.reduce(.statusRead(status, liveness: .exited, at: at))
    #expect(reducer.state == .idle)
    #expect(effects.contains(.announce("The recording was stopped before it started.")))
    #expect(!effects.contains { if case .finished = $0 { true } else { false } })
}

@Test func stopWhileStartingThatRecordedIsSaved() {
    // Stopped while starting, but the recorder had already captured a few seconds when it noticed: a real meeting.
    var reducer = startedReducer()
    _ = reducer.reduce(.stopConfirmed)
    let at = reducerStart.addingTimeInterval(20)
    let status = meetingStatus(reducerID, phase: .exited, updatedAt: at, elapsed: 5,
                               exit: RecorderExit(archiveStatus: ArchiveStatus.incomplete, reason: .signal))
    let effects = reducer.reduce(.statusRead(status, liveness: .exited, at: at))
    #expect(reducer.state == .idle)
    #expect(effects.contains { if case .finished(reducerID, let summary, _) = $0 { summary.hasPrefix("Saved Council meeting (0:00:05).") } else { false } })
}

@Test func undeliveredStopCanBeRetried() {
    var reducer = activeReducer()
    #expect(reducer.reduce(.stopConfirmed) == [.send(.stop, label: nil, sessionID: reducerID)])
    reducer.stopWasNotDelivered()
    #expect(reducer.reduce(.stopConfirmed) == [.send(.stop, label: nil, sessionID: reducerID)])
}

@Test func captureStopResumesDictation() {
    var reducer = activeReducer()
    let event = read(.transcribing, after: 20)
    let effects = reducer.reduce(event)
    guard case .statusRead(let status?, _, _) = event else { return }
    #expect(reducer.state == .finishing(sessionID: reducerID, status: status))
    #expect(effects == [.setDictationPaused(false)])
}

@Test func exitedStatusFinishesAndOffersNaming() {
    var reducer = activeReducer()
    _ = reducer.reduce(read(.postprocessing, after: 20))
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: .succeeded,
                            postprocessingMessage: "Labelled 3 speakers in 12 turns.")
    let effects = reducer.reduce(read(.exited, after: 10_692, exit: exit, liveness: .exited))
    #expect(reducer.state == .idle)
    guard case .finished(let id, let summary, let ready) = effects.first else {
        Issue.record("Expected finished first, got \(effects).")
        return
    }
    #expect(id == reducerID)
    #expect(ready)
    #expect(summary.contains("Council meeting"))
    #expect(summary.hasPrefix("Saved Council meeting (2:58:12)."))
    #expect(summary.contains("Labelled 3 speakers"))
    #expect(effects.contains(.offerNaming(sessionID: reducerID, name: "Council meeting")))
}

@Test func exitWithoutSpeakerModelsSaysSoAndOffersNothing() {
    var reducer = activeReducer()
    let message = "No speaker labels: speaker models are not installed. Install them from Setup, or run holos setup --speakers."
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: .partial,
                            postprocessingMessage: message)
    let effects = reducer.reduce(read(.exited, after: 30, exit: exit, liveness: .exited))
    #expect(effects.contains(.finished(sessionID: reducerID, summary: "Saved Council meeting (0:00:30). \(message)",
                                       speakersReady: false)))
    #expect(!effects.contains { if case .offerNaming = $0 { true } else { false } })
    #expect(effects.contains(.setDictationPaused(false)))
}

@Test func exitedWithoutCaptureFailsWithTheRecordersMessage() {
    var reducer = startedReducer()
    let exit = RecorderExit(archiveStatus: ArchiveStatus.failed, reason: .startFailed,
                            message: "Microphone access was denied.")
    _ = reducer.reduce(read(.exited, after: 4, exit: exit, liveness: .exited))
    #expect(isFailed(reducer.state) == "Microphone access was denied.")
}

@Test func automaticStopIsExplained() {
    var reducer = activeReducer()
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .diskLow, postprocessing: nil)
    let effects = reducer.reduce(read(.exited, after: 60, exit: exit, liveness: .exited))
    guard case .finished(_, let summary, false)? = effects.first else {
        Issue.record("Expected finished, got \(effects).")
        return
    }
    #expect(summary.contains("free disk space fell below 500 MB"))
}

@Test func finishingDeadGoesIdle() {
    var reducer = activeReducer()
    _ = reducer.reduce(read(.postprocessing, after: 20))
    let effects = reducer.reduce(.statusRead(nil, liveness: .dead, at: reducerStart.addingTimeInterval(40)))
    #expect(reducer.state == .idle)
    #expect(effects == [.finished(sessionID: reducerID,
                                  summary: "Saved Council meeting. Speaker labelling stopped; Holos will retry it, or use Label Speakers in Meetings.",
                                  speakersReady: false)])
}

@Test func finishingWaitsWhileItsStatusIsStillRewritten() {
    // In-process mode: the labelling child released the lease; the recorder writes exited a moment later.
    var reducer = activeReducer()
    let event = read(.postprocessing, after: 20)
    _ = reducer.reduce(event)
    guard case .statusRead(let status?, _, _) = event else { return }
    #expect(reducer.reduce(.statusRead(status, liveness: .dead, at: reducerStart.addingTimeInterval(21))).isEmpty)
    #expect(reducer.state == .finishing(sessionID: reducerID, status: status))
    // No rewrite for 10 s: the recorder is gone.
    let effects = reducer.reduce(.statusRead(status, liveness: .dead, at: reducerStart.addingTimeInterval(31)))
    #expect(reducer.state == .idle)
    #expect(effects.first.map { if case .finished(_, _, false) = $0 { true } else { false } } == true)
}

@Test func deadWhileTranscribingPointsToRecovery() {
    var reducer = activeReducer()
    _ = reducer.reduce(read(.transcribing, after: 20))
    let effects = reducer.reduce(.childExited(code: 137, logTail: nil, at: reducerStart.addingTimeInterval(25)))
    guard case .finished(_, let summary, false)? = effects.first else {
        Issue.record("Expected finished, got \(effects).")
        return
    }
    #expect(summary.contains("Recover"))
}

@Test func deadRecorderFails() {
    var reducer = activeReducer()
    let effects = reducer.reduce(.statusRead(nil, liveness: .dead, at: reducerStart.addingTimeInterval(20)))
    #expect(isFailed(reducer.state) == "The recorder stopped unexpectedly. Recover the saved audio from Meetings.")
    #expect(effects == [.setDictationPaused(false)])
}

@Test func deadRecorderMarkedExitedByMaintenanceIsNotASave() {
    // `holos session recover` marks a dead recorder's status exited (reason interrupted) before the menu noticed.
    var reducer = activeReducer()
    let exit = RecorderExit(archiveStatus: ArchiveStatus.recording, reason: .interrupted,
                            message: "The recorder stopped unexpectedly.")
    let effects = reducer.reduce(read(.exited, after: 30, exit: exit, liveness: .maintenance))
    #expect(isFailed(reducer.state)?.contains("Recover") == true)
    #expect(!effects.contains { if case .finished = $0 { true } else { false } })
    // Once failed, the same status changes nothing.
    #expect(reducer.reduce(read(.exited, after: 31, exit: exit, liveness: .exited)).isEmpty)
}

@Test func childExitWhileRecordingFails() {
    var reducer = activeReducer()
    _ = reducer.reduce(.childExited(code: 137, logTail: nil, at: reducerStart.addingTimeInterval(20)))
    #expect(isFailed(reducer.state)?.contains("Recover") == true)
}

@Test func stopConfirmedSendsOnce() {
    var reducer = activeReducer()
    #expect(reducer.reduce(.stopConfirmed) == [.send(.stop, label: nil, sessionID: reducerID)])
    #expect(reducer.reduce(.stopConfirmed).isEmpty)
    #expect(reducer.reduce(.pauseRequested).isEmpty, "Nothing else is sent once a stop was.")
}

@Test func pauseResumeAndMarkerAreSent() {
    var reducer = activeReducer()
    #expect(reducer.reduce(.pauseRequested) == [.send(.pause, label: nil, sessionID: reducerID)])
    #expect(reducer.reduce(.resumeRequested) == [.send(.resume, label: nil, sessionID: reducerID)])
    #expect(reducer.reduce(.markerRequested(label: "Vote")) == [.send(.marker, label: "Vote", sessionID: reducerID)])
    var idle = MeetingReducer()
    #expect(idle.reduce(.pauseRequested).isEmpty)
}

@Test func reviewOpenedClearsOffer() {
    var reducer = activeReducer()
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: .succeeded)
    #expect(reducer.reduce(read(.exited, after: 30, exit: exit, liveness: .exited))
        .contains(.offerNaming(sessionID: reducerID, name: "Council meeting")))
    #expect(reducer.reduce(.reviewOpened(sessionID: reducerID)) == [.clearNamingOffer(sessionID: reducerID)])
}

@Test func startWhileRecordingIsRefused() {
    var reducer = activeReducer()
    let effects = reducer.reduce(.startRequested(reducerSettings, sessionID: UUID().uuidString, at: reducerStart))
    #expect(effects == [.announce("A meeting is already recording.")])
    guard case .active(let id, _) = reducer.state else {
        Issue.record("The recording must continue.")
        return
    }
    #expect(id == reducerID)
}

@Test func reattachedMeetingPausesDictation() {
    var reducer = MeetingReducer()
    let status = meetingStatus(reducerID, phase: .paused, updatedAt: reducerStart)
    #expect(reducer.reduce(.reattached(sessionID: reducerID, status: status)) == [.setDictationPaused(true)])
    #expect(reducer.state == .active(sessionID: reducerID, status: status))
    var labelling = MeetingReducer()
    let post = meetingStatus(reducerID, phase: .postprocessing, updatedAt: reducerStart)
    #expect(labelling.reduce(.reattached(sessionID: reducerID, status: post)).isEmpty)
    #expect(labelling.state == .finishing(sessionID: reducerID, status: post))
}

@Test func dismissFailureGoesIdle() {
    var reducer = startedReducer()
    _ = reducer.reduce(.launchFailed(message: "The holos tool is missing."))
    #expect(reducer.state == .failed(sessionID: nil, message: "The holos tool is missing."))
    _ = reducer.reduce(.dismissFailure)
    #expect(reducer.state == .idle)
}

@Test func menuLayoutIgnoresTheClockButNotTheLines() {
    let base = meetingStatus(reducerID, phase: .recording, updatedAt: reducerStart, elapsed: 60)
    func layout(_ status: RecorderStatus) -> MeetingMenuLayout {
        MeetingMenuLayout(.active(sessionID: reducerID, status: status))
    }
    // The next second's status: new clock, sizes, and free space, the same lines.
    var later = base
    later.sequence += 1
    later.updatedAt = reducerStart.addingTimeInterval(1)
    later.elapsedSeconds = 61
    later.recordedSeconds = 61
    later.bytesWritten = 5_000_000
    later.freeBytes = 20_000_000_000
    #expect(layout(later) == layout(base))
    var paused = later
    paused.phase = .paused
    #expect(layout(paused) != layout(base), "Pause Recording becomes Resume Recording.")
    var warned = later
    warned.warnings = [RecorderWarning(code: .audioDropped, message: "Some audio was dropped.")]
    #expect(layout(warned) != layout(base))
    var behind = later
    behind.tracks = [TrackStatus(track: "mic", transcription: .behind)]
    #expect(layout(behind) != layout(base))
    var otherMicrophone = later
    otherMicrophone.microphoneName = "AirPods Pro"
    #expect(layout(otherMicrophone) != layout(base))
    // Saving: the progress line changes in place.
    let transcribing = meetingStatus(reducerID, phase: .transcribing, updatedAt: reducerStart)
    let labelling = meetingStatus(reducerID, phase: .postprocessing, updatedAt: reducerStart.addingTimeInterval(30))
    #expect(MeetingMenuLayout(.finishing(sessionID: reducerID, status: transcribing))
        == MeetingMenuLayout(.finishing(sessionID: reducerID, status: labelling)))
    #expect(MeetingMenuLayout(.finishing(sessionID: reducerID, status: labelling)) != layout(base))
    #expect(MeetingMenuLayout(.failed(sessionID: reducerID, message: "One."))
        != MeetingMenuLayout(.failed(sessionID: reducerID, message: "Two.")))
    #expect(MeetingMenuLayout(.idle) == MeetingMenuLayout(.idle))
}

@Test func defaultNameUsesTheLocalMinute() {
    let date = Date(timeIntervalSince1970: 1_790_172_000)  // 2026-09-23 14:00 UTC
    #expect(MeetingStartSettings.defaultName(now: date, timeZone: TimeZone(identifier: "UTC")!)
        == "Meeting 2026-09-23 14:00")
    let normalized = MeetingStartSettings(name: "  ", source: .microphone, applicationBundleID: "us.zoom.xos",
                                          othersInRoom: true, expectedSpeakers: 50)
        .normalized(now: date, timeZone: TimeZone(identifier: "UTC")!)
    #expect(normalized == MeetingStartSettings(name: "Meeting 2026-09-23 14:00", source: .microphone))
}
