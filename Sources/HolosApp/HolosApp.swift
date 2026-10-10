import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import HolosAppModel
import HolosAudio
import HolosCore
import HolosDesktop
import HolosDictation
import HolosMeeting
import HolosSpeech
import HolosSpelling
import HolosStorage
import os
import Security

@main
enum HolosAppMain {
    @MainActor static func main() {
        SystemSpelling.install(SystemSpellChecker())  // before dictation or a fix asks the spell checker
        if CommandLine.arguments.contains("--check") {
            // Packaging/capability check only: no NSApplication, prompt, tap, or recording.
            let report: [String: String] = [
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "missing",
                "microphone": AudioCapture.microphonePermission,
                "accessibility": AXIsProcessTrusted() ? "granted" : "notGranted",
                "inputMonitoring": CGPreflightListenEventAccess() ? "granted" : "notGranted",
                "defaultShortcut": "rightOption",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        guard Bundle.main.bundleIdentifier == "ca.orlenko.holos.app" else {
            fputs("Launch the VoiceIsLocal.app bundle built by scripts/build-app.sh.\n", stderr)
            return
        }
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: "ca.orlenko.holos.app")
        guard !siblings.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = HolosAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class HolosAppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    private let overlay = DictationOverlay()
    private var monitor: GlobalHotkeyMonitor?
    private var controller: DictationController!
    /// Meeting recording controls (HolosApp+Meeting.swift, docs/meeting/app-controls.md §5.8).
    let meeting = MeetingAppState()
    private(set) var enabled = false
    /// Session suspension belongs to dictation, not to a meeting; deferred setup cannot clear it.
    var dictationSession = DictationSessionPolicy()
    private var enabling = false
    private(set) var installingAssets = false
    private var enableGeneration = 0
    private var enableTask: Task<Void, Never>?
    private var assetTask: Task<Void, Never>?
    /// Hides the overlay eight seconds after a result or message, unless something else was shown since.
    private var overlayHideTask: Task<Void, Never>?
    /// Discards the kept result ten minutes after the dictation that produced it.
    private var resultExpiryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private enum Destination {
        case field(InsertionTarget)
        case keystrokes(KeystrokeTarget)
    }

    private var target: Destination?
    private var insertionBlockReason: String?
    /// Transcript prefix already written into the target during this utterance.
    private var insertedText = ""
    /// The app receiving keystrokes, when the target is typed into rather than written directly.
    private var typedAppName: String?
    /// This dictation is for a terminal: code tokens without backticks, and History says so for Run Again.
    private var dictationForTerminal = false
    /// A streamed write may have landed without being confirmed; the result must not claim it failed.
    private var streamUnverified = false
    /// The app or field changed during the utterance; pasting Copy Result now would land somewhere else.
    private var targetMoved = false
    /// Where the user was at key-down, to check before telling them where to paste Copy Result.
    private var originPID: pid_t?
    private var originFocus: AXUIElement?
    private var previewOpacity: Double {
        get { min(1, max(0.3, UserDefaults.standard.object(forKey: "previewOpacity") as? Double ?? 0.85)) }
        set { UserDefaults.standard.set(min(1, max(0.3, newValue)), forKey: "previewOpacity") }
    }
    private var opacitySampleTask: Task<Void, Never>?
    /// The overlay content token of the opacity sample currently on screen, if any.
    private var sampleToken: Int?
    /// When false, the preview is hidden during dictation and for results that went in fine; anything that
    /// needs the user (text that could not be written, failures) is still shown.
    private var showPreview: Bool {
        get { UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showPreview") }
    }
    /// Set when the current result was not written cleanly, so it is shown even with the preview off.
    private var resultNeedsAttention = false
    /// A finalization status message kept for the result message (for example release during startup).
    private var forcedStopMessage: String?

    var removeFillers: Bool {
        get { UserDefaults.standard.object(forKey: "removeFillers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "removeFillers") }
    }
    /// Fixes each chunk with Apple's on-device model before it is written (Setup option); nil when off.
    private var fixPipeline: DictationFixPipeline?
    /// The recognizer's text for this dictation's result (before filler removal, corrections and the on-device fix),
    /// kept when the fix changed what was written; for Copy Original once the dictation concludes.
    private var resultOriginal = ""
    /// What the menu's Copy Result and Copy Original offer: the last dictation that produced a result. A later
    /// press that produces nothing (cancelled, released before listening, nothing recognized) leaves it.
    private var retention = ResultRetention()
    var corrections = CorrectionList()
    /// The corrections the dictation in progress (or the last one) started with, used for all of its text until it
    /// ends. `corrections` can change while it runs (corrections.json reloaded after `voiceislocal eval apply`, or a
    /// change in Corrections); taking that mid-dictation would change text already streamed, fail the prefix check and
    /// stop insertion, so a change counts from the next dictation. Its word list and vocabulary are fixed at the start
    /// the same way (`DictationFixPipeline.make` takes the terms; `DictationController.begin` the contextual strings).
    private var dictationCorrections = CorrectionList()
    /// False when an existing corrections file could not be read, so it is never overwritten.
    private var correctionsWritable = true
    /// Loads corrections.json again when it changes on disk (`voiceislocal eval apply --add-corrections`).
    private var correctionsWatcher: FolderWatcher?
    /// The word list (HolosApp+WordList.swift), as `words.json` held it when last read.
    var wordList = WordList()
    let wordListStore = WordListStore()
    /// `words.json` as last read, so a change made outside the app (`voiceislocal words`) is read again.
    var wordListStamp: WordListStore.Stamp?
    /// People's names for dictation and Run Again, read again when the people store changed.
    let peopleNames = PeopleNames()
    /// Why `words.json` could not be read; nil when it could.
    var wordListProblem: String?
    /// The main window (HolosApp+MainWindow.swift), made on first use.
    var mainWindow: MainWindowController?
    /// The dictation history (HolosApp+History.swift).
    let history = DictationHistoryService()
    /// The Reading list and the readings being made (HolosApp+Reading.swift).
    let readings = ReadingController()
    /// The dictation in progress, for its History record; nil when there is none or it was refused.
    private var historyDraft: HistoryDraft?
    /// What happened to this dictation's text, for its History record.
    private var historyOutcome: DictationRecord.Outcome?
    /// The dictation in progress's audio, written from the frames the recognizer takes, when History keeps audio; its
    /// History record gets it, and a dictation History does not record deletes it.
    private var historyAudio: (id: UUID, writer: DictationAudioWriter)?
    /// The last complete transcript as Holos wrote it, for Corrections.
    private var lastTranscript = ""
    /// The same transcript before corrections, so edits are learned against what the recognizer heard.
    private var lastRecognized = ""
    /// The History ID of the dictation `lastTranscript` came from.
    private var lastTranscriptID: UUID?
    /// The recognizer's latest committed text, kept so a failure can still offer what was not written.
    private var latestCommitted = ""
    private let log = Logger(subsystem: "ca.orlenko.holos.app", category: "insertion")
    /// This dictation's text for Copy Result; the menu offers it once the dictation concludes (`retainResult`).
    private var resultText = ""
    private var message = "Disabled — open Settings… to get started"
    /// A history write failure shown as `message`, and the message it replaced (`showHistoryProblem`).
    private var historyProblemStatus: (shown: String, replaced: String)?
    /// Polls permissions while Settings is on screen (TCC has no change notification).
    private var setupRefreshTask: Task<Void, Never>?
    /// The Setup Assistant (HolosApp+SetupAssistant.swift). Its progress stays in memory when the window is closed.
    var assistantWindow: SetupAssistantWindow?
    var assistantRefreshTask: Task<Void, Never>?
    var assistantFlow = SetupAssistantFlow()
    /// The assistant shows the one-page check after it reopened Voice is Local.
    var assistantVerifying = false
    /// The assistant finished or was skipped this run; the menu's Setup Assistant… starts it again from Welcome.
    var assistantCompleted = false
    /// The hotkey tap was tried once Accessibility was granted during this showing of the assistant.
    var assistantProbedTap = false
    /// Dictation turns on when the speech model install that is running (or started for it) succeeds. Saved, so a
    /// quit or the assistant's reopen keeps it: the next launch resumes the install (`resumeSetupAssistantWork`).
    var enableWhenSpeechModelInstalled: Bool {
        get { UserDefaults.standard.bool(forKey: SetupAssistantFlow.enableAfterSpeechModelKey) }
        set {
            if newValue { UserDefaults.standard.set(true, forKey: SetupAssistantFlow.enableAfterSpeechModelKey) }
            else { UserDefaults.standard.removeObject(forKey: SetupAssistantFlow.enableAfterSpeechModelKey) }
        }
    }
    /// The assistant's Reopen Voice is Local: a helper reopens the app once this process has exited. Cleared when
    /// the quit is cancelled, so a later quit never reopens.
    var reopenAfterQuit = false
    private(set) var assetState: String?
    private var shortcut: HotkeyChoice = .rightOption
    /// The dictation language, chosen in Settings; until then, the supported one closest to the user's
    /// languages (`DictationLanguage.preferred`). Meetings keep their own (`meetingLocales`). Shown as
    /// `DictationLanguage.standard` while that default is not known yet (`resolvedLocale` nil): an action that uses
    /// the language (enabling dictation, installing its speech model) awaits `loadLanguages` first.
    private(set) var locale: String {
        get { resolvedLocale ?? DictationLanguage.standard }
        set { UserDefaults.standard.set(newValue, forKey: "dictationLocale") }
    }
    /// The dictation language, or nil while there is no saved choice and the supported languages have not loaded.
    var resolvedLocale: String? {
        DictationLanguage.resolvedForSystem(saved: UserDefaults.standard.string(forKey: "dictationLocale"),
                                            supported: supportedLocales)
    }
    /// The meeting languages chosen in the meeting start panel (the recorder transcribes live in the first; the others,
    /// at most two, are detected after the recording, docs/meeting/languages.md §4.14); until then, the dictation
    /// language. Nil while that is not known yet (`resolvedLocale`): the start panel keeps Start off until it is.
    var meetingLocales: [String]? {
        get {
            DictationLanguage.meetingLocales(
                saved: UserDefaults.standard.stringArray(forKey: MeetingAppState.localesKey), dictation: resolvedLocale)
        }
        set { UserDefaults.standard.set(newValue, forKey: MeetingAppState.localesKey) }
    }
    /// The languages Apple's speech transcriber supports; nil until a load finished, empty when it failed (the
    /// default is then `DictationLanguage.standard`, and the next `loadLanguages` tries again).
    private var supportedLocales: [String]?
    /// The same, grouped for a picker (`DictationLanguage.groups`).
    private(set) var localeGroups: [[String]] = []
    private var languagesTask: Task<Void, Never>?
    var languageName: String { DictationLanguage.name(of: locale) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()  // before any window opens
        if let raw = UserDefaults.standard.string(forKey: "shortcut"), let saved = HotkeyChoice(rawValue: raw) {
            shortcut = saved
        }
        controller = DictationController(locale: locale) { [weak self] update in self?.receive(update) }
        overlay.setOpacity(previewOpacity)
        do { corrections = try CorrectionList.load(from: CorrectionList.defaultURL) }
        catch {
            correctionsWritable = false
            message = "Could not read corrections.json; corrections are off until it is fixed or removed."
        }
        loadWordList()
        controller.contextualStrings = dictationVocabulary(language: locale)
        // Asked at each dictation's start: the word list and corrections as held then, and People's names as last read
        // in the background (read now, so the first dictation has them).
        peopleNames.refresh()
        controller.seamTerms = { [weak self] in self?.dictationSeamTerms() ?? [] }
        let folder = CorrectionList.defaultURL.deletingLastPathComponent()
        correctionsWatcher = FolderWatcher(folder: folder) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadCorrectionsIfChanged()
                // words.json lives in the same folder (`voiceislocal eval apply --add-vocabulary`, `voiceislocal words`).
                self?.refreshWordList()
            }
        }
        // Read both again now the watch is on: a change made between the first read and the watch (an `eval apply`
        // finishing then) would otherwise wait for the next change in the folder.
        reloadCorrectionsIfChanged()
        refreshWordList()
        controller.frameTap = { [weak self] id, frame in
            guard let audio = self?.historyAudio, audio.id == id else { return }
            audio.writer.append(frame)
        }
        history.onChange = { [weak self] in self?.historyChanged() }
        history.onFailure = { [weak self] problem in self?.showHistoryProblem(problem) }
        history.start()
        // Readings the user kept rendering over the last quit continue; the natural voices are looked at.
        startReadings()
        PeopleLaunch.resumePendingForgetsOnce()
        Task { await loadLanguages() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice is Local")
        statusItem.button?.toolTip = "Voice is Local — local push-to-talk"
        rebuildMenu()
        AppKeyboard.install { [weak self] in self?.isBusy ?? false }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendForSessionChange() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self else { return }
                if self.enabled, let app { TextInsertion.enableAccessibility(for: app) }
                guard self.isBusy else { return }
                self.target = nil
                self.targetMoved = true
                self.insertionBlockReason = "The active application changed; use Copy Result."
            }
        })
        // Follow any existing recorder; its lifecycle is independent of dictation.
        setUpMeetings()
        let dictationEnabled = UserDefaults.standard.bool(forKey: "dictationEnabled")
        // Before the assistant's window opens, so it shows the downloads it started before a quit or its reopen.
        resumeSetupAssistantWork(dictationEnabled: dictationEnabled)
        // First launch opens the Setup Assistant; later launches open Settings in the main window while dictation is
        // off, else the main window when Settings › General says so (on Meetings while one records).
        // The window opens first, so an enable that fails leaves it in front instead of opening Setup over it.
        switch setupAssistantLaunch(dictationEnabled: dictationEnabled) {
        case .assistant: showSetupAssistant(verify: false)
        case .verify: showSetupAssistant(verify: true)
        case .markDone, .normal: if dictationEnabled { openMainWindowAtLaunch() } else { showSetup() }
        }
        if dictationEnabled { enable() }
    }

    /// Closing the last window never quits: Voice is Local lives in the menu bar, and dictation, meeting recordings,
    /// and readings keep running. Only the menu's Quit and ⌘Q quit (`applicationShouldTerminate`).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A click on the Dock icon (the app is regular while one of its windows is open, the live transcript or Review
    /// included) brings back the main window: restored from the Dock when minimised, else opened on the section it
    /// last showed. With the main window on screen, AppKit's own handling brings the app forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let mainWindow, mainWindow.isMiniaturized {
            mainWindow.restoreFromDock()
            return false
        }
        guard mainWindow?.isVisible != true else { return true }
        showMainWindowFromMenu(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A reading being made asks first (Keep Rendering or Stop); a meeting's question can still cancel the quit.
        // A quit the meeting cancels, now or later (`waitBeforeQuitting`), calls `readings.quitCancelled()`.
        guard readingShouldTerminate() else {
            reopenAfterQuit = false
            return .terminateCancel
        }
        let reply = meetingShouldTerminate()
        if reply == .terminateCancel {
            reopenAfterQuit = false
            readings.quitCancelled()
        }
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        if reopenAfterQuit { reopenOnceExited() }
        enableTask?.cancel(); assetTask?.cancel(); overlayHideTask?.cancel(); resultExpiryTask?.cancel()
        setupRefreshTask?.cancel(); assistantRefreshTask?.cancel(); stopNaturalVoiceHelpers()
        history.stop()
        // A dictation just recorded, deleted, or cleared must reach the file before the process exits; bounded, so a
        // stuck disk never holds up the quit.
        switch history.flush(timeout: 5) {
        case .written: break
        case .failed: log.error("Quitting after a history write failed")
        case .timedOut: log.error("Quit before the history's last change was written")
        }
        monitor?.stop(); controller?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        overlay.hide()
    }

