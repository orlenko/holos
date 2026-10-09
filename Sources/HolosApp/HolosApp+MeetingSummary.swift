import AppKit
import Darwin
import Foundation
import HolosCore
import HolosDictation
import HolosMeeting
import HolosStorage
import os

/// Meeting titles and summaries in the app (docs/meeting-design.md §4.17): `voiceislocal session summarize` runs in the
/// background for one meeting at a time, as `MeetingSummarySchedule` picks them, once a meeting's transcript is final
/// and again when a final transcript replaces it. Nothing here blocks or slows a meeting's save: nothing starts while a
/// meeting starts, records or saves, and a run going on when one starts is stopped (nothing is written then) and made
/// again afterwards.
@MainActor
final class MeetingSummaryAppState {
    /// Settings › Meetings › "Title and summarize meetings with Apple Intelligence"; on unless turned off.
    static let enabledKey = "meetingSummaries"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The meeting summarized now and the child's handle (nil while it starts).
    var running: (sessionID: String, child: CommandHandle?)?
    /// The key (transcript and speakers' names) each meeting was last tried with when no summary came of it (failed),
    /// so it is not tried again until that key changes; kept until the app quits.
    var attempted: [String: String] = [:]
    /// Meetings refused for now (busy, transcript changed, stopped for a meeting): skipped until then.
    var delayedUntil: [String: Date] = [:]
    /// Summarize Again, newest last: saved on every change, and kept until the run ends for good (written, current,
    /// failed, unavailable), so a request that had to wait (a meeting started, another job ran, the app quit) runs
    /// later, forced. Each has a random ID, which its run writes into summary.json, so one a command finished while
    /// the app was closed is recognized as done (`MeetingSummarySchedule.satisfied`).
    static let requestsKey = "meetingSummaryRequestQueue"
    var requests: [MeetingSummarySchedule.Request] = MeetingSummaryAppState.loadRequests() {
        didSet {
            UserDefaults.standard.set(try? HolosJSON.encoder(pretty: false).encode(requests), forKey: Self.requestsKey)
        }
    }

    /// The meetings asked for, oldest first.
    var requested: [String] { requests.map(\.sessionID) }

    func removeRequest(_ sessionID: String) {
        requests.removeAll { $0.sessionID == sessionID }
    }

    private static func loadRequests() -> [MeetingSummarySchedule.Request] {
        let loaded = MeetingSummarySchedule.decodeRequests(UserDefaults.standard.data(forKey: requestsKey))
        // Requests saved before they had IDs got theirs now: saved at once, before anything can run them.
        if let migrated = loaded.migrated { UserDefaults.standard.set(migrated, forKey: requestsKey) }
        return loaded.requests
    }

    /// The people store could not be used for good (a newer build wrote it): no summary starts until it changes, and
    /// Settings and the Meetings list say why.
    var peopleStoreProblem: String?
    /// The run going now was stopped because a meeting started.
    var preempted: String?
    var scanning = false
    /// The launch's final-transcript reconciliation has queued the meetings saved while the app was closed (or had
    /// none to do): until then no summary starts, so none is made of a transcript a final one is about to replace.
    var launchReady = false
    /// Final-transcript reconciliations running (at launch, when the model is installed, when the setting is turned
    /// on): no summary starts while one runs, since it may queue a final transcript of the meeting.
    var reconciling = 0
    /// Meetings whose Review was asked for while this app summarizes them: opened when the summary ends.
    var reviewAfterRun: [String: (directory: URL, name: String)] = [:]
    var timer: Timer?
}

