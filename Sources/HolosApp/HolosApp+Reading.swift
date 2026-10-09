import AppKit
import Darwin
import HolosContent
import HolosCore
import HolosMeeting
import HolosSynthesis
import os

/// Settings › Reading's natural voice downloads (docs/design.md "Natural voices"): each pack's state and this app's
/// running `voiceislocal setup --natural-voices`.
///
/// Invariants:
/// 1. `installed` and `statuses` change only when a look (`refresh`) ends, together, from one scan.
/// 2. One look runs at a time; every `refresh` called during it gets its result.
/// 3. `pids[pack]` and `outputs[pack]` are set while this app's download of `pack` runs, and cleared when it ends.
/// 4. At most one install runs at a time (`mayStart`).
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
    /// Looks for the end of an install another process runs (`NaturalVoicesInstallPoll`).
    var poll: Task<Void, Never>?
    /// The launcher of the bundled tool, made on first use.
    lazy var launcher = MaintenanceLauncher(executable: ChildProcessLauncher.bundledExecutable)

    /// The app's one state (the app delegate's `naturalVoices`).
    static let shared = NaturalVoicesAppState()

    /// The packs installed, and each pack's status, as last looked at (`refresh`): what the menus, Preview, the
    /// renderer and Settings use, so none of them reads pack files on the main actor.
    private(set) var installed: Set<NaturalVoicePack> = []
    private(set) var statuses: [NaturalVoicePack: DeepModelStatus] = [:]
    /// Looks at every pack's files (lock, marker, inventory); tests replace it.
    var scan: @Sendable () -> [NaturalVoicePack: DeepModelStatus] = {
        Dictionary(uniqueKeysWithValues: NaturalVoicePack.allCases.map { ($0, NaturalVoiceModels.status(pack: $0)) })
    }
    private var looking: Task<Void, Never>?
    private var afterLook: [@MainActor () -> Void] = []

    /// Looks at the packs off the main actor, one look at a time, records what it found (and each download row's
    /// status), then calls `done`; a call during a look gets that look's result.
    func refresh(then done: @escaping @MainActor () -> Void = {}) {
        afterLook.append(done)
        guard looking == nil else { return }
        let scan = scan
        looking = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { scan() }.value
            guard let self else { return }
            statuses = found
            installed = Set(found.filter { $0.value == .installed }.keys)
            for (pack, status) in found { downloads[pack]?.checked(status) }
            looking = nil
            let waiting = afterLook
            afterLook = []
            waiting.forEach { $0() }
        }
    }

    /// Whether `pack`'s download may start: one install at a time, this app's or another process's (`voiceislocal
    /// setup` in Terminal, its install lock held), so two models are never set up together.
    func mayStart(_ pack: NaturalVoicePack) -> Bool {
        !downloads.contains { $0.key != pack && ($0.value.isRunning || $0.value.phase == .otherProcess) }
            && !statuses.contains { $0.key != pack && $0.value == .downloading }
    }
}

/// Natural voices: the download from Settings › Reading.
extension HolosAppDelegate {
    private static let readingLog = Logger(subsystem: "ca.orlenko.holos.app", category: "reading")

    /// Settings › Reading's natural voice downloads.
    var naturalVoices: NaturalVoicesAppState { .shared }

    /// At launch: readings the user kept rendering over the last quit continue; natural voice temporaries a crash or
    /// a SIGKILL left behind (a day old, so none in use) are removed; the voice menus start with the packs installed
    /// (a change later, in Terminal, is noticed at activation, or by polling while another process installs one).
    func startReadings() {
        DispatchQueue.global(qos: .utility).async { NaturalVoiceTemporaries.sweep() }
        // The packs first (off the main actor), so a natural reading continued now finds its voice.
        naturalVoices.refresh { [weak self] in
            self?.readings.start()
            self?.checkNaturalVoicesInstalled()
            self?.pollNaturalVoiceInstalls()
        }
    }

    /// At quit: natural voice helpers (a reading's part, a Preview) run detached, so they are stopped now and their
    /// folders removed.
    func stopNaturalVoiceHelpers() {
        NaturalVoiceHelpers.stopAll()
    }

    /// Settings › Reading's rows: each pack's download; its files are looked at again off the main actor, for the
    /// next refresh of Settings.
    func naturalVoiceDownloads() -> [NaturalVoicePack: NaturalVoiceDownload] {
        naturalVoices.refresh()
        return naturalVoices.downloads
    }

    /// The Settings action of a pack's row.
    func toggleNaturalVoiceDownload(for action: SetupAction) {
        toggleNaturalVoiceDownload(action == .naturalVoicesFrench ? .french : .english)
    }

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
        // One download at a time: Settings disables the other row meanwhile.
        guard state.mayStart(pack), download.start() else { return }
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
                // Read off the main actor: the output file is on disk.
                if let line = try? await offMain({ ProcessSpawner.lastLine(of: output) }) {
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
        state.pids[pack] = nil
        Self.readingLog.notice("Natural voices download (\(pack.rawValue, privacy: .public)) ended with \(code, privacy: .public)")
        Task { [weak self] in
            // The output's last line is read, and the file removed, off the main actor.
            let last = try? await offMain { () -> String? in
                defer { output.map(ProcessSpawner.removeRegularFile) }
                return output.flatMap { ProcessSpawner.lastLine(of: $0) }
            }
            self?.naturalVoiceDownloadFinished(pack, code: code, last: last ?? nil)
        }
    }

    private func naturalVoiceDownloadFinished(_ pack: NaturalVoicePack, code: Int32, last: String?) {
        let state = naturalVoices
        state.refresh { [weak self] in
            let installed = state.statuses[pack] == .installed
            state.downloads[pack]?.ended(code: code, lastLine: last, installed: installed)
            // The voice menus offer the new voices (Automatic now picks them); what the Reading card shows stays.
            if installed { self?.checkNaturalVoicesInstalled(force: true) }
            self?.updateSettings()
        }
    }

    /// When the app becomes active: a pack installed (or removed) meanwhile from Terminal (`voiceislocal setup
    /// --natural-voices`) is offered by the voice menus, as after a download from Settings. A check of two small files.
    func applicationDidBecomeActive(_ notification: Notification) {
        naturalVoices.refresh { [weak self] in
            self?.checkNaturalVoicesInstalled()
            self?.pollNaturalVoiceInstalls()
        }
    }

    /// While a pack is being installed by another process, checks every few seconds until it ends.
    func pollNaturalVoiceInstalls() {
        guard naturalVoices.poll == nil else { return }
        let state = naturalVoices
        let inProgress = { state.statuses.values.contains(.downloading) }
        guard inProgress() else { return }
        naturalVoices.poll = Task { [weak self] in
            await NaturalVoicesInstallPoll.run(
                inProgress: inProgress, check: { state.refresh { self?.checkNaturalVoicesInstalled() } },
                pause: { try? await Task.sleep(for: NaturalVoicesInstallPoll.interval) })
            self?.naturalVoices.poll = nil
        }
    }

    /// Tells the voice menus when the installed packs (as last looked at) changed since they were last told (`force`:
    /// tell them anyway).
    func checkNaturalVoicesInstalled(force: Bool = false) {
        if naturalVoices.watch.observe(naturalVoices.installed) || force {
            ReadingVoices.announceInstalled()
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
