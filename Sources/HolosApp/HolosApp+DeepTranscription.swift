import AppKit
import Darwin
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import IOKit.ps
import os

/// Deep transcription after meetings in the app (docs/meeting-design.md §4.16, "App"): the queue, its power policy,
/// and the model's install. The pass itself is `voiceislocal session deep-transcribe`, run as a maintenance command
/// by `coordinator`.
///
/// Invariants:
/// 1. Every change to the queue (`queue`, kept by `jobs`) is saved in UserDefaults (`queueKey`), and every change to
///    `considered` too (`consideredKey`): a pass cut short by a quit or crash runs again at the next launch.
/// 2. The after-meeting queueing and the launch check never queue a meeting already in `considered`, and every
///    meeting they queue joins it.
/// 3. Every turn of the setting changes `activation`; an automatic after-meeting language read or a reconciliation
///    begun under another activation queues nothing. A Make Final Transcript Now request is not bound to it: its
///    language read queues it whatever the setting did meanwhile.
/// 4. `coordinator` is made once (`setUpBackgroundJobs`), after the meeting controller and its maintenance launcher,
///    and is the only thing that starts a pass; it runs `jobs`.
@MainActor
final class DeepTranscriptionAppState {
    /// Settings › Meetings › "Deep transcription after meetings" (off until turned on, and only once the model is
    /// installed).
    static let enabledKey = "deepTranscriptionAfterMeetings"
    /// When it was last turned on: meetings started since then and found finished at launch are queued.
    static let enabledSinceKey = "deepTranscriptionEnabledSince"
    static let queueKey = "deepTranscriptionQueue"
    /// Meetings queued once already (whatever came of it), so the launch check never queues them again. Not capped:
    /// a few dozen bytes per meeting, and forgetting one could queue a meeting the user cancelled.
    static let consideredKey = "deepTranscriptionConsidered"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var enabledSince: Date? {
        get { UserDefaults.standard.object(forKey: enabledSinceKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: enabledSinceKey) }
    }

    /// The queue and what its passes come to; `BackgroundJobCoordinator` runs them.
    private(set) lazy var jobs = DeepTranscriptionJobs(
        queue: DeepTranscriptionQueue.decode(UserDefaults.standard.data(forKey: Self.queueKey)),
        save: { UserDefaults.standard.set($0.encoded(), forKey: Self.queueKey) },
        conditions: { [unowned self] in
            DeepTranscriptionJobs.Conditions(enabled: Self.enabled, modelInstalled: model == "installed", power: power)
        })
    /// Saved on every change, so a pass cut short by a quit or crash runs again at the next launch.
    var queue: DeepTranscriptionQueue {
        get { jobs.queue }
        set { jobs.queue = newValue }
    }
    /// Meetings just saved whose languages are being read to decide whether a final transcript is queued: a summary
    /// waits for that decision (§4.17), so none is made of a transcript a final one is about to replace.
    var deciding: Set<String> = []
    var considered: [String] = UserDefaults.standard.stringArray(forKey: consideredKey) ?? [] {
        didSet { UserDefaults.standard.set(considered, forKey: Self.consideredKey) }
    }
    /// Runs the passes, one background job at a time on this Mac (invariant 4).
    var coordinator: BackgroundJobCoordinator?
    /// Meetings whose Review was asked for while this app's pass works on them: opened when the pass ends.
    var reviewAfterPass: [String: (directory: URL, name: String)] = [:]
    /// Counts every turn of the setting on or off: a scan begun before one is dropped when it ends.
    var activation = 0
    /// Counts the 30 s timer's ticks: some checks run every other one.
    var ticks = 0
    /// `voiceislocal doctor --json` deepTranscriptionModel ("installed", "downloading", "notInstalled"); "unknown" when
    /// doctor ran but did not report it, "unavailable" when it could not run; nil before the first check.
    var model: String?
    /// Progress of `voiceislocal setup --whisper` while it runs, and the last install's failure.
    var install: String?
    var installError: String?
    var power: DeepTranscriptionSchedule.Power = .unknown
    var timer: Timer?

    func consider(_ sessionID: String) {
        guard !considered.contains(sessionID) else { return }
        considered.append(sessionID)
    }
}

/// Where the Mac's power comes from now (IOKit's providing power source).
enum PowerSource {
    static func current() -> DeepTranscriptionSchedule.Power {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return .unknown
        }
        switch type {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey: return .battery
        default: return .unknown
        }
    }
}

