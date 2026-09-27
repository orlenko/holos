import AppKit
@preconcurrency import ApplicationServices
import Foundation
import HolosAudio
import HolosCore
import HolosDesktop
import HolosMeeting
import os

/// The first-launch Setup Assistant (docs/design.md "First-launch setup"). The decisions are `SetupAssistantFlow`'s;
/// this runs them: it reads the permissions, starts the downloads, turns dictation on, and reopens the app.
extension HolosAppDelegate {
    /// UserDefaults key: macOS refused the hotkey tap with Accessibility granted, so Setup and the assistant offer
    /// Input Monitoring. Cleared once the tap starts.
    static let inputMonitoringNeededKey = "hotkeyNeedsInputMonitoring"
    private static let assistantLog = Logger(subsystem: "ca.orlenko.holos.app", category: "setup")

    var inputMonitoringNeeded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.inputMonitoringNeededKey) }
        set {
            guard newValue != inputMonitoringNeeded else { return }
            UserDefaults.standard.set(newValue, forKey: Self.inputMonitoringNeededKey)
        }
    }

    /// What this launch shows. An install set up before the assistant existed is marked done here, silently.
    func setupAssistantLaunch(dictationEnabled: Bool) -> SetupAssistantLaunch {
        let defaults = UserDefaults.standard
        let decision = SetupAssistantFlow.launch(
            done: defaults.object(forKey: SetupAssistantFlow.doneKey) as? Bool,
            awaitingReopenCheck: defaults.bool(forKey: SetupAssistantFlow.awaitingReopenCheckKey),
            dictationEnabled: dictationEnabled,
            microphoneGranted: AudioCapture.microphonePermission == "authorized",
            accessibility: AXIsProcessTrusted())
        if decision == .markDone { defaults.set(true, forKey: SetupAssistantFlow.doneKey) }
        return decision
    }

    @objc func showSetupAssistantFromMenu() { showSetupAssistant(verify: false) }

    /// Opens the assistant where it was left in this run, or at Welcome; `verify` shows the check after reopening
    /// instead, once (its flag is cleared as it opens).
    func showSetupAssistant(verify: Bool) {
        let defaults = UserDefaults.standard
        if verify {
            defaults.removeObject(forKey: SetupAssistantFlow.awaitingReopenCheckKey)
        } else {
            if assistantCompleted || assistantVerifying {
                assistantFlow = SetupAssistantFlow()
                assistantCompleted = false
            }
            // Started: until it finishes or is skipped, the next launch shows it again.
            if defaults.object(forKey: SetupAssistantFlow.doneKey) == nil {
                defaults.set(false, forKey: SetupAssistantFlow.doneKey)
            }
        }
        assistantVerifying = verify
        if assistantWindow == nil {
            assistantWindow = SetupAssistantWindow(
                perform: { [weak self] action in self?.performSetupAssistant(action) },
                onClose: { [weak self] in
                    self?.assistantRefreshTask?.cancel(); self?.assistantRefreshTask = nil
                    self?.setDockPresence(false, for: "assistant")
                },
                onLanguageChange: { [weak self] identifier in self?.changeLanguage(to: identifier) })
        }
        assistantProbedTap = false
        updateSetupAssistant(force: true)
        setDockPresence(true, for: "assistant")
        assistantWindow?.show()
        if localeGroups.isEmpty { Task { await loadLanguages() } }
        refreshAssetState()
        refreshSpeakerModels()
        // TCC has no change notification, so poll while the window is open; Accessibility turns green on its own.
        assistantRefreshTask?.cancel()
        assistantRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateSetupAssistant()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Setup's normal opening, except while the assistant is open: it already shows what is missing.
    func showSetupUnlessAssistant() {
        if assistantWindow?.isVisible == true { return updateSetupAssistant() }
        showSetup()
    }

    func updateSetupAssistant(force: Bool = false) {
        guard let assistantWindow, force || assistantWindow.isVisible else { return }
        let speakerLabels = speakerLabelsSetupState()
        assistantWindow.update(SetupAssistantViewState(
            flow: assistantFlow, facts: setupAssistantFacts(), verify: assistantVerifying,
            locale: locale, language: languageName, localeGroups: localeGroups, localeChangeable: canChangeLanguage,
            shortcutTitle: shortcutTitle,
            speakerModelsDetail: speakerLabels.status == "installing" || speakerLabels.status == "notInstalled"
                || speakerLabels.status == "damaged" ? speakerLabels.detail : nil))
    }

    private func setupAssistantFacts() -> SetupAssistantFacts {
        let accessibility = AXIsProcessTrusted()
        if accessibility, !assistantProbedTap, !enabled {
            // Once Accessibility is on, learn whether macOS also wants Input Monitoring for the hotkey, so the
            // Reopen page can group it with the other permissions that need a reopen.
            assistantProbedTap = true
            switch GlobalHotkeyMonitor.probe() {
            case nil: inputMonitoringNeeded = false
            case .tapRefused?: inputMonitoringNeeded = true
            case .accessibilityNotGranted?, .runLoopUnavailable?: assistantProbedTap = false
            }
        }
        return SetupAssistantFacts(
            microphone: AudioCapture.microphonePermission, accessibility: accessibility,
            languageKnown: resolvedLocale != nil, speechModel: assetState, installingSpeechModel: installingAssets,
            speakerModels: speakerLabelsSetupState().status, systemAudio: CGPreflightScreenCaptureAccess(),
            inputMonitoringNeeded: inputMonitoringNeeded, inputMonitoring: CGPreflightListenEventAccess(),
            dictationEnabled: enabled)
    }

    private func performSetupAssistant(_ action: SetupAssistantAction) {
        let facts = setupAssistantFacts()
        switch action {
        case .start:
            assistantFlow.start()
        case .skip:
            markSetupAssistantDone()
            assistantCompleted = true
            assistantWindow?.close()
            showSetup()
            return
        case .next, .continueWithout:
            for effect in assistantFlow.next(facts, without: action == .continueWithout) {
                switch effect {
                case .installSpeechModel: installAssets()
                case .installSpeakerModels: installSpeakerModels()
                }
            }
        case .back:
            assistantFlow.back(facts)
        case .microphone:
            performSetup(.microphone)
        case .accessibility:
            performSetup(.accessibility)
        case .systemAudio:
            assistantFlow.requestedSystemAudioSettings()
            performSetup(.systemAudio)
        case .inputMonitoring:
            assistantFlow.requestedInputMonitoringSettings()
            performSetup(.inputMonitoring)
        case .toggleMeetings:
            assistantFlow.setUpMeetings.toggle()
        case .finish:
            finishSetupAssistant(facts, reopen: assistantFlow.reopenNeeded)
            return
        case .openSetup:
            finishSetupAssistant(facts, reopen: false)
            showSetup()
            return
        case .done:
            finishSetupAssistant(facts, reopen: false)
            return
        }
        updateSetupAssistant()
    }

    /// Done, Reopen Voice is Local, or the check's buttons: dictation turns on once Microphone, Accessibility and the
    /// speech model allow it (after the download when it is still running), and the assistant is marked done.
    private func finishSetupAssistant(_ facts: SetupAssistantFacts, reopen: Bool) {
        markSetupAssistantDone()
        assistantCompleted = true
        switch SetupAssistantFlow.enable(facts) {
        case .now:
            if reopen {
                // Enabling is asynchronous and the app is about to quit: the reopened app enables it at launch.
                UserDefaults.standard.set(true, forKey: "dictationEnabled")
            } else {
                enable()
            }
        case .afterSpeechModelInstall:
            enableWhenSpeechModelInstalled = true
            if !installingAssets { installAssets() }
        case .alreadyOn, .notPossible:
            break
        }
        assistantWindow?.close()
        if reopen {
            reopenAfterQuit = true
            // The normal quit: a recording meeting still asks first, and Cancel keeps the app (and does not reopen).
            NSApplication.shared.terminate(nil)
        }
    }

    private func markSetupAssistantDone() {
        UserDefaults.standard.set(true, forKey: SetupAssistantFlow.doneKey)
    }

    /// From `applicationWillTerminate`, so only a quit that goes ahead reopens: a detached shell waits for this
    /// process to exit, then opens the bundle again, and the next launch shows the check.
    func reopenOnceExited() {
        reopenAfterQuit = false
        let command = SetupAssistantFlow.reopenCommand(waitingFor: ProcessInfo.processInfo.processIdentifier,
                                                       bundlePath: Bundle.main.bundlePath)
        do {
            try ProcessSpawner.spawnDetached(executable: URL(fileURLWithPath: command.executable),
                                             arguments: command.arguments)
            UserDefaults.standard.set(true, forKey: SetupAssistantFlow.awaitingReopenCheckKey)
        } catch {
            Self.assistantLog.error("Cannot reopen Voice is Local: \(error.localizedDescription, privacy: .public)")
        }
    }
}
