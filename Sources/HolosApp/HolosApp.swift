import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosDesktop
import HolosDictation
import HolosMeeting
import HolosSpeech
import os
import Security

@main
enum HolosAppMain {
    @MainActor static func main() {
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
    /// Meeting recording controls (HolosApp+Meeting.swift, docs/meeting-design.md §5.8).
    let meeting = MeetingAppState()
    private var enabled = false
    private var enabling = false
    private var installingAssets = false
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
    /// A forced stop (for example the maximum duration) reported while finalizing; kept for the result message.
    private var forcedStopMessage: String?

    private var removeFillers: Bool {
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
    /// False when an existing corrections file could not be read, so it is never overwritten.
    private var correctionsWritable = true
    private var correctionsWindow: CorrectionsWindow?
    /// The last complete transcript as Holos wrote it, for the Corrections window.
    private var lastTranscript = ""
    /// The same transcript before corrections, so edits are learned against what the recognizer heard.
    private var lastRecognized = ""
    /// The recognizer's latest committed text, kept so a failure can still offer what was not written.
    private var latestCommitted = ""
    private let log = Logger(subsystem: "ca.orlenko.holos.app", category: "insertion")
    /// This dictation's text for Copy Result; the menu offers it once the dictation concludes (`retainResult`).
    private var resultText = ""
    private var message = "Disabled — open Setup… to get started"
    private var setupWindow: SetupWindow?
    private var setupRefreshTask: Task<Void, Never>?
    private var assetState: String?
    private var shortcut: HotkeyChoice = .rightOption
    /// The dictation language, chosen in Setup or the menu. Meetings keep their own locale.
    private var locale: String {
        get { UserDefaults.standard.string(forKey: "dictationLocale") ?? DictationLanguage.standard }
        set { UserDefaults.standard.set(newValue, forKey: "dictationLocale") }
    }
    /// The languages Apple's speech transcriber supports (`DictationLanguage.groups`); empty until loaded.
    private var localeGroups: [[String]] = []
    private var languageName: String { DictationLanguage.name(of: locale) }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        controller.contextualStrings = corrections.vocabulary
        loadLanguages()
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
        // Before dictation starts: a meeting already recording (the app relaunched, or one started in a terminal)
        // keeps dictation paused.
        setUpMeetings()
        if UserDefaults.standard.bool(forKey: "dictationEnabled") {
            if !meeting.dictationPaused { enable() }
        } else {
            showSetup()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        meetingShouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        enableTask?.cancel(); assetTask?.cancel(); overlayHideTask?.cancel(); resultExpiryTask?.cancel()
        setupRefreshTask?.cancel()
        monitor?.stop(); controller?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        overlay.hide()
    }

    private var isBusy: Bool {
        guard let controller else { return false }
        if fixPipeline?.finishing == true { return true }
        return [.preparing, .listening, .finalizing].contains(controller.status.phase)
    }

    private var shortcutTitle: String { shortcut == .rightOption ? "Right Option" : "Control–Option–Space" }

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

    func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        addMeetingItems(to: menu)
        if meeting.dictationPaused {
            // A meeting is recording: this line replaces the dictation block (§4.12), except a result kept from
            // before the meeting, which stays reachable because nothing copies it to the clipboard on its own.
            addDictationPausedLine(to: menu)
            if !retention.kept.isEmpty { addResultItems(to: menu) }
        } else {
            let status = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
            let toggle = item("\(enabled ? "Disable" : "Enable") \(shortcutTitle) Dictation", #selector(toggleEnabled))
            toggle.state = enabled ? .on : .off
            toggle.isEnabled = !enabling && !installingAssets
            menu.addItem(toggle)
            let shortcuts = NSMenuItem(title: "Hold-to-talk shortcut", action: nil, keyEquivalent: "")
            let choices = NSMenu()
            choices.autoenablesItems = false
            for (choice, title) in [(HotkeyChoice.rightOption, "Right Option"), (.controlOptionSpace, "Control–Option–Space")] {
                let entry = item(title, #selector(changeShortcut(_:)))
                entry.representedObject = choice.rawValue
                entry.state = shortcut == choice ? .on : .off
                entry.isEnabled = !isBusy && !enabling
                choices.addItem(entry)
            }
            shortcuts.submenu = choices
            menu.addItem(shortcuts)
            if !localeGroups.isEmpty { menu.addItem(languageItem()) }
            let cancel = item("Cancel Dictation", #selector(cancelDictation))
            cancel.isEnabled = isBusy
            menu.addItem(cancel)
            addResultItems(to: menu)
            menu.addItem(item("Correct Last Dictation…", #selector(showCorrections)))
        }
        menu.addItem(.separator())
        addMeetingsItem(to: menu)
        addPeopleItem(to: menu)
        menu.addItem(item("Setup…", #selector(showSetup)))
        addAboutItem(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Quit Voice is Local", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.toolTip = meetingToolTip() ?? "Voice is Local — \(message)"
        updateStatusItemAppearance()
        updateSetupWindow()
    }

    /// "Language: French (Canada)", with a submenu of the supported languages grouped as in Setup.
    private func languageItem() -> NSMenuItem {
        let language = NSMenuItem(title: "Language: \(languageName)", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        for (index, group) in localeGroups.enumerated() {
            if index > 0 { choices.addItem(.separator()) }
            for identifier in group {
                let entry = item(DictationLanguage.name(of: identifier), #selector(changeLanguage(_:)))
                entry.representedObject = identifier
                entry.state = identifier == locale ? .on : .off
                entry.isEnabled = canChangeLanguage
                choices.addItem(entry)
            }
        }
        language.submenu = choices
        return language
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { enabled ? disable() : enable() }

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
        // A recording meeting keeps dictation paused; it resumes when capture stops (§4.12).
        guard !enabled, !enabling, !installingAssets, !meeting.dictationPaused else { return }
        guard !refuseIfReplaced() else { return }
        guard AudioCapture.microphonePermission == "authorized", AXIsProcessTrusted() else {
            show("Grant Microphone and Accessibility access in Voice is Local Setup, then enable dictation.")
            showSetup()
            return
        }
        enabling = true
        enableGeneration += 1
        let generation = enableGeneration
        show("Checking local speech assets…")
        enableTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await AppleSpeechEngine.assetStatus(locale: self.locale, backend: .speech)
                guard !Task.isCancelled, generation == self.enableGeneration else { return }
                self.assetState = state
                guard state == "installed" else {
                    self.enabling = false
                    self.show("Install the speech model for \(self.languageName) in Voice is Local Setup first.")
                    self.showSetup()
                    return
                }
                let monitor = GlobalHotkeyMonitor(shortcut: self.shortcut) { [weak self] action in self?.handle(action) }
                try monitor.start()
                self.monitor = monitor
                self.enabled = true
                self.enabling = false
                self.meeting.suspendedBySleep = false
                UserDefaults.standard.set(true, forKey: "dictationEnabled")
                if let app = NSWorkspace.shared.frontmostApplication { TextInsertion.enableAccessibility(for: app) }
                self.show("Ready — hold \(self.shortcutTitle); wait for Listening")
                self.overlay.hide()
            } catch {
                guard generation == self.enableGeneration else { return }
                self.enabling = false
                self.show(error.localizedDescription)
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

    @objc private func changeShortcut(_ sender: NSMenuItem) {
        guard !isBusy, !meeting.dictationPaused, let raw = sender.representedObject as? String, let choice = HotkeyChoice(rawValue: raw) else { return }
        let wasEnabled = enabled
        disable()
        shortcut = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "shortcut")
        if wasEnabled { enable() } else { show("Disabled — shortcut: \(shortcutTitle)") }
    }

    /// Not while a dictation, install, or enable is in progress: a change applies from the next dictation.
    private var canChangeLanguage: Bool { !isBusy && !enabling && !installingAssets }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        changeLanguage(to: identifier)
    }

    private func changeLanguage(to identifier: String) {
        guard identifier != locale, canChangeLanguage else {
            updateSetupWindow()  // puts a refused choice back in Setup
            return
        }
        locale = identifier
        controller.locale = identifier
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

    /// Loads the languages Apple's speech transcriber supports, for Setup and the menu.
    private func loadLanguages() {
        Task { [weak self] in
            let supported = await AppleSpeechEngine.capabilities(backend: .speech).supportedLocales
            guard let self, !supported.isEmpty else { return }
            self.localeGroups = DictationLanguage.groups(supported)
            self.rebuildMenu()
        }
    }

    private func handle(_ action: HotkeyAction) {
        guard enabled else { return }
        switch action {
        case .began:
            guard !meeting.dictationPaused, !isBusy, !refuseIfReplaced(), !TextInsertion.isSecureInputActive() else {
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
            if controller.begin() {
                // A pending opacity sample must not hide this dictation's own preview or result.
                // A rejected begin leaves the timer running so the sample still hides on time.
                opacitySampleTask?.cancel()
                opacitySampleTask = nil
                sampleToken = nil
                fixPipeline?.cancel()
                fixPipeline = DictationFixPipeline.make(corrections: corrections, language: locale) { [weak self] chunk, text in
                    self?.writeFixed(chunk, as: text) ?? false
                }
            } else {
                target = nil
                _ = retention.conclude(DictationResult())  // nothing started, so the previous result stays
                show("Previous dictation is still stopping; release and try again shortly.")
            }
        case .ended: controller.end()
        case .cancelled: cancelDictation()
        }
    }

    private func receive(_ update: DictationStatus) {
        monitor?.setSessionActive([.preparing, .listening, .finalizing].contains(update.phase))
        switch update.phase {
        case .idle:
            target = nil
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
            let text = corrections.apply(to: recognized)
            if !text.isEmpty {
                lastTranscript = text
                lastRecognized = recognized
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
            presentResult()
        case .failed:
            // Keep committed words that were withheld or not yet written, so Copy Result still has them. A chunk
            // whose fixed write failed is offered as fixed, the text Holos tried to write.
            let committed = cleaned(latestCommitted).trimmingCharacters(in: .whitespacesAndNewlines)
            let unwritten = TextInsertion.unwritten(committed, after: insertedText)
            let attempted = unwritten.map {
                AIFixUnwritten.attempted($0, fixedRest: nil, failedWrite: fixPipeline?.failedWrite)
            }
            endFixing(heard: latestCommitted, offered: attempted ?? "", recognized: unwritten ?? "")
            target = nil
            message = update.message ?? "Dictation failed; no text was inserted."
            if !insertedText.isEmpty { message += " Text inserted before the failure stays in the field." }
            if !resultOriginal.isEmpty { message += " Copy Original has what was heard, before Apple Intelligence's fix." }
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
                retainResult()
                overlay.show(title: message, text: resultText, attention: true)
                scheduleOverlayHide()
                rebuildMenu()
                return
            }
            if unwritten == nil, !committed.isEmpty {
                // The transcript no longer extends what was inserted, so no tail is safe to paste.
                resultText = committed
                message += " The transcript changed after text was inserted; check the field. Copy Result has the full transcript."
                retainResult()
                overlay.show(title: message, text: resultText, attention: true)
                scheduleOverlayHide()
                rebuildMenu()
                return
            }
            resultText = update.text
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
        // Only this last part may gain closing punctuation. When the recognizer committed everything before release,
        // nothing is added at the end.
        let writable = enabled && insertionBlockReason == nil && target != nil
        if writable, let rest = TextInsertion.unwritten(text, after: insertedText),
           !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fixedRest = await pipeline.fix(rest, isFinal: true).text
            guard fixPipeline === pipeline else { return }
        }
        let destination = target
        target = nil // No callback or retry can write to this target again.
        // The fix of the part not yet written: written in its place, or, when that write fails or a streamed chunk's
        // write failed, what Copy Result offers, since Holos tried to write it and it may already be in the field.
        let unwritten = TextInsertion.unwritten(text, after: insertedText)
        let attempted = unwritten.map {
            AIFixUnwritten.attempted($0, fixedRest: fixedRest, failedWrite: pipeline.failedWrite)
        }
        endFixing(heard: heard, offered: attempted ?? "", recognized: unwritten ?? "")
        let written = finish(text, into: destination, writing: attempted == unwritten ? nil : attempted)
        if !resultOriginal.isEmpty {
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
                message += " Apple Intelligence fixed misheard words; Copy Original has what was heard."
            } else if attempted != unwritten {
                // Copy Result has the fixed words Holos tried to write (set by `finish`).
                message += " Copy Result has Apple Intelligence's fix; Copy Original has what was heard."
            } else {
                // Only chunks already in the field were fixed; Copy Result has the rest as recognized.
                message += " Text already written was fixed by Apple Intelligence; Copy Original has what was heard."
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

    /// Filler removal, then learned corrections: the text Holos shows and writes.
    private func cleaned(_ text: String) -> String {
        corrections.apply(to: withoutFillers(text))
    }

    /// Like `cleaned`, but holds back a trailing comma or phrase start that later words may still change.
    private func cleanedForStreaming(_ text: String) -> String {
        corrections.applyWithholdingPartialMatch(
            to: removeFillers ? FillerWords.removeWithholdingTrailingComma(from: text, language: locale) : text)
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
            return false
        }
        let remainder = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            message = outcomeMessage(typedAppName == nil ? .inserted : .typed)
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

    @objc private func showCorrections() {
        if correctionsWindow == nil {
            correctionsWindow = CorrectionsWindow(
                onLearn: { [weak self] edited in self?.learnCorrections(from: edited) },
                onAdd: { [weak self] correction, edit in
                    self?.addCorrection(correction, resolving: edit) ?? false
                },
                onRemove: { [weak self] correction in self?.changeCorrections { $0.remove(correction) } ?? false },
                onReplace: { [weak self] old, new, edit in
                    self?.replaceCorrection(old, with: new, resolving: edit) ?? false
                })
        }
        correctionsWindow?.show(lastTranscript: lastTranscript, corrections: corrections.entries)
    }

    private func learnCorrections(from edited: String) -> CorrectionsWindow.LearnResult? {
        // Diff against the recognizer's words, so fixing text an existing rule produced replaces that rule.
        // A word counts as "common" only if its lowercase form is in the dictionary: the spell checker also
        // accepts capitalized names ("Gwen"), which should be learned on their own.
        let result = CorrectionList.learnReportingDeclined(original: lastRecognized, corrected: edited) { word in
            NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0).location == NSNotFound
        }
        let learned = result.learned.filter { corrections.apply(to: $0.heard) != $0.meant }
        let declined = result.declined.filter { corrections.apply(to: $0.heard) != $0.meant }
        guard !learned.isEmpty else {
            // Nothing is saved yet; each declined swap carries the edit, kept once the user adds that swap.
            return CorrectionsWindow.LearnResult(
                learned: [], declined: declined,
                edit: .init(recognized: lastRecognized, edited: edited))
        }
        guard changeCorrections({ list in for correction in learned { list.add(correction) } }) else { return nil }
        lastTranscript = edited
        lastRecognized = edited
        return CorrectionsWindow.LearnResult(learned: learned, declined: declined, edit: nil)
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

    /// Keeps a declined swap's edited transcript, unless a newer dictation or kept edit has replaced the text it
    /// was edited from.
    private func keep(_ edit: DeclinedCorrectionQueue.PendingEdit?) {
        if let transcript = edit?.transcript(whenLastRecognized: lastRecognized) {
            lastTranscript = transcript
            lastRecognized = transcript
        }
    }

    /// Returns false when the change was rejected or could not be saved.
    @discardableResult
    private func changeCorrections(_ change: (inout CorrectionList) -> Void) -> Bool {
        guard correctionsWritable else {
            show("Could not read corrections.json; fix or remove it, then relaunch Voice is Local.")
            return false
        }
        change(&corrections)
        controller.contextualStrings = corrections.vocabulary
        correctionsWindow?.update(corrections: corrections.entries)
        do {
            try corrections.save(to: CorrectionList.defaultURL)
            return true
        } catch {
            show("Could not save corrections: \(error.localizedDescription)")
            return false
        }
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

    @objc private func showSetup() {
        if setupWindow == nil {
            setupWindow = SetupWindow(perform: { [weak self] action in self?.performSetup(action) },
                                      onClose: { [weak self] in
                                          self?.setupRefreshTask?.cancel(); self?.setupRefreshTask = nil
                                          self?.setDockPresence(false, for: "setup")
                                      },
                                      onOpacityChange: { [weak self] value in self?.changePreviewOpacity(value) },
                                      onLanguageChange: { [weak self] identifier in self?.changeLanguage(to: identifier) })
        }
        setDockPresence(true, for: "setup")
        setupWindow?.show()
        if localeGroups.isEmpty { loadLanguages() }
        refreshAssetState()
        refreshSpeakerModels()
        // TCC has no change notification, so poll while the window is open.
        setupRefreshTask?.cancel()
        setupRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateSetupWindow()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Applies the new opacity and shows a sample preview for a moment so the user can see the effect,
    /// unless a dictation is in progress (its own preview already shows it).
    private func changePreviewOpacity(_ value: Double) {
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

    func updateSetupWindow() {
        guard let setupWindow, setupWindow.isVisible else { return }
        let speakerLabels = speakerLabelsSetupState()
        setupWindow.update(SetupState(
            microphone: AudioCapture.microphonePermission, accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess(), systemAudio: CGPreflightScreenCaptureAccess(),
            assets: assetState, installingAssets: installingAssets,
            dictationEnabled: enabled, enabling: enabling, busy: isBusy, shortcutTitle: shortcutTitle,
            removeFillers: removeFillers, showPreview: showPreview, previewOpacity: previewOpacity,
            // While a meeting records, its pause takes precedence over every other dictation message (§4.12).
            message: meeting.dictationPaused ? "Dictation paused during meeting recording" : message,
            dictationPausedForMeeting: meeting.dictationPaused,
            speakerModels: speakerLabels.status, speakerModelsDetail: speakerLabels.detail,
            speakerModelsBusy: speakerLabels.busy,
            aiFix: AIFixSetting.isOn, aiFixUnavailable: AIFixSetting.unavailableReason(language: locale),
            locale: locale, localeGroups: localeGroups, localeChangeable: canChangeLanguage,
            fillerExamples: FillerWords.examples(language: locale)))
    }

    private func refreshAssetState() {
        let locale = locale
        Task { [weak self] in
            let state = (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: .speech)) ?? "unknown"
            // A check for a language changed since is dropped; the change started its own.
            guard let self, self.locale == locale else { return }
            self.assetState = state
            self.updateSetupWindow()
        }
    }

    private func performSetup(_ action: SetupAction) {
        switch action {
        case .microphone:
            if AudioCapture.microphonePermission == "notDetermined" { requestMicrophone() }
            else { openPrivacySettings("Privacy_Microphone") }
        case .accessibility:
            if !AXIsProcessTrusted() {
                // Asking adds Holos to the Accessibility list; macOS shows its own prompt only once.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            openPrivacySettings("Privacy_Accessibility")
        case .inputMonitoring:
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            openPrivacySettings("Privacy_ListenEvent")
        case .assets: installAssets()
        case .dictation: toggleEnabled()
        case .toggleFillers:
            removeFillers.toggle()
            updateSetupWindow()
        case .togglePreview:
            showPreview.toggle()
            // Anything that does not need the user goes away at once, during or after a dictation.
            if !showPreview && !overlay.showingAttention { overlay.hide() }
            updateSetupWindow()
        case .toggleAIFix:
            AIFixSetting.isOn.toggle()  // takes effect from the next dictation
            updateSetupWindow()
        case .speakerModels:
            installSpeakerModels()
        case .systemAudio:
            // Asking adds Holos to the Screen & System Audio Recording list; macOS shows its own prompt only once,
            // and the permission takes effect after Holos is reopened.
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            openPrivacySettings("Privacy_ScreenCapture")
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func installAssets() {
        guard !installingAssets, !isBusy, !enabled, !enabling else { return }
        installingAssets = true  // also keeps the language from changing until the install ends
        let locale = locale
        let name = languageName
        show("Installing the speech model for \(name) — this may download Apple's model")
        assetTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await AppleSpeechEngine.installAssets(locale: locale, backend: .speech)
                self.installingAssets = false
                self.assetState = "installed"
                self.show("Speech model for \(name) ready; enable dictation when ready")
            } catch {
                self.installingAssets = false
                self.refreshAssetState()
                self.show("Asset setup failed: \(error.localizedDescription)")
            }
        }
    }

    private func suspendForSessionChange() {
        // Remembered so the end of a meeting does not turn dictation back on after a sleep (§4.12).
        meeting.suspendedBySleep = true
        disable(persist: false)
        discardResult()
        show("Paused after sleep/session change — enable from the menu to resume")
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