    private var isBusy: Bool {
        guard let controller else { return false }
        if fixPipeline?.finishing == true { return true }
        return [.preparing, .listening, .finalizing].contains(controller.status.phase)
    }

    var shortcutTitle: String { shortcut == .rightOption ? "Right Option" : "Control–Option–Space" }

    /// Copy Result, Copy Original and Discard Result for the last dictation that produced a result.
    private func addResultItems(to menu: NSMenu) {
        let copy = item("Copy Result", #selector(copyResult))
        copy.isEnabled = !retention.kept.text.isEmpty
        menu.addItem(copy)
        if !retention.kept.original.isEmpty {
            menu.addItem(item("Copy Original (As Heard)", #selector(copyOriginal)))
        }
        let discard = item("Discard Result", #selector(discardResult))
        discard.isEnabled = !retention.kept.isEmpty && !isBusy
        menu.addItem(discard)
    }

    /// The menu bar menu: the dictation status and toggle, the kept result's Copy items, the meeting block, then the
    /// main window's items (docs/design.md "Main window"). The language and shortcut are chosen in Settings.
    func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let status = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let toggle = item("\(enabled ? "Disable" : "Enable") \(shortcutTitle) Dictation", #selector(toggleEnabled))
        toggle.state = enabled ? .on : .off
        toggle.isEnabled = !enabling && !installingAssets
        menu.addItem(toggle)
        if isBusy { menu.addItem(item("Cancel Dictation", #selector(cancelDictation))) }
        if !retention.kept.isEmpty { addResultItems(to: menu) }
        menu.addItem(item("Correct Last Dictation…", #selector(showCorrections)))
        menu.addItem(.separator())
        addMeetingItems(to: menu)
        addWindowItems(to: menu)
        menu.addItem(.separator())
        addAboutItem(to: menu)
        menu.addItem(item("Quit Voice is Local", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.toolTip = meetingToolTip() ?? "Voice is Local — \(message)"
        updateStatusItemAppearance()
        updateSettings()
        updateSetupAssistant()
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        if enabled {
            enableWhenSpeechModelInstalled = false  // the user turned it off: a pending install must not turn it on
            disable()
        } else {
            enable()
        }
    }

    /// False when the app bundle was replaced on disk while this process runs (a rebuild). macOS then
    /// treats Holos as unknown code: permissions re-prompt, and typing into a terminal froze it.
    private static func codeSignatureIsIntact() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    private func refuseIfReplaced() -> Bool {
        guard !Self.codeSignatureIsIntact() else { return false }
        log.error("Code signature no longer matches the app on disk; dictation paused")
        if enabled || enabling { disable(persist: false) }
        show("Voice is Local was rebuilt while running. Quit and reopen Voice is Local to dictate again.")
        overlay.show(title: "Voice is Local was rebuilt while running", text: "Quit and reopen Voice is Local to dictate again.",
                     force: true, attention: true)
        scheduleOverlayHide()
        return true
    }

    func enable() {
        guard !enabled, !enabling, !installingAssets else { return }
        guard !refuseIfReplaced() else { return }
        guard AudioCapture.microphonePermission == "authorized", AXIsProcessTrusted() else {
            show("Grant Microphone and Accessibility access in Voice is Local Settings, then enable dictation.")
            showSetupUnlessAssistant()
            return
        }
        enabling = true
        enableGeneration += 1
        let generation = enableGeneration
        show("Checking local speech assets…")
        enableTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Without a saved choice the language is the default one, known once the languages are loaded.
                await self.loadLanguages()
                guard !Task.isCancelled, generation == self.enableGeneration else { return }
                self.controller.locale = self.locale
                self.controller.contextualStrings = self.dictationVocabulary(language: self.locale)
                let state = try await AppleSpeechEngine.assetStatus(locale: self.locale, backend: .speech)
                guard !Task.isCancelled, generation == self.enableGeneration else { return }
                self.assetState = state
                guard state == "installed" else {
                    self.enabling = false
                    self.show("Install the speech model for \(self.languageName) in Voice is Local Settings first.")
                    self.showSetupUnlessAssistant()
                    return
                }
                let monitor = GlobalHotkeyMonitor(shortcut: self.shortcut) { [weak self] action in self?.handle(action) }
                try monitor.start()
                self.inputMonitoringNeeded = false
                self.monitor = monitor
                self.enabled = true
                self.enabling = false
                self.dictationSession.didEnable()
                UserDefaults.standard.set(true, forKey: "dictationEnabled")
                self.enableWhenSpeechModelInstalled = false  // done: the assistant's deferred enable is fulfilled
                if let app = NSWorkspace.shared.frontmostApplication { TextInsertion.enableAccessibility(for: app) }
                self.show("Ready — hold \(self.shortcutTitle); wait for Listening")
                self.overlay.hide()
            } catch {
                guard generation == self.enableGeneration else { return }
                self.enabling = false
                self.show(error.localizedDescription)
                if error as? HotkeyStartError == .tapRefused {
                    // Only now does Setup show its Input Monitoring row (GlobalHotkeyMonitor).
                    self.inputMonitoringNeeded = true
                    self.showSetupUnlessAssistant()
                }
            }
        }
    }

    func disable(persist: Bool = true) {
        enableGeneration += 1
        enableTask?.cancel(); enableTask = nil
        enabling = false
        enabled = false
        target = nil
        monitor?.stop(); monitor = nil
        endFixing(heard: latestCommitted)
        controller.cancel()
        if persist { UserDefaults.standard.set(false, forKey: "dictationEnabled") }
        show("Disabled — \(shortcutTitle) is available to other apps")
        overlay.hide()
    }

    /// Not during a dictation or an enable; Settings then shows the current shortcut again.
    var canChangeShortcut: Bool { !isBusy && !enabling }

    func changeShortcut(to choice: HotkeyChoice) {
        guard choice != shortcut, canChangeShortcut else {
            updateSettings()  // puts a refused choice back in Settings
            return
        }
        let wasEnabled = enabled
        disable()
        shortcut = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "shortcut")
        if wasEnabled { enable() } else { show("Disabled — shortcut: \(shortcutTitle)") }
    }

    /// Not while a dictation, install, or enable is in progress: a change applies from the next dictation.
    var canChangeLanguage: Bool { !isBusy && !enabling && !installingAssets }

    func changeLanguage(to identifier: String) {
        guard identifier != locale, canChangeLanguage else {
            updateSettings()  // puts a refused choice back in Settings
            return
        }
        locale = identifier
        controller.locale = identifier
        controller.contextualStrings = dictationVocabulary(language: identifier)
        assetState = nil
        if enabled {
            // Enabling again checks the new language's speech model; without it, dictation stays off and Setup
            // offers the install.
            disable()
            enable()
        } else {
            show("Dictation language: \(languageName)")
            refreshAssetState()
        }
    }

    /// Loads the languages Apple's speech transcriber supports, for Setup, the menu, the meeting start panel, and the
    /// default language; returns once they are loaded (or could not be: the default is then
    /// `DictationLanguage.standard`, and a later call tries again). Loads them once.
    func loadLanguages() async {
        if let supportedLocales, !supportedLocales.isEmpty { return }
        if let languagesTask { return await languagesTask.value }
        let task = Task { [weak self] in
            let supported = await AppleSpeechEngine.capabilities(backend: .speech).supportedLocales
            guard let self else { return }
            self.languagesTask = nil
            let before = self.locale
            // Also when empty: the default is then known to be `standard`, so what waited for it can go on.
            self.supportedLocales = supported
            if !supported.isEmpty { self.localeGroups = DictationLanguage.groups(supported) }
            // The default language may have changed from the provisional one; enabling uses the new one.
            if self.locale != before {
                self.assetState = nil
                self.refreshAssetState()
            }
            self.rebuildMenu()
            self.languagesLoaded()
        }
        languagesTask = task
        await task.value
    }

    private func handle(_ action: HotkeyAction) {
        guard enabled else { return }
        switch action {
        case .began:
            guard !isBusy, !refuseIfReplaced(), !TextInsertion.isSecureInputActive() else {
                return
            }
            overlay.allowShowing()
            resultNeedsAttention = false
            forcedStopMessage = nil
            insertionBlockReason = nil
            insertedText = ""
            latestCommitted = ""
            streamUnverified = false
            targetMoved = false
            originPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            originFocus = TextInsertion.currentFocus()
            typedAppName = nil
            if let app = NSWorkspace.shared.frontmostApplication { TextInsertion.enableAccessibility(for: app) }
            let terminal: KeystrokeTarget?
            var terminalRefusal: String?
            do {
                terminal = try KeystrokeTarget.captureTerminal()
            } catch {
                terminal = nil
                terminalRefusal = error.localizedDescription
            }
            // A terminal's code tokens are typed without backticks, also when its focus changed at key-down and the
            // text waits for Copy Result.
            dictationForTerminal = terminal?.isTerminal == true || terminalRefusal != nil
            if let terminalRefusal {
                // Focus moved while it was captured; the text is kept for Copy Result, never typed.
                target = nil
                insertionBlockReason = "The terminal's focus changed as dictation started; use Copy Result."
                log.notice("No target: \(terminalRefusal, privacy: .public)")
            } else if let terminal {
                target = .keystrokes(terminal)
                typedAppName = terminal.appName
                log.notice("Target: terminal \(terminal.appName, privacy: .public)")
            } else if let web = KeystrokeTarget.captureWebEditor() {
                target = .keystrokes(web)
                typedAppName = web.appName
                log.notice("Target: web editor in \(web.appName, privacy: .public)")
            } else {
                do {
                    target = .field(try TextInsertion.captureTarget())
                    log.notice("Target: text field")
                } catch TextInsertionError.secureInput {
                    target = nil
                    show("Dictation is disabled in secure/password fields.")
                    return
                } catch TextInsertionError.notWritable(let reason) {
                    // The field has no direct write; typing is the only way in. Safety-check failures
                    // (large selection, unreadable range) fall through to Copy instead.
                    if let editable = KeystrokeTarget.captureEditableField() {
                        target = .keystrokes(editable)
                        typedAppName = editable.appName
                        log.notice("Target: typing into a field in \(editable.appName, privacy: .public) (\(reason, privacy: .public))")
                    } else {
                        target = nil
                        insertionBlockReason = "This field cannot be safely updated; use Copy Result."
                        log.notice("No target: \(reason, privacy: .public)")
                    }
                } catch {
                    target = nil
                    insertionBlockReason = "This field cannot be safely updated; use Copy Result."
                    log.notice("No target: \(error.localizedDescription, privacy: .public)")
                }
            }
            overlayHideTask?.cancel()
            // The previous result, its menu items and its expiry stay until this dictation produces one of its own
            // (`retainResult`). `begin` can conclude at once (no microphone permission), so this comes first.
            resultText = ""
            resultOriginal = ""
            retention.begin()
            // Only now, past the secure-field checks above: a refused dictation never gets a History record.
            let fieldPID: pid_t? = if case .field(let field) = target { field.pid } else { nil }
            historyOutcome = nil
            historyDraft = HistoryDraft(date: Date(),
                                        app: Self.historyAppName(typed: typedAppName, pid: fieldPID ?? originPID),
                                        language: locale, terminal: dictationForTerminal)
            // Terms added with `voiceislocal words` since the last dictation count for this one.
            refreshWordList()
            // This dictation's corrections, fixed now; a refused begin leaves the one still stopping with its own.
            let previousCorrections = dictationCorrections
            dictationCorrections = corrections
            if controller.begin() {
                // A pending opacity sample must not hide this dictation's own preview or result.
                // A rejected begin leaves the timer running so the sample still hides on time.
                opacitySampleTask?.cancel()
                opacitySampleTask = nil
                sampleToken = nil
                fixPipeline?.cancel()
                fixPipeline = DictationFixPipeline.make(corrections: dictationCorrections, wordList: wordList.terms,
                                                        heardAs: wordList.heardAsPairs, language: locale,
                                                        terminal: dictationForTerminal) { [weak self] chunk, text in
                    self?.writeFixed(chunk, as: text) ?? false
                }
                // Its audio, for Run Again, when History keeps it; not for a dictation that already ended (`begin`
                // can fail at once), which has no draft any more.
                discardHistoryAudio()
                if let id = historyDraft?.id, history.recordsAudio {
                    historyAudio = (id, DictationAudioWriter(store: history.store, id: id))
                }
            } else {
                dictationCorrections = previousCorrections
                target = nil
                historyDraft = nil
                _ = retention.conclude(DictationResult())  // nothing started, so the previous result stays
                show("Previous dictation is still stopping; release and try again shortly.")
            }
        case .ended: controller.end()
        case .cancelled: cancelDictation()
        }
    }

    private func receive(_ update: DictationStatus) {
        monitor?.setSessionActive([.preparing, .listening, .finalizing].contains(update.phase))
        noteHistoryPhase(update)
        switch update.phase {
        case .idle:
            target = nil
            historyDraft = nil  // cancelled or disabled: nothing is recorded, not its audio either
            discardHistoryAudio()
            overlay.hide()
            message = enabled ? "Ready — hold \(shortcutTitle)" : "Disabled"
            // Cancelled or disabled: usually nothing to keep, but Copy Original may hold what was heard when Apple
            // Intelligence's fix already changed written text.
            retainResult()
        case .preparing:
            message = "Preparing — wait before speaking"
            if showPreview {
                overlay.show(title: message, text: "Release to stop · Esc to cancel")
            } else {
                overlay.hide()  // an earlier result's message no longer applies
            }
        case .listening:
            message = "Listening — release \(shortcutTitle) to finish"
            if showPreview {
                overlay.show(title: message,
                             text: update.text.isEmpty ? "Speak now · Esc to cancel" : cleaned(update.text))
            }
            latestCommitted = update.committedText
            stream(cleanedForStreaming(update.committedText))
        case .finalizing:
            if let reason = update.message {
                target = nil
                insertionBlockReason = reason + " Use Copy Result."
            }
            message = update.message ?? "Finishing locally…"
            if let forced = update.message {  // a forced stop must stay visible through the result
                resultNeedsAttention = true
                forcedStopMessage = forced
            }
            if showPreview || update.message != nil {
                overlay.show(title: message, text: cleaned(update.text), attention: update.message != nil)
            }
            if !update.committedText.isEmpty { latestCommitted = update.committedText }
            stream(cleanedForStreaming(update.committedText))
        case .result:
            let recognized = withoutFillers(update.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = dictationCorrections.apply(to: recognized)
            if !text.isEmpty {
                lastTranscript = text
                lastRecognized = recognized
                // Its History ID, else one of its own: Corrections tells the last dictation apart by ID, not text.
                lastTranscriptID = historyDraft?.id ?? UUID()
            }
            if let pipeline = fixPipeline {
                // Earlier chunks may still be waiting for their fix; the target stays until they are written.
                pipeline.finishing = true
                let heard = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { [weak self] in await self?.finishFixing(text, heard: heard, with: pipeline) }
                break
            }
            let destination = target
            target = nil // No callback or retry can write to this target again.
            finish(text, into: destination)
            recordHistory(recognized: text, heard: update.text)
            presentResult()
        case .failed:
            // Keep committed words that were withheld or not yet written, so Copy Result still has them. A chunk
            // whose fixed write failed is offered as fixed, the text Holos tried to write.
            let committed = cleaned(latestCommitted).trimmingCharacters(in: .whitespacesAndNewlines)
            let unwritten = TextInsertion.unwritten(committed, after: insertedText)
            // Read before `endFixing` drops the pipeline: the chunks it wrote as fixed, for History.
            let pipeline = fixPipeline
            let fixedWritten = pipeline?.written ?? ""
            let attempted = unwritten.map {
                AIFixUnwritten.attempted($0, fixedRest: nil, failedWrite: pipeline?.failedWrite)
            }
            // The same after spoken code alone, so History counts Apple Intelligence's words apart from code.
            let codedAttempted = unwritten.map {
                AIFixUnwritten.attempted($0, fixedRest: nil, failedWrite: pipeline?.failedWrite.map {
                    ($0.chunk, pipeline?.failedCoded?.text ?? $0.chunk)
                })
            }
            let changes = pipeline?.changes(offered: attempted ?? "", coded: codedAttempted ?? "",
                                            recognized: unwritten ?? "")
            endFixing(heard: latestCommitted, offered: attempted ?? "", recognized: unwritten ?? "")
            target = nil
            message = update.message ?? "Dictation failed; no text was inserted."
            if !insertedText.isEmpty { message += " Text inserted before the failure stays in the field." }
            if !resultOriginal.isEmpty {
                let steps = PipelineChangeText.steps(code: changes?.code ?? false, fix: changes?.fix ?? true)
                message += " Copy Original has what was heard, before \(steps)."
            }
            if let unwritten, let rest = attempted, !unwritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Keep the leading space so pasting after the inserted prefix does not join words.
                resultText = insertedText.isEmpty ? rest.trimmingCharacters(in: .whitespaces) : rest
                // Never written to the clipboard on its own (it may hold something sensitive); Copy Result has it.
                if streamUnverified {
                    // An unconfirmed write may already have landed; pasting blindly could duplicate it.
                    message += " Some text may already be in the field — check it before using Copy Result."
                } else if focusMovedSinceKeyDown() {
                    message += " Copy Result has the words that were not inserted; return to the original field first."
                } else {
                    message += " Copy Result has the words that were not inserted."
                }
            } else if unwritten == nil, !committed.isEmpty {
                // The transcript no longer extends what was inserted, so no tail is safe to paste.
                resultText = committed
                message += " The transcript changed after text was inserted; check the field. Copy Result has the full transcript."
            } else {
                resultText = update.text
            }
            // History keeps what was recognized before the failure, by the same rules as a released dictation: the
            // text as written or offered (with Apple Intelligence's fix), and the outcome the stream left
            // (unverified, the app or field changed, or not inserted), partly written when a prefix went in.
            historyOutcome = .afterFailure(reason: update.message ?? insertionBlockReason ?? "Dictation failed.",
                                           rest: unwritten, wroteAny: !insertedText.isEmpty,
                                           typed: typedAppName != nil, unverified: streamUnverified,
                                           targetMoved: targetMoved)
            recordHistory(recognized: committed, heard: latestCommitted, fixedWritten: fixedWritten, rest: attempted,
                          coded: pipeline.map { ($0.writtenCoded, codedAttempted) },
                          codeSpans: (pipeline?.writtenCodeSpans ?? 0) + (pipeline?.failedCoded?.spans ?? 0))
            retainResult()
            overlay.show(title: message, text: resultText, attention: true)
            scheduleOverlayHide()
        }
        rebuildMenu()
    }

    /// Writes newly finalized words while the user is still speaking. Any refusal stops streaming for
    /// the rest of the utterance, and the unwritten remainder is offered through Copy Result.
    private func stream(_ committed: String) {
        guard enabled, insertionBlockReason == nil, let destination = target else { return }
        // With on-device fixing, text handed to the pipeline counts as written: it is written once fixed.
        guard let chunk = TextInsertion.unwritten(committed, after: fixPipeline?.submitted ?? insertedText) else {
            target = nil
            insertionBlockReason = "The recognizer revised text that was already inserted; check the field."
            log.notice("Stream stopped: committed text no longer extends the inserted prefix")
            return
        }
        guard !chunk.isEmpty else { return }
        if let fixPipeline {
            fixPipeline.submit(chunk)
            return
        }
        writeStreamed(chunk, as: chunk, to: destination)
    }

    /// Writes a chunk the fix pipeline is done with; false when streaming has stopped meanwhile.
    private func writeFixed(_ chunk: String, as text: String) -> Bool {
        guard enabled, insertionBlockReason == nil, let destination = target else { return false }
        return writeStreamed(chunk, as: text, to: destination)
    }

    /// Writes `text` (the recognized `chunk`, or its on-device fix) and moves past it. False when the write failed.
    @discardableResult
    private func writeStreamed(_ chunk: String, as text: String, to destination: Destination) -> Bool {
        let outcome = write(text, to: destination)
        log.notice("Stream chunk of \(text.utf16.count) units: \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .inserted:
            insertedText += chunk
            if case .field(let field) = destination {
                if let next = TextInsertion.advance(field, past: text) { target = .field(next) }
                else {
                    target = nil
                    insertionBlockReason = "The field changed after the last insertion."
                    targetMoved = true
                    log.notice("Stream stopped: field did not match the expected state after insertion")
                }
            }
            return true
        case .typed:
            insertedText += chunk
            return true
        case .needsCopy(let reason), .unverified(let reason), .targetChanged(let reason):
            if case .unverified = outcome { streamUnverified = true }
            if case .targetChanged = outcome { targetMoved = true }
            target = nil
            insertionBlockReason = reason
            return false
        }
    }

    /// The end of a dictation with on-device fixing: waits for the chunks still being fixed, fixes the rest, then
    /// finishes as without it. Cancelling or disabling dictation meanwhile drops the pipeline and ends this.
    /// `heard` is the recognizer's text before filler removal and corrections, for Copy Original.
    private func finishFixing(_ text: String, heard: String, with pipeline: DictationFixPipeline) async {
        await pipeline.idle()
        guard fixPipeline === pipeline else { return }
        var fixedRest: String?
        var codedRest: (text: String, spans: Int)?
        // Only this last part may gain closing punctuation. When the recognizer committed everything before release,
        // nothing is added at the end.
        let writable = enabled && insertionBlockReason == nil && target != nil
        if writable, let rest = TextInsertion.unwritten(text, after: insertedText),
           !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let result = await pipeline.fix(rest, isFinal: true)
            guard fixPipeline === pipeline else { return }
            fixedRest = result.text
            codedRest = (result.coded, result.codeSpans)
        }
        let destination = target
        target = nil // No callback or retry can write to this target again.
        // The fix of the part not yet written: written in its place, or, when that write fails or a streamed chunk's
        // write failed, what Copy Result offers, since Holos tried to write it and it may already be in the field.
        let unwritten = TextInsertion.unwritten(text, after: insertedText)
        let attempted = unwritten.map {
            AIFixUnwritten.attempted($0, fixedRest: fixedRest, failedWrite: pipeline.failedWrite)
        }
        // The same after spoken code alone.
        let codedAttempted = unwritten.map {
            AIFixUnwritten.attempted($0, fixedRest: codedRest?.text, failedWrite: pipeline.failedWrite.map {
                ($0.chunk, pipeline.failedCoded?.text ?? $0.chunk)
            })
        }
        let changes = pipeline.changes(offered: attempted ?? "", coded: codedAttempted ?? "",
                                       recognized: unwritten ?? "")
        endFixing(heard: heard, offered: attempted ?? "", recognized: unwritten ?? "")
        let written = finish(text, into: destination, writing: attempted == unwritten ? nil : attempted)
        // History: what Holos wrote or tried to write, how many words Apple Intelligence changed, and how many
        // spoken paths were written as code.
        let restSpans = codedRest?.spans ?? (fixedRest == nil ? pipeline.failedCoded?.spans ?? 0 : 0)
        recordHistory(recognized: text, heard: heard, fixedWritten: pipeline.written, rest: attempted,
                      coded: (pipeline.writtenCoded, codedAttempted), codeSpans: pipeline.writtenCodeSpans + restSpans)
        if !resultOriginal.isEmpty {
            let what = PipelineChangeText.what(code: changes.code, fix: changes.fix)
            let steps = PipelineChangeText.steps(code: changes.code, fix: changes.fix)
            // What Holos wrote or tried to write: the fixed chunks, then the fix of the rest.
            let fixed = pipeline.written + (attempted ?? "")
            if let final = AIFixTranscript.final(written: pipeline.written, rest: attempted) {
                // Correct Last Dictation opens exactly what was written and learns only the speaker's own edits
                // from it, not Apple Intelligence's. Copy Original keeps the text as heard.
                lastTranscript = final
                lastRecognized = final
            }
            if written {
                resultText = fixed
                message += " \(what); Copy Original has what was heard."
            } else if attempted != unwritten {
                // Copy Result has the fixed words Holos tried to write (set by `finish`).
                message += " Copy Result has the text after \(steps); Copy Original has what was heard."
            } else {
                // Only chunks already in the field were changed; Copy Result has the rest as recognized.
                message += " Text already written was changed by \(steps); Copy Original has what was heard."
            }
        }
        presentResult()
        rebuildMenu()
    }

    /// Ends on-device fixing, however the dictation ends: released, failed, cancelled or disabled. When a fix changed
    /// text already written, or what was written or offered in place of the `recognized` rest (`offered`), Copy
    /// Original keeps `heard`, the recognizer's text, since the field may hold Apple Intelligence's words.
    private func endFixing(heard: String, offered: String = "", recognized: String = "") {
        guard let pipeline = fixPipeline else { return }
        pipeline.cancel()
        fixPipeline = nil
        if let kept = AIFixOriginal.heard(heard.trimmingCharacters(in: .whitespacesAndNewlines),
                                          written: pipeline.written, writtenOriginal: pipeline.writtenOriginal,
                                          offered: offered, recognized: recognized) {
            resultOriginal = kept
        }
    }

    /// Writes whatever the final transcript adds beyond the streamed prefix, in a single attempt.
    private func withoutFillers(_ text: String) -> String {
        removeFillers ? FillerWords.remove(from: text, language: locale) : text
    }

    /// Filler removal, then learned corrections (this dictation's): the text Holos shows and writes.
    private func cleaned(_ text: String) -> String {
        dictationCorrections.apply(to: withoutFillers(text))
    }

    /// Like `cleaned`, but holds back a trailing comma or phrase start that later words may still change, and with
    /// spoken code, a trailing spoken path that later words may continue.
    private func cleanedForStreaming(_ text: String) -> String {
        DictationTextPipeline.cleanedForStreaming(text, language: locale, removeFillers: removeFillers,
                                                  corrections: dictationCorrections,
                                                  spokenCode: fixPipeline?.formatsCode == true)
    }

    /// `fixed` is the on-device fix of the part not yet written, written in its place; when it cannot be written,
    /// Copy Result gets it instead of the recognized text. True when the whole transcript is now
    /// in the target.
    @discardableResult
    private func finish(_ text: String, into destination: Destination?, writing fixed: String? = nil) -> Bool {
        resultText = text
        guard !insertedText.isEmpty else {
            guard !text.isEmpty else {
                message = "No speech recognized"
                resultNeedsAttention = true  // shown even with the preview off, so it is not mistaken for success
                return false
            }
            let outcome: InsertionOutcome = if enabled, insertionBlockReason == nil, let destination {
                write(fixed ?? text, to: destination)
            } else {
                blockedOutcome(default: "No writable target.")
            }
            log.notice("Nothing streamed; whole result of \(text.utf16.count) units: \(String(describing: outcome), privacy: .public)")
            conclude(outcome, unwritten: fixed ?? text, partial: false)
            return outcome == .inserted || outcome == .typed
        }
        guard let rest = TextInsertion.unwritten(text, after: insertedText) else {
            // An empty final transcript is no result, so Copy Result keeps the previous dictation's text instead.
            message = text.isEmpty
                ? "Text was inserted while you spoke, but the final transcript came back empty. Check the field."
                : "Text was inserted while you spoke, but the final transcript differs. Check the field; Copy Result copies the full transcript."
            resultNeedsAttention = true
            // History keeps this dictation too: an empty final result still left the streamed text in the field.
            historyOutcome = text.isEmpty ? .transcriptEmpty : .transcriptDiffers
            return false
        }
        let remainder = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            message = outcomeMessage(typedAppName == nil ? .inserted : .typed)
            historyOutcome = .init(kind: typedAppName == nil ? .inserted : .typed)
            return true
        }
        let outcome: InsertionOutcome = if enabled, insertionBlockReason == nil, let destination {
            write(fixed ?? rest, to: destination)
        } else {
            blockedOutcome(default: "Insertion stopped.")
        }
        log.notice("Final chunk of \(rest.utf16.count) units: \(String(describing: outcome), privacy: .public)")
        // Keep the leading space so pasting after the inserted prefix does not join words.
        conclude(outcome, unwritten: (fixed ?? rest).trimmingCharacters(in: .newlines), partial: true)
        return outcome == .inserted || outcome == .typed
    }

    /// Shows the result of a finished dictation, and a forced stop that ended it.
    private func presentResult() {
        if let forced = forcedStopMessage, !message.hasPrefix(forced) { message = forced + " " + message }
        retainResult()
        if showPreview || resultNeedsAttention {
            overlay.show(title: message, text: resultText, attention: resultNeedsAttention)
        }
        scheduleOverlayHide()
    }

    /// Concludes this dictation for the menu: its result replaces the kept one and starts a new ten-minute expiry,
    /// unless it produced nothing; then the previous result, its menu items and its expiry stay as they were.
    private func retainResult() {
        switch retention.conclude(DictationResult(text: resultText, original: resultOriginal)) {
        case .replaced:
            resultExpiryTask?.cancel()
            resultExpiryTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(600))
                    self?.expireResult()
                } catch { }
            }
        case .keptPrevious:
            if !retention.kept.text.isEmpty, controller.status.phase != .idle {
                message += (message.hasSuffix(".") ? "" : ".") + " Copy Result still has the previous dictation."
            }
        case .nothing:
            break
        }
    }

    private func blockedOutcome(default reason: String) -> InsertionOutcome {
        let reason = insertionBlockReason ?? reason
        if streamUnverified { return .unverified(reason) }
        return targetMoved ? .targetChanged(reason) : .needsCopy(reason)
    }

    /// Text that could not be written is kept for Copy Result in the menu. It is never put on the clipboard on its
    /// own: dictated text can be sensitive (even a password), so only the user's Copy Result or Copy Original does.
    private func conclude(_ outcome: InsertionOutcome, unwritten: String, partial: Bool) {
        historyOutcome = switch outcome {
        case .inserted: .init(kind: .inserted)
        case .typed: .init(kind: .typed)
        case .needsCopy(let reason): .init(kind: .needsCopy, reason: reason, partial: partial)
        case .unverified(let reason): .init(kind: .unverified, reason: reason, partial: partial)
        case .targetChanged(let reason): .init(kind: .targetChanged, reason: reason, partial: partial)
        }
        switch outcome {
        case .inserted, .typed:
            message = outcomeMessage(outcome)
        case .needsCopy(let reason), .unverified(let reason), .targetChanged(let reason):
            log.notice("Not written: \(reason, privacy: .public)")
            resultNeedsAttention = true
            resultText = unwritten
            let moved: Bool = if case .targetChanged = outcome { true } else { focusMovedSinceKeyDown() }
            if moved {
                let head = partial ? "Inserted the first part; then the app or field changed."
                                   : "The app or field changed before Voice is Local could write."
                message = "\(head) Use Copy Result after returning to the original field."
                return
            }
            let head: String = if case .unverified = outcome {
                "Insertion unverified — check the field before using Copy Result."
            } else if partial {
                "Inserted the first part; couldn't write the rest."
            } else {
                "Couldn't write into this field."
            }
            message = "\(head) Use Copy Result."
        }
    }

    /// Checked when the result message is written, so a focus change inside the same app counts too.
    private func focusMovedSinceKeyDown() -> Bool {
        if targetMoved { return true }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != originPID { return true }
        if let originFocus { return !TextInsertion.stillFocused(originFocus) }
        return false
    }

    private func copyToClipboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    /// History's Copy and Copy As Heard: only ever on the user's request.
    func copyToClipboardOnRequest(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return copyToClipboard(text)
    }

    // MARK: - History

    /// Follows the dictation in progress for its History record: its ID, and when Listening started and ended.
    private func noteHistoryPhase(_ update: DictationStatus) {
        guard var draft = historyDraft else { return }
        if let id = update.utteranceID {
            if draft.id == nil { draft.id = id } else if draft.id != id { return }  // an earlier dictation's update
        }
        let now = Date()
        switch update.phase {
        case .listening:
            if draft.listeningStarted == nil { draft.listeningStarted = now }
        case .finalizing, .result, .failed:
            if draft.listeningStarted != nil, draft.listeningEnded == nil { draft.listeningEnded = now }
        case .idle, .preparing:
            break
        }
        historyDraft = draft
    }

    /// Records the dictation that just ended in History, by one rule however it ended (released, with or without
    /// Apple Intelligence's fix, or failed). `recognized` is the transcript after fillers and corrections, `heard` the
    /// recognizer's text before them; with the fix, `fixedWritten` is what its pipeline wrote and `rest` what was
    /// written or offered after that (`AIFixUnwritten.attempted`), so the text kept is the text written or offered
    /// (`DictationRecord.endText`). The outcome is `historyOutcome`, and a partly written dictation keeps what Copy
    /// Result offers (`resultText`) for History's Copy, so this runs once both are set. Once per dictation, never for
    /// one refused at key-down (no draft), never with History off, and never while secure input is on.
    /// With spoken code, `coded` is the same text after spoken code alone (`DictationRecord.endText`), and `codeSpans`
    /// the code spans in the text kept.
    private func recordHistory(recognized: String, heard: String, fixedWritten: String = "", rest: String? = nil,
                               coded: (written: String, rest: String?)? = nil, codeSpans: Int = 0) {
        // The audio goes with the record, or is deleted when there is none.
        let audio = historyAudio
        historyAudio = nil
        guard let draft = historyDraft else {
            audio?.writer.discard()
            return
        }
        historyDraft = nil
        let outcome = historyOutcome
        historyOutcome = nil
        // Text written while the user spoke counts even when the final transcript came back empty.
        let written = DictationRecord.endText(recognized: recognized, fixChanged: !resultOriginal.isEmpty,
                                              fixedWritten: fixedWritten, rest: rest, inserted: insertedText,
                                              coded: coded)
        let aiChangedWords = written.aiChangedWords
        let text = written.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outcome, !text.isEmpty, history.retention.records, !TextInsertion.isSecureInputActive() else {
            audio?.writer.discard()
            return
        }
        var heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.isEmpty { heard = latestCommitted.trimmingCharacters(in: .whitespacesAndNewlines) }
        let withoutFill = withoutFillers(heard)
        let fillersRemoved = removeFillers && WordDiff.normalized(withoutFill) != WordDiff.normalized(heard)
        let swaps = dictationCorrections
            .applyCounting(to: withoutFill.trimmingCharacters(in: .whitespacesAndNewlines)).count
        history.add(DictationRecord(
            id: draft.id ?? UUID(), date: draft.date, app: draft.app, language: draft.language, text: text,
            heard: heard.isEmpty ? text : heard, unwritten: resultText,
            fixes: .init(fillersRemoved: fillersRemoved, corrections: swaps, aiChangedWords: aiChangedWords,
                         codeSpans: resultOriginal.isEmpty ? 0 : codeSpans),
            outcome: outcome, seconds: draft.seconds(now: Date()), terminal: draft.terminal),
            audio: audio.flatMap { $0.id == draft.id ? $0.writer : nil })
        if let audio, audio.id != draft.id { audio.writer.discard() }
    }

    /// Deletes the audio of a dictation History will not record (cancelled, disabled, or replaced).
    private func discardHistoryAudio() {
        historyAudio?.writer.discard()
        historyAudio = nil
    }

    /// "Correct Last Dictation…": the main window's Corrections section with the last dictation.
    @objc private func showCorrections() {
        showMainWindow(.corrections)
        (mainWindow?.existingController(for: .corrections) as? CorrectionsPane)?.load(
            transcript: lastTranscript, recognized: lastRecognized, dictation: lastTranscriptID,
            title: "Last dictation — fix any misheard words, then Learn", corrections: corrections.entries)
    }

    /// History's Correct…: Corrections with that dictation. The last dictation is compared with its text as
    /// recognized; an older one with its text as written, the only form History keeps of it.
    func correct(_ record: DictationRecord) {
        let isLast = record.id == lastTranscriptID && !lastTranscript.isEmpty
        showMainWindow(.corrections)
        (mainWindow?.existingController(for: .corrections) as? CorrectionsPane)?.load(
            transcript: isLast ? lastTranscript : record.text, recognized: isLast ? lastRecognized : record.text,
            dictation: record.id, title: "Dictation in \(record.app ?? "an app") — fix any misheard words, then Learn",
            corrections: corrections.entries)
    }

    func makeCorrectionsPane() -> CorrectionsPane {
        let pane = CorrectionsPane(
            onLearn: { [weak self] edited, original, dictation in
                self?.learnCorrections(from: edited, original: original, dictation: dictation)
            },
            onAdd: { [weak self] correction, edit in
                self?.addCorrection(correction, resolving: edit) ?? false
            },
            onRemove: { [weak self] correction in self?.changeCorrections { $0.remove(correction) } ?? false },
            onReplace: { [weak self] old, new, edit in
                self?.replaceCorrection(old, with: new, resolving: edit) ?? false
            },
            wordList: makeWordListView(),
            onShow: { [weak self] in self?.refreshWordList() })
        pane.wordListView.update(entries: wordList.entries, problem: wordListProblem)
        pane.load(transcript: lastTranscript, recognized: lastRecognized, dictation: lastTranscriptID,
                  title: "Last dictation — fix any misheard words, then Learn", corrections: corrections.entries)
        return pane
    }

    /// Learns from `edited` against `original`, the text it was edited from as recognized (the last dictation's
    /// `lastRecognized`, or a History dictation's text). `dictation` is the ID of the dictation edited: only the last
    /// one's edit replaces what Correct Last Dictation opens, even when an older one has the same text.
    private func learnCorrections(from edited: String, original: String,
                                  dictation: UUID?) -> CorrectionsPane.LearnResult? {
        // Diff against the recognizer's words, so fixing text an existing rule produced replaces that rule.
        // A word counts as "common" only if its lowercase form is in the dictionary: the spell checker also
        // accepts capitalized names ("Gwen"), which should be learned on their own.
        let result = CorrectionList.learnReportingDeclined(original: original, corrected: edited) { word in
            NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0).location == NSNotFound
        }
        let learned = result.learned.filter { corrections.apply(to: $0.heard) != $0.meant }
        let declined = result.declined.filter { corrections.apply(to: $0.heard) != $0.meant }
        guard !learned.isEmpty else {
            // Nothing is saved yet; each declined swap carries the edit, kept once the user adds that swap.
            return CorrectionsPane.LearnResult(
                learned: [], declined: declined,
                edit: .init(recognized: original, edited: edited, dictation: dictation))
        }
        guard changeCorrections({ list in for correction in learned { list.add(correction) } }) else { return nil }
        if let dictation, dictation == lastTranscriptID, original == lastRecognized {
            lastTranscript = edited
            lastRecognized = edited
        }
        return CorrectionsPane.LearnResult(learned: learned, declined: declined, edit: nil)
    }

    /// A live meeting's exact timed text correction also teaches safe, small mishearing pairs for future speech.
    /// Reconciles every live-managed rule with the latest edit of each phrase, so a shared rule stays until its last
    /// confirming phrase releases it while an identical rule predating live editing is never claimed. Rewordings and
    /// unanchored dictionary-word swaps remain timed-only.
    func learnMeetingCorrection(state: LiveHints.CorrectionLearningState,
                                heard: String, meant: String) -> LiveTextLearning {
        let dictionaryWord: (String) -> Bool = { word in
            NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0).location == NSNotFound
        }
        let learned = CorrectionList.learn(original: heard, corrected: meant, isDictionaryWord: dictionaryWord)
        let desired = state.other + learned
        guard !state.managed.isEmpty || !desired.isEmpty else {
            return LiveTextLearning(learned: learned, owned: [], displaced: [])
        }
        var reconciliation = CorrectionList.LearningReconciliation()
        guard changeCorrections({
            reconciliation = $0.reconcileLearned(state.managed, preserving: state.preexisting, with: desired)
        }) else {
            // Nil metadata leaves the prior successful learning state in place for this phrase.
            return LiveTextLearning(problem: "the corrections list is unavailable")
        }
        return LiveTextLearning(learned: learned, owned: reconciliation.owned, displaced: reconciliation.displaced,
                                rollback: { [weak self] in
            self?.changeCorrections { list in
                list.reconcileLearned(state.managed + reconciliation.owned,
                                      preserving: state.preexisting + reconciliation.displaced,
                                      with: state.other + state.previous)
            } ?? false
        })
    }

    /// The corrections a word edit saved in a meeting's Review teaches (`TranscriptEditLearning`; none for a trivial
    /// edit).
    func reviewEditCorrections(_ edit: ReviewWordEdit) -> [Correction] {
        let dictionaryWord: (String) -> Bool = { word in
            NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0).location == NSNotFound
        }
        return TranscriptEditLearning.corrections(heard: edit.heard, meant: edit.meant, before: edit.before,
                                                  after: edit.after, heardBefore: edit.heardBefore,
                                                  heardAfter: edit.heardAfter, isDictionaryWord: dictionaryWord)
    }

