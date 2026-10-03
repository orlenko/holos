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
    /// Meetings queued once already (whatever came of it), so the launch check never queues them again.
    static let consideredKey = "deepTranscriptionConsidered"
    /// The most meetings `considered` remembers (the newest).
    static let consideredLimit = 1_000

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
    /// The pass running now: its meeting and the child's pid (0 while it starts).
    var running: (sessionID: String, pid: Int32)?
    /// A meeting whose command was refused because another process holds it: a pass started before the app was
    /// quit, still running. Only it is tried until it can be had, so two passes never run at once.
    var waitingFor: String?
    /// Starting the command failed (a transient process limit): tried again after this.
    var retryAfter: Date?
    /// The launch check of meetings that finished while the app was closed ran.
    var reconciled = false
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
        considered = Array((considered + [sessionID]).suffix(Self.consideredLimit))
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
    /// while another process downloads it, and retries the queue.
    func setUpDeepTranscription() {
        meeting.deep.power = PowerSource.current()
        meeting.deep.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let power = PowerSource.current()
                if power != self.meeting.deep.power {
                    self.meeting.deep.power = power
                    self.updateDeepStates()
                }
                // A download started before this launch (detached) ends without telling this app.
                if self.meeting.deep.model == "downloading" { self.refreshSpeakerModels() }
                self.scheduleDeepTranscription()
            }
        }
        scheduleDeepTranscription()
    }

    /// The doctor check reported the model (or could not run).
    func deepModelChecked(_ model: String) {
        meeting.deep.model = model
        reconcileDeepTranscription()
        scheduleDeepTranscription()
    }

    // MARK: - Queue

    /// After a meeting is saved and its own post-processing ended: queued when the setting is on, the model
    /// installed, and the meeting in one language.
    func queueDeepTranscriptionAfterMeeting(sessionID: String) {
        guard let root = meeting.controller?.root,
              let directory = try? SessionLocator.resolve(sessionID, root: root) else { return }
        let languages = Self.languageCount(directory)
        guard DeepTranscriptionSchedule.queuesAfterMeeting(enabled: DeepTranscriptionAppState.enabled,
                                                          modelInstalled: meeting.deep.model == "installed",
                                                          languages: languages) else { return }
        meeting.deep.queue.enqueue(sessionID: sessionID, path: directory.path, at: Date())
        meeting.deep.consider(sessionID)
        updateDeepStates()
        scheduleDeepTranscription()
    }

    /// Once per launch, with the setting on and the model installed: queues the meetings that finished while the app
    /// was closed (in child-recorder mode a recorder saves and post-processes on its own after the app quits),
    /// started since the setting was turned on, in one language, with no deep transcript, and not queued before.
    func reconcileDeepTranscription() {
        guard !meeting.deep.reconciled, DeepTranscriptionAppState.enabled, meeting.deep.model == "installed",
              let root = meeting.controller?.root, let since = DeepTranscriptionAppState.enabledSince else { return }
        meeting.deep.reconciled = true
        let considered = Set(meeting.deep.considered)
        let queue = meeting.deep.queue
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
            guard let self, !found.isEmpty else { return }
            for candidate in found {
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
        guard Self.languageCount(summary.directory) <= 1 else {
            showDeepAlert("“\(Self.short(summary.name))” is in several languages.",
                          "Deep transcription handles meetings in one language for now; its transcript stays as it is.")
            return
        }
        meeting.deep.queue.enqueue(sessionID: summary.id, path: summary.directory.path, at: Date(), runNow: true)
        meeting.deep.consider(summary.id)
        meeting.deep.retryAfter = nil
        updateDeepStates()
        scheduleDeepTranscription()
    }

    /// Meetings › Cancel Final Transcript: takes the meeting off the queue and stops its pass (SIGTERM: the command
    /// cancels and says whether the new transcript was already published).
    func cancelDeepTranscription(_ sessionID: String) {
        meeting.deep.queue.remove(sessionID)
        if meeting.deep.waitingFor == sessionID { meeting.deep.waitingFor = nil }
        if let running = meeting.deep.running, running.sessionID == sessionID, running.pid > 0 {
            kill(running.pid, SIGTERM)
        }
        updateDeepStates()
    }

    /// Starts the next pass when `DeepTranscriptionSchedule` says so.
    func scheduleDeepTranscription() {
        guard let controller = meeting.controller, let maintenance = meeting.maintenance else { return }
        if let retryAfter = meeting.deep.retryAfter, retryAfter > Date() { return }
        meeting.deep.retryAfter = nil
        let busy: Bool = switch controller.state {
        case .idle, .failed: false
        default: true
        }
        // Review owns a meeting while it is open, opening, or still saving.
        let inUse = Set(controller.sessionsInUse.keys).union(controller.sessionsUnderReview())
        let situation = DeepTranscriptionSchedule.Situation(
            enabled: DeepTranscriptionAppState.enabled, modelInstalled: meeting.deep.model == "installed",
            power: meeting.deep.power, meetingBusy: busy, running: meeting.deep.running?.sessionID, inUse: inUse,
            waitingFor: meeting.deep.waitingFor)
        guard case .run(let sessionID) = DeepTranscriptionSchedule.next(meeting.deep.queue, situation),
              let item = meeting.deep.queue.items.first(where: { $0.sessionID == sessionID }) else {
            updateDeepStates()
            return
        }
        guard FileManager.default.fileExists(atPath: item.path) else {
            meeting.deep.queue.remove(sessionID)
            if meeting.deep.waitingFor == sessionID { meeting.deep.waitingFor = nil }
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
        let arguments = ["session", "deep-transcribe", item.path, "--json"] + (item.runNow ? ["--force"] : [])
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
        Self.removeFile(output)
        Self.removeFile(errors)
        if code == 1, DeepTranscriptionSchedule.isLeaseConflict(errorText) {
            // A pass from before a relaunch still holds the meeting: it stays queued, and nothing else starts until it
            // can be had again (then the queued one finds the transcript made, or makes it).
            meeting.deep.waitingFor = sessionID
            meeting.deep.retryAfter = Date().addingTimeInterval(60)
        } else {
            // Done, refused (exit 1: no model, deleted audio, several languages), partial (3), or cancelled: off the
            // queue either way. Only a pass the app did not see end (a quit, a crash) stays queued, and runs again
            // from the start at the next launch. Off the queue before the meeting is let go of, since letting go
            // schedules the next pass.
            meeting.deep.queue.remove(sessionID)
            if meeting.deep.waitingFor == sessionID { meeting.deep.waitingFor = nil }
        }
        meeting.deep.running = nil
        meeting.controller?.endUsing(sessionID)
        Self.deepLog.notice("Deep transcription of \(sessionID, privacy: .public) ended with \(code, privacy: .public)")
        meeting.maintenanceEnded[sessionID, default: 0] += 1
        meeting.meetingsPane?.refresh()
        updateDeepStates()
        scheduleDeepTranscription()
    }

    /// The Meetings list's State column for queued and running passes.
    func updateDeepStates() {
        var states: [String: String] = [:]
        for item in meeting.deep.queue.items {
            if let text = DeepTranscriptionSchedule.stateText(sessionID: item.sessionID, queue: meeting.deep.queue,
                                                              running: meeting.deep.running?.sessionID,
                                                              power: meeting.deep.power) {
                states[item.sessionID] = text
            }
        }
        meeting.meetingsPane?.update(deepStates: states, running: meeting.deep.running?.sessionID)
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
        if on {
            DeepTranscriptionAppState.enabledSince = Date()
        } else {
            meeting.deep.queue.removeAutomatic()
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
