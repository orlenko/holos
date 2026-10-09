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
            released: { [weak self] _, sessionID, hold in self?.backgroundJobReleased(sessionID, hold: hold) },
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

    /// The review hold of the background job working on the meeting now (an echo analysis), if any.
    func backgroundJobHold(on sessionID: String) -> ReviewMaintenance.Hold? {
        meeting.deep.coordinator?.reviewHold(on: sessionID)
    }

    /// A job let go of its meeting: Meetings stops showing it, a review opened meanwhile rereads the meeting, and one
    /// an echo analysis held read-only (its `hold`, `BackgroundJobCoordinator.reviewHold(on:)`) becomes editable
    /// again, so its labels and playback follow the new mask. A final transcript holds no review: Review waits for it
    /// (`reviewWaitsForDeepTranscription`).
    private func backgroundJobReleased(_ sessionID: String, hold: ReviewMaintenance.Hold?) {
        if let hold {
            maintenanceFinished(sessionID, hold: hold)
        } else {
            meeting.controller?.endUsing(sessionID)
            meeting.maintenanceEnded[sessionID, default: 0] += 1
        }
        meeting.meetingsPane?.refresh()
    }
}
