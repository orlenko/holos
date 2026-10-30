import Foundation
import HolosAppModel
import HolosMeeting

/// The wiring of `BackgroundJobCoordinator` (docs/meeting/deep-transcription.md §4.16 "App", docs/meeting/titles-summaries.md §4.17, docs/meeting/online-calls-echo.md §5.11 "Catching up in the
/// app"): final transcripts (`meeting.deep.jobs`), echo analyses (`meeting.echo`), summaries
/// (`meeting.summaries.jobs`) and the audio cleanup (docs/design.md "Automatic audio cleanup"), one job at a time.
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
            released: { [weak self] kind, sessionID, hold in self?.backgroundJobReleased(kind, sessionID, hold: hold) },
            changed: { [weak self] in
                guard let self else { return }
                self.updateDeepStates()
                self.updateEchoStates()
                self.meeting.meetingsPane?.update(summarizing: self.summaryRunning)
            })
        let summaries = meeting.summaries.jobs
        summaries.root = controller.root
        summaries.conditions = { [weak self] in
            self?.meetingSummaryConditions() ?? .init(enabled: false, modelAvailable: false, onBattery: false)
        }
        summaries.onScanned = { [weak self] in self?.scheduleBackgroundJobs() }
        summaries.onProblemChanged = { [weak self] in self?.meetingSummaryProblemChanged() }
        // Asked for from the meeting's menu and not made: the user is told why (as Make Final Transcript Now), for
        // example a language Apple Intelligence does not support.
        summaries.onRequestFailed = { [weak self] _, message in
            self?.showSummaryAlert("The meeting was not summarized.", message)
        }
        let cleanup = audioCleanupJobs(root: controller.root)
        // Kinds in their order when two picks have the same priority: final transcripts, echo analyses, summaries,
        // the audio cleanup.
        meeting.deep.coordinator = BackgroundJobCoordinator(runner: commands,
                                                            kinds: [meeting.deep.jobs, meeting.echo, summaries, cleanup],
                                                            environment: environment)
        meeting.deep.jobs.onEnded = { [weak self] report in self?.deepTranscriptionEnded(report) }
    }

    /// The audio cleanup, looked for at launch, hourly (a meeting grows old while the app runs) and when Settings
    /// changes it. A final transcript or echo analysis still queued on a meeting keeps its audio.
    private func audioCleanupJobs(root: URL) -> AudioCleanupJobs {
        let cleanup = AudioCleanupJobs()
        cleanup.root = root
        cleanup.olderThanDays = { MeetingAudioPreferences().cleanupAfterDays }
        cleanup.pending = { [weak self] in
            guard let self else { return [] }
            return Set(self.meeting.deep.jobs.queue.items.map(\.sessionID)).union(self.meeting.echo.queue.map(\.sessionID))
        }
        cleanup.onScanned = { [weak self] in self?.scheduleBackgroundJobs() }
        // No voice can be learned from the meeting any more, as after Delete Audio.
        cleanup.onDeleted = { PendingVoiceSamples().clear($0) }
        NotificationCenter.default.addObserver(forName: MeetingAudioPreferences.cleanupChanged, object: nil,
                                               queue: .main) { [weak self, weak cleanup] _ in
            MainActor.assumeIsolated {
                cleanup?.rescan()
                self?.scheduleBackgroundJobs()
            }
        }
        Timer.scheduledTimer(withTimeInterval: AudioCleanupJobs.rescanAfter, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleBackgroundJobs() }
        }
        return cleanup
    }

    /// Starts the next final transcript, echo analysis or summary when one may start (a summary after its scan).
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
    private func backgroundJobReleased(_ kind: any BackgroundJobKind, _ sessionID: String,
                                       hold: ReviewMaintenance.Hold?) {
        if kind === meeting.summaries.jobs {
            meetingSummaryReleased(sessionID)
            return
        }
        if let hold {
            maintenanceFinished(sessionID, hold: hold)
        } else {
            meeting.controller?.endUsing(sessionID)
            meeting.maintenanceEnded[sessionID, default: 0] += 1
        }
        meeting.meetingsPane?.refresh()
    }
}