    /// How a review's close changes the list Corrections shows (`ReviewSession.correctionsWriter`): corrections.json
    /// loaded, changed, and saved under its file lock, off the main actor (the review runs it inside the meeting's
    /// speaker lock). Nil while the list cannot be written (corrections.json unreadable).
    func reviewCorrectionsWriter() -> ReviewSession.CorrectionsUpdate? {
        guard correctionsWritable else { return nil }
        let url = CorrectionList.defaultURL
        return { change in _ = try CorrectionList.update(at: url) { try change(&$0) } }
    }

    /// A review's close wrote corrections.json: the list is taken again.
    func reviewCorrectionsWritten() {
        reloadCorrectionsIfChanged()
    }

    /// A manual Add; one that resolves a declined swap also keeps the edit that swap came from, as Learn
    /// does, unless a newer dictation or kept edit has replaced the text it was edited from.
    private func addCorrection(_ correction: Correction, resolving edit: DeclinedCorrectionQueue.PendingEdit?)
        -> Bool {
        guard changeCorrections({ $0.add(correction) }) else { return false }
        keep(edit)
        return true
    }

    /// An edited rule; like a manual Add, one that resolves a declined swap also keeps that swap's edit.
    private func replaceCorrection(_ old: Correction, with new: Correction,
                                   resolving edit: DeclinedCorrectionQueue.PendingEdit?) -> Bool {
        guard changeCorrections({ $0.replace(old, with: new) }) else { return false }
        keep(edit)
        return true
    }