extension HolosAppDelegate {
    private static let deepLog = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    /// At launch: every 30 s checks the power source (and so notices AC power coming back), checks the model again
    /// while another process downloads it (every 60 s while it is not installed and the setting is on or Settings
    /// shows, so an install in Terminal is noticed), and looks for the next background job (`BackgroundJobCoordinator`:
    /// a meeting a review held, one turned down for now, or one that waited for another job). Run Now requests whose
    /// languages were being read when the app quit are read again.
    func setUpDeepTranscription() {
        setUpBackgroundJobs()
        meeting.deep.power = PowerSource.current()
        for request in meeting.deep.queue.pending {
            checkRunNowLanguages(sessionID: request.sessionID, directory: URL(fileURLWithPath: request.path), name: nil)
        }
        meeting.deep.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let power = PowerSource.current()
                if power != self.meeting.deep.power {
                    self.meeting.deep.power = power
                    self.updateDeepStates()
                }
                // A download started before this launch (detached) ends without telling this app; one started in
                // Terminal begins without telling it.
                self.meeting.deep.ticks += 1
                if self.meeting.deep.model == "downloading" {
                    self.refreshSpeakerModels()
                } else if self.meeting.deep.model != "installed", self.meeting.deep.ticks % 2 == 0,
                          DeepTranscriptionAppState.enabled || self.settingsShowing {
                    self.refreshSpeakerModels()
                }
                self.scheduleBackgroundJobs()
            }
        }
        scheduleBackgroundJobs()
    }

    /// The doctor check reported the model (or could not run).
    func deepModelChecked(_ model: String) {
        let previous = meeting.deep.model
        meeting.deep.model = model
        // Meetings that finished while the model was missing or downloading were not queued: found again now.
        if DeepTranscriptionSchedule.reconcilesOnModelChange(from: previous, to: model) {
            reconcileDeepTranscription()
        } else if model != "downloading" {
            // Nothing to reconcile: summaries need not wait for it (§4.17). While the model downloads they wait: once
            // it is installed the reconciliation runs (and then lets them start); a failed download lets them start.
            meetingSummaryLaunchReconciled()
        }
        scheduleBackgroundJobs()
    }

    /// Whether the meeting state leaves no room for a pass: a meeting starting, recording, or saving, one that
    /// failed while its recorder may still be capturing or post-processing, or a recorder the app launched that has
    /// not exited, even without a session folder (`MeetingController.recorderMayStillRun`, as a start checks it).
    func meetingIsBusy(_ state: MeetingState) -> Bool {
        if meeting.controller?.recorderMayStillRun() == true { return true }
        switch state {
        case .idle: return false
        case .failed(let sessionID, _):
            guard let sessionID, let root = meeting.controller?.root,
                  let directory = try? SessionLocator.resolve(sessionID, root: root) else { return false }
            return [.capturing, .processing].contains(RecorderChannel.liveness(session: directory))
        default: return true
        }
    }

    // MARK: - Queue

    /// After a meeting is saved and its own post-processing ended: queued when the setting is on, the model
    /// installed, and the pass transcribes the meeting (one language, English). Its summary is looked for once that is decided (§4.17), so a
    /// meeting about to get a final transcript is summarized after it, not before.
    func queueDeepTranscriptionAfterMeeting(sessionID: String) {
        guard DeepTranscriptionAppState.enabled, meeting.deep.model == "installed", let root = meeting.controller?.root,
              let directory = try? SessionLocator.resolve(sessionID, root: root) else {
            scheduleMeetingSummaries()
            return
        }
        let activation = meeting.deep.activation
        meeting.deep.deciding.insert(sessionID)
        // Reading the language can mean decoding a long meeting's transcript: off the main actor.
        Task { [weak self] in
            let transcribable = await Task.detached {
                SessionDeepTranscribeCommand.languageProblem(session: directory) == nil
            }.value
            defer {
                self?.meeting.deep.deciding.remove(sessionID)
                self?.scheduleMeetingSummaries()
            }
            // The setting was turned off (and maybe on again) while it was read: that turning off took it off.
            // Checked against the live queue and the meetings considered: the user may have asked for it (and maybe
            // cancelled it) while it was read.
            guard let self, self.meeting.deep.activation == activation, DeepTranscriptionSchedule.queuesAfterMeeting(
                enabled: DeepTranscriptionAppState.enabled, modelInstalled: self.meeting.deep.model == "installed",
                transcribable: transcribable, queued: self.meeting.deep.queue.contains(sessionID),
                considered: self.meeting.deep.considered.contains(sessionID)) else { return }
            self.meeting.deep.queue.enqueue(sessionID: sessionID, path: directory.path, at: Date())
            self.meeting.deep.consider(sessionID)
            self.updateDeepStates()
            self.scheduleBackgroundJobs()
        }
    }

    /// Once per launch, with the setting on and the model installed: queues the meetings that finished while the app
    /// was closed (in child-recorder mode a recorder saves and post-processes on its own after the app quits),
    /// started since the setting was turned on, that the pass transcribes (one language, English), with no deep
    /// transcript, and not queued before.
    func reconcileDeepTranscription() {
        guard DeepTranscriptionAppState.enabled, meeting.deep.model == "installed",
              let root = meeting.controller?.root, let since = DeepTranscriptionAppState.enabledSince else {
            meetingSummaryLaunchReconciled()
            return
        }
        let considered = Set(meeting.deep.considered)
        let queue = meeting.deep.queue
        let activation = meeting.deep.activation
        // Summaries wait while it runs (§4.17): it may queue a final transcript of a meeting they would summarize.
        meetingSummaryReconcileStarted()
        Task { [weak self] in
            // Once the meetings saved while the app was closed are queued (or none were), summaries may start.
            defer { self?.meetingSummaryReconcileEnded() }
            let found = await Task.detached { () -> [DeepTranscriptionSchedule.Candidate] in
                let candidates = SessionCatalog.list(root: root)
                    .filter { $0.createdAt >= since && !considered.contains($0.id) && !queue.contains($0.id) }
                    .map { summary in
                        DeepTranscriptionSchedule.Candidate(
                            sessionID: summary.id, path: summary.directory.path, createdAt: summary.createdAt,
                            finished: DeepTranscriptionSchedule.isFinished(summary.state,
                                                                           audioDeleted: summary.audioDeleted),
                            transcribable: SessionDeepTranscribeCommand.languageProblem(session: summary.directory)
                                == nil,
                            hasDeepTranscript: Self.hasDeepTranscript(summary.directory))
                    }
                    .sorted { $0.createdAt < $1.createdAt }
                return DeepTranscriptionSchedule.reconcile(candidates, enabledSince: since, considered: considered,
                                                           queue: queue)
            }.value
            // The setting may have been turned off (or off and on again) while the folder was read.
            guard let self, !found.isEmpty, self.meeting.deep.activation == activation,
                  DeepTranscriptionAppState.enabled, DeepTranscriptionAppState.enabledSince == since else { return }
            for candidate in found {
                // Checked again against the queue and the meetings considered now: the user may have run, cancelled,
                // or queued one while the folder was read.
                guard !self.meeting.deep.queue.contains(candidate.sessionID),
                      !self.meeting.deep.considered.contains(candidate.sessionID) else { continue }
                self.meeting.deep.queue.enqueue(sessionID: candidate.sessionID, path: candidate.path, at: Date())
                self.meeting.deep.consider(candidate.sessionID)
            }
            Self.deepLog.notice("Deep transcription: queued \(found.count, privacy: .public) meetings saved while the app was closed")
            self.updateDeepStates()
            self.scheduleBackgroundJobs()
        }
    }

    /// Meetings › Make Final Transcript Now (relabels speakers): runs next, whatever the power source, with `--force`,
    /// so a transcript the model made before is made again and edited speaker labels are replaced (names carry over).
    func runDeepTranscriptionNow(_ summary: SessionSummary) {
        guard meeting.deep.model == "installed" else {
            showDeepAlert("The deep transcription model is not installed.",
                          "Install it in Settings › Meetings (about 1.6 GB), then try again.")
            return
        }
        guard DeepTranscriptionSchedule.isFinished(summary.state, audioDeleted: summary.audioDeleted) else {
            showDeepAlert("“\(Self.short(summary.displayTitle))” is not finished.",
                          "Recover it first if it was interrupted, or wait until it is saved.")
            return
        }
        // Reserved at once, and saved with the queue: a queued automatic item is not started without --force while the
        // languages are read, a quit meanwhile does not lose the request, and the meeting is considered, so a scan
        // that ends meanwhile does not queue it again once it is cancelled.
        meeting.deep.queue.reserveRunNow(sessionID: summary.id, path: summary.directory.path, at: Date())
        meeting.deep.consider(summary.id)
        updateDeepStates()
        checkRunNowLanguages(sessionID: summary.id, directory: summary.directory, name: summary.name)
    }

    /// Reads the language of a reserved Run Now request off the main actor, then queues it (the pass transcribes it:
    /// one language, English) or leaves the meeting as it was with an alert saying why (several languages, or another
    /// language: Run Now passes `--force`, so the pass would not refuse it). Cancelled meanwhile, nothing happens.
    private func checkRunNowLanguages(sessionID: String, directory: URL, name: String?) {
        Task { [weak self] in
            let problem = await Task.detached { SessionDeepTranscribeCommand.languageProblem(session: directory) }.value
            guard let self, self.meeting.deep.queue.isPending(sessionID) else { return }
            let accepted = problem == nil
            self.meeting.deep.queue.resolveRunNow(sessionID, accepted: accepted)
            if accepted { self.meeting.deep.coordinator?.clearRetry(self.meeting.deep.jobs) }
            self.updateDeepStates()
            self.scheduleBackgroundJobs()
            guard !accepted else { return }
            let shown = name ?? (try? SessionArchive.readManifest(at: directory).name) ?? "The meeting"
            self.showDeepAlert("“\(Self.short(shown))” keeps its transcript.", problem ?? "")
        }
    }

    /// Meetings › Cancel Final Transcript: takes the meeting off the queue and stops its pass (SIGTERM: the command
    /// cancels and says whether the new transcript was already published).
    func cancelDeepTranscription(_ sessionID: String) {
        // Only this app's own pass is signalled.
        meeting.deep.coordinator?.cancel(meeting.deep.jobs, sessionID)
        meeting.deep.queue.remove(sessionID)
        updateDeepStates()
    }

    /// The app's pass ended (`DeepTranscriptionJobs.onEnded`, once the next jobs were looked for): a Review asked
    /// for meanwhile opens, and a Make Final Transcript Now that was not done says why (a cancel takes it off the queue
    /// first, so it says nothing).
    func deepTranscriptionEnded(_ report: DeepTranscriptionJobs.PassReport) {
        let sessionID = report.sessionID
        let code = report.result.code
        let errorText = report.result.errors
        let lateCancel = errorText.split(separator: "\n").first { $0.hasPrefix("Cancelled after the new transcript") }
        var failure: String?
        if report.end == .done, report.item?.runNow == true, code != 0, lateCancel == nil {
            failure = DeepTranscriptionSchedule.failureText(code: code, record: report.result.outcome, errors: errorText)
        }
        // Review asked for while the pass worked on the meeting.
        if let review = meeting.deep.reviewAfterPass.removeValue(forKey: sessionID) {
            openReview(sessionID: sessionID, directory: review.directory, name: review.name)
        }
        if let lateCancel {
            // The new transcript was already current when the pass stopped: its labels and files may be behind.
            showDeepAlert("A final transcript was cancelled after it was saved.",
                          String(lateCancel).replacingOccurrences(of: "Run voiceislocal session diarize on the meeting",
                                                                  with: "Choose Label Speakers in Meetings"))
        } else if let failure, let item = report.item {
            let name = (try? SessionArchive.readManifest(at: URL(fileURLWithPath: item.path)).name).map {
                Self.short($0)
            } ?? "the meeting"
            showDeepAlert(code == 3 ? "The final transcript of “\(name)” is not complete."
                              : "The final transcript of “\(name)” was not made.", failure)
        }
    }

    /// The Meetings list's State column for queued and running passes.
    func updateDeepStates() {
        let running = deepRunning
        // Another process's pass holds the lock (one started in Terminal, or one left running from before a
        // relaunch): the queue waits for it. The app never signals or adopts it.
        let otherPassRunning = meeting.deep.coordinator?.lock.isDeepPass ?? false
        var states: [String: String] = [:]
        for item in meeting.deep.queue.items + meeting.deep.queue.pending {
            if let text = DeepTranscriptionSchedule.stateText(sessionID: item.sessionID, queue: meeting.deep.queue,
                                                              running: running, power: meeting.deep.power,
                                                              otherPassRunning: otherPassRunning) {
                states[item.sessionID] = text
            }
        }
        let offersRunNow = Set(meeting.deep.queue.items.map(\.sessionID).filter {
            DeepTranscriptionSchedule.offersRunNow(sessionID: $0, queue: meeting.deep.queue, running: running)
        })
        meeting.meetingsPane?.update(deepStates: states, running: running,
                                     queuedAutomatically: offersRunNow)
    }

    // MARK: - Model

    /// Runs `voiceislocal setup --whisper` (about 1.6 GB; an interrupted download resumes) and shows its progress.
    func installDeepTranscriptionModel() {
        guard let maintenance = meeting.maintenance, meeting.deep.install == nil else { return }
        let output = Self.temporaryFile("setup-whisper")
        meeting.deep.install = "Starting the download…"
        meeting.deep.installError = nil
        updateSettings()
        do {
            try maintenance.run(["setup", "--whisper"], standardOutput: output, standardError: output) { [weak self] code in
                guard let self else { return }
                let last = Self.lastLine(output)
                Self.removeFile(output)
                self.meeting.deep.install = nil
                if code != 0 { self.meeting.deep.installError = last ?? "The download failed (code \(code))." }
                self.meeting.deep.model = nil
                self.refreshSpeakerModels()
                self.updateSettings()
            }
        } catch {
            meeting.deep.install = nil
            meeting.deep.installError = error.localizedDescription
            Self.removeFile(output)
            updateSettings()
            return
        }
        Task { [weak self] in
            while let self, self.meeting.deep.install != nil {
                if let line = Self.lastLine(output), line.hasPrefix("Deep transcription model:")
                    || line.hasPrefix("Downloading") || line.hasPrefix("Resuming") || line.hasPrefix("Checking") {
                    self.meeting.deep.install = line
                    self.updateSettings()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Settings › Meetings › "Deep transcription after meetings": on only with the model installed; off takes the
    /// automatic passes off the queue (Make Final Transcript Now ones stay). Turning it on records when, so meetings
    /// saved from then on while the app is closed are queued at the next launch.
    func toggleDeepTranscription() {
        let on = !DeepTranscriptionAppState.enabled
        guard !on || meeting.deep.model == "installed" else {
            installDeepTranscriptionModel()
            return
        }
        DeepTranscriptionAppState.enabled = on
        meeting.deep.activation += 1
        if on {
            DeepTranscriptionAppState.enabledSince = Date()
            reconcileDeepTranscription()
        } else {
            // The pass running now keeps its item until it ends (then it is taken off).
            meeting.deep.queue.removeAutomatic(keeping: deepRunning)
            // No final transcripts to wait for: summaries held back at launch (the model still being checked or
            // downloaded) may start.
            meetingSummaryLaunchReconciled()
        }
        updateSettings()
        updateDeepStates()
        scheduleBackgroundJobs()
    }

    /// Settings' "Deep transcription" row: the model state, its progress or error, and the setting.
    func deepTranscriptionSetupState() -> (model: String?, detail: String?, enabled: Bool) {
        if let progress = meeting.deep.install { return ("installing", progress, DeepTranscriptionAppState.enabled) }
        return (meeting.deep.model, meeting.deep.installError, DeepTranscriptionAppState.enabled)
    }

    // MARK: - Helpers

    /// Review asked for (from any entry point: Meetings, the menu bar's Name Speakers) while a deep transcription
    /// pass works on the meeting: this app's own (its `sessionsInUse` entry), or another process's (the lock's
    /// holder). Review would load a transcript and labels the pass is about to replace, so it waits: the alert says
    /// so and offers to cancel this app's pass; Review opens when this app's pass ends. Returns whether it waits.
    func reviewWaitsForDeepTranscription(sessionID: String, directory: URL, name: String) -> Bool {
        let own = meeting.controller?.sessionsInUse[sessionID] == DeepTranscriptionJobs.runningText
            && deepRunning == sessionID
        var other = false
        if !own, case .held(let holder?) = DeepTranscriptionLock.state(), holder.isDeepPass {
            other = holder.sessionID == sessionID
        }
        guard own || other else { return false }
        let alert = NSAlert()
        alert.messageText = "Final transcript in progress"
        if own {
            alert.informativeText = "“\(Self.short(name))” is being transcribed again. Review opens when it finishes."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel Final Transcript")
            meeting.deep.reviewAfterPass[sessionID] = (directory, name)
        } else {
            alert.informativeText = "“\(Self.short(name))” is being transcribed again by another Voice is Local "
                + "process. Open Review when it finishes."
        }
        NSApplication.shared.activate()
        if alert.runModal() == .alertSecondButtonReturn { cancelDeepTranscription(sessionID) }
        return true
    }

    /// Whether Settings shows in the main window (the deep transcription row with it).
    private var settingsShowing: Bool {
        guard let mainWindow, mainWindow.isVisible else { return false }
        return mainWindow.current == .settings
    }

    /// Whether a deep transcription was journaled for the meeting.
    nonisolated static func hasDeepTranscript(_ directory: URL) -> Bool {
        guard let events = try? SessionArchive.readEvents(at: directory).events else { return false }
        return events.contains { $0.kind == MeetingEventKind.deepTranscribed }
    }

    private func showDeepAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApplication.shared.activate()
        alert.runModal()
    }
}
