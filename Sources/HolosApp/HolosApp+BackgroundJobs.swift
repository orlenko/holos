import Foundation
import HolosMeeting

/// The wiring of `BackgroundJobCoordinator` (docs/meeting-design.md §4.16 "App"): final transcripts
/// (`meeting.deep.jobs`), one job at a time beside this app's summaries (§4.17) and echo catch-up (§5.11), which keep
/// their own schedulers.
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
            otherJobRunning: { [weak self] in
                guard let self else { return false }
                return self.meeting.summaries.running != nil || self.meeting.echo.running != nil
            },
            summaryRequestScan: { [weak self] in
                guard let self else { return false }
                return self.meeting.summaries.scanning && !self.meeting.summaries.requests.isEmpty
            },
            // A call's missing echo analysis goes before an automatic final transcript (§5.11).
            otherCatchUpReady: { [weak self] in self?.echoCatchUpReady() ?? false },
            startOtherCatchUp: { [weak self] in self?.scheduleEchoCatchUp() },
            // Summaries first, so one the user asked for goes before the next automatic job.
            scheduleOthers: { [weak self] in
                self?.scheduleMeetingSummaries()
                self?.scheduleEchoCatchUp()
            },
            released: { [weak self] _, sessionID in self?.backgroundJobReleased(sessionID) },
            changed: { [weak self] in self?.updateDeepStates() })
        meeting.deep.coordinator = BackgroundJobCoordinator(runner: commands, kinds: [meeting.deep.jobs],
                                                environment: environment)
        meeting.deep.jobs.onEnded = { [weak self] report in self?.deepTranscriptionEnded(report) }
    }

    /// Starts the next final transcript when one may start.
    func scheduleBackgroundJobs() {
        meeting.deep.coordinator?.schedule()
    }

    /// The meeting of the app's final transcript, if one runs.
    var deepRunning: String? {
        meeting.deep.coordinator?.runningSession(of: meeting.deep.jobs)
    }

    /// A final transcript let go of its meeting: Meetings stops showing it, and a review opened meanwhile rereads the
    /// meeting.
    private func backgroundJobReleased(_ sessionID: String) {
        meeting.controller?.endUsing(sessionID)
        meeting.maintenanceEnded[sessionID, default: 0] += 1
        meeting.meetingsPane?.refresh()
    }
}
