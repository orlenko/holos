import AppKit
import Foundation
import HolosAudio
import HolosCore
import HolosMeeting
import HolosStorage
import os

/// What the menu bar keeps about meetings (docs/meeting-design.md §5.8).
@MainActor
final class MeetingAppState {
    static let modeKey = "meetingRecorderMode"
    static let lastSettingsKey = "meeting.lastSettings"
    static let consentKey = "meeting.consentReminderDismissed"
    static let promptedKey = "meeting.promptedInterrupted"
    /// Settings › Meetings: meetings record the computer's audio too (on when never set).
    static let recordSystemAudioKey = "meetingRecordSystemAudio"
    /// Settings › Meetings: capture the screen during meetings (`MeetingScreenPreference`, off for new installs).
    static var screenCaptureDefault: Bool {
        get { MeetingScreenPreference.enabled(in: .standard) }
        set { MeetingScreenPreference.set(newValue, in: .standard) }
    }
    /// The meeting languages chosen in the start panel (`HolosAppDelegate.meetingLocales`).
    static let localesKey = "meetingLocales"

    static var recordSystemAudio: Bool {
        get { UserDefaults.standard.object(forKey: recordSystemAudioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: recordSystemAudioKey) }
    }

    var controller: MeetingController?
    var maintenance: MaintenanceLauncher?
    /// Set in in-process mode (UserDefaults "meetingRecorderMode" = "inProcess").
    var inProcess: InProcessLauncher?
    /// The latest `announce` text, shown under the meeting's first menu line.
    var notice: String?
    /// The meeting started from the app that records the microphone alone because System audio was not allowed,
    /// and the menu line saying so. Saved in UserDefaults, so a relaunch that follows the same meeting shows it again.
    var sourceNotice: MeetingSourceNotice? = MeetingSourceNotice.load(from: .standard) {
        didSet { MeetingSourceNotice.save(sourceNotice, to: .standard) }
    }
    /// The case of the last meeting state seen ("idle", "starting", …).
    var lastStep = "idle"
    /// How the last meeting ended, until the next one starts.
    var lastSummary: (sessionID: String, text: String)?
    var startPanel: MeetingStartPanel?
    var meetingsPane: MeetingsPane?
    /// Open review windows by session ID (one per meeting), and reviews being opened (the window once shown, nil when
    /// it was not).
    var reviewWindows: [String: ReviewWindow] = [:]
    /// Checks the open review windows' titles every 2 s, whatever the main window shows, so a rename in Terminal (or
    /// a new generated title) reaches them; it ends when the last one closes.
    var reviewTitleWatch: Task<Void, Never>?
    var openingReviews: [String: Task<ReviewWindow?, Never>] = [:]
    /// The run of the Meetings or interrupted-prompt command working on a meeting, by session ID
    /// (`ReviewMaintenance`).
    var maintenanceOn: [String: ReviewMaintenance.Hold] = [:]
    /// The run of the automatic relabel working on a meeting, by session ID.
    var automaticHolds: [String: ReviewMaintenance.Hold] = [:]
    /// How many maintenance commands have ended per meeting, so a review that opened meanwhile rereads it.
    var maintenanceEnded: [String: Int] = [:]
    /// A deletion of several meetings from Meetings, one at a time (`performBulkMeetingAction`): its action, how many
    /// meetings it has still to do (what a quit says), and whether a quit waits for it.
    var bulkRun: Task<Void, Never>?
    var bulkAction: MeetingBulkPlan.Action?
    var bulkRemaining = 0
    var bulkQuitting = false
    /// Its failure report while a quit waits on it, shown if the quit does not go ahead.
    var bulkReport = MeetingBulkReportHold()
    /// Holos is quitting: review windows close without alerts.
    var quitting = false
    var savingWindow: NSWindow?
    /// `voiceislocal doctor --json` speakerModels ("verified", "notInstalled", "damaged"), "unavailable" when the voiceislocal tool
    /// cannot run, "unknown" when it ran but did not report them, nil before the first check.
    var speakerModels: String?
    var checkingSpeakerModels = false
    /// Progress of `voiceislocal setup --speakers` while it runs.
    var speakerModelInstall: String?
    /// The last install's failure, shown until the next attempt.
    var speakerModelError: String?
    /// The start panel's speech model checks and installs (HolosApp+MeetingLanguage.swift).
    var speechModels: [String: String] = [:]
    var speechModelInstalling: String?
    var speechModelErrors: [String: String] = [:]
    /// The status item's menu is open; per-second updates change its lines in place.
    var menuOpen = false
    var menuStale = false
    /// The meeting layout the menu was last built for.
    var menuLayout: MeetingMenuLayout?
    weak var headlineItem: NSMenuItem?
    weak var detailItem: NSMenuItem?
    /// Windows that give Holos a Dock icon while open.
    var windowsInDock: Set<String> = []
    /// Deep transcription after meetings (docs/meeting-design.md §4.16, "App").
    let deep = DeepTranscriptionAppState()
    /// Meeting titles and summaries (docs/meeting-design.md §4.17).
    let summaries = MeetingSummaryAppState()
    /// The acoustic echo analysis of calls that miss it (docs/meeting-design.md §5.11, "Catching up in the app").
    let echo = EchoCatchUpAppState()
}

extension HolosAppDelegate: NSMenuDelegate {
    private static let meetingLog = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    // MARK: - Launch

    /// Creates the meeting controller, follows a live meeting, and checks the speaker models (§5.8).
    func setUpMeetings() {
        let executable = ChildProcessLauncher.bundledExecutable
        let maintenance = MaintenanceLauncher(executable: executable)
        let launcher: any RecorderLauncher
        if UserDefaults.standard.string(forKey: MeetingAppState.modeKey) == "inProcess" {
            let inProcess = InProcessLauncher(executable: executable)
            meeting.inProcess = inProcess
            launcher = inProcess
        } else {
            launcher = ChildProcessLauncher(executable: executable)
        }
        let controller = MeetingController(
            launcher: launcher, maintenance: maintenance, freeSpace: VolumeFreeSpace(),
            findInputDevices: { BuiltInMicrophone.devices() },
            vocabulary: { [weak self] languages in self?.meetingVocabulary(languages: languages) ?? [] },
            modelsInstalled: { [weak self] in self?.meeting.speakerModels == "verified" },
            onChange: { [weak self] state in self?.meetingStateChanged(state) },
            onEffect: { [weak self] effect in self?.handleMeetingEffect(effect) })
        controller.onSessionsInUseChanged = { [weak self, weak controller] in
            guard let controller else { return }
            self?.meeting.meetingsPane?.update(running: controller.sessionsInUse)
            // A meeting another command let go of may be the next deep transcription's, the next summary's, or the
            // next echo analysis's. Summaries are looked for first, so a Summarize Again waiting goes before the next
            // automatic job (which waits for that scan); the echo analysis goes before an automatic final transcript.
            self?.scheduleMeetingSummaries()
            self?.scheduleEchoCatchUp()
            self?.scheduleDeepTranscription()
        }
        // Reviews open, opening, or still saving after they closed: the automatic relabel leaves those meetings alone.
        controller.sessionsUnderReview = { [weak self] in
            guard let self else { return [] }
            return Set(self.meeting.reviewWindows.keys).union(self.meeting.openingReviews.keys)
        }
        controller.onAutoRelabel = { [weak self] sessionID, running in
            self?.automaticRelabelChanged(sessionID, running: running)
        }
        meeting.controller = controller
        meeting.maintenance = maintenance
        Self.sweepCommandOutputs()
        controller.attachOnLaunch()
        refreshSpeakerModels()
        setUpDeepTranscription()
        setUpMeetingSummaries()
        setUpEchoCatchUp()
        Task { [weak self] in await self?.promptAboutInterruptedRecordings() }
    }

    // MARK: - State and effects

    private func meetingStateChanged(_ state: MeetingState) {
        // A notice belongs to the step it was made in ("Waiting for permission…" while starting): recording, saving,
        // or a failure replaces it.
        let step = Self.step(state)
        if step != meeting.lastStep, ["active", "finishing", "failed"].contains(step) { meeting.notice = nil }
        meeting.lastStep = step
        // The recorder rewrites its status every second. Only a change of the menu's lines rebuilds it (never while
        // it is open, under the pointer); the clock and progress lines are retitled in place.
        if MeetingMenuLayout(state) == meeting.menuLayout {
            refreshMeetingItemsInPlace()
            refreshStatusItem()
        } else if meeting.menuOpen {
            refreshMeetingItemsInPlace()
            meeting.menuStale = true
            refreshStatusItem()
        } else {
            rebuildMenu()
        }
        meeting.meetingsPane?.update(meetingState: state)
        // A meeting needs the Mac: a final transcript, a summary or an echo analysis in progress is stopped and runs
        // again afterwards.
        deepTranscriptionMeetingStateChanged()
        meetingSummaryMeetingStateChanged()
        echoCatchUpMeetingStateChanged()
    }

    private func handleMeetingEffect(_ effect: MeetingEffect) {
        switch effect {
        case .announce(let text):
            meeting.notice = text
        case .finished(let sessionID, let summary, _):
            meeting.lastSummary = (sessionID, summary)
            meeting.notice = nil
            meeting.meetingsPane?.refresh()
            // The meeting's own post-processing ran in the recorder: the final transcript can follow (§4.16), and its
            // title and summary once that is decided (§4.17). Its echo analysis was made then too, unless it failed:
            // the meetings are looked at again (§5.11).
            queueDeepTranscriptionAfterMeeting(sessionID: sessionID)
            scanEchoCatchUp()
        case .offerNaming, .clearNamingOffer:
            // `MeetingController.namingOffer` changed; the menu and the status item show it.
            break
        case .launch, .send, .terminateChild:
            return
        }
        rebuildMenu()
    }

