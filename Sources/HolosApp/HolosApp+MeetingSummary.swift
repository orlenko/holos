import AppKit
import Darwin
import Foundation
import HolosCore
import HolosDictation
import HolosMeeting
import HolosStorage
import os

/// Meeting titles and summaries in the app (docs/meeting-design.md §4.17): `voiceislocal session summarize` runs in the
/// background for one meeting at a time, once a meeting's transcript is final and again when a final transcript
/// replaces it. `MeetingSummaryJobs` keeps the requests and picks from its scans; `BackgroundJobCoordinator` runs them
/// with final transcripts and echo analyses. Nothing here blocks or slows a meeting's save: nothing starts while a
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

    /// Summarize Again, saved on every change (`MeetingSummaryJobs.requests`).
    static let requestsKey = "meetingSummaryRequestQueue"

    /// The requests, scans and failures of summaries.
    let jobs = MeetingSummaryJobs(requests: MeetingSummaryAppState.loadRequests(), save: { requests in
        UserDefaults.standard.set(try? HolosJSON.encoder(pretty: false).encode(requests), forKey: MeetingSummaryAppState.requestsKey)
    })

    private static func loadRequests() -> [MeetingSummarySchedule.Request] {
        let loaded = MeetingSummarySchedule.decodeRequests(UserDefaults.standard.data(forKey: requestsKey))
        // Requests saved before they had IDs got theirs now: saved at once, before anything can run them.
        if let migrated = loaded.migrated { UserDefaults.standard.set(migrated, forKey: requestsKey) }
        return loaded.requests
    }

    /// Meetings whose Review was asked for while this app summarizes them: opened when the summary ends.
    var reviewAfterRun: [String: (directory: URL, name: String)] = [:]
}

extension HolosAppDelegate {
    /// At launch: with final transcripts off nothing is reconciled, so summaries may start; otherwise the model check
    /// reconciles and then opens the way (`meetingSummaryLaunchReconciled`). The 30 s tick of final transcripts looks
    /// for summaries too.
    func setUpMeetingSummaries() {
        if !DeepTranscriptionAppState.enabled { meetingSummaryLaunchReconciled() }
    }

    /// What a summary pick depends on besides the scan (`MeetingSummaryJobs.Conditions`).
    func meetingSummaryConditions() -> MeetingSummaryJobs.Conditions {
        MeetingSummaryJobs.Conditions(
            enabled: MeetingSummaryAppState.enabled, modelAvailable: OnDeviceFix.unavailableReason == nil,
            onBattery: PowerSource.current() == .battery,
            finalTranscriptQueued: Set((meeting.deep.queue.items + meeting.deep.queue.pending).map(\.sessionID))
                .union(meeting.deep.deciding))
    }

    /// The launch's final-transcript reconciliation ended (or was not needed): summaries may start.
    func meetingSummaryLaunchReconciled() {
        guard !meeting.summaries.jobs.launchReady else { return }
        meeting.summaries.jobs.launchReady = true
        scheduleBackgroundJobs()
    }

    /// A final-transcript reconciliation starts: summaries wait for it, and one running now is stopped (it writes
    /// nothing) and made again afterwards, if its meeting is not queued for a final transcript meanwhile.
    func meetingSummaryReconcileStarted() {
        meeting.summaries.jobs.reconcileStarted()
        meeting.deep.coordinator?.preempt(meeting.summaries.jobs)
    }

    /// The reconciliation ended (its meetings are queued): summaries may start again.
    func meetingSummaryReconcileEnded() {
        meeting.summaries.jobs.reconcileEnded()
        scheduleBackgroundJobs()
    }

    /// Why Apple Intelligence cannot summarize meetings on this Mac, for Settings; nil when it can.
    var meetingSummaryUnavailableReason: String? {
        OnDeviceFix.unavailableReason ?? meeting.summaries.jobs.peopleStoreProblem
    }

    /// Settings › Meetings › "Title and summarize meetings with Apple Intelligence".
    func toggleMeetingSummaries() {
        MeetingSummaryAppState.enabled.toggle()
        if MeetingSummaryAppState.enabled {
            // Meetings that failed before are tried once more.
            meeting.summaries.jobs.attempted = [:]
            scheduleBackgroundJobs()
        }
        updateSettings()
    }

    /// Meetings › Summarize Again: made next (forced), also with the setting off.
    func summarizeMeetingAgain(_ summary: SessionSummary) {
        meeting.summaries.jobs.removeRequest(summary.id)
        meeting.summaries.jobs.requests.append(MeetingSummarySchedule.Request(sessionID: summary.id))
        meeting.deep.coordinator?.clearDelay(meeting.summaries.jobs, summary.id)
        scheduleBackgroundJobs()
    }

    /// Meetings › Cancel Summarize: the request is dropped, and a run of it going now stops (SIGTERM; nothing is
    /// written).
    func cancelMeetingSummary(_ sessionID: String) {
        meeting.summaries.jobs.removeRequest(sessionID)
        meeting.deep.coordinator?.stop(meeting.summaries.jobs, sessionID)
    }

    /// The meeting of the app's summary, if one runs.
    var summaryRunning: String? {
        meeting.deep.coordinator?.runningSession(of: meeting.summaries.jobs)
    }

    /// The people store's problem changed: Settings and the Meetings list say why summaries do not start.
    func meetingSummaryProblemChanged() {
        updateSettings()
        meeting.meetingsPane?.refresh()
    }

    /// A summary let go of its meeting: a new generated title may be the one the meeting shows (an open Review window
    /// takes it), and a Review asked for while it was made opens, before the next jobs are looked for.
    func meetingSummaryReleased(_ sessionID: String) {
        meeting.controller?.endUsing(sessionID)
        meeting.maintenanceEnded[sessionID, default: 0] += 1
        refreshReviewTitle(sessionID)
        meeting.meetingsPane?.update(summarizing: nil)
        meeting.meetingsPane?.refresh()
        if let review = meeting.summaries.reviewAfterRun.removeValue(forKey: sessionID) {
            openReview(sessionID: sessionID, directory: review.directory, name: review.name)
        }
    }

    /// Review asked for while a summary is made of the meeting: by this app (its `sessionsInUse` entry), or by another
    /// process (the lock's holder, a summary). Review would show labels the summary is being made from, so it waits:
    /// the alert says so and offers to cancel this app's summary; Review opens when it ends. Returns whether it waits.
    func reviewWaitsForSummary(sessionID: String, directory: URL, name: String) -> Bool {
        let own = summaryRunning == sessionID
            && meeting.controller?.sessionsInUse[sessionID] == MeetingSummaryJobs.runningText
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

    func showSummaryAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApplication.shared.activate()
        alert.runModal()
    }
}
