import AppKit
import Darwin
import HolosCore
import HolosMeeting
import HolosSynthesis
import os

/// Settings › Reading's natural voice downloads (docs/design.md "Natural voices"): each pack's state and this app's
/// running `voiceislocal setup --natural-voices`.
@MainActor
final class NaturalVoicesAppState {
    var downloads: [NaturalVoicePack: NaturalVoiceDownload] = Dictionary(
        uniqueKeysWithValues: NaturalVoicePack.allCases.map { ($0, NaturalVoiceDownload(pack: $0)) })
    /// The pid of this app's download per pack, while it runs.
    var pids: [NaturalVoicePack: Int32] = [:]
    /// The download's output, followed for its progress.
    var outputs: [NaturalVoicePack: URL] = [:]
    /// The packs installed as the voice menus last showed them.
    var watch = NaturalVoicesWatch()
    /// The launcher of the bundled tool, made on first use.
    lazy var launcher = MaintenanceLauncher(executable: ChildProcessLauncher.bundledExecutable)
}

/// Natural voices: the download from Settings › Reading.
extension HolosAppDelegate {
    private static let readingLog = Logger(subsystem: "ca.orlenko.holos.app", category: "reading")

    /// Settings › Reading's natural voice row for `pack`: starts its download, or cancels the one running.
    func toggleNaturalVoiceDownload(_ pack: NaturalVoicePack) {
        let state = naturalVoices
        guard var download = state.downloads[pack] else { return }
        if download.isRunning {
            if download.cancel(), let pid = state.pids[pack] { kill(pid, SIGTERM) }
            state.downloads[pack] = download
            updateSettings()
            return
        }
        guard download.start() else { return }
        state.downloads[pack] = download
        let output = Self.temporaryFile("setup-natural")
        state.outputs[pack] = output
        let arguments = ["setup", "--natural-voices"] + (pack == .english ? [] : ["--language", pack.languageCode])
        do {
            state.pids[pack] = try state.launcher.run(arguments, standardOutput: output, standardError: output) {
                [weak self] code in self?.naturalVoiceDownloadEnded(pack, code: code)
            }
        } catch {
            state.downloads[pack]?.ended(code: -1, lastLine: error.localizedDescription, installed: false)
            state.outputs[pack] = nil
            Self.removeFile(output)
            updateSettings()
            return
        }
        Self.readingLog.notice("Natural voices download (\(pack.rawValue, privacy: .public)) started")
        updateSettings()
        Task { [weak self] in
            while let self, self.naturalVoices.downloads[pack]?.isRunning == true {
                if let line = Self.lastLine(output) {
                    self.naturalVoices.downloads[pack]?.said(line)
                    self.updateSettings()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func naturalVoiceDownloadEnded(_ pack: NaturalVoicePack, code: Int32) {
        let state = naturalVoices
        let output = state.outputs.removeValue(forKey: pack)
        let last = output.flatMap(Self.lastLine)
        output.map(Self.removeFile)
        state.pids[pack] = nil
        let installed = NaturalVoiceModels.status(pack: pack) == .installed
        state.downloads[pack]?.ended(code: code, lastLine: last, installed: installed)
        Self.readingLog.notice("Natural voices download (\(pack.rawValue, privacy: .public)) ended with \(code, privacy: .public)")
        // The voice menus offer the new voices (Automatic now picks them); what the Reading card shows stays.
        if installed { checkNaturalVoicesInstalled(force: true) }
        updateSettings()
    }

    /// When the app becomes active: a pack installed (or removed) meanwhile from Terminal (`voiceislocal setup
    /// --natural-voices`) is offered by the voice menus, as after a download from Settings. A check of two small files.
    func applicationDidBecomeActive(_ notification: Notification) {
        checkNaturalVoicesInstalled()
    }

    /// Tells the voice menus when the installed packs changed since they were last told (`force`: tell them anyway).
    func checkNaturalVoicesInstalled(force: Bool = false) {
        if naturalVoices.watch.observe(NaturalVoiceModels.installedPacks()) || force {
            ReadingVoices.announceInstalled()
        }
    }

    /// Checks the packs' files (a download in Terminal, or one finished while the app was closed).
    func refreshNaturalVoices() {
        for pack in NaturalVoicePack.allCases {
            naturalVoices.downloads[pack]?.checked(NaturalVoiceModels.status(pack: pack))
        }
    }
}

/// The Reading section's part of quitting (docs/design.md "Reading section").
extension HolosAppDelegate {
    /// Asks what becomes of the readings being made or waiting: Keep Rendering (quit now; they continue at the next
    /// launch), Stop (they stop, with Resume), or Cancel. Keep Rendering is offered only while the list is saved.
    /// Returns false to cancel the quit. `ReadingController.quitCancelled` undoes the preparation when the quit is
    /// cancelled later.
    func readingShouldTerminate() -> Bool {
        guard readings.isBusy else {
            // Nothing is being made, but a change since the last save that worked (a Stop, a Delete) may not be
            // saved: the next launch would then find the list as it was.
            guard !readings.saveBeforeQuit() else { return true }
            let alert = NSAlert()
            alert.messageText = "The Reading list could not be saved."
            alert.informativeText = "The next launch may continue a reading you stopped or show one you deleted. "
                + "Free some space or fix the folder's permissions, then quit again.\n\n\(readings.notice ?? "")"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            NSApplication.shared.activate()
            return alert.runModal() == .alertSecondButtonReturn
        }
        let alert = NSAlert()
        let title = readings.runningTitle.map { "“\($0)”" } ?? "A reading"
        let waiting = readings.waitingCount
        alert.messageText = "\(title) is being made."
        let keep = readings.canPersist
        if keep {
            var text = "Keep Rendering quits now and continues it the next time you open Voice is Local"
            if waiting > 0 { text += ", with the \(waiting == 1 ? "reading" : "\(waiting) readings") waiting after it" }
            alert.informativeText = text + ". Stop ends it; its row offers Resume."
            alert.addButton(withTitle: "Keep Rendering")
        } else {
            alert.informativeText = "The Reading list cannot be saved now, so it cannot continue after Voice is Local "
                + "quits. Stop ends it and quits."
        }
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        let response = alert.runModal()
        switch (keep, response) {
        case (true, .alertFirstButtonReturn):
            if !readings.prepareForQuit(keep: true) {
                // The save failed just now (or did not end in time): what the next launch finds cannot be told (the
                // list may have been written without being flushed, or still be being written), so Voice is Local
                // does not quit; the readings go on.
                readings.quitCancelled()
                let failed = NSAlert()
                failed.messageText = "Voice is Local did not quit."
                failed.informativeText = "The Reading list could not be saved, so it cannot be told whether the next "
                    + "launch would continue the reading. It goes on now. Free some space or fix the folder's "
                    + "permissions, then quit again.\n\n\(readings.notice ?? "")"
                failed.runModal()
                return false
            }
        case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn):
            if !readings.prepareForQuit(keep: false) {
                // The saved list may still ask the next launch to continue these readings (an earlier Keep
                // Rendering): quitting now would undo this Stop. The readings stay stopped, with Resume.
                readings.quitCancelled()
                let failed = NSAlert()
                failed.messageText = "Voice is Local did not quit."
                failed.informativeText = "The reading was stopped, but the Reading list could not be saved, so the "
                    + "next launch could continue it anyway. Free some space or fix the folder's permissions, then "
                    + "quit again.\n\n\(readings.notice ?? "")"
                failed.runModal()
                return false
            }
        default:
            return false
        }
        return true
    }
}