    // MARK: - Menu

    /// The meeting lines at the top of the menu, followed by a separator.
    func addMeetingItems(to menu: NSMenu) {
        guard let controller = meeting.controller else { return }
        meeting.headlineItem = nil
        meeting.detailItem = nil
        meeting.menuLayout = MeetingMenuLayout(controller.state)
        switch controller.state {
        case .idle:
            if let offer = controller.namingOffer {
                menu.addItem(item("Name Speakers — \(Self.short(offer.name))…", #selector(nameSpeakers)))
            }
            if let notice = meeting.notice { menu.addItem(disabledLine(notice)) }
            if let summary = meeting.lastSummary {
                let line = item(Self.short(summary.text, limit: 90), #selector(showLastMeeting))
                line.toolTip = summary.text
                menu.addItem(line)
            }
            menu.addItem(item("Start Meeting Recording…", #selector(startMeetingRecording)))
        case .starting:
            // The recorder notices a stop only once its start returns (after a permission prompt is answered), so
            // the item says Stop, and the menu says so once it was asked.
            let stopping = controller.reducer.stoppedWhileStarting
            let name = Self.short(controller.reducer.meetingName ?? "meeting")
            let headline = disabledLine(stopping ? "◌ Stopping — \(name)…" : "◌ Starting — \(name)")
            menu.addItem(headline)
            meeting.headlineItem = headline
            if let notice = meeting.notice { menu.addItem(disabledLine(notice, indent: 1)) }
            if let source = sourceNotice(controller) { menu.addItem(disabledLine(source, indent: 1)) }
            addRecordingControls(MeetingRecordingControls(controller), to: menu)
        case .active(_, let status):
            addRecordingItems(status, to: menu)
        case .finishing(_, let status):
            if let offer = controller.namingOffer {
                menu.addItem(item("Name Speakers — \(Self.short(offer.name))…", #selector(nameSpeakers)))
            }
            let headline = disabledLine(Self.savingText(status, name: controller.reducer.meetingName))
            menu.addItem(headline)
            meeting.headlineItem = headline
        case .failed(_, let message):
            let line = disabledLine("⚠ " + Self.short(message, limit: 90))
            line.toolTip = message
            menu.addItem(line)
            menu.addItem(item("Dismiss", #selector(dismissMeetingFailure)))
            menu.addItem(item("Start Meeting Recording…", #selector(startMeetingRecording)))
        }
        menu.addItem(.separator())
    }

    private func addRecordingItems(_ status: RecorderStatus, to menu: NSMenu) {
        let headline = disabledLine(Self.headline(status))
        menu.addItem(headline)
        meeting.headlineItem = headline
        let detail = disabledLine(Self.detailLine(status), indent: 1)
        menu.addItem(detail)
        meeting.detailItem = detail
        if let microphone = status.microphoneLine { menu.addItem(disabledLine(microphone, indent: 1)) }
        if let transcription = Self.transcriptionLine(status) {
            menu.addItem(disabledLine(transcription, indent: 1))
        }
        for warning in Self.shownWarnings(status) {
            menu.addItem(disabledLine("⚠ \(warning.message)", indent: 1))
        }
        if let notice = meeting.notice { menu.addItem(disabledLine(notice, indent: 1)) }
        if let controller = meeting.controller, let source = sourceNotice(controller) {
            menu.addItem(disabledLine(source, indent: 1))
        }
        addRecordingControls(MeetingRecordingControls(meeting.controller), to: menu)
    }

    /// Pause or Resume Recording, Add Marker…, Show Live Transcript…, and Stop and Save… while a meeting records;
    /// Stop Recording while it starts (`MeetingRecordingControls`, the rules the live transcript's header and the
    /// meeting's menu in Meetings follow too).
    private func addRecordingControls(_ controls: MeetingRecordingControls, to menu: NSMenu) {
        if let pause = controls.pause {
            let entry = item(pause.title, pause == .pause ? #selector(pauseMeetingRecording)
                                                          : #selector(resumeMeetingRecording))
            entry.isEnabled = controls.pauseEnabled
            menu.addItem(entry)
            let marker = item("Add Marker…", #selector(addMeetingMarker))
            marker.isEnabled = controls.markerEnabled
            menu.addItem(marker)
            menu.addItem(item("Show Live Transcript…", #selector(showLiveTranscript)))
        }
        if let stop = controls.stop {
            let entry = item(stop.title, #selector(stopMeetingRecording))
            entry.isEnabled = controls.stopEnabled
            menu.addItem(entry)
        }
    }

    func addAboutItem(to menu: NSMenu) {
        menu.addItem(item("About Voice is Local", #selector(showAbout)))
    }

    private func disabledLine(_ title: String, indent: Int = 0) -> NSMenuItem {
        let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        line.isEnabled = false
        line.indentationLevel = indent
        return line
    }

    /// Keeps the open menu's clock and headline current without replacing the menu under the pointer.
    private func refreshMeetingItemsInPlace() {
        guard let controller = meeting.controller else { return }
        switch controller.state {
        case .active(_, let status):
            meeting.headlineItem?.title = Self.headline(status)
            meeting.detailItem?.title = Self.detailLine(status)
        case .finishing(_, let status):
            meeting.headlineItem?.title = Self.savingText(status, name: controller.reducer.meetingName)
        default:
            break
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        meeting.menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        meeting.menuOpen = false
        if meeting.menuStale {
            meeting.menuStale = false
            rebuildMenu()
        }
    }

    // MARK: - Status item

    /// The status item's symbol, clock, and tooltip, without rebuilding the menu.
    private func refreshStatusItem() {
        if let tip = meetingToolTip() { statusItem?.button?.toolTip = tip }
        updateStatusItemAppearance()
    }

    /// Idle: the waveform (with a dot while a naming offer waits). Recording: a red record symbol and the elapsed
    /// time; paused and waiting have their own symbols; "⚠" while a warning is present. Saving: the waveform and "…".
    func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let state = meeting.controller?.state ?? .idle
        var symbol = "waveform"
        var title = ""
        var tint: NSColor?
        switch state {
        case .idle:
            if meeting.controller?.namingOffer != nil { title = "•" }
        case .starting:
            symbol = "record.circle"
            title = "…"
        case .active(_, let status):
            switch status.phase {
            case .paused:
                symbol = "pause.circle.fill"
            case .waiting, .sleeping:
                symbol = "circle.dotted"
            default:
                symbol = "record.circle.fill"
                tint = .systemRed
            }
            title = MeetingFormat.clock(status.elapsedSeconds) + (Self.shownWarnings(status).isEmpty ? "" : " ⚠")
        case .finishing:
            title = "…"
        case .failed:
            symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice is Local")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice is Local")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        // A plain title lets the status bar choose its text color for the current appearance and highlight.
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.title = title.isEmpty ? "" : " " + title
    }

    /// The tooltip while a meeting is followed; nil otherwise (the dictation message is used).
    func meetingToolTip() -> String? {
        guard let controller = meeting.controller else { return nil }
        switch controller.state {
        case .idle: return nil
        case .starting: return "Voice is Local — " + (meeting.notice ?? "starting a meeting recording")
        case .active(_, let status): return "Voice is Local — \(Self.headline(status)), \(MeetingFormat.clock(status.elapsedSeconds))"
        case .finishing(let id, let status): return "Voice is Local — " + Self.savingText(status, name: status?.name ?? id)
        case .failed(_, let message): return "Voice is Local — " + message
        }
    }

    // MARK: - Texts

    /// The state's case, for noticing a change of step.
    private static func step(_ state: MeetingState) -> String {
        switch state {
        case .idle: "idle"
        case .starting: "starting"
        case .active: "active"
        case .finishing: "finishing"
        case .failed: "failed"
        }
    }

    static func short(_ text: String, limit: Int = 60) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }

    static func headline(_ status: RecorderStatus) -> String {
        let name = short(status.name)
        return switch status.phase {
        case .paused: "⏸ Paused — \(name)"
        case .waiting: "◌ Waiting for audio — \(name)"
        case .sleeping: "◌ Paused while the Mac sleeps — \(name)"
        case .stopping: "Stopping — \(name)…"
        case .starting: "◌ Starting — \(name)"
        default: "● Recording — \(name)"
        }
    }

    /// The recorder's warnings the menu shows: all but `echoRisk`, which recorders before the one-mode change wrote
    /// while a call played on the laptop speakers.
    static func shownWarnings(_ status: RecorderStatus) -> [RecorderWarning] {
        status.warnings.filter { $0.code != .echoRisk }
    }

    /// The menu line of the followed meeting when it records the microphone alone for want of the permission.
    private func sourceNotice(_ controller: MeetingController) -> String? {
        meeting.sourceNotice?.text(for: controller.state.sessionID)
    }

    /// "1:23:45 · 0.9 GB used · 22.8 GB free".
    static func detailLine(_ status: RecorderStatus) -> String {
        var parts = [MeetingFormat.clock(status.elapsedSeconds), "\(MeetingFormat.gigabytes(status.bytesWritten)) used"]
        if let free = status.freeBytes { parts.append("\(MeetingFormat.gigabytes(free)) free") }
        if let screen = status.screenSnapshotStatus { parts.append(screen) }
        return parts.joined(separator: " · ")
    }

    static func transcriptionLine(_ status: RecorderStatus) -> String? {
        let states = status.tracks.map(\.transcription)
        guard !states.isEmpty else { return nil }
        if states.contains(.behind) { return "Transcription: behind — will finish after stop" }
        if states.allSatisfy({ $0 == .off }) { return "Transcription: off" }
        return "Transcription: live"
    }

    /// "Saving Council meeting — labelling speakers 42%".
    static func savingText(_ status: RecorderStatus?, name: String?) -> String {
        let meetingName = short(status?.name ?? name ?? "meeting")
        guard let status else { return "Saving \(meetingName)…" }
        if status.phase == .transcribing { return "Saving \(meetingName) — finishing the transcript…" }
        guard let progress = status.progress else { return "Saving \(meetingName)…" }
        let percent = progress.fraction.map { " \(Int((min(1, max(0, $0)) * 100).rounded()))%" } ?? ""
        let what = switch progress.stage {
        case .languages: "detecting languages"
        case .wordFixes: "fixing misheard words"
        case .render, .echo, .diarize, .align, .recognize: "labelling speakers"
        case .export: "writing transcript files"
        default: "reading the transcript"
        }
        return "Saving \(meetingName) — \(what)\(percent)"
    }

    // MARK: - Actions

    @objc func startMeetingRecording() {
        guard meeting.controller != nil else { return }
        if meeting.startPanel == nil {
            meeting.startPanel = MeetingStartPanel(
                environment: { [weak self] in self?.startPanelEnvironment() ?? .unknown },
                onStart: { [weak self] settings, hideConsent in
                    self?.startMeeting(settings, hideConsentReminder: hideConsent)
                },
                onInstallSpeakerModels: { [weak self] in self?.installSpeakerModels() },
                onCheckSpeechModel: { [weak self] locale in self?.checkMeetingSpeechModel(locale) },
                onInstallSpeechModel: { [weak self] locale in self?.installMeetingSpeechModel(locale) },
                onClose: { [weak self] in self?.setDockPresence(false, for: "start") })
        }
        let saved = UserDefaults.standard.data(forKey: MeetingAppState.lastSettingsKey)
            .flatMap { try? HolosJSON.decoder().decode(MeetingStartSettings.self, from: $0) }
        setDockPresence(true, for: "start")
        meeting.startPanel?.show(
            name: MeetingStartSettings.defaultName(now: Date(), timeZone: .current), saved: saved,
            // No languages yet while the default one is not known: the panel keeps Start off until they arrive.
            locales: meetingLocales ?? [],
            consentDismissed: UserDefaults.standard.bool(forKey: MeetingAppState.consentKey))
        if localeGroups.isEmpty { Task { await loadLanguages() } }
        if meeting.speakerModels != "verified" { refreshSpeakerModels() }
    }

    private func startPanelEnvironment() -> MeetingStartPanel.Environment {
        let root = meeting.controller?.root ?? HolosPaths.sessions
        var environment = MeetingStartPanel.Environment(
            devices: BuiltInMicrophone.devices(), freeBytes: try? VolumeFreeSpace().availableBytes(at: root),
            speakerModels: meeting.speakerModels, checking: meeting.checkingSpeakerModels,
            installProgress: meeting.speakerModelInstall, installError: meeting.speakerModelError,
            recordSystemAudio: MeetingAppState.recordSystemAudio, systemAudioAllowed: CGPreflightScreenCaptureAccess(),
            screenCaptureDefault: MeetingAppState.screenCaptureDefault)
        addLanguages(to: &environment)
        return environment
    }

    /// Starts from the panel; returns the error text to show there, or nil once the recorder is starting.
    private func startMeeting(_ settings: MeetingStartSettings, hideConsentReminder: Bool) -> String? {
        guard let controller = meeting.controller else { return "Meetings are not available." }
        // The panel keeps Start off until it has a language; without one the recorder would take its own default.
        guard !settings.normalized().locales.isEmpty else {
            return "Still finding the meeting language; try again in a moment."
        }
        meeting.notice = nil
        do {
            try controller.start(settings)
        } catch {
            return error.localizedDescription
        }
        meeting.sourceNotice = MeetingSourceNotice.started(settings, sessionID: controller.state.sessionID,
                                                           recordSystemAudio: MeetingAppState.recordSystemAudio)
        rememberMeetingLocales(settings)
        var remembered = settings
        remembered.name = ""
        remembered.locales = []  // kept in `meetingLocales` instead
        remembered.screen = nil  // the next meeting's "Capture screen" starts from Settings, not the last meeting
        if let data = try? HolosJSON.encoder().encode(remembered) {
            UserDefaults.standard.set(data, forKey: MeetingAppState.lastSettingsKey)
        }
        if hideConsentReminder { UserDefaults.standard.set(true, forKey: MeetingAppState.consentKey) }
        meeting.lastSummary = nil
        rebuildMenu()
        return nil
    }

    /// The menu bar's Stop and Save… (Stop Recording while the meeting starts).
    @objc func stopMeetingRecording() { performMeetingRecordingCommand(.stop) }

    @objc func pauseMeetingRecording() { performMeetingRecordingCommand(.pause) }

    @objc func resumeMeetingRecording() { performMeetingRecordingCommand(.resume) }

    /// Stop, Pause, and Resume of the followed meeting from the menu bar, the live transcript's header, or the
    /// meeting's menu in Meetings: one path with the menu bar's rules (`MeetingRecordingCommands.perform`).
    /// `sessionID`: the meeting the control was shown for (nil: the one followed). `window`: the window the control is
    /// in, where Stop and Save…'s question shows as a sheet; without one it is a modal alert, as from the menu bar.
    func performMeetingRecordingCommand(_ command: MeetingRecordingCommand, sessionID: String? = nil,
                                        window: NSWindow? = nil) {
        guard let controller = meeting.controller else { return }
        MeetingRecordingCommands.perform(command, on: controller, sessionID: sessionID) { [weak self] question, answer in
            self?.askToStopMeeting(question, window: window) { [weak self] confirmed in
                answer(confirmed)
                self?.meeting.meetingsPane?.refreshLiveHeader()
            }
        }
        // A stop asked for leaves the state as it was until the recorder answers: the header's Stop turns off now.
        meeting.meetingsPane?.refreshLiveHeader()
    }

    private func askToStopMeeting(_ question: MeetingRecordingCommands.StopQuestion, window: NSWindow?,
                                  answer: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = question.message
        alert.informativeText = question.information
        alert.addButton(withTitle: MeetingRecordingCommands.StopQuestion.stopButton)
        alert.addButton(withTitle: MeetingRecordingCommands.StopQuestion.keepButton)
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(response == .alertFirstButtonReturn) }
            }
            return
        }
        NSApplication.shared.activate()
        answer(alert.runModal() == .alertFirstButtonReturn)
    }

    @objc func addMeetingMarker() {
        guard let controller = meeting.controller, case .active = controller.state else { return }
        let alert = NSAlert()
        alert.messageText = "Add a marker"
        alert.informativeText = "The marker notes this moment in the recording. A label is optional."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Label (optional)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add Marker")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.addMarker(label: String(field.stringValue.prefix(200)))
    }

    /// "Show Live Transcript…": the main window's Meetings section with the meeting's live transcript.
    @objc func showLiveTranscript() {
        guard let controller = meeting.controller, let id = controller.state.sessionID else { return }
        showMainWindow(.meetings)
        meeting.meetingsPane?.showLive(sessionID: id, directory: controller.sessionURL(id))
    }

    /// The live transcript's header for meeting `sessionID`: its name, phase, and what it is doing.
    func liveMeetingHeader(sessionID: String, summary: SessionSummary?) -> LiveMeetingHeader {
        let state = meeting.controller?.state ?? .idle
        let follows = state.sessionID == sessionID
        let status = follows ? meeting.controller?.status : nil
        let phase = LiveMeetingPhase.of(sessionID: sessionID, state: state, summary: summary)
        // Once saved, the title the Meetings list shows (a rename, or the generated title); while it records, the
        // name it was started with.
        let finished = phase == .saved || phase == .interrupted || phase == .failed
        let name = (finished ? summary?.displayTitle : nil) ?? status?.name
            ?? (follows ? meeting.controller?.reducer.meetingName : nil) ?? summary?.displayTitle ?? "Meeting"
        let detail: String
        switch phase {
        case .starting:
            detail = "Starting…"
        case .recording, .paused:
            var parts = [status.map { MeetingFormat.clock($0.elapsedSeconds) } ?? "Recording"]
            if phase == .paused { parts.insert("Paused", at: 0) }
            if let status, status.tracks.contains(where: { $0.transcription == .behind }) {
                parts.append("transcription is behind; the rest is transcribed after stop")
            }
            detail = parts.joined(separator: " · ")
        case .saving:
            detail = Self.savingText(status, name: name)
        case .saved:
            detail = (summary.map(MeetingsPane.stateText) ?? "Saved")
                + (summary.map { " · \(MeetingFormat.clock($0.savedSeconds))" } ?? "")
        case .interrupted:
            detail = "Interrupted before it was saved · select it in Meetings and choose Recover…"
        case .failed:
            if follows, case .failed(_, let message) = state {
                detail = message
            } else {
                detail = summary.map(MeetingsPane.stateText) ?? "Failed"
            }
        }
        // Stop and Pause for the meeting the app follows (a meeting the voiceislocal tool records has none here).
        let controls = follows ? MeetingRecordingControls(meeting.controller) : .none
        return LiveMeetingHeader(name: name, phase: phase, detail: detail, controls: controls)
    }

    @objc func showMeetings() {
        showMeetingsWindow(selecting: nil)
    }

    /// "Name Speakers — <name>…": opens Review for the meeting (Meetings, with the meeting selected, when it cannot
    /// be reviewed) and reports `reviewOpened`, which ends the offer.
    @objc func nameSpeakers() {
        guard let controller = meeting.controller, let offer = controller.namingOffer else { return }
        openReview(sessionID: offer.sessionID, directory: controller.sessionURL(offer.sessionID), name: offer.name,
                   fallBackToMeetings: true)
    }

    @objc func showLastMeeting() {
        guard let summary = meeting.lastSummary else { return }
        meeting.lastSummary = nil
        rebuildMenu()
        showMeetingsWindow(selecting: summary.sessionID)
    }

    @objc func dismissMeetingFailure() {
        meeting.notice = nil
        meeting.controller?.dismissFailure()
        rebuildMenu()
    }

    @objc func showAbout() {
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: AboutCredits.attributed()])
    }

    // MARK: - Meetings window

    /// The main window on Meetings, with the meeting `sessionID` selected once the list is read.
    func showMeetingsWindow(selecting sessionID: String?) {
        showMainWindow(.meetings)
        meeting.meetingsPane?.select(sessionID: sessionID)
    }

    /// The Meetings section; nil when the meeting controller could not be set up.
    func makeMeetingsPane() -> MeetingsPane? {
        guard let controller = meeting.controller else { return nil }
        let pane = MeetingsPane(
            root: controller.root,
            perform: { [weak self] action, summary in self?.performMeetingAction(action, summary) },
            openReview: { [weak self] summary in
                self?.openReview(sessionID: summary.id, directory: summary.directory, name: summary.displayTitle)
            },
            beginUsing: { [weak controller] id, doing in controller?.beginUsing(id, for: doing) ?? false },
            endUsing: { [weak controller] id in controller?.endUsing(id) },
            liveHeader: { [weak self] id, summary in
                self?.liveMeetingHeader(sessionID: id, summary: summary)
                    ?? LiveMeetingHeader(name: summary?.displayTitle ?? "Meeting", phase: .saved, detail: "")
            },
            learnLiveText: { [weak self] state, heard, meant in
                self?.learnMeetingCorrection(state: state, heard: heard, meant: meant) ?? .init()
            })
        pane.update(running: controller.sessionsInUse)
        pane.onDeepTranscription = { [weak self] runNow, summary in
            if runNow { self?.runDeepTranscriptionNow(summary) } else { self?.cancelDeepTranscription(summary.id) }
        }
        pane.onSummarize = { [weak self] summary in self?.summarizeMeetingAgain(summary) }
        pane.onCancelSummary = { [weak self] id in self?.cancelMeetingSummary(id) }
        pane.summaryRequested = { [weak self] id in self?.meeting.summaries.requested.contains(id) ?? false }
        pane.summaryUnavailableReason = { [weak self] in self?.meetingSummaryUnavailableReason }
        // A rename, here or in Terminal, or a new generated title shows in the meeting's Review window (the live
        // transcript's header follows the list).
        pane.onTitleChanged = { [weak self] id in self?.refreshReviewTitle(id) }
        pane.runRename = { [weak self] summary, request in self?.runRename(summary, request) }
        pane.performBulk = { [weak self] action, plan in self?.performBulkMeetingAction(action, plan) }
        // The live transcript's Stop and Save… and Pause / Resume, and the meeting's menu: the menu bar's path, with
        // Stop's question as a sheet on the main window.
        pane.onRecordingCommand = { [weak self, weak pane] command, sessionID in
            self?.performMeetingRecordingCommand(command, sessionID: sessionID, window: pane?.view.window)
        }
        pane.update(summarizing: meeting.summaries.running?.sessionID)
        pane.update(meetingState: controller.state)
        meeting.meetingsPane = pane
        updateDeepStates()
        updateEchoStates()
        return pane
    }

    /// Recover…, Label Speakers, Delete Audio…, and Delete Meeting… run `voiceislocal` maintenance commands (§5.8). A review
    /// of the meeting, open or still opening, follows `ReviewMaintenance` first: it closes (saving its changes) before
    /// a Delete Meeting, and otherwise turns read-only with its changes saved and playback stopped until the command
    /// ends, when it rereads the meeting. Delete Meeting can also forget the voice samples learned from the meeting
    /// (PR9), before the meeting is moved.
    private func performMeetingAction(_ action: MeetingsPane.Action, _ summary: SessionSummary) {
        guard let controller = meeting.controller else { return }
        // Asked before the confirmation too, so no confirmation is shown for a command that would be turned down.
        if let doing = controller.sessionsInUse[summary.id] {
            showSessionInUse(summary, doing: doing)
            return
        }
        let name = Self.short(summary.displayTitle)
        let path = summary.directory.path
        let arguments: [String]
        let doing: String
        var forgetSamples = false
        switch action {
        case .recover:
            guard confirm("Recover “\(name)”?",
                          "Voice is Local indexes the saved audio, rebuilds the transcript from what was transcribed while recording, transcribes the rest, and labels speakers. Saved audio is never changed.",
                          button: "Recover") else { return }
            arguments = ["session", "recover", path, "--json"]
            doing = "Recovering…"
        case .labelSpeakers:
            arguments = ["session", "diarize", path, "--json"]
            doing = "Labelling speakers…"
        case .deleteAudio:
            guard confirm("Delete the audio of “\(name)”?",
                          "The audio is deleted for good. The transcript, speaker labels, and transcript files stay.",
                          button: "Delete Audio") else { return }
            (arguments, doing) = Self.deletion(.deleteAudio, path: path)
        case .deleteMeeting:
            guard let forget = confirmDeleteMeeting(name) else { return }
            forgetSamples = forget
            (arguments, doing) = Self.deletion(.deleteMeeting, path: path)
        }
        startMeetingCommand(action, summary, arguments: arguments, doing: doing, forgetSamples: forgetSamples)
    }

    /// The command line of a deletion and what the list says while it runs, the same for one meeting and several.
    private static func deletion(_ action: MeetingBulkPlan.Action, path: String) -> (arguments: [String],
                                                                                     doing: String) {
        switch action {
        case .deleteAudio: (["session", "delete", path, "--audio-only", "--yes", "--json"], "Deleting audio…")
        case .deleteMeeting: (["session", "delete", path, "--yes", "--json"], "Moving to the Trash…")
        }
    }

    /// Delete Meeting… or Delete Audio… on several meetings from Meetings (`MeetingBulkPlan`): one confirmation, with
    /// the meetings skipped and why, then each meeting in turn through the single deletion's path
    /// (`startMeetingCommand`: registered as in use, its review let go, the voice samples forgotten when asked, the
    /// `voiceislocal session delete` child holding the lease and locks). A meeting that fails does not stop the rest;
    /// one alert lists the failures at the end. Right after the confirmation every target is reserved in
    /// `sessionsInUse` ("Waiting to …", `MeetingBulkRun.reserve`), so no background job starts on one still waiting;
    /// each meeting's turn takes its reservation over (`startMeetingCommand(reserved:)`). The list shows the waiting
    /// meetings and the progress meanwhile; a quit asks whether to finish first (`meetingShouldTerminate`).
    func performBulkMeetingAction(_ action: MeetingsPane.Action, _ plan: MeetingBulkPlan) {
        guard let controller = meeting.controller else { return }
        guard meeting.bulkRun == nil else {
            showMeetingAlert("Voice is Local is still deleting the meetings selected before.",
                             "Try again when it finishes; the Meetings list shows its progress.")
            return
        }
        guard !plan.targets.isEmpty else {
            showMeetingAlert(plan.nothingTitle, plan.skipText ?? "")
            return
        }
        var forgetSamples = false
        switch plan.action {
        case .deleteMeeting:
            guard let forget = confirmBulkDelete(plan) else { return }
            forgetSamples = forget
        case .deleteAudio:
            guard confirm(plan.confirmationTitle, plan.confirmationText, button: plan.confirmationButton) else { return }
        }
        let waiting = plan.action == .deleteMeeting ? "Waiting to move to the Trash…" : "Waiting to delete audio…"
        // At once, before anything else runs on the main actor: the background schedulers check `sessionsInUse`.
        let reservation = MeetingBulkRun.reserve(plan.targets, waiting: waiting, in: controller)
        meeting.bulkAction = plan.action
        meeting.bulkRemaining = plan.targets.count
        // The list remembers its order now, to select the meeting after the first deleted one once the run ended.
        meeting.meetingsPane?.bulkDeletionStarted(plan.targets.map(\.id))
        meeting.bulkRun = Task { [weak self, controller] in
            let result = await MeetingBulkRun.run(reservation, waiting: waiting, uses: controller, progress: { done in
                self?.meeting.bulkRemaining = plan.targets.count - done
                self?.meeting.meetingsPane?.update(bulkStatus: plan.progressText(done: done))
            }, each: { summary in
                guard let self else { return "Voice is Local stopped." }
                let (arguments, doing) = Self.deletion(plan.action, path: summary.directory.path)
                return await withCheckedContinuation { continuation in
                    self.startMeetingCommand(action, summary, arguments: arguments, doing: doing,
                                             forgetSamples: forgetSamples, reserved: true) { failure in
                        continuation.resume(returning: failure)
                    }
                }
            })
            guard let self else { return }
            self.meeting.bulkRun = nil
            self.meeting.bulkAction = nil
            self.meeting.bulkRemaining = 0
            self.meeting.meetingsPane?.update(bulkStatus: nil)
            self.meeting.meetingsPane?.bulkDeletionEnded()
            let report = plan.report(result).map { MeetingBulkReportHold.Report(title: $0.title, text: $0.text) }
            // Quitting (Finish Deleting or Quit Now): held, not an alert that would hold up the quit; shown if the
            // quit does not go ahead (`bulkQuitDecided`).
            let quitting = self.meeting.bulkQuitting || result.cancelled
            if quitting, report != nil {
                Self.meetingLog.error("Deletion of several meetings ended with \(result.failures.count, privacy: .public) not done while quitting")
            }
            if let shown = self.meeting.bulkReport.runEnded(report, quitting: quitting) {
                self.showMeetingAlert(shown.title, shown.text)
            }
        }
    }

    /// The quit that waited for a deletion of several meetings was decided: when it did not go ahead, the report of
    /// the meetings not done is shown after all.
    private func bulkQuitDecided(terminating: Bool) {
        guard let report = meeting.bulkReport.quitEnded(terminating: terminating) else { return }
        showMeetingAlert(report.title, report.text)
    }

    /// A quit while a deletion of several meetings runs: asks whether to finish it first (Finish Deleting) or to quit
    /// once the meeting being deleted now is done (Quit Now, the others left as they are; their reservations are
    /// released), or cancels. Either way the quit waits for the run to end, then goes on as `meetingShouldTerminate`
    /// would have; nil when no deletion runs.
    private func quitAfterBulkDeletion() -> NSApplication.TerminateReply? {
        guard let run = meeting.bulkRun, let action = meeting.bulkAction else { return nil }
        let question = MeetingBulkRun.quitQuestion(remaining: max(1, meeting.bulkRemaining), action: action)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.text
        alert.addButton(withTitle: question.wait)
        alert.addButton(withTitle: question.quit)
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
            return .terminateCancel
        }
        meeting.bulkQuitting = true
        if response == .alertSecondButtonReturn { run.cancel() }
        Task { [weak self] in
            await run.value
            guard let self else {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
                return
            }
            self.meeting.bulkQuitting = false
            switch self.meetingShouldTerminate() {
            case .terminateNow:
                self.bulkQuitDecided(terminating: true)
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            case .terminateCancel:
                self.reopenAfterQuit = false
                self.readings.quitCancelled()
                NSApplication.shared.reply(toApplicationShouldTerminate: false)
                self.bulkQuitDecided(terminating: false)
            case .terminateLater: break  // that path replies itself, and decides the held report (`bulkQuitDecided`)
            @unknown default: NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// The one confirmation of a deletion of several meetings, with "Also forget voice samples learned from these
    /// meetings"; nil when cancelled, else whether the box was checked.
    private func confirmBulkDelete(_ plan: MeetingBulkPlan) -> Bool? {
        let alert = NSAlert()
        alert.messageText = plan.confirmationTitle
        alert.informativeText = plan.confirmationText
        let box = NSButton(checkboxWithTitle: plan.forgetSamplesTitle, target: nil, action: nil)
        alert.accessoryView = box
        alert.addButton(withTitle: plan.confirmationButton)
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return box.state == .on
    }

    /// Registers the meeting as in use (`MeetingController.beginUsing`; a meeting the app already uses is turned down
    /// with an alert), lets a review of it go (`ReviewMaintenance`), then runs the command. Delete Meeting with
    /// "Also forget voice samples" forgets them first, after the review closed and before the meeting moves.
    ///
    /// `completion` (a deletion of several meetings): called once when the command ended, with nil when it succeeded,
    /// else why not; it then takes the place of the alerts about this meeting. `reserved`: the deletion of several
    /// already holds the meeting in `sessionsInUse` (`MeetingBulkRun.reserve`), and this takes that use over without
    /// releasing it in between.
    private func startMeetingCommand(_ action: MeetingsPane.Action, _ summary: SessionSummary, arguments: [String],
                                     doing: String, forgetSamples: Bool = false, reserved: Bool = false,
                                     completion: ((String?) -> Void)? = nil) {
        guard meeting.maintenance != nil, let controller = meeting.controller else {
            completion?("Voice is Local cannot run meeting commands now.")
            return
        }
        // The automatic relabel or another command may have taken the meeting while the confirmation was open.
        let registered = reserved ? controller.continueUsing(summary.id, for: doing)
            : controller.beginUsing(summary.id, for: doing)
        guard registered else {
            if let completion {
                let doing = controller.sessionsInUse[summary.id]
                completion("Voice is Local is working on it" + (doing.map { " (\($0))" } ?? "") + ".")
            } else {
                showSessionInUse(summary, doing: controller.sessionsInUse[summary.id])
            }
            return
        }
        let name = Self.short(summary.displayTitle)
        let hold = ReviewMaintenance.Hold(Self.maintenanceCommand(action))
        meeting.maintenanceOn[summary.id] = hold
        Task { [weak self] in
            await self?.reviewsLetGo(of: summary.id, for: hold)
            if forgetSamples {
                let failure = await Task.detached { () -> String? in
                    do {
                        try VoiceProfileService.forget(sessionID: summary.id, store: SpeakerProfileStore())
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let failure {
                    guard let self else {
                        completion?(failure)
                        return
                    }
                    self.maintenanceFinished(summary.id)
                    if let completion {
                        completion("Its voice samples could not be forgotten, so it was not moved to the Trash. "
                                   + failure)
                    } else {
                        self.showMeetingAlert(
                            "Voice is Local could not forget the voice samples learned from “\(name)”.",
                            "The meeting was not moved to the Trash. \(failure)")
                    }
                    return
                }
            }
            guard let self else {
                completion?("Voice is Local stopped.")
                return
            }
            self.runMeetingCommand(action, summary, arguments: arguments, completion: completion)
        }
    }

    private static func maintenanceCommand(_ action: MeetingsPane.Action) -> ReviewMaintenance.Command {
        switch action {
        case .recover: .recover
        case .labelSpeakers: .labelSpeakers
        case .deleteAudio: .deleteAudio
        case .deleteMeeting: .deleteMeeting
        }
    }

    /// "Move to the Trash?" with "Also forget voice samples learned from this meeting"; nil when cancelled, else
    /// whether the box was checked.
    private func confirmDeleteMeeting(_ name: String) -> Bool? {
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"
        alert.informativeText = "The meeting folder goes to the Trash, where you can restore it. Voice samples learned from this meeting stay until you forget them in People, unless you check the box."
        let box = NSButton(checkboxWithTitle: "Also forget voice samples learned from this meeting", target: nil,
                           action: nil)
        alert.accessoryView = box
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return box.state == .on
    }

    /// Runs the maintenance command of a Meetings action, the meeting already registered as in use
    /// (`startMeetingCommand`); `maintenanceFinished` ends that use however the command ends.
    private func runMeetingCommand(_ action: MeetingsPane.Action, _ summary: SessionSummary, arguments: [String],
                                   completion: ((String?) -> Void)? = nil) {
        guard let maintenance = meeting.maintenance else {
            maintenanceFinished(summary.id)
            completion?("Voice is Local cannot run meeting commands now.")
            return
        }
        let output = Self.temporaryFile("out")
        let errors = Self.temporaryFile("err")
        do {
            try maintenance.run(arguments, standardOutput: output, standardError: errors) { [weak self] code in
                guard let self else {
                    completion?("Voice is Local stopped.")
                    return
                }
                self.meetingCommandEnded(action, summary, code: code, output: output, errors: errors,
                                         completion: completion)
            }
        } catch {
            maintenanceFinished(summary.id)
            Self.removeFile(output)
            Self.removeFile(errors)
            if let completion {
                completion(error.localizedDescription)
                return
            }
            let title = action == .recover ? "Voice is Local could not recover “\(Self.short(summary.displayTitle))”."
                : "Voice is Local could not run the command."
            showMeetingAlert(title, error.localizedDescription)
        }
    }

    private func showSessionInUse(_ summary: SessionSummary, doing: String?) {
        showMeetingAlert("Voice is Local is working on “\(Self.short(summary.displayTitle))”.",
                         (doing.map { $0 + " " } ?? "") + "Try again when it finishes; the Meetings list shows when it is done.")
    }

    /// `completion` (a deletion of several meetings): told nil on success, else why not, in place of the alert. Only
    /// deletions pass it: a failed Recover or Label Speakers still needs the labelling bookkeeping below.
    private func meetingCommandEnded(_ action: MeetingsPane.Action, _ summary: SessionSummary, code: Int32,
                                     output: URL, errors: URL, completion: ((String?) -> Void)? = nil) {
        let result = Self.commandResult(output: output, errors: errors)
        // `session diarize` succeeds without labels when the speaker models are missing; its record then has no run.
        let madeRun = Self.jsonObject(output)?["runID"] is String
        Self.removeFile(output)
        Self.removeFile(errors)
        // Ending the use derives the naming offer again (a meeting deleted, recovered, or labelled changes it), and an
        // open review shows the meeting as the command left it (new transcript, labels, or no audio).
        maintenanceFinished(summary.id)
        meeting.meetingsPane?.refresh()
        let name = Self.short(summary.displayTitle)
        if code == 0, action == .deleteMeeting || action == .deleteAudio {
            // No voice can be learned from the meeting any more.
            PendingVoiceSamples().clear(summary.id)
            if action == .deleteMeeting {
                PendingExports().clear(summary.id)
                if meeting.lastSummary?.sessionID == summary.id { meeting.lastSummary = nil }
                rebuildMenu()
            }
            completion?(nil)
            return
        }
        if let completion {
            completion(result ?? "The command ended with code \(code).")
            return
        }
        let session = summary.directory
        let controller = meeting.controller
        Task { [weak self] in
            // A run counts as labels only once the saved labels load as the catalog and the exports load them
            // (`MeetingController.speakerLabelsReady`, off the main actor).
            let labels = action == .recover || (action == .labelSpeakers && madeRun)
            var labelled = false
            if labels, let controller {
                labelled = await controller.labellingCommandEnded(session: session, code: code)
            }
            let title: String = switch (action, code) {
            case (.recover, 0): "Recovered “\(name)”."
            case (.recover, 3): "Recovered “\(name)”, with a warning."
            case (.recover, _): "Voice is Local could not recover “\(name)”."
            case (.labelSpeakers, 0) where labelled: "Labelled the speakers of “\(name)”."
            case (.labelSpeakers, 3) where labelled: "Labelled the speakers of “\(name)”, with a warning."
            case (.labelSpeakers, 0), (.labelSpeakers, 3): "The speakers of “\(name)” were not labelled."
            case (.labelSpeakers, _): "Voice is Local could not label the speakers of “\(name)”."
            case (.deleteAudio, _): "Voice is Local could not delete the audio of “\(name)”."
            case (.deleteMeeting, _): "Voice is Local could not move “\(name)” to the Trash."
            }
            self?.showMeetingAlert(title, result ?? (code == 0 ? "" : "The command ended with code \(code)."))
        }
    }

    // MARK: - Review window (PR9)

    /// The meeting's Review window, when open, takes the title the Meetings list shows now (`MeetingNaming.currentTitle`,
    /// read off the main actor): after a rename, and after a summary, whose generated title may be the one shown.
    func refreshReviewTitle(_ sessionID: String) {
        // The folder the review was opened with (a session folder may have any `<something>.holos` name).
        guard let window = meeting.reviewWindows[sessionID] else { return }
        let session = window.review.session
        Task { [weak self, weak window] in
            let title = await Task.detached { MeetingNaming.currentTitle(session: session) }.value
            guard let self, let window, let title, self.meeting.reviewWindows[sessionID] === window,
                  window.meetingTitle != title else { return }
            window.meetingTitle = title
        }
    }

    /// Starts `reviewTitleWatch` unless it runs: every 2 s each open review window takes the title its meeting shows.
    private func watchReviewTitles() {
        guard meeting.reviewTitleWatch == nil else { return }
        meeting.reviewTitleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard !self.meeting.reviewWindows.isEmpty else {
                    self.meeting.reviewTitleWatch = nil
                    return
                }
                for id in self.meeting.reviewWindows.keys { self.refreshReviewTitle(id) }
            }
        }
    }

    // MARK: - Rename (§4.17)

    /// Runs a rename from Meetings as `voiceislocal session rename` (`MeetingRenameRun`), a child in its own session
    /// like the other maintenance commands, so quitting never cuts it between its writes. The meeting is registered as
    /// in use meanwhile ("Renaming…"; one already in use is turned down with an alert). Nothing is remembered about it:
    /// whether its transcript files are out of date afterwards is read from the files (the Meetings list's
    /// `TranscriptFilesCache`), so a quit before it ends, or a rename in Terminal, shows the same way.
    func runRename(_ summary: SessionSummary, _ request: MeetingRenameRequest) {
        guard let controller = meeting.controller, let maintenance = meeting.maintenance else { return }
        guard controller.beginUsing(summary.id, for: "Renaming…") else {
            showSessionInUse(summary, doing: controller.sessionsInUse[summary.id])
            return
        }
        // A Review's failed rewrite marked before the rename started is the one its rewrite makes up for; a newer one
        // (a review that failed meanwhile) is kept.
        let pendingGeneration = PendingExports().generation(summary.id)
        let output = Self.temporaryFile("out")
        let errors = Self.temporaryFile("err")
        do {
            try maintenance.run(MeetingRenameRun.arguments(session: summary.directory, request: request,
                                                           expectedID: summary.id),
                                standardOutput: output, standardError: errors) { [weak self] code in
                self?.renameEnded(summary, code: code, pendingGeneration: pendingGeneration, output: output,
                                  errors: errors)
            }
        } catch {
            controller.endUsing(summary.id)
            Self.removeFile(output)
            Self.removeFile(errors)
            meeting.meetingsPane?.renameEnded(summary, outcome: nil, failure: error.localizedDescription)
        }
    }

    private func renameEnded(_ summary: SessionSummary, code: Int32, pendingGeneration: Int, output: URL,
                             errors: URL) {
        // A result about another meeting (it cannot be, with --expect-id) is not applied to this one.
        let outcome = (try? AtomicFile.readIfPresent(output, maxBytes: 1 << 20)).flatMap {
            $0.flatMap { try? HolosJSON.decoder().decode(SessionRenameCommand.Outcome.self, from: $0) }
        }.flatMap { $0.sessionID.map { $0.caseInsensitiveCompare(summary.id) == .orderedSame } ?? true ? $0 : nil }
        let failure = Self.commandResult(output: output, errors: errors)
            ?? "The rename command ended with code \(code)."
        Self.removeFile(output)
        Self.removeFile(errors)
        // The files were rewritten from the saved speaker labels: a Review's earlier failed rewrite is made up for.
        if outcome?.exportsUpdated == true { PendingExports().clear(summary.id, ifGeneration: pendingGeneration) }
        meeting.controller?.endUsing(summary.id)
        refreshReviewTitle(summary.id)
        meeting.meetingsPane?.renameEnded(summary, outcome: outcome, failure: failure)
    }

    /// Opens the review window of a labelled meeting (or brings it forward) and reports `reviewOpened`, which clears
    /// a "Name Speakers" offer for it. The labels load off the main actor first. When the meeting cannot be reviewed,
    /// an alert says why, and with `fallBackToMeetings` Meetings opens with the meeting selected.
    func openReview(sessionID: String, directory: URL, name: String, fallBackToMeetings: Bool = false) {
        // A deep transcription pass on the meeting goes first; Review opens when this app's pass ends.
        if reviewWaitsForDeepTranscription(sessionID: sessionID, directory: directory, name: name) { return }
        // So does a summary being made of it (§4.17).
        if reviewWaitsForSummary(sessionID: sessionID, directory: directory, name: name) { return }
        if let window = meeting.reviewWindows[sessionID], !window.isClosing {
            window.show()
            meeting.controller?.reviewOpened(sessionID: sessionID)
            return
        }
        guard meeting.openingReviews[sessionID] == nil else { return }
        let maintenance = meeting.maintenance
        // A window of this meeting that was just closed finishes saving before the new one reads the labels.
        let closing = meeting.reviewWindows[sessionID]
        let endedBefore = meeting.maintenanceEnded[sessionID, default: 0]
        meeting.openingReviews[sessionID] = Task { [weak self] () -> ReviewWindow? in
            if let closing { await closing.closeAndWait() }
            let opened: Result<ReviewWindow, any Error>
            do {
                opened = .success(try await ReviewWindow.open(sessionID: sessionID, session: directory,
                                                              maintenance: maintenance))
            } catch {
                opened = .failure(error)
            }
            guard let self else { return nil }
            self.meeting.openingReviews[sessionID] = nil
            switch opened {
            case .success(let window):
                // A command that started on the meeting while the review opened (`ReviewMaintenance`): a deletion
                // closes it unseen; any other command shows it read-only until the command ends.
                let hold = self.runningMaintenance(on: sessionID)
                let response = hold.map { ReviewMaintenance.response(to: $0.command) } ?? .unaffected
                if response == .close {
                    await window.closeAndWait()
                    return nil
                }
                self.install(window, sessionID: sessionID)
                if let hold, case .readOnly(let banner) = response {
                    await window.pauseForMaintenance(hold, banner: banner)
                } else if self.meeting.maintenanceEnded[sessionID, default: 0] != endedBefore {
                    window.reloadAll()
                }
                guard !window.isClosing else { return nil }
                window.show()
                self.meeting.controller?.reviewOpened(sessionID: sessionID)
                return window
            case .failure(let error):
                Self.meetingLog.notice("Session \(sessionID, privacy: .public): review not opened (\(ProcessSpawner.logCategory(error), privacy: .public))")
                if fallBackToMeetings {
                    self.showMeetingsWindow(selecting: sessionID)
                    self.meeting.controller?.reviewOpened(sessionID: sessionID)
                }
                self.showMeetingAlert("Voice is Local could not open the review of “\(Self.short(name))”.",
                                      error.localizedDescription)
                return nil
            }
        }
    }

    /// Keeps an opened review window: its close, relabels, Dock presence, and transcript files still to rewrite.
    private func install(_ window: ReviewWindow, sessionID: String) {
        // Per window: a closing window of the meeting must not take the new one's Dock presence away.
        let dockKey = "review-\(ObjectIdentifier(window).hashValue)"
        // Weak: the window holds this closure, so a strong capture would keep every closed window alive.
        window.onClose = { [weak self, weak window] in
            guard let self else { return }
            if let window {
                if self.meeting.reviewWindows[sessionID] === window { self.meeting.reviewWindows[sessionID] = nil }
                self.reviewClosed(sessionID, review: window.review, title: window.meetingTitle)
            }
            self.setDockPresence(false, for: dockKey)
        }
        window.onRelabel = { [weak self] running in self?.reviewRelabelChanged(sessionID, running: running) }
        // Word edits in Review teach corrections and offer word-list terms (docs/meeting-design.md §5.10).
        // Learned when the window closes, from every word edited in the meeting; existing corrections are kept.
        window.review.correctionsToLearn = { [weak self] edit in self?.reviewEditCorrections(edit) ?? [] }
        window.review.correctionsWriter = { [weak self] in self?.reviewCorrectionsWriter() }
        window.review.correctionsWritten = { [weak self] in self?.reviewCorrectionsWritten() }
        window.wordListHeardAs = { [weak self] term in self?.wordListHeardAs(term) }
        window.addWordListTerm = { [weak self] term, heardAs in
            self?.addReviewTerm(term, heardAs: heardAs) ?? "The word list is not available."
        }
        meeting.reviewWindows[sessionID] = window
        watchReviewTitles()
        setDockPresence(true, for: dockKey)
        // Rewriting them failed when an earlier review of the meeting closed.
        if PendingExports().contains(sessionID) { window.review.markExportsPending() }
    }

    /// A review window closed and saved: when its transcript files could not be rewritten, the meeting is marked
    /// (Meetings says so, and the next review rewrites them) and an alert says what happened, unless Holos is
    /// quitting or the meeting is being deleted.
    private func reviewClosed(_ sessionID: String, review: ReviewSession, title: String) {
        guard review.exportsPending else {
            PendingExports().clear(sessionID)
            return
        }
        PendingExports().mark(sessionID)
        if let controller = meeting.controller { meeting.meetingsPane?.update(running: controller.sessionsInUse) }
        Self.meetingLog.error("Session \(sessionID, privacy: .public): transcript files not rewritten when the review closed; marked pending")
        guard !meeting.quitting, meeting.maintenanceOn[sessionID]?.command != .deleteMeeting else { return }
        let name = Self.short(title)
        let problem = review.exportProblem.map { "\n\n" + $0 } ?? ""
        Task { [weak self] in
            self?.showMeetingAlert(
                "Voice is Local could not update the transcript files of “\(name)”.",
                "Your changes to the speakers are saved, but transcript.md and the other files in the meeting's exports folder still show the speakers from before. Voice is Local writes them again the next time you open Review for this meeting.\(problem)")
        }
    }

    // MARK: - Reviews and maintenance (ReviewMaintenance, §5.10)

    /// The run of the maintenance command working on the meeting now: one from Meetings or the interrupted prompt, or
    /// the automatic relabel.
    private func runningMaintenance(on sessionID: String) -> ReviewMaintenance.Hold? {
        if let hold = meeting.maintenanceOn[sessionID] { return hold }
        return meeting.controller?.relabellingSessionID == sessionID ? meeting.automaticHolds[sessionID] : nil
    }

    /// The command run `hold` is about to start on the meeting: a review still opening is waited for, then the review
    /// closes (Delete Meeting) or turns read-only once its changes are saved.
    private func reviewsLetGo(of sessionID: String, for hold: ReviewMaintenance.Hold) async {
        if let opening = meeting.openingReviews[sessionID] { _ = await opening.value }
        // A run that already ended (a quick automatic relabel) must not leave the review read-only.
        guard runningMaintenance(on: sessionID) == hold, let window = meeting.reviewWindows[sessionID] else { return }
        switch ReviewMaintenance.response(to: hold.command) {
        case .unaffected:
            return
        case .close:
            await window.closeAndWait()
        case .readOnly(let banner):
            // A window closed just before still saves; the command starts after that.
            if window.isClosing {
                await window.closeAndWait()
            } else {
                await window.pauseForMaintenance(hold, banner: banner)
            }
        }
    }

    /// A command from Meetings, the interrupted prompt, or the echo catch-up ended (or never started): its use of the
    /// meeting ends (`MeetingController.endUsing`, so Meetings stops showing it and the naming offer is derived
    /// again), and a review of the meeting reads the meeting again and is editable.
    func maintenanceFinished(_ sessionID: String) {
        let hold = meeting.maintenanceOn.removeValue(forKey: sessionID)
        meeting.controller?.endUsing(sessionID)
        if let hold { reviewsTakeBack(sessionID, after: hold) }
    }

    /// The command run `hold` ended: the review lets go of that run only, so a command started meanwhile keeps it
    /// read-only.
    private func reviewsTakeBack(_ sessionID: String, after hold: ReviewMaintenance.Hold) {
        meeting.maintenanceEnded[sessionID, default: 0] += 1
        guard case .readOnly = ReviewMaintenance.response(to: hold.command),
              let window = meeting.reviewWindows[sessionID] else { return }
        Task { await window.resumeAfterMaintenance(hold) }
    }

    /// The automatic relabel started or ended on a meeting (the controller calls this as it sets or clears
    /// `relabellingSessionID`, so each run gets its own hold before anything asks for it).
    private func automaticRelabelChanged(_ sessionID: String, running: Bool) {
        if running {
            let hold = ReviewMaintenance.Hold(.automaticRelabel)
            meeting.automaticHolds[sessionID] = hold
            Task { [weak self] in await self?.reviewsLetGo(of: sessionID, for: hold) }
        } else {
            let hold = meeting.automaticHolds.removeValue(forKey: sessionID) ?? ReviewMaintenance.Hold(.automaticRelabel)
            reviewsTakeBack(sessionID, after: hold)
            meeting.meetingsPane?.refresh()
        }
    }

    /// Text Meetings shows while a review window relabels the meeting.
    private static let reviewRelabelText = "Labelling speakers (Review)…"

    /// A review window started or finished relabelling its meeting: the meeting is in use meanwhile
    /// (`MeetingController.beginUsing`), so Meetings shows it and turns its commands down, and the automatic relabel
    /// leaves it alone. A use something else already holds is left as it is.
    private func reviewRelabelChanged(_ sessionID: String, running: Bool) {
        guard let controller = meeting.controller else { return }
        if running {
            _ = controller.beginUsing(sessionID, for: Self.reviewRelabelText)
        } else {
            if controller.sessionsInUse[sessionID] == Self.reviewRelabelText { controller.endUsing(sessionID) }
            meeting.meetingsPane?.refresh()
        }
    }

    /// Quitting with review windows open: they close first, so their last changes reach the transcript files. Returns
    /// once they closed or `limit` passed, whichever comes first; a save still running then is not waited for.
    private func closeReviews(_ windows: [ReviewWindow], limit: Duration = .seconds(10)) async {
        guard !windows.isEmpty else { return }
        meeting.quitting = true
        // All start closing at once: a slow close (a voice sync) never keeps another window's typed words unsaved.
        let finished = await ReviewQuit.closeAll(windows, limit: limit)
        // Word edits that were refused or failed while closing, timeout or not: their windows are gone, so they are
        // logged with what was typed.
        for window in windows {
            for failed in window.review.failedWordEditsAtClose {
                Self.meetingLog.error("Quitting after a word edit was not saved (\(failed.reason, privacy: .private); what was typed: \(failed.typed, privacy: .private))")
            }
            // Edits refused earlier whose fields could not open again (the window's footer held them).
            for typed in window.unsavedEditTexts {
                Self.meetingLog.error("Quitting with a word edit not saved (what was typed: \(typed, privacy: .private))")
            }
        }
        if !finished {
            Self.meetingLog.error("Quitting before \(windows.count, privacy: .public) review windows finished saving")
            // Every word edit not saved, each with what was typed: those Return or Tab handed over and still saving,
            // and the one the field held at the close (closing queued it with the others).
            for window in windows {
                for typed in window.review.unsavedWordEdits {
                    Self.meetingLog.error("Quitting before a word edit was saved (what was typed: \(typed, privacy: .private))")
                }
            }
            // Their voice work stops now, so no child process outlives the app with a render of the audio.
            for window in windows { window.review.stopBackgroundWork() }
        }
    }

    /// `.terminateNow`, or, with review windows open, `.terminateLater` and the reply once they closed.
    private func quitAfterClosingReviews() -> NSApplication.TerminateReply {
        let windows = Array(meeting.reviewWindows.values)
        guard !windows.isEmpty else { return .terminateNow }
        Task {
            await self.closeReviews(windows)
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The result line a command printed: `summary` or `message` of its JSON output, else its last stderr line.
    private static func commandResult(output: URL, errors: URL) -> String? {
        if let object = jsonObject(output) {
            if let summary = object["summary"] as? String, !summary.isEmpty { return summary }
            if let message = object["message"] as? String, !message.isEmpty { return message }
        }
        return lastLine(errors)
    }

    /// The JSON object a command printed on stdout, if any.
    private static func jsonObject(_ output: URL) -> [String: Any]? {
        guard let data = try? AtomicFile.readIfPresent(output, maxBytes: 4 << 20) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showMeetingAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApplication.shared.activate()
        alert.runModal()
    }

    // MARK: - Interrupted recordings

    /// After launch: one alert per interrupted recording not asked about before (§5.8 "Interrupted prompt").
    func promptAboutInterruptedRecordings() async {
        guard let controller = meeting.controller else { return }
        let alreadyPrompted = Set(UserDefaults.standard.stringArray(forKey: MeetingAppState.promptedKey) ?? [])
        let interrupted = await controller.interruptedSessions(excluding: alreadyPrompted)
        // Read again: the list took a while.
        var prompted = Set(UserDefaults.standard.stringArray(forKey: MeetingAppState.promptedKey) ?? [])
        for summary in interrupted where !prompted.contains(summary.id) {
            prompted.insert(summary.id)
            UserDefaults.standard.set(Array(prompted), forKey: MeetingAppState.promptedKey)
            let alert = NSAlert()
            alert.messageText = "Voice is Local found an interrupted recording: \(Self.short(summary.displayTitle)) (\(MeetingFormat.clock(summary.savedSeconds)) saved)."
            alert.informativeText = "Recover indexes its saved audio, rebuilds the transcript, and labels speakers. You can also recover it later from Meetings."
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Later")
            NSApplication.shared.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { continue }
            runRecovery(summary)
        }
    }

    private func runRecovery(_ summary: SessionSummary) {
        startMeetingCommand(.recover, summary, arguments: ["session", "recover", summary.directory.path, "--json"],
                            doing: "Recovering…")
    }

    // MARK: - Speaker models (Setup "Speaker labels", start panel)

    /// Reads `speakerModels` from `voiceislocal doctor --json`.
    func refreshSpeakerModels() {
        guard let maintenance = meeting.maintenance, !meeting.checkingSpeakerModels else { return }
        meeting.checkingSpeakerModels = true
        let output = Self.temporaryFile("doctor")
        do {
            try maintenance.run(["doctor", "--json"], standardOutput: output, standardError: nil) { [weak self] _ in
                guard let self else { return }
                self.meeting.checkingSpeakerModels = false
                let data = try? AtomicFile.readIfPresent(output, maxBytes: 1 << 20)
                Self.removeFile(output)
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                // The tool ran but reported nothing usable: unknown, not missing.
                self.meeting.speakerModels = object?["speakerModels"] as? String ?? "unknown"
                self.deepModelChecked(object?["deepTranscriptionModel"] as? String ?? "unknown")
                self.updateSettings()
                self.meeting.startPanel?.refresh()
                if self.meeting.speakerModels == "verified" { self.meeting.controller?.runAutoRelabel() }
            }
        } catch {
            meeting.checkingSpeakerModels = false
            meeting.speakerModels = "unavailable"
            deepModelChecked("unavailable")
            Self.removeFile(output)
            Self.meetingLog.error("Cannot check the speaker models (\(ProcessSpawner.logCategory(error), privacy: .public)): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Runs `voiceislocal setup --speakers` (about 21 MB, pinned and verified) and shows its progress. `resumable`
    /// (the Setup Assistant's install): saved as pending with its process, so a launch after a quit that cut it short
    /// resumes it (`resumeSetupAssistantWork`); cleared when it ends.
    func installSpeakerModels(resumable: Bool = false) {
        guard let maintenance = meeting.maintenance, meeting.speakerModelInstall == nil else { return }
        let output = Self.temporaryFile("setup")
        meeting.speakerModelInstall = "Starting the download…"
        meeting.speakerModelError = nil
        updateSettings()
        meeting.startPanel?.refresh()
        let defaults = UserDefaults.standard
        do {
            let pid = try maintenance.run(["setup", "--speakers"], standardOutput: output,
                                          standardError: output) { [weak self] code in
                guard let self else { return }
                // Ended, whichever install it was: nothing is left to resume.
                for key in [SetupAssistantFlow.speakerModelsPendingKey, Self.speakerInstallPIDKey,
                            Self.speakerInstallStartKey] {
                    defaults.removeObject(forKey: key)
                }
                let last = Self.lastLine(output)
                Self.removeFile(output)
                self.meeting.speakerModelInstall = nil
                if code != 0 { self.meeting.speakerModelError = last ?? "The download failed (code \(code))." }
                self.meeting.speakerModels = nil
                self.refreshSpeakerModels()
                self.updateSettings()
                self.meeting.startPanel?.refresh()
            }
            if resumable {
                defaults.set(true, forKey: SetupAssistantFlow.speakerModelsPendingKey)
                defaults.set(Int(pid), forKey: Self.speakerInstallPIDKey)
                if let started = ProcessSpawner.startTime(of: pid) {
                    defaults.set(Int(clamping: started), forKey: Self.speakerInstallStartKey)
                }
            }
        } catch {
            defaults.removeObject(forKey: SetupAssistantFlow.speakerModelsPendingKey)
            meeting.speakerModelInstall = nil
            meeting.speakerModelError = error.localizedDescription
            Self.removeFile(output)
            updateSettings()
            meeting.startPanel?.refresh()
            return
        }
        Task { [weak self] in
            while let self, self.meeting.speakerModelInstall != nil {
                if let line = Self.lastLine(output), line.hasPrefix("Speaker models:") || line.hasPrefix("Downloading") {
                    self.meeting.speakerModelInstall = line
                    self.updateSettings()
                    self.meeting.startPanel?.refresh()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Settings' "Speaker labels" row.
    func speakerLabelsSetupState() -> (status: String?, detail: String?, busy: Bool) {
        if let progress = meeting.speakerModelInstall { return ("installing", progress, true) }
        return (meeting.speakerModels, meeting.speakerModelError, meeting.checkingSpeakerModels)
    }

    // MARK: - Quit (§5.8)

    /// While a meeting records: in child mode offers Stop and Save (waits up to 10 s for the recorder to stop
    /// capturing), Keep Recording (quits the app only), or Cancel; in-process mode offers Stop and Save (waits up to 10
    /// minutes for the transcript) or Cancel. An in-process meeting that is still saving its transcript is waited for.
    /// Open review windows close first in every case, so their last changes reach the transcript files.
    func meetingShouldTerminate() -> NSApplication.TerminateReply {
        // A deletion of several meetings asks first, and the rest of this is asked once it ended.
        if let reply = quitAfterBulkDeletion() { return reply }
        guard let controller = meeting.controller else { return quitAfterClosingReviews() }
        // Whether this process runs the recording, not which launcher is configured: in in-process mode Holos can
        // still follow a meeting started in a terminal, which quitting does not end.
        let inProcess = meeting.inProcess?.isRecording == true
        switch controller.state {
        case .active, .starting:
            let alert = NSAlert()
            alert.messageText = "A meeting is recording."
            alert.addButton(withTitle: "Stop and Save")
            if inProcess {
                alert.informativeText = "Voice is Local records this meeting itself, so quitting ends it. Stop and Save saves the audio and the transcript before Voice is Local quits; speaker labelling then continues on its own."
            } else {
                alert.informativeText = "Stop and Save ends and saves the recording; speaker labelling continues after Voice is Local quits. Keep Recording quits only the app: the recording goes on, and Voice is Local shows it again when you open it."
                alert.addButton(withTitle: "Keep Recording")
            }
            alert.addButton(withTitle: "Cancel")
            NSApplication.shared.activate()
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                controller.confirmStop()
                waitBeforeQuitting(inProcess: inProcess)
                return .terminateLater
            }
            if !inProcess, response == .alertSecondButtonReturn { return quitAfterClosingReviews() }
            return .terminateCancel
        case .idle, .finishing, .failed:
            // A recording still running in this process is waited for, whatever its phase: saving its transcript
            // (also one whose start timed out in the menu but that did start), labelling speakers (it is told to
            // leave that to its child, then writes exited), or retrying its exited status (`ExitRetry`). Quitting
            // earlier would cut the save short or leave status.json unfinished. Open reviews close first either way.
            guard inProcess else { return quitAfterClosingReviews() }
            waitBeforeQuitting(inProcess: true)
            return .terminateLater
        }
    }

    /// Replies to the pending terminate once the recorder has stopped capturing (child: 10 s at most) or, in-process,
    /// once the recording here has ended (10 minutes at most): after its transcript is saved it stops following the
    /// labelling child (`InProcessLauncher.leaveLabellingToItsChild`) and writes its exited status.
    private func waitBeforeQuitting(inProcess: Bool) {
        if inProcess { showSavingWindow() }
        let limit: Duration = inProcess ? .seconds(600) : .seconds(10)
        Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: limit)
            var undelivered = false
            while clock.now < deadline {
                guard let self, let controller = self.meeting.controller else { break }
                // The stop request could not be published and no signal reached the recorder (a meeting this app
                // did not start): quitting now would leave it recording with no one told.
                if Self.stopNotDelivered(controller) {
                    undelivered = true
                    break
                }
                // Labelling continues in its child after the quit (§5.8): a recording here that reached it stops
                // waiting for it, writes its exited status, and ends.
                if inProcess { self.meeting.inProcess?.leaveLabellingToItsChild() }
                let recordingHere = self.meeting.inProcess?.isRecording == true
                if QuitReadiness.ready(controller.state, inProcess: inProcess, recordingHere: recordingHere) { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.meeting.savingWindow?.close()
            if !undelivered, let self { await self.closeReviews(Array(self.meeting.reviewWindows.values)) }
            NSApplication.shared.reply(toApplicationShouldTerminate: !undelivered)
            // A deletion of several meetings this quit waited for: its report, if the quit did not go ahead.
            self?.bulkQuitDecided(terminating: !undelivered)
            if undelivered, let self {
                self.reopenAfterQuit = false  // the quit was cancelled: a later quit must not reopen
                self.readings.quitCancelled()  // readings kept for the next launch continue now
                let reason = self.meeting.notice.map { "\n\n\($0)" } ?? ""
                self.showMeetingAlert(
                    "Voice is Local could not stop the recording.",
                    "The meeting is still recording, so Voice is Local did not quit. Try Stop and Save from the menu again, or stop it where it was started.\(reason)")
            }
        }
    }

    /// The meeting is still recording and no stop is on its way: the request failed and could not be signalled.
    private static func stopNotDelivered(_ controller: MeetingController) -> Bool {
        guard case .active(_, let status) = controller.state else { return false }
        return status.phase != .stopping && !controller.reducer.stopRequested
    }

    private func showSavingWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Voice is Local"
        window.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(wrappingLabelWithString: "Saving the meeting’s transcript. Voice is Local quits when it is saved.")
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        meeting.savingWindow = window
    }

    // MARK: - Dock presence

    /// Holos is a menu bar app with no Dock icon. While one of its windows is open it becomes a regular app, so the
    /// window shows in the Dock and Command-Tab and can be found when other windows cover it.
    func setDockPresence(_ visible: Bool, for window: String) {
        if visible { meeting.windowsInDock.insert(window) } else { meeting.windowsInDock.remove(window) }
        let policy: NSApplication.ActivationPolicy = meeting.windowsInDock.isEmpty ? .accessory : .regular
        guard NSApplication.shared.activationPolicy() != policy else { return }
        // An LSUIElement app that turns regular shows the generic icon in the Dock and Command-Tab unless it sets
        // its icon itself.
        if policy == .regular, NSApplication.shared.applicationIconImage?.name() != Self.appIconName,
           let url = Bundle.main.url(forResource: Self.appIconName, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            icon.setName(Self.appIconName)
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.setActivationPolicy(policy)
    }

    /// The bundle's icon file (CFBundleIconFile), without its extension.
    private static let appIconName = "VoiceIsLocal"

    // MARK: - Helpers

    /// A private temporary file name for a command's output.
    static func temporaryFile(_ kind: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-command-\(UUID().uuidString).\(kind)", isDirectory: false)
    }

    /// Removes command outputs an app that quit or crashed left behind (older than an hour).
    private static func sweepCommandOutputs() {
        ProcessSpawner.removeStaleFiles(in: FileManager.default.temporaryDirectory, prefix: "holos-command-",
                                        olderThan: Date().addingTimeInterval(-3_600))
    }

    static func removeFile(_ url: URL) { ProcessSpawner.removeRegularFile(url) }

    /// The last non-empty line of a command's output, without ArgumentParser's "Error: ".
    static func lastLine(_ url: URL) -> String? { ProcessSpawner.lastLine(of: url) }
}
