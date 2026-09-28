import AppKit
import Foundation
import HolosCore
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
            clear: { [weak self] in self?.history.clear() }))
        updateHistoryPane(pane)
        return pane
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
