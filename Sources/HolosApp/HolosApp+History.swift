import AppKit
import Foundation
import HolosCore
import HolosDictation
import HolosStorage

// The dictation history itself (records in memory, the serial file queue, flushing on quit) is
// `DictationHistoryService` in HolosStorage.

/// What the app knows about a dictation in progress, for its History record. Made at key-down only after the
/// secure-field checks passed, so a refused dictation never has one.
struct HistoryDraft {
    var id: UUID?
    let date: Date
    let app: String?
    let language: String
    var listeningStarted: Date?
    var listeningEnded: Date?

    /// Seconds from Listening to release (to the result when release was not seen).
    func seconds(now: Date) -> Double {
        guard let start = listeningStarted else { return 0 }
        return max(0, (listeningEnded ?? now).timeIntervalSince(start))
    }
}

extension HolosAppDelegate {
    /// The History section's actions and the history's changes, wired once the service and window exist.
    func makeHistoryPane() -> HistoryPane {
        let pane = HistoryPane(actions: HistoryPane.Actions(
            copy: { [weak self] text in self?.copyToClipboardOnRequest(text) ?? false },
            correct: { [weak self] record in self?.correct(record) },
            delete: { [weak self] record in self?.history.delete(record.id) },
            clear: { [weak self] in self?.history.clear() },
            audioURL: { [weak self] record in self?.historyAudioURL(record) },
            rerun: { [weak self] record in
                guard let self else { throw CancellationError() }
                return try await self.runAgain(record)
            },
            update: { [weak self] record, report in
                self?.history.update(DictationRerun.updated(record, with: report))
            }))
        updateHistoryPane(pane)
        return pane
    }

    /// A dictation's saved audio, when its record links it and the file is still there.
    func historyAudioURL(_ record: DictationRecord) -> URL? {
        guard record.audio != nil else { return nil }
        let url = history.store.audioURL(for: record.id)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    /// Run Again: the dictation's audio through the recognizer and the text steps with today's settings (the
    /// dictation language, the learned corrections as vocabulary and replacements, filler removal, spoken code, Apple
    /// Intelligence's fix), as live dictation would write it now. Nothing is typed anywhere and nothing is copied.
    func runAgain(_ record: DictationRecord) async throws -> DictationRerunReport {
        guard let url = historyAudioURL(record) else {
            throw HolosError.unavailable("The audio of this dictation is no longer on this Mac.")
        }
        let (pipeline, note) = DictationRerun.pipeline(language: locale, removeFillers: removeFillers,
                                                       corrections: corrections, aiFix: AIFixSetting.isOn,
                                                       spokenCode: SpokenCodeSetting.isOn,
                                                       backticks: SpokenCodeSetting.backticks)
        return try await DictationRerun.run(record, audio: url, pipeline: pipeline, aiNote: note)
    }

    /// Settings › Keep the audio of dictations. Turning it off stops keeping new audio and offers to delete the audio
    /// already kept.
    func changeKeepsHistoryAudio(_ keeps: Bool) {
        guard keeps != history.keepsAudio else { return }
        history.keepsAudio = keeps
        updateSettings()
        guard !keeps else { return }
        let kept = history.records.count { $0.audio != nil }
        let bytes = history.audioBytes ?? 0
        guard kept > 0 || bytes > 0 else { return }
        // Asked outside the checkbox's action, so the modal alert never runs inside it.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.history.keepsAudio else { return }
            let alert = NSAlert()
            alert.messageText = "Also delete the audio already kept?"
            alert.informativeText = "New dictations no longer keep their audio. The audio of "
                + (kept > 0 ? "\(kept) \(kept == 1 ? "dictation" : "dictations")" : "earlier dictations")
                + " (\(HistoryAudio.sizeText(bytes))) stays on this Mac until you delete it; their text stays in "
                + "History either way."
            alert.addButton(withTitle: "Delete Audio")
            alert.addButton(withTitle: "Keep It")
            NSApplication.shared.activate()
            if alert.runModal() == .alertFirstButtonReturn { self.history.removeAllAudio() }
        }
    }

    private func updateHistoryPane(_ pane: HistoryPane) {
        pane.update(records: history.records, retention: history.retention, problem: history.problem,
                    hidden: history.newerLines, unreadable: history.unreadable)
    }

    /// Keeps the History section, Settings' count, and the status message current: once a later change clears the
    /// history's problem, the status stops reporting it.
    func historyChanged() {
        if let pane = mainWindow?.existingController(for: .history) as? HistoryPane { updateHistoryPane(pane) }
        if history.problem == nil { showHistoryProblem(nil) }
        updateSettings()
    }

    /// Settings › Keep dictations. Off asks whether to clear what is already kept: once the history has been read,
    /// so an Off chosen before the launch load finished still counts (and offers to clear) the dictations on disk.
    func changeHistoryRetention(to retention: HistoryRetention) {
        guard retention != history.retention else { return }
        history.retention = retention
        if retention == .off {
            history.whenLoaded { [weak self] in
                // Asked outside the load's completion (and this action), so the modal alert never runs inside them.
                DispatchQueue.main.async { self?.offerToClearHistoryAfterOff() }
            }
        }
        history.sweep()
        historyChanged()
    }

    private func offerToClearHistoryAfterOff() {
        // History may have been turned back on while the load finished.
        guard history.retention == .off, let kept = HistoryPane.clearTarget(count: history.keptCount,
                                                                           unreadable: history.unreadable) else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "History is off. Also clear \(kept.phrase)?"
        alert.informativeText = "New dictations are no longer kept. The ones already kept stay on this Mac until you clear them."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Keep Them")
        NSApplication.shared.activate()
        if alert.runModal() == .alertFirstButtonReturn { history.clear() }
    }

    /// Settings › Clear History…, with a confirmation.
    func confirmClearHistory() {
        guard let kept = HistoryPane.clearTarget(count: history.keptCount, unreadable: history.unreadable) else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Clear History?"
        alert.informativeText = "\(kept.sentence) Text already written into other apps stays there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        if alert.runModal() == .alertFirstButtonReturn { history.clear() }
    }

    /// The name of the app a dictation is for: the typed-into app, else the process that owns the target.
    static func historyAppName(typed: String?, pid: pid_t?) -> String? {
        if let typed, !typed.isEmpty { return typed }
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.localizedName
            ?? app.bundleURL.map { FileManager.default.displayName(atPath: $0.path) }
    }
}
