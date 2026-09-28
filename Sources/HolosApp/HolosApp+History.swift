import AppKit
import Foundation
import HolosCore
import HolosStorage
import os

/// The dictation history the app keeps (docs/design.md "Dictation history"): the records in memory for the History
/// section, and every file operation on one serial queue off the main actor (`DictationHistoryStore`), in the order
/// they were asked for. Nothing here logs dictated text.
@MainActor
final class DictationHistoryService {
    private nonisolated static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "history")
    private let store: DictationHistoryStore
    private let queue = DispatchQueue(label: "ca.orlenko.holos.history", qos: .utility)
    /// Oldest first, as stored.
    private(set) var records: [DictationRecord] = []
    /// Bumped by every change made here, so a reload read before it does not replace it.
    private var generation = 0
    private var dailySweep: Task<Void, Never>?
    /// Called on the main actor whenever `records` changed.
    var onChange: (() -> Void)?

    init(store: DictationHistoryStore = DictationHistoryStore()) {
        self.store = store
    }

    var retention: HistoryRetention {
        get { HistoryRetention.saved(UserDefaults.standard.string(forKey: HistoryRetention.defaultsKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: HistoryRetention.defaultsKey) }
    }

    /// At launch: sweeps what the retention setting no longer keeps, loads the rest, and sweeps again once a day.
    func start() {
        sweep()
        dailySweep?.cancel()
        dailySweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                guard !Task.isCancelled, let self else { return }
                self.sweep()
            }
        }
    }

    func stop() {
        dailySweep?.cancel()
        dailySweep = nil
    }

    /// Rereads the file (the command line may have cleared it).
    func reload() {
        let store = self.store
        let asked = generation
        queue.async { [weak self] in
            let contents: DictationHistoryStore.Contents?
            do {
                contents = try store.load()
            } catch {
                Self.log.error("Cannot read the history: \(error.localizedDescription, privacy: .public)")
                contents = nil
            }
            Task { @MainActor in
                guard let self, let contents, self.generation == asked else { return }
                self.records = contents.records
                self.onChange?()
            }
        }
    }

    /// Records a finished dictation, unless History is off.
    func add(_ record: DictationRecord) {
        guard retention.records else { return }
        generation += 1
        records.append(record)
        onChange?()
        write("append") { try $0.append(record) }
    }

    func delete(_ id: UUID) {
        generation += 1
        records.removeAll { $0.id == id }
        onChange?()
        write("delete") { try $0.delete(id: id) }
    }

    func clear() {
        generation += 1
        records.removeAll()
        onChange?()
        write("clear") { try $0.clear() }
    }

    /// Removes what the retention setting no longer keeps, then reloads.
    func sweep() {
        let retention = self.retention
        generation += 1
        if let cutoff = retention.cutoff(now: Date()) {
            records.removeAll { $0.date < cutoff }
            onChange?()
        }
        write("sweep") { try $0.sweep(retention) }
        reload()
    }

    private func write(_ what: String, _ body: @escaping @Sendable (DictationHistoryStore) throws -> Void) {
        let store = self.store
        queue.async {
            do {
                try body(store)
            } catch {
                Self.log.error("History \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

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