    /// Keeps a declined swap's edited transcript when it was edited from the last dictation (by ID: an older one
    /// with the same text does not count), unless a kept edit has replaced the text it was edited from.
    private func keep(_ edit: DeclinedCorrectionQueue.PendingEdit?) {
        if let transcript = edit?.transcript(for: lastTranscriptID, whenLastRecognized: lastRecognized) {
            lastTranscript = transcript
            lastRecognized = transcript
        }
    }

    /// Returns false when the change was rejected or could not be saved.
    @discardableResult
    /// The change is made to the list as saved now, under its lock (`CorrectionList.update`), so corrections another
    /// process added since it was loaded (`voiceislocal eval apply`) are kept, never saved over.
    private func changeCorrections(_ change: (inout CorrectionList) -> Void) -> Bool {
        guard correctionsWritable else {
            show("Could not read corrections.json; fix or remove it, then relaunch Voice is Local.")
            return false
        }
        do {
            adoptCorrections(try CorrectionList.update(at: CorrectionList.defaultURL) { change(&$0) }.list)
            return true
        } catch {
            show("Could not save corrections: \(error.localizedDescription)")
            return false
        }
    }

    private func adoptCorrections(_ list: CorrectionList) {
        corrections = list
        updateDictationVocabulary()
        (mainWindow?.existingController(for: .corrections) as? CorrectionsPane)?.update(corrections: corrections.entries)
    }