extension HolosAppDelegate {
    private static let summaryLog = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    /// At launch: looks for meetings to summarize every 30 s (the first look a little after launch).
    func setUpMeetingSummaries() {
        meeting.summaries.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleMeetingSummaries() }
        }
        // With final transcripts off nothing is reconciled at launch; otherwise the model check reconciles and then
        // opens the way (`meetingSummaryLaunchReconciled`).
        if !DeepTranscriptionAppState.enabled { meetingSummaryLaunchReconciled() }
    }

    /// The launch's final-transcript reconciliation ended (or was not needed): summaries may start.
    func meetingSummaryLaunchReconciled() {
        guard !meeting.summaries.launchReady else { return }
        meeting.summaries.launchReady = true
        scheduleMeetingSummaries()
    }

    /// A final-transcript reconciliation starts: summaries wait for it, and one running now is stopped (it writes
    /// nothing) and made again afterwards, if its meeting is not queued for a final transcript meanwhile.
    func meetingSummaryReconcileStarted() {
        meeting.summaries.reconciling += 1
        if let running = meeting.summaries.running, meeting.summaries.preempted == nil,
           running.child?.terminate() == true {
            meeting.summaries.preempted = running.sessionID
        }
    }

    /// The reconciliation ended (its meetings are queued): summaries may start again.
    func meetingSummaryReconcileEnded() {
        meeting.summaries.reconciling = max(0, meeting.summaries.reconciling - 1)
        meeting.summaries.launchReady = true
        scheduleMeetingSummaries()
    }

    /// Why Apple Intelligence cannot summarize meetings on this Mac, for Settings; nil when it can.
    var meetingSummaryUnavailableReason: String? {
        OnDeviceFix.unavailableReason ?? meeting.summaries.peopleStoreProblem
    }

    /// Settings › Meetings › "Title and summarize meetings with Apple Intelligence".
    func toggleMeetingSummaries() {
        MeetingSummaryAppState.enabled.toggle()
        if MeetingSummaryAppState.enabled {
            // Meetings that failed before are tried once more.
            meeting.summaries.attempted = [:]
            scheduleMeetingSummaries()
        }
        updateSettings()
    }

    /// Meetings › Summarize Again: made next (forced), also with the setting off.
    func summarizeMeetingAgain(_ summary: SessionSummary) {
        meeting.summaries.removeRequest(summary.id)
        meeting.summaries.requests.append(MeetingSummarySchedule.Request(sessionID: summary.id))
        meeting.summaries.delayedUntil[summary.id] = nil
        scheduleMeetingSummaries()
    }

    /// Meetings › Cancel Summarize: the request is dropped, and a run of it going now stops (SIGTERM; nothing is
    /// written).
    func cancelMeetingSummary(_ sessionID: String) {
        meeting.summaries.removeRequest(sessionID)
        if let running = meeting.summaries.running, running.sessionID == sessionID {
            running.child?.terminate()
        }
    }

    /// A meeting is starting, recording, or saving: a summary being made now is stopped (it writes nothing) and made
    /// again once the meeting is saved.
    func meetingSummaryMeetingStateChanged() {
        guard let controller = meeting.controller, meetingIsBusy(controller.state),
              let running = meeting.summaries.running, meeting.summaries.preempted == nil,
              running.child?.terminate() == true else { return }
        meeting.summaries.preempted = running.sessionID
        Self.summaryLog.notice("Summary of \(running.sessionID, privacy: .public) stopped for a meeting")
    }

    /// Looks for the next meeting to summarize (off the main actor) and starts it when `MeetingSummarySchedule` says
    /// so.
    func scheduleMeetingSummaries() {
        guard let controller = meeting.controller, meeting.maintenance != nil, !meeting.summaries.scanning,
              meeting.summaries.running == nil else { return }
        // The setting and the model are `MeetingSummarySchedule.next`'s to weigh: transcript files left without their
        // summary are rewritten without them (no model call).
        guard meeting.summaries.launchReady, meeting.summaries.reconciling == 0,
              !meetingIsBusy(controller.state) else { return }
        meeting.summaries.scanning = true
        let root = controller.root
        let requested = meeting.summaries.requested
        Task { [weak self] in
            let scan = await Task.detached { () -> PeopleStoreScan in
                // People's names and Remember voices, once per scan: a summary whose names changed is made again. A
                // people store that cannot be read stops the scan: no key is made up from no names (every meeting
                // that names someone would look out of date); one a newer build wrote stops summaries until it
                // changes.
                let voice: SessionSummarizeCommand.VoiceInputs
                do {
                    voice = try SessionSummarizeCommand.VoiceInputs.read()
                } catch {
                    let terminal = SessionSummarizeCommand.peopleStoreStatus(error) == .failed
                    return .unreadable(terminal ? "the people store: \(error.localizedDescription)" : nil)
                }
                let candidates = MeetingSummarySchedule.scan(root: root, profileNames: voice.names,
                                                             recognition: voice.recognition, selfName: voice.selfName)
                // A requested meeting the scan did not list is gone only when no folder holds it, whatever the
                // folder's name: one whose manifest cannot be read now (or a sessions folder not there) keeps it.
                let listed = Set(candidates.map(\.sessionID))
                let gone = Set(requested.filter {
                    !listed.contains($0) && SessionCatalog.hasSession($0, in: root) == false
                })
                return .scanned(candidates, gone)
            }.value
            guard let self else { return }
            self.meeting.summaries.scanning = false
            switch scan {
            case .unreadable(let problem):
                // Transient (nil): looked at again at the next scan. For good: said once, in Settings and the list.
                if let problem, problem != self.meeting.summaries.peopleStoreProblem {
                    self.meeting.summaries.peopleStoreProblem = problem
                    self.updateSettings()
                    self.meeting.meetingsPane?.refresh()
                }
            case .scanned(let candidates, let gone):
                if self.meeting.summaries.peopleStoreProblem != nil {
                    self.meeting.summaries.peopleStoreProblem = nil
                    self.updateSettings()
                    self.meeting.meetingsPane?.refresh()
                }
                self.startNextMeetingSummary(candidates, gone: gone)
            }
            self.meetingSummaryScanEnded()
        }
    }

    /// A Make Final Transcript Now pass is queued (or its languages are being read) and could start (the setting and power do not hold it back; its
    /// meeting is not in use or delayed, and the model is installed): asked-for work goes before automatic summaries.
    func askedForPassWaiting(inUse: Set<String>, now: Date) -> Bool {
        guard meeting.deep.model == "installed", meeting.deep.retryAfter.map({ $0 <= now }) ?? true else { return false }
        // One whose languages are still being read (`pending`, saved so the request survives a quit) counts too: it
        // is about to join the queue.
        if meeting.deep.queue.pending.contains(where: \.runNow) { return true }
        return meeting.deep.queue.items.contains { item in
            item.runNow && !inUse.contains(item.sessionID)
                && (meeting.deep.delayed[item.sessionID].map { $0 <= now } ?? true)
        }
    }

    /// A scan's result: the meetings, or a people store it could not read (with the reason when that is for good).
    private enum PeopleStoreScan: Sendable {
        case scanned([MeetingSummarySchedule.Candidate], Set<String>)
        case unreadable(String?)
    }

    /// An echo analysis or automatic final transcript held back for this scan (`waitsForSummaryScan`) is looked at
    /// again: it starts unless the scan started a summary (then it waits for it).
    private func meetingSummaryScanEnded() {
        if meeting.echo.waitsForSummaryScan {
            meeting.echo.waitsForSummaryScan = false
            scheduleEchoCatchUp()
        }
        guard meeting.deep.waitsForSummaryScan else { return }
        meeting.deep.waitsForSummaryScan = false
        scheduleDeepTranscription()
    }

    private func startNextMeetingSummary(_ candidates: [MeetingSummarySchedule.Candidate], gone: Set<String>) {
        // A reconciliation that began while the folder was scanned holds summaries back; the next look starts one.
        guard let controller = meeting.controller, let commands = meeting.commands,
              meeting.summaries.running == nil, meeting.summaries.launchReady,
              meeting.summaries.reconciling == 0 else { return }
        let now = Date()
        meeting.summaries.delayedUntil = meeting.summaries.delayedUntil.filter { $0.value > now }
        // A request for a meeting that is gone (`gone`, by the scan) is dropped, and so is one a summary made since
        // already answers (a command that finished while the app was closed).
        let satisfied = MeetingSummarySchedule.satisfied(meeting.summaries.requests, by: candidates)
        meeting.summaries.requests.removeAll { gone.contains($0.sessionID) || satisfied.contains($0.sessionID) }
        let inUse = Set(controller.sessionsInUse.keys).union(controller.sessionsUnderReview())
        let situation = MeetingSummarySchedule.Situation(
            enabled: MeetingSummaryAppState.enabled, modelAvailable: OnDeviceFix.unavailableReason == nil,
            meetingBusy: meetingIsBusy(controller.state),
            // This app's echo analysis counts as a job running (one at a time, §5.11).
            deepPassRunning: meeting.deep.running != nil || DeepTranscriptionLock.state() != .free
                || meeting.echo.running != nil,
            running: nil,
            inUse: inUse, attempted: meeting.summaries.attempted, delayedUntil: meeting.summaries.delayedUntil,
            requested: meeting.summaries.requested, onBattery: PowerSource.current() == .battery,
            finalTranscriptQueued: Set((meeting.deep.queue.items + meeting.deep.queue.pending).map(\.sessionID))
                .union(meeting.deep.deciding),
            askedForPassWaiting: askedForPassWaiting(inUse: inUse, now: now),
            now: now)
        guard case .run(let sessionID, let path, let force) = MeetingSummarySchedule.next(candidates, situation)
        else { return }
        // A call's missing echo analysis goes before an automatic summary (§5.11); Summarize Again does not wait.
        if !meeting.summaries.requested.contains(sessionID), echoCatchUpReady() {
            scheduleEchoCatchUp()
            return
        }
        // A failure is remembered by the meeting's key (transcript and speakers' names): either changing makes it
        // due again.
        let key = candidates.first { $0.sessionID == sessionID }?.key
        // Marked running before the meeting is taken: taking it schedules again (`onSessionsInUseChanged`), which must
        // then see a summary running and start nothing else. The meeting is held for the whole run, as for a final
        // transcript, so Review and the meeting's commands wait and its speaker labels cannot change under it.
        meeting.summaries.running = (sessionID, nil)
        guard controller.beginUsing(sessionID, for: Self.summaryRunningText) else {
            meeting.summaries.running = nil
            meeting.summaries.delayedUntil[sessionID] = Date().addingTimeInterval(60)
            return
        }
        do {
            // Run for a Summarize Again: its ID goes into summary.json, so the request is known answered.
            let answers = meeting.summaries.requests.last { $0.sessionID == sessionID }.map {
                ["--answers-request", $0.id]
            } ?? []
            let child = try commands.start(["session", "summarize", path, "--json"] + (force ? ["--force"] : [])
                                               + answers,
                                           output: "summary", errors: "summary-err", maxOutputBytes: 4 << 20,
                                           as: SessionSummarizeCommand.Outcome.self) { [weak self] result in
                self?.meetingSummaryEnded(sessionID, key: key, result)
            }
            meeting.summaries.running = (sessionID, child)
            Self.summaryLog.notice("Summary of \(sessionID, privacy: .public) started")
        } catch {
            meeting.summaries.running = nil
            meeting.summaries.delayedUntil[sessionID] = Date().addingTimeInterval(60)
            controller.endUsing(sessionID)
            Self.summaryLog.error("Cannot start the summary: \(error.localizedDescription, privacy: .private)")
        }
        meeting.meetingsPane?.update(summarizing: meeting.summaries.running?.sessionID)
    }

    private func meetingSummaryEnded(_ sessionID: String, key: String?,
                                     _ result: CommandResult<SessionSummarizeCommand.Outcome>) {
        let code = result.code
        let outcome = result.outcome
        let preempted = meeting.summaries.preempted == sessionID
        if preempted { meeting.summaries.preempted = nil }
        meeting.summaries.running = nil
        let status = outcome?.status
        let requested = meeting.summaries.requested.contains(sessionID)
        // A result the command reports decides: a summary it saved counts even when a meeting started at the very
        // end (SIGTERM cannot stop the save). Without one, a run stopped for a meeting is tried again.
        if status.map(\.retriesLater) ?? preempted {
            // Stopped for a meeting, held by another command or job, or the transcript changed: tried again in a
            // minute, and a request stays.
            meeting.summaries.delayedUntil[sessionID] = Date().addingTimeInterval(60)
        } else {
            // Done for good: written, up to date, failed, or Apple Intelligence cannot be used for it.
            meeting.summaries.removeRequest(sessionID)
            // A summary saved clears an earlier failure of the same transcript.
            if status == .written { meeting.summaries.attempted[sessionID] = nil }
            if status == .written, code != 0 {
                // Saved, but its transcript files were not rewritten (`exportsPending`): rewritten later, without the
                // model, after a delay.
                meeting.summaries.delayedUntil[sessionID] = Date().addingTimeInterval(300)
            } else if code != 0, let key {
                // A failure is not tried again automatically for this transcript and these names.
                meeting.summaries.attempted[sessionID] = key
            }
            // Asked for from the meeting's menu and not made: the user is told why (as Make Final Transcript Now),
            // for example a language Apple Intelligence does not support.
            if requested, code != 0, status != .written {
                showSummaryAlert("The meeting was not summarized.",
                                 outcome?.message ?? "The summary command stopped (code \(code)).")
            }
        }
        Self.summaryLog.notice("Summary of \(sessionID, privacy: .public) ended with \(code, privacy: .public) (\(outcome?.status.rawValue ?? "no result", privacy: .public))")
        meeting.controller?.endUsing(sessionID)
        meeting.maintenanceEnded[sessionID, default: 0] += 1
        // A new generated title may be the one the meeting shows: an open Review window takes it.
        refreshReviewTitle(sessionID)
        meeting.meetingsPane?.update(summarizing: nil)
        meeting.meetingsPane?.refresh()
        // Review asked for while the summary was made.
        if let review = meeting.summaries.reviewAfterRun.removeValue(forKey: sessionID) {
            openReview(sessionID: sessionID, directory: review.directory, name: review.name)
        }
        // A final transcript waits while a summary runs (they share the background job lock), and so does an echo
        // analysis. Summaries are looked for first, so one the user asked for goes before the next automatic job
        // (which waits for the scan).
        scheduleMeetingSummaries()
        scheduleEchoCatchUp()
        scheduleDeepTranscription()
    }

    /// What the Meetings list shows while a summary is made (`MeetingController.beginUsing`).
    static let summaryRunningText = "Writing summary…"

    /// Review asked for while a summary is made of the meeting: by this app (its `sessionsInUse` entry), or by another
    /// process (the lock's holder, a summary). Review would show labels the summary is being made from, so it waits:
    /// the alert says so and offers to cancel this app's summary; Review opens when it ends. Returns whether it waits.
    func reviewWaitsForSummary(sessionID: String, directory: URL, name: String) -> Bool {
        let own = meeting.summaries.running?.sessionID == sessionID
            && meeting.controller?.sessionsInUse[sessionID] == Self.summaryRunningText
        var other = false
        if !own, case .held(let holder?) = DeepTranscriptionLock.state(), holder.isSummary {
            other = holder.sessionID == sessionID
        }
        guard own || other else { return false }
        let alert = NSAlert()
        alert.messageText = "Summary in progress"
        if own {
            alert.informativeText = "“\(Self.short(name))” is being summarized. Review opens when it finishes."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel Summary")
            meeting.summaries.reviewAfterRun[sessionID] = (directory, name)
        } else {
            alert.informativeText = "“\(Self.short(name))” is being summarized by another Voice is Local process. "
                + "Open Review when it finishes."
        }
        NSApplication.shared.activate()
        // Cancel Summary: the summary stops, and Review opens once it has let go of the meeting.
        if alert.runModal() == .alertSecondButtonReturn { cancelMeetingSummary(sessionID) }
        return true
    }

    private func showSummaryAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApplication.shared.activate()
        alert.runModal()
    }
}
