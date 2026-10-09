import Foundation
import HolosMeeting

/// The wiring of `BackgroundJobCoordinator` (docs/meeting-design.md §4.16 "App", §5.11 "Catching up in the app"):
/// final transcripts (`meeting.deep.jobs`) and echo analyses (`meeting.echo`), one job at a time, beside this app's
/// summaries (§4.17), which keep their own scheduler.
extension HolosAppDelegate {
    /// Creates the coordinator once the meeting controller and the maintenance launcher exist.
    func setUpBackgroundJobs() {
        guard meeting.deep.coordinator == nil, let controller = meeting.controller,
              let commands = meeting.commands else { return }
        let environment = BackgroundJobCoordinator.Environment(
            meetingBusy: { [weak self, weak controller] in
                guard let self, let controller else { return false }
                return self.meetingIsBusy(controller.state)
            },
            // Review owns a meeting while it is open, opening, or still saving.
            sessionsInUse: { [weak controller] in
                guard let controller else { return [] }
                return Set(controller.sessionsInUse.keys).union(controller.sessionsUnderReview())
            },
            beginUsing: { [weak controller] sessionID, doing in controller?.beginUsing(sessionID, for: doing) ?? false },
            otherJobRunning: { [weak self] in self?.meeting.summaries.running != nil },
            summaryRequestScan: { [weak self] in
                guard let self else { return false }
                return self.meeting.summaries.scanning && !self.meeting.summaries.requests.isEmpty
            },
            scheduleOthers: { [weak self] in self?.scheduleMeetingSummaries() },
            started: { [weak self] kind, sessionID in self?.backgroundJobStarted(kind, sessionID) },
            released: { [weak self] kind, sessionID in self?.backgroundJobReleased(kind, sessionID) },
            changed: { [weak self] in
                self?.updateDeepStates()
                self?.updateEchoStates()
            })
        meeting.deep.coordinator = BackgroundJobCoordinator(runner: commands, kinds: [meeting.deep.jobs, meeting.echo],
                                                environment: environment)
        meeting.deep.jobs.onEnded = { [weak self] report in self?.deepTranscriptionEnded(report) }
    }

    /// Starts the next final transcript or echo analysis when one may start.
    func scheduleBackgroundJobs() {
        meeting.deep.coordinator?.schedule()
    }

    /// The meeting of the app's final transcript, if one runs.
    var deepRunning: String? {
        meeting.deep.coordinator?.runningSession(of: meeting.deep.jobs)
    }

    /// An echo analysis holds its meeting as a maintenance command does: a review that opens while it runs opens
    /// read-only and rereads the meeting when it ends (`ReviewMaintenance`). None holds the meeting now (the
    /// coordinator skips meetings under review). A final transcript holds Review off instead
    /// (`reviewWaitsForDeepTranscription`).
    private func backgroundJobStarted(_ kind: any BackgroundJobKind, _ sessionID: String) {
        guard kind === meeting.echo else { return }
        meeting.maintenanceOn[sessionID] = ReviewMaintenance.Hold(.echoAnalysis)
    }

    /// A job let go of its meeting: Meetings stops showing it, a review opened meanwhile rereads the meeting (an echo
    /// analysis's review also becomes editable again, so its labels and playback follow the new mask).
    private func backgroundJobReleased(_ kind: any BackgroundJobKind, _ sessionID: String) {
        if kind === meeting.echo {
            maintenanceFinished(sessionID)
        } else {
            meeting.controller?.endUsing(sessionID)
            meeting.maintenanceEnded[sessionID, default: 0] += 1
        }
        meeting.meetingsPane?.refresh()
    }
}