    /// corrections.json changed on disk (or its folder did): takes the saved list when it differs. An unreadable
    /// file changes nothing; one that became readable again makes corrections writable again.
    private func reloadCorrectionsIfChanged() {
        guard let list = try? CorrectionList.load(from: CorrectionList.defaultURL) else { return }
        guard list != corrections || !correctionsWritable else { return }
        correctionsWritable = true
        adoptCorrections(list)
    }

    /// The next dictation's contextual strings: the word list, then the words of learned corrections. A dictation
    /// already listening keeps the ones it started with.
    func updateDictationVocabulary() {
        controller.contextualStrings = dictationVocabulary(language: locale)
    }

    private func write(_ text: String, to destination: Destination) -> InsertionOutcome {
        switch destination {
        case .field(let field): TextInsertion.insert(text, into: field)
        case .keystrokes(let terminal): terminal.type(text)
        }
    }

    private func outcomeMessage(_ outcome: InsertionOutcome) -> String {
        switch outcome {
        case .inserted: "Inserted — hold \(shortcutTitle) for another dictation"
        case .typed: "Typed into \(typedAppName ?? "the app") — hold \(shortcutTitle) for another dictation"
        case .needsCopy(let reason): "Not inserted: \(reason) Use Copy Result."
        case .targetChanged(let reason): "Not inserted: \(reason) Return to the original field, then use Copy Result."
        case .unverified(let reason): "Insertion unverified: \(reason) Check the field before copying."
        }
    }

