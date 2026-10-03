import AppKit
import Darwin
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import IOKit.ps
import os

/// Deep transcription after meetings in the app (docs/meeting-design.md §4.16, "App"): the queue, its power policy,
/// and the model's install. The pass itself is `voiceislocal session deep-transcribe`, run as a maintenance command.
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

    /// Saved on every change, so a pass cut short by a quit or crash runs again at the next launch.
    var queue = DeepTranscriptionQueue.decode(UserDefaults.standard.data(forKey: queueKey)) {
        didSet { UserDefaults.standard.set(queue.encoded(), forKey: Self.queueKey) }
    }
    var considered: [String] = UserDefaults.standard.stringArray(forKey: consideredKey) ?? [] {
        didSet { UserDefaults.standard.set(considered, forKey: Self.consideredKey) }
    }
    /// The pass this app is running now (its own child; the app manages no other): its meeting and the child's pid
    /// (0 while it starts), which no other process can have until the app reaps it.
    var running: (sessionID: String, pid: Int32)?
    /// Another process holds `DeepTranscriptionLock` (a pass started in Terminal, or one left running from before a
    /// relaunch): nothing starts until it is free, checked every 30 s. The app never signals or adopts it.
    var otherPassRunning = false
    /// Meetings whose Review was asked for while this app's pass works on them: opened when the pass ends.
    var reviewAfterPass: [String: (directory: URL, name: String)] = [:]
    /// The pass stopped because a meeting started: it stays queued and runs again from the start afterwards.
    var preempted: String?
    /// Starting the command failed (a transient process limit), or another process held the meeting or the lock:
    /// tried again after this.
    var retryAfter: Date?
    /// Counts every turn of the setting on or off: a scan begun before one is dropped when it ends.
    var activation = 0
    /// Meetings whose command was refused because another command held them: skipped until then, so the others
    /// are not held up (another pass holding the lock delays everything, `retryAfter`).
    var delayed: [String: Date] = [:]
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
    /// What the Meetings list shows while the pass runs (`MeetingController.beginUsing`).
    static let deepRunningText = "Final transcript in progress…"

    /// At launch: every 30 s checks the power source (and so notices AC power coming back), checks the model again
    /// while another process downloads it (every 60 s while it is not installed and the setting is on or Settings
    /// shows, so an install in Terminal is noticed), and retries the queue. Run Now requests whose languages were
    /// being read when the app quit are read again.
    func setUpDeepTranscription() {
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
                self.scheduleDeepTranscription()
            }
        }
        scheduleDeepTranscription()
    }

    /// The doctor check reported the model (or could not run).
    func deepModelChecked(_ model: String) {
        let previous = meeting.deep.model
        meeting.deep.model = model
        // Meetings that finished while the model was missing or downloading were not queued: found again now.
        if DeepTranscriptionSchedule.reconcilesOnModelChange(from: previous, to: model) {
            reconcileDeepTranscription()
        }
        scheduleDeepTranscription()
    }

    /// A meeting is starting, recording, or saving: this app's pass running now is stopped (SIGTERM; it publishes
    /// nothing, or says it was cancelled late) and stays queued, so the meeting has the Mac to itself; it runs again
    /// afterwards. A pass another process runs is left alone: it is the user's own explicit run.
    func deepTranscriptionMeetingStateChanged() {
        guard let controller = meeting.controller, meetingIsBusy(controller.state),
              let running = meeting.deep.running, running.pid > 0, meeting.deep.preempted == nil,
              kill(running.pid, SIGTERM) == 0 else { return }
        meeting.deep.preempted = running.sessionID
        Self.deepLog.notice("Deep transcription of \(running.sessionID, privacy: .public) stopped for a meeting")
        updateDeepStates()
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
    /// installed, and the meeting in one language.
    func queueDeepTranscriptionAfterMeeting(sessionID: String) {
        guard DeepTranscriptionAppState.enabled, meeting.deep.model == "installed", let root = meeting.controller?.root,
              let directory = try? SessionLocator.resolve(sessionID, root: root) else { return }
        let activation = meeting.deep.activation
        // Reading the languages can mean decoding a long meeting's transcript: off the main actor.
        Task { [weak self] in
            let languages = await Task.detached { Self.languageCount(directory) }.value
            // The setting was turned off (and maybe on again) while it was read: that turning off took it off.
            // Checked against the live queue and the meetings considered: the user may have asked for it (and maybe
            // cancelled it) while it was read.
            guard let self, self.meeting.deep.activation == activation, DeepTranscriptionSchedule.queuesAfterMeeting(
                enabled: DeepTranscriptionAppState.enabled, modelInstalled: self.meeting.deep.model == "installed",
                languages: languages, queued: self.meeting.deep.queue.contains(sessionID),
                considered: self.meeting.deep.considered.contains(sessionID)) else { return }
            self.meeting.deep.queue.enqueue(sessionID: sessionID, path: directory.path, at: Date())
            self.meeting.deep.consider(sessionID)
            self.updateDeepStates()
            self.scheduleDeepTranscription()
        }
    }

    /// Once per launch, with the setting on and the model installed: queues the meetings that finished while the app
    /// was closed (in child-recorder mode a recorder saves and post-processes on its own after the app quits),
    /// started since the setting was turned on, in one language, with no deep transcript, and not queued before.
    func reconcileDeepTranscription() {
        guard DeepTranscriptionAppState.enabled, meeting.deep.model == "installed",
              let root = meeting.controller?.root, let since = DeepTranscriptionAppState.enabledSince else { return }
        let considered = Set(meeting.deep.considered)
        let queue = meeting.deep.queue
        let activation = meeting.deep.activation
        Task { [weak self] in
            let found = await Task.detached { () -> [DeepTranscriptionSchedule.Candidate] in
                let candidates = SessionCatalog.list(root: root)
                    .filter { $0.createdAt >= since && !considered.contains($0.id) && !queue.contains($0.id) }
                    .map { summary in
                        DeepTranscriptionSchedule.Candidate(
                            sessionID: summary.id, path: summary.directory.path, createdAt: summary.createdAt,
                            finished: DeepTranscriptionSchedule.isFinished(summary.state,
                                                                           audioDeleted: summary.audioDeleted),
                            languages: Self.languageCount(summary.directory),
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
            self.scheduleDeepTranscription()
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
            showDeepAlert("“\(Self.short(summary.name))” is not finished.",
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

    /// Reads the languages of a reserved Run Now request off the main actor, then queues it (one language) or leaves
    /// the meeting as it was with an alert (several). Cancelled meanwhile, nothing happens.
    private func checkRunNowLanguages(sessionID: String, directory: URL, name: String?) {
        Task { [weak self] in
            let languages = await Task.detached { Self.languageCount(directory) }.value
            guard let self, self.meeting.deep.queue.isPending(sessionID) else { return }
            let accepted = languages <= 1
            self.meeting.deep.queue.resolveRunNow(sessionID, accepted: accepted)
            if accepted { self.meeting.deep.retryAfter = nil }
            self.updateDeepStates()
            self.scheduleDeepTranscription()
            guard !accepted else { return }
            let shown = name ?? (try? SessionArchive.readManifest(at: directory).name) ?? "The meeting"
            self.showDeepAlert("“\(Self.short(shown))” is in several languages.",
                               "Deep transcription handles meetings in one language for now; its transcript stays as it "
                                   + "is.")
        }
    }

    /// Meetings › Cancel Final Transcript: takes the meeting off the queue and stops its pass (SIGTERM: the command
    /// cancels and says whether the new transcript was already published).
    func cancelDeepTranscription(_ sessionID: String) {
        // Only this app's own pass is signalled.
        if let running = meeting.deep.running, running.sessionID == sessionID, running.pid > 0 {
            kill(running.pid, SIGTERM)
        }
        if meeting.deep.preempted == sessionID { meeting.deep.preempted = nil }
        meeting.deep.delayed[sessionID] = nil
        meeting.deep.queue.remove(sessionID)
        updateDeepStates()
    }

    /// Starts the next pass when `DeepTranscriptionSchedule` says so.
    func scheduleDeepTranscription() {
        // With the setting off, automatic items go (the app's running pass keeps its own until it ends): at launch,
        // on every 30 s tick, and after every pass, however it ended.
        if meeting.deep.queue.dropAutomatic(enabled: DeepTranscriptionAppState.enabled,
                                            running: meeting.deep.running?.sessionID) {
            updateDeepStates()
        }
        guard let controller = meeting.controller, let maintenance = meeting.maintenance else { return }
        // Another process's pass holds the lock: wait for it (checked again every 30 s). One at a time on this Mac.
        if meeting.deep.running == nil {
            let other = DeepTranscriptionLock.state() != .free
            if other != meeting.deep.otherPassRunning {
                meeting.deep.otherPassRunning = other
                updateDeepStates()
            }
            if other { return }
        }
        if let retryAfter = meeting.deep.retryAfter, retryAfter > Date() { return }
        meeting.deep.retryAfter = nil
        let busy = meetingIsBusy(controller.state)
        let now = Date()
        meeting.deep.delayed = meeting.deep.delayed.filter { $0.value > now }
        // Review owns a meeting while it is open, opening, or still saving.
        let inUse = Set(controller.sessionsInUse.keys).union(controller.sessionsUnderReview())
        let situation = DeepTranscriptionSchedule.Situation(
            enabled: DeepTranscriptionAppState.enabled, modelInstalled: meeting.deep.model == "installed",
            power: meeting.deep.power, meetingBusy: busy, running: meeting.deep.running?.sessionID, inUse: inUse,
            delayed: Set(meeting.deep.delayed.keys))
        // A meeting deleted while queued is taken off, and the next ready one is picked in the same call.
        var queue = meeting.deep.queue
        let decision = DeepTranscriptionSchedule.nextPresent(&queue, situation) {
            FileManager.default.fileExists(atPath: $0)
        }
        if queue != meeting.deep.queue { meeting.deep.queue = queue }
        guard case .run(let sessionID) = decision,
              let item = meeting.deep.queue.items.first(where: { $0.sessionID == sessionID }) else {
            updateDeepStates()
            return
        }
        // Marked running before the meeting is taken: taking it schedules again (`onSessionsInUseChanged`), which must
        // then see one pass running and start no other.
        meeting.deep.running = (sessionID, 0)
        guard controller.beginUsing(sessionID, for: Self.deepRunningText) else {
            meeting.deep.running = nil
            return
        }
        let output = Self.temporaryFile("deep")
        let errors = Self.temporaryFile("deep-err")
        // Asked for from the meeting's menu: made again even when made before, and over edited labels.
        let arguments = ["session", "deep-transcribe", item.path, "--json"]
            + (DeepTranscriptionSchedule.forces(item) ? ["--force"] : [])
        do {
            let pid = try maintenance.run(arguments, standardOutput: output, standardError: errors) { [weak self] code in
                self?.deepTranscriptionEnded(sessionID, code: code, output: output, errors: errors)
            }
            meeting.deep.running = (sessionID, pid)
            Self.deepLog.notice("Deep transcription of \(sessionID, privacy: .public) started")
        } catch {
            // Kept queued: the scheduler tries again in a minute.
            meeting.deep.running = nil
            meeting.deep.retryAfter = Date().addingTimeInterval(60)
            controller.endUsing(sessionID)
            Self.removeFile(output)
            Self.removeFile(errors)
            Self.deepLog.error("Cannot start deep transcription: \(error.localizedDescription, privacy: .private)")
        }
        updateDeepStates()
    }

    private func deepTranscriptionEnded(_ sessionID: String, code: Int32, output: URL, errors: URL) {
        let errorText = (try? AtomicFile.readIfPresent(errors, maxBytes: 1 << 16)).flatMap {
            $0.map { String(decoding: $0, as: UTF8.self) }
        } ?? ""
        let record = (try? AtomicFile.readIfPresent(output, maxBytes: 16 << 20)).flatMap {
            $0.flatMap { try? HolosJSON.decoder().decode(PostProcessingRecord.self, from: $0) }
        }
        Self.removeFile(output)
        Self.removeFile(errors)
        let item = meeting.deep.queue.items.first { $0.sessionID == sessionID }
        var failure: String?
        let lateCancel = errorText.split(separator: "\n").first { $0.hasPrefix("Cancelled after the new transcript") }
        let preempted = meeting.deep.preempted == sessionID
        if preempted { meeting.deep.preempted = nil }
        switch DeepTranscriptionSchedule.passEnded(code: code, preempted: preempted, errors: errorText) {
        case .keepPreempted:
            // Stopped for a meeting: stays queued, and runs again from the start once the meeting is saved (an
            // automatic one only while the setting is on, which the scheduler applies).
            break
        case .retryLater(let global):
            // Stays queued. Another command holds the meeting: only it waits a minute, the others go on. Another
            // process's pass holds the lock: everything waits.
            if global {
                meeting.deep.retryAfter = Date().addingTimeInterval(60)
            } else {
                meeting.deep.delayed[sessionID] = Date().addingTimeInterval(60)
            }
        case .done:
            // Asked for from the menu and not done (a cancel takes it off the queue first): the user is told why.
            if item?.runNow == true, code != 0, lateCancel == nil {
                failure = DeepTranscriptionSchedule.failureText(code: code, record: record, errors: errorText)
            }
            // Done, refused (exit 1: no model, deleted audio, several languages), partial (3), or cancelled: off the
            // queue either way. Only a pass the app did not see end (a quit, a crash) stays queued, and runs again
            // from the start at the next launch. Off the queue before the meeting is let go of, since letting go
            // schedules the next pass.
            meeting.deep.queue.remove(sessionID)
            meeting.deep.delayed[sessionID] = nil
        }
        meeting.deep.running = nil
        meeting.controller?.endUsing(sessionID)
        Self.deepLog.notice("Deep transcription of \(sessionID, privacy: .public) ended with \(code, privacy: .public)")
        meeting.maintenanceEnded[sessionID, default: 0] += 1
        meeting.meetingsPane?.refresh()
        updateDeepStates()
        scheduleDeepTranscription()
        // The final transcript is a new transcript: its summary follows (§4.17).
        scheduleMeetingSummaries()
        // Review asked for while the pass worked on the meeting.
        if let review = meeting.deep.reviewAfterPass.removeValue(forKey: sessionID) {
            openReview(sessionID: sessionID, directory: review.directory, name: review.name)
        }
        if let lateCancel {
            // The new transcript was already current when the pass stopped: its labels and files may be behind.
            showDeepAlert("A final transcript was cancelled after it was saved.",
                          String(lateCancel).replacingOccurrences(of: "Run voiceislocal session diarize on the meeting",
                                                                  with: "Choose Label Speakers in Meetings"))
        } else if let failure, let item {
            let name = (try? SessionArchive.readManifest(at: URL(fileURLWithPath: item.path)).name).map {
                Self.short($0)
            } ?? "the meeting"
            showDeepAlert(code == 3 ? "The final transcript of “\(name)” is not complete."
                              : "The final transcript of “\(name)” was not made.", failure)
        }
    }

    /// The Meetings list's State column for queued and running passes.
    func updateDeepStates() {
        var states: [String: String] = [:]
        for item in meeting.deep.queue.items + meeting.deep.queue.pending {
            if let text = DeepTranscriptionSchedule.stateText(sessionID: item.sessionID, queue: meeting.deep.queue,
                                                              running: meeting.deep.running?.sessionID,
                                                              power: meeting.deep.power,
                                                              otherPassRunning: meeting.deep.otherPassRunning) {
                states[item.sessionID] = text
            }
        }
        let offersRunNow = Set(meeting.deep.queue.items.map(\.sessionID).filter {
            DeepTranscriptionSchedule.offersRunNow(sessionID: $0, queue: meeting.deep.queue,
                                                   running: meeting.deep.running?.sessionID)
        })
        meeting.meetingsPane?.update(deepStates: states, running: meeting.deep.running?.sessionID,
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
            meeting.deep.queue.removeAutomatic(keeping: meeting.deep.running?.sessionID)
        }
        updateSettings()
        updateDeepStates()
        scheduleDeepTranscription()
    }

    /// Settings' "Deep transcription" row: the model state, its progress or error, and the setting.
    func deepTranscriptionSetupState() -> (model: String?, detail: String?, enabled: Bool) {
        if let progress = meeting.deep.install { return ("installing", progress, DeepTranscriptionAppState.enabled) }
        return (meeting.deep.model, meeting.deep.installError, DeepTranscriptionAppState.enabled)
    }

    // MARK: - Helpers

    /// The most languages the meeting names: meeting.json's, or its current transcript's (`session languages` can
    /// merge several without changing meeting.json); 1 when neither names any or can be read.
    nonisolated static func languageCount(_ directory: URL) -> Int {
        var count = 1
        if let data = try? AtomicFile.readIfPresent(SessionPaths.meetingInfo(directory), maxBytes: 1 << 20),
           let info = try? HolosJSON.decoder().decode(MeetingInfo.self, from: data) {
            count = max(count, DictationLanguage.meetingLanguages(info.languages ?? []).count)
        }
        if let id = try? SessionArchive.currentTranscriptID(at: directory),
           let data = try? AtomicFile.readIfPresent(SessionPaths.transcript(id, in: directory), maxBytes: 256 << 20),
           let transcript = try? HolosJSON.decoder().decode(Transcript.self, from: data) {
            count = max(count, DictationLanguage.meetingLanguages(transcript.languages ?? []).count)
        }
        return count
    }

    /// Review asked for (from any entry point: Meetings, the menu bar's Name Speakers) while a deep transcription
    /// pass works on the meeting: this app's own (its `sessionsInUse` entry), or another process's (the lock's
    /// holder). Review would load a transcript and labels the pass is about to replace, so it waits: the alert says
    /// so and offers to cancel this app's pass; Review opens when this app's pass ends. Returns whether it waits.
    func reviewWaitsForDeepTranscription(sessionID: String, directory: URL, name: String) -> Bool {
        let own = meeting.controller?.sessionsInUse[sessionID] == Self.deepRunningText
            && meeting.deep.running?.sessionID == sessionID
        var other = false
        if !own, case .held(let holder?) = DeepTranscriptionLock.state() { other = holder.sessionID == sessionID }
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
