import Darwin
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import os

/// The echo catch-up in the app (docs/meeting-design.md §5.11, "Catching up in the app"): calls recorded before the
/// acoustic echo analysis existed, or whose analysis failed, get `voiceislocal session echo-analyze` in the background,
/// newest first, one meeting at a time, as `EchoCatchUpSchedule` picks them. The queue is read from the meetings'
/// files (at launch and after each meeting is saved), never saved: a run a quit cut short leaves the analysis missing,
/// so the next launch finds it again. No setting: it takes about 5 s per hour of audio.
@MainActor
final class EchoCatchUpAppState {
    /// The meetings found needing the analysis, newest first; each leaves it when its run ends.
    var queue: [EchoCatchUpSchedule.Candidate] = []
    /// The meeting analysed now (this app's own child).
    var running: String?
    /// The running child's handle (nil while it starts), which signals it only until the app reaps it: used only when
    /// a meeting starts.
    var child: CommandHandle?
    /// The run was stopped because a meeting started: it stays queued and runs again once the meeting is saved.
    var preempted: String?
    var scanning = false
    /// The first scan of this launch ended: until then the queue is not known yet, and automatic final transcripts
    /// and summaries wait for it (they would be made from labels a call's echo analysis is about to change).
    var scanned = false
    /// A scan was asked for while one ran: it runs again once that one ends.
    var scanAgain = false
    /// How the runs that did not finish in this launch ended (failed: not tried again until the next launch;
    /// partial: the analysis was saved, something after it was not), for the Meetings list. Kept until the app quits.
    var problems: [String: EchoCatchUpSchedule.RunEnd] = [:]
    /// Meetings whose run was turned down because another process held them: how many times in a row, and when they
    /// are tried again (`EchoCatchUpSchedule.retryDelay`).
    var turnedDown: [String: (attempts: Int, until: Date)] = [:]
    /// Starting the command failed (a transient process limit): nothing starts before this.
    var retryAfter: Date?
    /// Held back for the summary scan going on, which may start a summary the user asked for (asked-for work goes
    /// first): looked at again when the scan ends.
    var waitsForSummaryScan = false
    var timer: Timer?

    /// Meetings whose run ended in this launch, however it ended: queued again only at the next launch (a scan that
    /// still finds one, as a partial run's transcript files or voice samples out of step with the mask, would
    /// otherwise retry it after every saved meeting).
    var ended: Set<String> = []
    /// Meetings not tried again before the next launch: every run that ended in this launch.
    var failed: Set<String> {
        ended.union(problems.compactMap { id, end in
            switch end {
            case .failed, .partial: return id
            default: return nil
            }
        })
    }
}