    func show(_ value: String) {
        message = value
        rebuildMenu()
    }

    /// A history write failure as the status message (`problem`), or, with nil once the history works again, the
    /// message it replaced, if the failure is still what the status shows.
    func showHistoryProblem(_ problem: String?) {
        if let problem {
            let replaced = historyProblemStatus.flatMap { message == $0.shown ? $0.replaced : nil } ?? message
            historyProblemStatus = (problem, replaced)
            show(problem)
        } else if let status = historyProblemStatus {
            historyProblemStatus = nil
            if message == status.shown { show(status.replaced) }
        }
    }

    private func scheduleOverlayHide() {
        overlayHideTask?.cancel()
        let shown = overlay.contentToken
        overlayHideTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                // Hide only the content this timer was scheduled for, never something shown since.
                if let self, self.overlay.contentToken == shown { self.overlay.hide() }
            } catch { }
        }
    }

    /// The kept result's ten minutes are up. During a later dictation only the kept result goes; that dictation
    /// still concludes on its own.
    private func expireResult() {
        guard isBusy else { return discardResult() }
        retention.discard()
        resultExpiryTask = nil
        rebuildMenu()
    }

    @objc private func cancelDictation() {
        target = nil
        insertionBlockReason = "Cancelled"
        endFixing(heard: latestCommitted)
        controller.cancel()
        overlay.hide()
    }

    @objc private func copyResult() {
        guard !retention.kept.text.isEmpty else { return }
        let copied = copyToClipboard(retention.kept.text)
        show(copied ? "Copied — paste where you choose" : "Clipboard write failed; result is still available")
    }

    @objc private func copyOriginal() {
        guard !retention.kept.original.isEmpty else { return }
        let copied = copyToClipboard(retention.kept.original)
        show(copied ? "Copied the text as heard, before any fixes" : "Clipboard write failed; the original is still available")
    }

    @objc private func discardResult() {
        guard !isBusy else { return }
        overlayHideTask?.cancel(); overlayHideTask = nil
        resultExpiryTask?.cancel(); resultExpiryTask = nil
        retention.discard()
        resultText = ""
        resultOriginal = ""
        controller.reset()
        overlay.hide()
        rebuildMenu()
    }

    private func requestMicrophone() {
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            self?.show(granted ? "Microphone access granted; enable dictation when ready" : "Microphone denied; review System Settings → Privacy & Security")
        }
    }

    /// "Setup…" everywhere: the main window on Settings.
    @objc func showSetup() {
        showMainWindow(.settings)
    }

    /// Settings came on screen: checks the speech model and speaker models, and polls the permissions every second
    /// while it stays (TCC has no change notification).
    func startSettingsRefresh() {
        if localeGroups.isEmpty { Task { await loadLanguages() } }
        refreshAssetState()
        refreshSpeakerModels()
        setupRefreshTask?.cancel()
        setupRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateSettings()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopSettingsRefresh() {
        setupRefreshTask?.cancel()
        setupRefreshTask = nil
    }

    /// Applies the new opacity and shows a sample preview for a moment so the user can see the effect,
    /// unless a dictation is in progress (its own preview already shows it).
    func changePreviewOpacity(_ value: Double) {
        previewOpacity = value
        overlay.setOpacity(previewOpacity)
        // A visible preview or result already shows the new opacity; never replace it with the sample.
        let sampleShowing = overlay.isVisible && sampleToken == overlay.contentToken
        guard !isBusy, showPreview, !overlay.isVisible || sampleShowing else { return }
        overlay.show(title: "Preview opacity \(Int((previewOpacity * 100).rounded())) %",
                     text: "This is how the dictation preview looks over your windows.", force: true)
        let sample = overlay.contentToken
        sampleToken = sample
        opacitySampleTask?.cancel()
        opacitySampleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            // Hide only if the panel still shows this sample, never a warning or result shown since.
            if self.overlay.contentToken == sample { self.overlay.hide() }
            if self.sampleToken == sample { self.sampleToken = nil }
        }
    }

    /// Refreshes the main window while it is visible: the sidebar's status card, and Settings when it shows.
    func updateSettings() {
        guard let mainWindow, mainWindow.isVisible else { return }
        mainWindow.updateStatus(mainStatus())
        guard mainWindow.current == .settings,
              let settings = mainWindow.existingController(for: .settings) as? SettingsPane else { return }
        let speakerLabels = speakerLabelsSetupState()
        let deep = deepTranscriptionSetupState()
        settings.update(SetupState(
            microphone: AudioCapture.microphonePermission, accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess(), inputMonitoringNeeded: inputMonitoringNeeded,
            systemAudio: CGPreflightScreenCaptureAccess(),
            recordSystemAudio: MeetingAppState.recordSystemAudio,
            screenCaptureDefault: MeetingAppState.screenCaptureDefault,
            assets: assetState, installingAssets: installingAssets,
            dictationEnabled: enabled, enabling: enabling, busy: isBusy, shortcutTitle: shortcutTitle,
            shortcut: shortcut, shortcutChangeable: canChangeShortcut,
            removeFillers: removeFillers, showPreview: showPreview, previewOpacity: previewOpacity,
            message: message,
            speakerModels: speakerLabels.status, speakerModelsDetail: speakerLabels.detail,
            speakerModelsBusy: speakerLabels.busy,
            deepTranscriptionModel: deep.model, deepTranscriptionDetail: deep.detail,
            deepTranscriptionEnabled: deep.enabled,
            meetingSummaries: MeetingSummaryAppState.enabled,
            meetingSummariesUnavailable: meetingSummaryUnavailableReason,
            aiFix: AIFixSetting.isOn, aiFixUnavailable: AIFixSetting.unavailableReason(language: locale),
            spokenCode: SpokenCodeSetting.isOn, spokenCodeBackticks: SpokenCodeSetting.backticks,
            locale: locale, localeGroups: localeGroups, localeChangeable: canChangeLanguage,
            fillerExamples: FillerWords.examples(language: locale),
            historyRetention: history.retention, historyCount: history.keptCount,
            historyUnreadable: history.unreadable, historyKeepsAudio: history.keepsAudio,
            historyAudioBytes: history.audioBytes,
            openWindowAtLaunch: openWindowAtLaunch, appearance: appearance, naturalVoices: naturalVoiceDownloads()))
    }

    /// The sidebar's dictation status, independent of meeting recording.
    private func mainStatus() -> MainStatus {
        if isBusy { return MainStatus(tone: .busy, title: "Dictating", message: message) }
        if enabling || installingAssets { return MainStatus(tone: .busy, title: "Starting…", message: message) }
        if enabled { return MainStatus(tone: .ready, title: "Dictation ready", message: message) }
        return MainStatus(tone: .off, title: "Dictation off", message: message)
    }

    func refreshAssetState() {
        let locale = locale
        Task { [weak self] in
            let state = (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: .speech)) ?? "unknown"
            // A check for a language changed since is dropped; the change started its own.
            guard let self, self.locale == locale else { return }
            self.assetState = state
            self.updateSettings()
        }
    }

    func performSetup(_ action: SetupAction) {
        switch action {
        case .microphone:
            if AudioCapture.microphonePermission == "notDetermined" { requestMicrophone() }
            else { openPrivacySettings("Privacy_Microphone") }
        // Allow… and System Settings… (`PermissionButtons`) each do one thing: asking adds Voice is Local to the
        // list (again after its entry was removed), and macOS shows its own prompt only while it still will.
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .accessibilitySettings:
            openPrivacySettings("Privacy_Accessibility")
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .inputMonitoringSettings:
            openPrivacySettings("Privacy_ListenEvent")
        case .assets: installAssets()
        case .dictation: toggleEnabled()
        case .toggleFillers:
            removeFillers.toggle()
            updateSettings()
        case .togglePreview:
            showPreview.toggle()
            // Anything that does not need the user goes away at once, during or after a dictation.
            if !showPreview && !overlay.showingAttention { overlay.hide() }
            updateSettings()
        case .toggleAIFix:
            AIFixSetting.isOn.toggle()  // takes effect from the next dictation
            updateSettings()
        case .toggleSpokenCode:
            SpokenCodeSetting.isOn.toggle()  // takes effect from the next dictation
            updateSettings()
        case .toggleSpokenCodeBackticks:
            SpokenCodeSetting.backticks.toggle()
            updateSettings()
        case .toggleOpenWindowAtLaunch:
            openWindowAtLaunch.toggle()  // takes effect from the next launch
            updateSettings()
        case .toggleRecordSystemAudio:
            MeetingAppState.recordSystemAudio.toggle()  // takes effect from the next meeting
            meeting.startPanel?.refresh()
            updateSettings()
        case .toggleMeetingScreenCapture:
            MeetingAppState.screenCaptureDefault.toggle()
            updateSettings()
        case .speakerModels: installSpeakerModels()
        case .deepTranscriptionModel:
            installDeepTranscriptionModel()
        case .naturalVoicesEnglish, .naturalVoicesFrench: toggleNaturalVoiceDownload(for: action)
        case .toggleDeepTranscription:
            toggleDeepTranscription()
        case .toggleMeetingSummaries:
            toggleMeetingSummaries()
        case .systemAudio:
            // Screen & System Audio Recording takes effect after Voice is Local is reopened.
            _ = CGRequestScreenCaptureAccess()
        case .systemAudioSettings:
            openPrivacySettings("Privacy_ScreenCapture")
        case .people:
            showMainWindow(.people)
        case .clearHistory:
            confirmClearHistory()
        case .toggleHistoryAudio:
            changeKeepsHistoryAudio(!history.keepsAudio)
        case .setupAssistant:
            showSetupAssistant(verify: false)
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    func installAssets() {
        guard !installingAssets, !isBusy, !enabled, !enabling else { return }
        installingAssets = true  // also keeps the language from changing until the install ends
        updateSettings()
        assetTask = Task { [weak self] in
            guard let self else { return }
            // Without a saved choice the language is the default one, known once the languages are loaded: installing
            // before then would install `DictationLanguage.standard` for a user whose language is another.
            await self.loadLanguages()
            guard !Task.isCancelled else {
                self.installingAssets = false
                return
            }
            let locale = self.locale
            let name = self.languageName
            self.show("Installing the speech model for \(name) — this may download Apple's model")
            do {
                try await AppleSpeechEngine.installAssets(locale: locale, backend: .speech)
                self.installingAssets = false
                self.assetState = "installed"
                self.show("Speech model for \(name) ready; enable dictation when ready")
                // The Setup Assistant finished while this downloaded (in this run or before a quit or its reopen).
                if self.enableWhenSpeechModelInstalled {
                    self.enableWhenSpeechModelInstalled = false
                    self.enableDictationFromSetup(deferred: true)
                }
            } catch {
                self.installingAssets = false
                // Cancelled by the quit (the assistant's reopen included): the saved intent stays for the next launch.
                if Task.isCancelled || error is CancellationError { return }
                self.enableWhenSpeechModelInstalled = false
                self.refreshAssetState()
                self.show("Asset setup failed: \(error.localizedDescription)")
            }
        }
    }

    private func suspendForSessionChange() {
        // Sleep/session suspension is cleared only by an explicit enable, never by a meeting ending.
        dictationSession.suspend()
        disable(persist: false)
        discardResult()
        show("Paused after sleep/session change — enable from the menu to resume")
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
