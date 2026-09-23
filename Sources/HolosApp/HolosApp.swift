import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Foundation
import HolosAudio
import HolosDesktop
import HolosDictation
import HolosSpeech

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
    private var statusItem: NSStatusItem!
    private let overlay = DictationOverlay()
    private var monitor: GlobalHotkeyMonitor?
    private var controller: DictationController!
    private var enabled = false
    private var enabling = false
    private var installingAssets = false
    private var enableGeneration = 0
    private var enableTask: Task<Void, Never>?
    private var assetTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var target: InsertionTarget?
    private var insertionBlockReason: String?
    private var resultText = ""
    private var message = "Disabled — setup is available below"
    private var shortcut: HotkeyChoice = .rightOption
    private let locale = "en-CA"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let raw = UserDefaults.standard.string(forKey: "shortcut"), let saved = HotkeyChoice(rawValue: raw) {
            shortcut = saved
        }
        controller = DictationController(locale: locale) { [weak self] update in self?.receive(update) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Holos")
        statusItem.button?.toolTip = "Holos — local push-to-talk"
        rebuildMenu()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendForSessionChange() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isBusy else { return }
                self.target = nil
                self.insertionBlockReason = "The active application changed; use Copy Result."
            }
        })
        if UserDefaults.standard.bool(forKey: "dictationEnabled") { enable() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        enableTask?.cancel(); assetTask?.cancel(); expiryTask?.cancel()
        monitor?.stop(); controller?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        overlay.hide()
    }

    private var isBusy: Bool {
        guard let controller else { return false }
        return [.preparing, .listening, .finalizing].contains(controller.status.phase)
    }

    private var shortcutTitle: String { shortcut == .rightOption ? "Right Option" : "Control–Option–Space" }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
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
        menu.addItem(.separator())
        menu.addItem(item("Grant Microphone Access…", #selector(requestMicrophone)))
        menu.addItem(item("Grant Accessibility Access…", #selector(requestAccessibility)))
        menu.addItem(item("Grant Input Monitoring Access…", #selector(requestInputMonitoring)))
        let assets = item(installingAssets ? "Installing English Speech Assets…" : "Install English Speech Assets…", #selector(installAssets))
        assets.isEnabled = !installingAssets && !isBusy && !enabled && !enabling
        menu.addItem(assets)
        menu.addItem(item("Show Setup Status", #selector(showSetupStatus)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Holos", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.toolTip = "Holos — \(message)"
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { enabled ? disable() : enable() }

    private func enable() {
        guard !enabled, !enabling, !installingAssets else { return }
        guard AudioCapture.microphonePermission == "authorized", AXIsProcessTrusted() else {
            show("Grant Microphone and Accessibility access from the Holos menu, then enable dictation.")
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
                guard state == "installed" else {
                    self.enabling = false
                    self.show("Install English Speech Assets from the Holos menu first.")
                    return
                }
                let monitor = GlobalHotkeyMonitor(shortcut: self.shortcut) { [weak self] action in self?.handle(action) }
                try monitor.start()
                self.monitor = monitor
                self.enabled = true
                self.enabling = false
                UserDefaults.standard.set(true, forKey: "dictationEnabled")
                self.show("Ready — hold \(self.shortcutTitle); wait for Listening")
                self.overlay.hide()
            } catch {
                guard generation == self.enableGeneration else { return }
                self.enabling = false
                self.show(error.localizedDescription)
            }
        }
    }

    private func disable(persist: Bool = true) {
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
        guard !isBusy, let raw = sender.representedObject as? String, let choice = HotkeyChoice(rawValue: raw) else { return }
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
            guard !isBusy, !TextInsertion.isSecureInputActive() else { return }
            insertionBlockReason = nil
            do { target = try TextInsertion.captureTarget() }
            catch TextInsertionError.secureInput {
                target = nil
                show("Dictation is disabled in secure/password fields.")
                return
            } catch {
                target = nil
                insertionBlockReason = "This field cannot be safely updated; use Copy Result."
            }
            expiryTask?.cancel()
            resultText = ""
            if !controller.begin() {
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
            overlay.show(title: message, text: "Release to stop · Esc to cancel")
        case .listening:
            message = "Listening — release \(shortcutTitle) to finish"
            overlay.show(title: message, text: update.text.isEmpty ? "Speak now · Esc to cancel" : update.text)
        case .finalizing:
            if let reason = update.message {
                target = nil
                insertionBlockReason = reason + " Use Copy Result."
            }
            message = update.message ?? "Finishing locally…"
            overlay.show(title: message, text: update.text)
        case .result:
            resultText = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = target
            target = nil // No callback or retry can write to this target a second time.
            if resultText.isEmpty {
                message = "No speech recognized"
            } else if enabled, insertionBlockReason == nil, let destination {
                switch TextInsertion.insert(resultText, into: destination) {
                case .inserted: message = "Inserted — hold \(shortcutTitle) for another dictation"
                case .needsCopy(let reason): message = "Not inserted: \(reason) Use Copy Result."
                case .unverified(let reason): message = "Insertion unverified: \(reason) Check the field before copying."
                }
            } else {
                message = insertionBlockReason ?? "Result ready — use Copy Result."
            }
            overlay.show(title: message, text: resultText)
            scheduleExpiry()
        case .failed:
            target = nil
            message = update.message ?? "Dictation failed; no text was inserted."
            resultText = update.text
            overlay.show(title: message, text: resultText)
            scheduleExpiry()
        }
        rebuildMenu()
    }

    private func show(_ value: String) {
        message = value
        rebuildMenu()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                self?.overlay.hide()
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
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(resultText, forType: .string)
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

    @objc private func requestMicrophone() {
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            self?.show(granted ? "Microphone access granted; enable dictation when ready" : "Microphone denied; review System Settings → Privacy & Security")
        }
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        show("Review Holos under System Settings → Privacy & Security → Accessibility")
    }

    @objc private func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        show("Review Holos under Privacy & Security → Input Monitoring; relaunch if macOS asks")
    }

    @objc private func installAssets() {
        guard !installingAssets, !isBusy, !enabled, !enabling else { return }
        installingAssets = true
        show("Installing en-CA assets — this may download Apple's model")
        assetTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await AppleSpeechEngine.installAssets(locale: self.locale, backend: .speech)
                self.installingAssets = false
                self.show("English speech assets ready; enable dictation when ready")
            } catch {
                self.installingAssets = false
                self.show("Asset setup failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func showSetupStatus() {
        show("Mic: \(AudioCapture.microphonePermission) · AX: \(AXIsProcessTrusted() ? "yes" : "no") · Input: \(CGPreflightListenEventAccess() ? "yes" : "no") · en-CA")
    }

    private func suspendForSessionChange() {
        disable(persist: false)
        discardResult()
        show("Paused after sleep/session change — enable from the menu to resume")
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
