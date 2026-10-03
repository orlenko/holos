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

    /// The meeting summarized now and the child's pid (0 while it starts).
    var running: (sessionID: String, pid: Int32)?
    /// The transcript each meeting was last tried with when no summary came of it for good (failed, unavailable),
    /// so it is not tried again until its transcript changes; kept until the app quits.
    var attempted: [String: String] = [:]
    /// Meetings refused for now (busy, transcript changed, stopped for a meeting): skipped until then.
    var delayedUntil: [String: Date] = [:]
    /// Summarize Again, newest last: saved on every change, and kept until the run ends for good (written, current,
    /// failed, unavailable), so a request that had to wait (a meeting started, another job ran, the app quit) runs
    /// later, forced.
    static let requestsKey = "meetingSummaryRequests"
    var requested: [String] = UserDefaults.standard.stringArray(forKey: requestsKey) ?? [] {
        didSet { UserDefaults.standard.set(requested, forKey: Self.requestsKey) }
    }
    /// The run going now was stopped because a meeting started.
    var preempted: String?
    var scanning = false
    var timer: Timer?
}

extension HolosAppDelegate {
    private static let summaryLog = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    /// At launch: looks for meetings to summarize every 30 s (the first look a little after launch).
    func setUpMeetingSummaries() {
        meeting.summaries.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleMeetingSummaries() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.scheduleMeetingSummaries()
        }
    }

    /// Why Apple Intelligence cannot summarize meetings on this Mac, for Settings; nil when it can.
    var meetingSummaryUnavailableReason: String? { OnDeviceFix.unavailableReason }

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
        meeting.summaries.requested.removeAll { $0 == summary.id }
        meeting.summaries.requested.append(summary.id)
        meeting.summaries.delayedUntil[summary.id] = nil
        scheduleMeetingSummaries()
    }

    /// Meetings › Cancel Summarize: the request is dropped, and a run of it going now stops (SIGTERM; nothing is
    /// written).
    func cancelMeetingSummary(_ sessionID: String) {
        meeting.summaries.requested.removeAll { $0 == sessionID }
        if let running = meeting.summaries.running, running.sessionID == sessionID, running.pid > 0 {
            kill(running.pid, SIGTERM)
        }
    }

    /// A meeting is starting, recording, or saving: a summary being made now is stopped (it writes nothing) and made
    /// again once the meeting is saved.
    func meetingSummaryMeetingStateChanged() {
        guard let controller = meeting.controller, meetingIsBusy(controller.state),
              let running = meeting.summaries.running, running.pid > 0, meeting.summaries.preempted == nil,
              kill(running.pid, SIGTERM) == 0 else { return }
        meeting.summaries.preempted = running.sessionID
        Self.summaryLog.notice("Summary of \(running.sessionID, privacy: .public) stopped for a meeting")
    }

    /// Looks for the next meeting to summarize (off the main actor) and starts it when `MeetingSummarySchedule` says
    /// so.
    func scheduleMeetingSummaries() {
        guard let controller = meeting.controller, meeting.maintenance != nil, !meeting.summaries.scanning,
              meeting.summaries.running == nil else { return }
        let wanted = MeetingSummaryAppState.enabled || !meeting.summaries.requested.isEmpty
        guard wanted, OnDeviceFix.unavailableReason == nil, !meetingIsBusy(controller.state) else { return }
        meeting.summaries.scanning = true
        let root = controller.root
        Task { [weak self] in
            let candidates = await Task.detached { MeetingSummarySchedule.scan(root: root) }.value
            guard let self else { return }
            self.meeting.summaries.scanning = false
            self.startNextMeetingSummary(candidates)
        }
    }

    private func startNextMeetingSummary(_ candidates: [MeetingSummarySchedule.Candidate]) {
        guard let controller = meeting.controller, let maintenance = meeting.maintenance,
              meeting.summaries.running == nil else { return }
        let now = Date()
        meeting.summaries.delayedUntil = meeting.summaries.delayedUntil.filter { $0.value > now }
        // A request for a meeting that is gone is dropped.
        let listed = Set(candidates.map(\.sessionID))
        meeting.summaries.requested.removeAll { !listed.contains($0) }
        let situation = MeetingSummarySchedule.Situation(
            enabled: MeetingSummaryAppState.enabled, modelAvailable: OnDeviceFix.unavailableReason == nil,
            meetingBusy: meetingIsBusy(controller.state),
            deepPassRunning: meeting.deep.running != nil || DeepTranscriptionLock.state() != .free,
            running: nil,
            inUse: Set(controller.sessionsInUse.keys).union(controller.sessionsUnderReview()),
            attempted: meeting.summaries.attempted, delayedUntil: meeting.summaries.delayedUntil,
            requested: meeting.summaries.requested, onBattery: PowerSource.current() == .battery,
            finalTranscriptQueued: Set((meeting.deep.queue.items + meeting.deep.queue.pending).map(\.sessionID)),
            now: now)
        guard case .run(let sessionID, let path, let force) = MeetingSummarySchedule.next(candidates, situation)
        else { return }
        let transcriptID = candidates.first { $0.sessionID == sessionID }?.transcriptID
        let output = Self.temporaryFile("summary")
        let errors = Self.temporaryFile("summary-err")
        meeting.summaries.running = (sessionID, 0)
        do {
            let pid = try maintenance.run(["session", "summarize", path, "--json"] + (force ? ["--force"] : []),
                                          standardOutput: output, standardError: errors) { [weak self] code in
                self?.meetingSummaryEnded(sessionID, transcriptID: transcriptID, code: code, output: output,
                                          errors: errors)
            }
            meeting.summaries.running = (sessionID, pid)
            Self.summaryLog.notice("Summary of \(sessionID, privacy: .public) started")
        } catch {
            meeting.summaries.running = nil
            meeting.summaries.delayedUntil[sessionID] = Date().addingTimeInterval(60)
            Self.removeFile(output)
            Self.removeFile(errors)
            Self.summaryLog.error("Cannot start the summary: \(error.localizedDescription, privacy: .private)")
        }
        meeting.meetingsPane?.update(summarizing: meeting.summaries.running?.sessionID)
    }

    private func meetingSummaryEnded(_ sessionID: String, transcriptID: String?, code: Int32, output: URL,
                                     errors: URL) {
        let outcome = (try? AtomicFile.readIfPresent(output, maxBytes: 4 << 20)).flatMap {
            $0.flatMap { try? HolosJSON.decoder().decode(SummaryOutcome.self, from: $0) }
        }
        Self.removeFile(output)
        Self.removeFile(errors)
        let preempted = meeting.summaries.preempted == sessionID
        if preempted { meeting.summaries.preempted = nil }
        meeting.summaries.running = nil
        let status = outcome.map { SessionSummarizeCommand.Status($0.status) }
        let requested = meeting.summaries.requested.contains(sessionID)
        // A result the command reports decides: a summary it saved counts even when a meeting started at the very
        // end (SIGTERM cannot stop the save). Without one, a run stopped for a meeting is tried again.
        if status.map(\.retriesLater) ?? preempted {
            // Stopped for a meeting, held by another command or job, or the transcript changed: tried again in a
            // minute, and a request stays.
            meeting.summaries.delayedUntil[sessionID] = Date().addingTimeInterval(60)
        } else {
            // Done for good: written, up to date, failed, or Apple Intelligence cannot be used for it.
            meeting.summaries.requested.removeAll { $0 == sessionID }
            // A failure is not tried again automatically for this transcript.
            if code != 0, let transcriptID { meeting.summaries.attempted[sessionID] = transcriptID }
            // Asked for from the meeting's menu and not made: the user is told why (as Make Final Transcript Now),
            // for example a language Apple Intelligence does not support.
            if requested, code != 0, status != .written {
                showSummaryAlert("The meeting was not summarized.",
                                 outcome?.message ?? "The summary command stopped (code \(code)).")
            }
        }
        Self.summaryLog.notice("Summary of \(sessionID, privacy: .public) ended with \(code, privacy: .public) (\(outcome?.status ?? "no result", privacy: .public))")
        meeting.meetingsPane?.update(summarizing: nil)
        meeting.meetingsPane?.refresh()
        // A final transcript waits while a summary runs (they share the background job lock).
        scheduleDeepTranscription()
        scheduleMeetingSummaries()
    }

    /// The part of `voiceislocal session summarize --json` the app reads.
    private struct SummaryOutcome: Decodable {
        var status: String
        var message: String?
    }

    private func showSummaryAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApplication.shared.activate()
        alert.runModal()
    }
}
