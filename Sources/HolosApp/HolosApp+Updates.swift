import AppKit
import HolosAppModel
import Sparkle

/// In-app updates (docs/release.md "Updates"): Sparkle reads the appcast at SUFeedURL, accepts only an update signed
/// with the key in SUPublicEDKey, and installs it when the user says so. Only release builds carry SUFeedURL; the local
/// build (scripts/build-app.sh) leaves it out, so it never checks. Sparkle starts only when it has something to do:
/// at launch when the user chose automatic checks, else on Check for Updates…, so nothing goes online before the
/// user's answer (`UpdateCheckConsent`).
@MainActor
final class AppUpdates: NSObject, SPUUpdaterDelegate {
    /// Whether this build can update itself: a release build with a feed and a key.
    let available: Bool
    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        available = bundle.object(forInfoDictionaryKey: "SUFeedURL") is String
            && bundle.object(forInfoDictionaryKey: "SUPublicEDKey") is String
        self.defaults = defaults
        super.init()
    }

    /// Settings › General › "Check for updates automatically"; off until the user turns it on or answers yes.
    var checksAutomatically: Bool {
        controller?.updater.automaticallyChecksForUpdates ?? (answer ?? false)
    }

    func setChecksAutomatically(_ on: Bool) {
        if let controller {
            controller.updater.automaticallyChecksForUpdates = on
        } else {
            defaults.set(on, forKey: UpdateCheckConsent.automaticChecksKey)
        }
        if on { start() }
    }

    /// Called once at launch: starts Sparkle when the user chose automatic checks, and returns whether to ask now.
    func launch() -> Bool {
        guard available else { return false }
        let launchedBefore = defaults.bool(forKey: UpdateCheckConsent.launchedBeforeKey)
        defaults.set(true, forKey: UpdateCheckConsent.launchedBeforeKey)
        switch UpdateCheckConsent.launch(answer: answer, launchedBefore: launchedBefore) {
        case .wait: return false
        case .ask: return true
        case .answered(let automatic):
            if automatic { start() }
            return false
        }
    }

    /// Sparkle has started: from then on it may check on its own when the user chose automatic checks.
    var started: Bool { controller != nil }

    /// Check for Updates…: Sparkle's own window shows the check and what it found.
    func checkNow() {
        start()
        controller?.checkForUpdates(nil)
    }

    private var answer: Bool? { defaults.object(forKey: UpdateCheckConsent.automaticChecksKey) as? Bool }

    private func start() {
        guard available, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    /// The app asks its own question (`askAboutUpdateChecks`), worded for what it fetches; never Sparkle's.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
}

extension HolosAppDelegate {
    /// At launch: the second launch of a release build asks once, after the window has opened. While the Setup
    /// Assistant is open, a dictation runs, or a meeting records, the question waits for a later launch: its alert is
    /// modal.
    func startUpdates() {
        guard updates.launch() else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.assistantWindow?.isVisible != true, !self.isBusy,
                  !self.meetingRecordingAtLaunch else { return }
            self.askAboutUpdateChecks()
        }
    }

    func askAboutUpdateChecks() {
        let alert = NSAlert()
        alert.messageText = "Check for updates automatically?"
        alert.informativeText = """
            Voice is Local can look for a new version about once a day. Each check downloads one small file from \
            voiceislocal.com and sends only the app's name and version. An update downloads only when you choose to \
            install it. You can change this in Settings › General, and Check for Updates… in the menu works either way.
            """
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")
        NSApp.activate()
        updates.setChecksAutomatically(alert.runModal() == .alertFirstButtonReturn)
        updateSettings()
    }

    func addUpdateItem(to menu: NSMenu) {
        guard updates.available else { return }
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
    }

    @objc func checkForUpdates() {
        updates.checkNow()
    }
}