extension HolosAppDelegate {
    private static let echoLog = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    /// At launch: looks for calls that miss their echo analysis, and every 30 s tries the queue again (a meeting a
    /// review held, one turned down for now, or one that waited for another job).
    func setUpEchoCatchUp() {
        meeting.echo.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEchoCatchUp() }
        }
        scanEchoCatchUp()
    }

    /// Reads the meetings off the main actor (`EchoCatchUpSchedule.scan`) and makes the result the queue. A scan
    /// asked for while one runs runs once more after it.
    func scanEchoCatchUp() {
        guard let root = meeting.controller?.root else { return }
        guard !meeting.echo.scanning else {
            meeting.echo.scanAgain = true
            return
        }
        meeting.echo.scanning = true
        Task { [weak self] in
            let found = await Task.detached { EchoCatchUpSchedule.scan(root: root, profiles: SpeakerProfileStore()) }.value
            guard let self else { return }
            self.meeting.echo.scanning = false
            self.meeting.echo.scanned = true
            // A meeting analysed since the scan read it is checked again before its run starts.
            self.meeting.echo.queue = found
            if !found.isEmpty {
                Self.echoLog.notice("Echo catch-up: \(found.count, privacy: .public) calls miss their echo analysis")
            }
            if self.meeting.echo.scanAgain {
                self.meeting.echo.scanAgain = false
                self.scanEchoCatchUp()
            }
            self.updateEchoStates()
            self.scheduleEchoCatchUp()
            // The automatic jobs held back while the queue was not known go on (or keep waiting for a call it found).
            if !self.meeting.echo.scanning {
                self.scheduleMeetingSummaries()
                self.scheduleDeepTranscription()
            }
        }
    }

    /// Whether a queued meeting could be analysed now were no other job running (not in use, under review, failed in
    /// this launch, or turned down for now), or a scan has not ended (the first of the launch, or one after a meeting
    /// was saved: the queue is not known yet): an automatic final transcript or summary then waits for it.
    func echoCatchUpReady() -> Bool {
        guard let controller = meeting.controller else { return false }
        // A scan going on (the first of the launch, or one after a meeting was saved) may find a call to analyse.
        if meeting.echo.scanning || (!meeting.echo.scanned && controller.root != nil) { return true }
        guard meeting.echo.running == nil, !meeting.echo.queue.isEmpty else { return false }
        let now = Date()
        if let retryAfter = meeting.echo.retryAfter, retryAfter > now { return false }
        return !EchoCatchUpSchedule.ready(meeting.echo.queue, echoSituation(controller, now: now)).isEmpty
    }

    private func echoSituation(_ controller: MeetingController, now: Date) -> EchoCatchUpSchedule.Situation {
        // Review owns a meeting while it is open, opening, or still saving.
        let inUse = Set(controller.sessionsInUse.keys).union(controller.sessionsUnderReview())
        // A Summarize Again the summary scan going on may start goes first.
        let summaryAsked = meeting.summaries.scanning && !meeting.summaries.requests.isEmpty
        return EchoCatchUpSchedule.Situation(
            meetingBusy: meetingIsBusy(controller.state),
            otherJobRunning: meeting.deep.running != nil || meeting.summaries.running != nil
                || DeepTranscriptionLock.state() != .free,
            askedForWorkWaiting: summaryAsked || askedForPassWaiting(inUse: inUse, now: now),
            running: meeting.echo.running, inUse: inUse, failed: meeting.echo.failed,
            delayedUntil: meeting.echo.turnedDown.mapValues(\.until), now: now)
    }

    /// Starts the next run when `EchoCatchUpSchedule` says so. One job at a time on this Mac: not while a meeting
    /// starts, records or saves, while this app makes a final transcript or a summary, or while any process holds the
    /// background job lock (the command holds it too, so a run left going from before a relaunch holds the queue
    /// back); a final transcript or summary the user asked for goes first.
    func scheduleEchoCatchUp() {
        guard let controller = meeting.controller, meeting.maintenance != nil, meeting.echo.running == nil,
              !meeting.echo.queue.isEmpty else { return }
        let now = Date()
        if let retryAfter = meeting.echo.retryAfter, retryAfter > now { return }
        meeting.echo.retryAfter = nil
        let situation = echoSituation(controller, now: now)
        let decision = EchoCatchUpSchedule.next(meeting.echo.queue, situation)
        if decision == .wait, meeting.summaries.scanning, !meeting.summaries.requests.isEmpty {
            meeting.echo.waitsForSummaryScan = true
        }
        guard case .run(let candidate) = decision else { return }
        let sessionID = candidate.sessionID
        // Marked running before the meeting is taken: taking it schedules again (`onSessionsInUseChanged`), which must
        // then see this run and start no other job.
        meeting.echo.running = sessionID
        guard controller.beginUsing(sessionID, for: EchoCatchUpSchedule.runningText) else {
            meeting.echo.running = nil
            echoTurnedDown(sessionID)
            return
        }
        // A review that opens while it runs opens read-only and rereads the meeting when it ends (`ReviewMaintenance`):
        // none holds the meeting now (the schedule skips meetings under review).
        meeting.maintenanceOn[sessionID] = ReviewMaintenance.Hold(.echoAnalysis)
        updateEchoStates()
        let directory = URL(fileURLWithPath: candidate.path)
        Task { [weak self] in
            // Made since the scan (a relabel, Recover, a run in Terminal), or deleted: nothing to run.
            let needed = await Task.detached {
                EchoCatchUpSchedule.needsAnalysis(session: directory, profiles: SpeakerProfileStore())
            }.value
            guard let self else { return }
            guard needed else {
                // Nothing to do: a result from earlier in this launch (a partial run) stays in the list.
                self.echoCatchUpEnded(sessionID, end: .done, keepsProblem: true)
                return
            }
            // A meeting started while the files were read: it has the Mac to itself; this one stays queued.
            if let controller = self.meeting.controller, self.meetingIsBusy(controller.state) {
                self.echoCatchUpEnded(sessionID, end: nil)
                return
            }
            self.runEchoAnalyze(sessionID, path: candidate.path)
        }
    }

    /// Runs `voiceislocal session echo-analyze <path> --json` as a maintenance command: the analysis, the transcript
    /// files and the voice samples learned from the meeting, exactly as the command does them.
    private func runEchoAnalyze(_ sessionID: String, path: String) {
        guard let commands = meeting.commands else {
            echoCatchUpEnded(sessionID, end: nil)
            return
        }
        do {
            meeting.echo.child = try commands.start(["session", "echo-analyze", path, "--json"], output: "echo",
                                                    errors: "echo-err", maxOutputBytes: 1 << 20,
                                                    as: SessionEchoAnalyzeCommand.Outcome.self) { [weak self] result in
                self?.echoAnalyzeExited(sessionID, result)
            }
            Self.echoLog.notice("Echo analysis of \(sessionID, privacy: .public) started")
        } catch {
            // Kept queued: the scheduler tries again in a minute.
            meeting.echo.retryAfter = Date().addingTimeInterval(60)
            Self.echoLog.error("Cannot start the echo analysis: \(error.localizedDescription, privacy: .private)")
            echoCatchUpEnded(sessionID, end: nil)
        }
    }

    /// A meeting is starting, recording, or saving: this app's echo analysis running now is stopped (SIGTERM; the
    /// command stops before or while the voice samples are recomputed, which can take minutes, and leaves what it did
    /// not finish for the next run) and stays queued, so the meeting has the Mac to itself; it runs again once the
    /// meeting is saved. A run another process started is left alone: it is the user's own (or one from before a
    /// relaunch).
    func echoCatchUpMeetingStateChanged() {
        guard let controller = meeting.controller, meetingIsBusy(controller.state),
              let running = meeting.echo.running, meeting.echo.preempted == nil,
              meeting.echo.child?.terminate() == true else { return }
        meeting.echo.preempted = running
        Self.echoLog.notice("Echo analysis of \(running, privacy: .public) stopped for a meeting")
    }

    private func echoAnalyzeExited(_ sessionID: String, _ result: CommandResult<SessionEchoAnalyzeCommand.Outcome>) {
        let code = result.code
        let preempted = meeting.echo.preempted == sessionID
        Self.echoLog.notice("Echo analysis of \(sessionID, privacy: .public) ended with \(code, privacy: .public)")
        echoCatchUpEnded(sessionID, end: EchoCatchUpSchedule.runEnded(code: code, preempted: preempted,
                                                                      summary: result.outcome?.summary,
                                                                      errors: result.errors))
    }

    /// The run on the meeting ended (`end`), or did not start (nil: it stays queued as it was, as does one stopped for
    /// a meeting). The meeting is let go of: a review opened meanwhile rereads it, so its labels and playback follow
    /// the new mask, and the next job is looked for (summaries first, so a Summarize Again goes before the next
    /// automatic job).
    private func echoCatchUpEnded(_ sessionID: String, end: EchoCatchUpSchedule.RunEnd?, keepsProblem: Bool = false) {
        switch end {
        case .retryLater?:
            echoTurnedDown(sessionID)
        case .done?, .failed?, .partial?:
            meeting.echo.queue.removeAll { $0.sessionID == sessionID }
            meeting.echo.ended.insert(sessionID)
            meeting.echo.turnedDown[sessionID] = nil
            // Failed: the list says why, and it is not tried again in this launch. Partial: the list says what was
            // not brought in step.
            if !keepsProblem { meeting.echo.problems[sessionID] = end == .done ? nil : end }
        case .stopped?, nil:
            break
        }
        if case .failed? = end {
            Self.echoLog.error("Echo analysis of \(sessionID, privacy: .public) failed; tried again at the next launch")
        }
        meeting.echo.running = nil
        meeting.echo.child = nil
        meeting.echo.preempted = nil
        maintenanceFinished(sessionID)
        meeting.meetingsPane?.refresh()
        updateEchoStates()
        scheduleMeetingSummaries()
        scheduleEchoCatchUp()
        scheduleDeepTranscription()
    }

    /// Another process held the meeting or the background job lock (or it records again): it waits, longer each time
    /// in a row.
    private func echoTurnedDown(_ sessionID: String) {
        let attempts = (meeting.echo.turnedDown[sessionID]?.attempts ?? 0) + 1
        meeting.echo.turnedDown[sessionID] = (attempts, Date().addingTimeInterval(
            EchoCatchUpSchedule.retryDelay(attempts: attempts)))
    }

    /// The Meetings list's badges for queued meetings and its notes for runs that did not finish (the running one
    /// shows as its use of the meeting, `EchoCatchUpSchedule.runningText`).
    func updateEchoStates() {
        meeting.meetingsPane?.update(
            echoStates: EchoCatchUpSchedule.stateTexts(meeting.echo.queue, running: meeting.echo.running,
                                                       failed: meeting.echo.failed),
            problems: meeting.echo.problems)
    }
}
