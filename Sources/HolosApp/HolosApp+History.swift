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
        pane.update(records: history.records, retention: history.retention)
        return pane
    }

    /// Keeps the History section and Settings' count current.
    func historyChanged() {
        if let pane = mainWindow?.existingController(for: .history) as? HistoryPane {
            pane.update(records: history.records, retention: history.retention)
        }
        updateSettings()
    }

    /// Settings › Keep dictations. Off asks whether to clear what is already kept.
    func changeHistoryRetention(to retention: HistoryRetention) {
        guard retention != history.retention else { return }
        history.retention = retention
        if retention == .off, !history.records.isEmpty {
            let count = history.records.count
            let alert = NSAlert()
            alert.messageText = "History is off. Also clear the \(count) \(count == 1 ? "dictation" : "dictations") already kept?"
            alert.informativeText = "New dictations are no longer kept. The ones already kept stay on this Mac until you clear them."
            alert.addButton(withTitle: "Clear History")
            alert.addButton(withTitle: "Keep Them")
            NSApplication.shared.activate()
            if alert.runModal() == .alertFirstButtonReturn { history.clear() }
        }
        history.sweep()
        historyChanged()
    }

    /// Settings › Clear History…, with a confirmation.
    func confirmClearHistory() {
        let count = history.records.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Clear History?"
        alert.informativeText = "All \(count) \(count == 1 ? "dictation" : "dictations") kept on this Mac are deleted. Text already written into other apps stays there."
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
