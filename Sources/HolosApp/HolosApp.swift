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
            fputs("Launch the Holos.app bundle built by scripts/build-app.sh.\n", stderr)
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
    private var expiryTask: Task<Void, Never>?
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
    /// The app or field changed during the utterance; ⌘V now would paste somewhere else.
    private var targetMoved = false
    /// Where the user was at key-down, to check before telling them to paste.
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
    /// needs the user (text left on the clipboard, failures) is still shown.
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
    private var resultText = ""
    private var message = "Disabled — open Setup… to get started"
    private var setupWindow: SetupWindow?
    private var setupRefreshTask: Task<Void, Never>?
    private var assetState: String?
    private var shortcut: HotkeyChoice = .rightOption
    private let locale = "en-CA"

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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Holos")
        statusItem.button?.toolTip = "Holos — local push-to-talk"
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
        enableTask?.cancel(); assetTask?.cancel(); expiryTask?.cancel(); setupRefreshTask?.cancel()
        monitor?.stop(); controller?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        overlay.hide()
    }

    private var isBusy: Bool {
        guard let controller else { return false }
        return [.preparing, .listening, .finalizing].contains(controller.status.phase)
    }

    private var shortcutTitle: String { shortcut == .rightOption ? "Right Option" : "Control–Option–Space" }

    func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        addMeetingItems(to: menu)
        if meeting.dictationPaused {
            // A meeting is recording: this line replaces the whole dictation block (§4.12).
            addDictationPausedLine(to: menu)
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
            let cancel = item("Cancel Dictation", #selector(cancelDictation))
            cancel.isEnabled = isBusy
            menu.addItem(cancel)
            let copy = item("Copy Result", #selector(copyResult))
            copy.isEnabled = !resultText.isEmpty
            menu.addItem(copy)
            let discard = item("Discard Result", #selector(discardResult))
            discard.isEnabled = !resultText.isEmpty && !isBusy
            menu.addItem(discard)
            menu.addItem(item("Correct Last Dictation…", #selector(showCorrections)))
        }
        menu.addItem(.separator())
        addMeetingsItem(to: menu)
        menu.addItem(item("Setup…", #selector(showSetup)))
        addAboutItem(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Quit Holos", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.toolTip = meetingToolTip() ?? "Holos — \(message)"
        updateStatusItemAppearance()
        updateSetupWindow()
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
        show("Holos was rebuilt while running. Quit and reopen Holos to dictate again.")
        overlay.show(title: "Holos was rebuilt while running", text: "Quit and reopen Holos to dictate again.",
                     force: true, attention: true)
        scheduleExpiry()
        return true
    }

    func enable() {
        // A recording meeting keeps dictation paused; it resumes when capture stops (§4.12).
        guard !enabled, !enabling, !installingAssets, !meeting.dictationPaused else { return }
        guard !refuseIfReplaced() else { return }
        guard AudioCapture.microphonePermission == "authorized", AXIsProcessTrusted() else {
            show("Grant Microphone and Accessibility access in Holos Setup, then enable dictation.")
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
                    self.show("Install English Speech Assets in Holos Setup first.")
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
            if let terminal = KeystrokeTarget.captureTerminal() {
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
            expiryTask?.cancel()
            resultText = ""
            if controller.begin() {
                // A pending opacity sample must not hide this dictation's own preview or result.
                // A rejected begin leaves the timer running so the sample still hides on time.
                opacitySampleTask?.cancel()
                opacitySampleTask = nil
                sampleToken = nil
            } else {
                target = nil
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
            let destination = target
            target = nil // No callback or retry can write to this target again.
            let recognized = withoutFillers(update.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = corrections.apply(to: recognized)
            if !text.isEmpty {
                lastTranscript = text
                lastRecognized = recognized
            }
            finish(text, into: destination)
            if let forced = forcedStopMessage, !message.hasPrefix(forced) { message = forced + " " + message }
            if showPreview || resultNeedsAttention {
                overlay.show(title: message, text: resultText, attention: resultNeedsAttention)
            }
            scheduleExpiry()
        case .failed:
            target = nil
            message = update.message ?? "Dictation failed; no text was inserted."
            if !insertedText.isEmpty { message += " Text inserted before the failure stays in the field." }
            // Keep committed words that were withheld or not yet written, so Copy Result still has them.
            let committed = cleaned(latestCommitted).trimmingCharacters(in: .whitespacesAndNewlines)
            if let rest = TextInsertion.unwritten(committed, after: insertedText),
               !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Keep the leading space so pasting after the inserted prefix does not join words.
                resultText = insertedText.isEmpty ? rest.trimmingCharacters(in: .whitespaces) : rest
                let copied = copyToClipboard(resultText)
                if streamUnverified {
                    // An unconfirmed write may already have landed; pasting blindly could duplicate it.
                    message += copied
                        ? " Some text may already be in the field — check it before pasting the clipboard."
                        : " Some text may already be in the field — check it before using Copy Result."
                } else if focusMovedSinceKeyDown() {
                    message += copied
                        ? " The words that were not inserted are on the clipboard — go back to the original field before pressing ⌘V."
                        : " Copy Result has the words that were not inserted; return to the original field first."
                } else {
                    message += copied
                        ? " The words that were not inserted are on the clipboard — press ⌘V."
                        : " Copy Result has the words that were not inserted."
                }
                overlay.show(title: message, text: resultText, attention: true)
                scheduleExpiry()
                rebuildMenu()
                return
            }
            if TextInsertion.unwritten(committed, after: insertedText) == nil, !committed.isEmpty {
                // The transcript no longer extends what was inserted, so no tail is safe to paste.
                resultText = committed
                message += " The transcript changed after text was inserted; check the field. Copy Result has the full transcript."
                overlay.show(title: message, text: resultText, attention: true)
                scheduleExpiry()
                rebuildMenu()
                return
            }
            resultText = update.text
            overlay.show(title: message, text: resultText, attention: true)
            scheduleExpiry()
        }
        rebuildMenu()
    }

    /// Writes newly finalized words while the user is still speaking. Any refusal stops streaming for
    /// the rest of the utterance, and the unwritten remainder is offered through Copy Result.
    private func stream(_ committed: String) {
        guard enabled, insertionBlockReason == nil, let destination = target else { return }
        guard let chunk = TextInsertion.unwritten(committed, after: insertedText) else {
            target = nil
            insertionBlockReason = "The recognizer revised text that was already inserted; check the field."
            log.notice("Stream stopped: committed text no longer extends the inserted prefix")
            return
        }
        guard !chunk.isEmpty else { return }
        let outcome = write(chunk, to: destination)
        log.notice("Stream chunk of \(chunk.utf16.count) units: \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .inserted:
            insertedText = committed
            if case .field(let field) = destination {
                if let next = TextInsertion.advance(field, past: chunk) { target = .field(next) }
                else {
                    target = nil
                    insertionBlockReason = "The field changed after the last insertion."
                    targetMoved = true
                    log.notice("Stream stopped: field did not match the expected state after insertion")
                }
            }
        case .typed:
            insertedText = committed
        case .needsCopy(let reason), .unverified(let reason), .targetChanged(let reason):
            if case .unverified = outcome { streamUnverified = true }
            if case .targetChanged = outcome { targetMoved = true }
            target = nil
            insertionBlockReason = reason
        }
    }

    /// Writes whatever the final transcript adds beyond the streamed prefix, in a single attempt.
    private func withoutFillers(_ text: String) -> String {
        removeFillers ? FillerWords.remove(from: text) : text
    }

    /// Filler removal, then learned corrections: the text Holos shows and writes.
    private func cleaned(_ text: String) -> String {
        corrections.apply(to: withoutFillers(text))
    }

    /// Like `cleaned`, but holds back a trailing comma or phrase start that later words may still change.
    private func cleanedForStreaming(_ text: String) -> String {
        corrections.applyWithholdingPartialMatch(
            to: removeFillers ? FillerWords.removeWithholdingTrailingComma(from: text) : text)
    }

    private func finish(_ text: String, into destination: Destination?) {
        resultText = text
        guard !insertedText.isEmpty else {
            guard !text.isEmpty else {
                message = "No speech recognized"
                resultNeedsAttention = true  // shown even with the preview off, so it is not mistaken for success
                return
            }
            let outcome: InsertionOutcome = if enabled, insertionBlockReason == nil, let destination {
                write(text, to: destination)
            } else {
                blockedOutcome(default: "No writable target.")
            }
            log.notice("Nothing streamed; whole result of \(text.utf16.count) units: \(String(describing: outcome), privacy: .public)")
            conclude(outcome, unwritten: text, partial: false)
            return
        }
        guard let rest = TextInsertion.unwritten(text, after: insertedText) else {
            message = "Text was inserted while you spoke, but the final transcript differs. Check the field; Copy Result copies the full transcript."
            resultNeedsAttention = true
            return
        }
        let remainder = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            message = outcomeMessage(typedAppName == nil ? .inserted : .typed)
            return
        }
        let outcome: InsertionOutcome = if enabled, insertionBlockReason == nil, let destination {
            write(rest, to: destination)
        } else {
            blockedOutcome(default: "Insertion stopped.")
        }
        log.notice("Final chunk of \(rest.utf16.count) units: \(String(describing: outcome), privacy: .public)")
        // Keep the leading space so pasting after the inserted prefix does not join words.
        conclude(outcome, unwritten: rest.trimmingCharacters(in: .newlines), partial: true)
    }

    private func blockedOutcome(default reason: String) -> InsertionOutcome {
        let reason = insertionBlockReason ?? reason
        if streamUnverified { return .unverified(reason) }
        return targetMoved ? .targetChanged(reason) : .needsCopy(reason)
    }

    /// Text that could not be written goes to the clipboard right away, so it is one ⌘V from the field.
    private func conclude(_ outcome: InsertionOutcome, unwritten: String, partial: Bool) {
        switch outcome {
        case .inserted, .typed:
            message = outcomeMessage(outcome)
        case .needsCopy(let reason), .unverified(let reason), .targetChanged(let reason):
            log.notice("Not written: \(reason, privacy: .public)")
            resultNeedsAttention = true
            resultText = unwritten
            let copied = copyToClipboard(unwritten)
            let moved: Bool = if case .targetChanged = outcome { true } else { focusMovedSinceKeyDown() }
            if moved {
                let head = partial ? "Inserted the first part; then the app or field changed."
                                   : "The app or field changed before Holos could write."
                message = copied ? "\(head) Copied to the clipboard — go back to the original field before pressing ⌘V."
                                 : "\(head) Use Copy Result after returning to the original field."
                return
            }
            let head: String = if case .unverified = outcome {
                "Insertion unverified — check the field before pasting."
            } else if partial {
                "Inserted the first part; couldn't write the rest."
            } else {
                "Couldn't write into this field."
            }
            message = copied ? "\(head) Copied to the clipboard — press ⌘V." : "\(head) Use Copy Result."
        }
    }

    /// Checked at the moment Holos suggests ⌘V, so a focus change inside the same app counts too.
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
            show("Could not read corrections.json; fix or remove it, then relaunch Holos.")
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

    private func scheduleExpiry() {
        expiryTask?.cancel()
        let shown = overlay.contentToken
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                // Hide only the content this timer was scheduled for, never something shown since.
                if let self, self.overlay.contentToken == shown { self.overlay.hide() }
                try await Task.sleep(for: .seconds(592))
                self?.discardResult()
            } catch { }
        }
    }

    @objc private func cancelDictation() {
        target = nil
        insertionBlockReason = "Cancelled"
        controller.cancel()
        overlay.hide()
    }

    @objc private func copyResult() {
        guard !resultText.isEmpty else { return }
        let copied = copyToClipboard(resultText)
        show(copied ? "Copied — paste where you choose" : "Clipboard write failed; result is still available")
    }

    @objc private func discardResult() {
        guard !isBusy else { return }
        expiryTask?.cancel(); expiryTask = nil
        resultText = ""
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
                                      onOpacityChange: { [weak self] value in self?.changePreviewOpacity(value) })
        }
        setDockPresence(true, for: "setup")
        setupWindow?.show()
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
            speakerModelsBusy: speakerLabels.busy))
    }

    private func refreshAssetState() {
        Task { [weak self] in
            guard let self else { return }
            self.assetState = (try? await AppleSpeechEngine.assetStatus(locale: self.locale, backend: .speech)) ?? "unknown"
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
        installingAssets = true
        show("Installing en-CA assets — this may download Apple's model")
        assetTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await AppleSpeechEngine.installAssets(locale: self.locale, backend: .speech)
                self.installingAssets = false
                self.assetState = "installed"
                self.show("English speech assets ready; enable dictation when ready")
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
