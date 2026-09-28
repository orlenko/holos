import Foundation
import HolosCore
import os

/// The dictation history the app keeps (docs/design.md "Dictation history"): the records in memory for the History
/// section, and every file operation on one serial queue off the main actor (`DictationHistoryStore`), in the order
/// they were asked for. Quitting waits for that queue (`flush`), so a dictation just recorded, deleted, or cleared
/// reaches the file first. Nothing here logs dictated text.
@MainActor
public final class DictationHistoryService {
    private nonisolated static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "history")
    public nonisolated let store: DictationHistoryStore
    private nonisolated let queue = DispatchQueue(label: "ca.orlenko.holos.history", qos: .utility)
    private let defaults: UserDefaults
    /// Oldest first, as stored.
    public private(set) var records: [DictationRecord] = []
    /// Bumped by every change made here.
    private var generation = 0
    /// The changes made while a reload reads the file, by generation: each reload applies the ones made after it
    /// was asked for to what it read, since the file may not have had them yet. Emptied when no reload is reading.
    private var journal: [(generation: Int, change: DictationHistoryChange)] = []
    private var loadsInFlight = 0
    private var dailySweep: Task<Void, Never>?
    /// Called on the main actor whenever `records` changed.
    public var onChange: (() -> Void)?

    public init(store: DictationHistoryStore = DictationHistoryStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    public var retention: HistoryRetention {
        get { HistoryRetention.saved(defaults.string(forKey: HistoryRetention.defaultsKey)) }
        set { defaults.set(newValue.rawValue, forKey: HistoryRetention.defaultsKey) }
    }

    /// At launch: sweeps what the retention setting no longer keeps, loads the rest, and sweeps again once a day.
    public func start() {
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

    public func stop() {
        dailySweep?.cancel()
        dailySweep = nil
    }

    /// Waits, at most `timeout` seconds, for every file operation asked for so far to finish; false when the time
    /// ran out. For quitting: a queued append, delete, or clear must reach the file before the process exits.
    @discardableResult
    public nonisolated func flush(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Returns once every file operation asked for so far has finished.
    public func flushed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Rereads the file (the command line may have cleared it). Changes made here while it reads are applied to
    /// what it read, never lost. The returned task ends once the records are updated.
    @discardableResult
    public func reload() -> Task<Void, Never> {
        let asked = generation
        loadsInFlight += 1
        let store = self.store
        let (stream, continuation) = AsyncStream.makeStream(of: DictationHistoryStore.Contents?.self)
        // Queued now, so it reads the file after every operation asked for before it and before any asked after.
        queue.async {
            do {
                continuation.yield(try store.load())
            } catch {
                Self.log.error("Cannot read the history: \(error.localizedDescription, privacy: .public)")
                continuation.yield(nil)
            }
            continuation.finish()
        }
        return Task { [weak self] in
            var contents: DictationHistoryStore.Contents?
            for await value in stream { contents = value }
            self?.loaded(contents, asked: asked)
        }
    }

    private func loaded(_ contents: DictationHistoryStore.Contents?, asked: Int) {
        loadsInFlight -= 1
        defer { if loadsInFlight == 0 { journal.removeAll() } }
        guard let contents else { return }
        var merged = contents.records
        for entry in journal where entry.generation > asked { entry.change.apply(to: &merged) }
        records = merged
        onChange?()
    }

    /// Records a finished dictation, unless History is off.
    public func add(_ record: DictationRecord) {
        guard retention.records else { return }
        change(.add(record), "append") { try $0.append(record) }
    }

    public func delete(_ id: UUID) {
        change(.delete(id), "delete") { try $0.delete(id: id) }
    }

    public func clear() {
        change(.clear, "clear") { try $0.clear() }
    }

    /// Removes what the retention setting no longer keeps (and compacts the file), then reloads.
    public func sweep(now: Date = Date()) {
        let cutoff = retention.cutoff(now: now) ?? .distantPast
        change(.sweep(before: cutoff), "sweep") { try $0.sweep(before: cutoff) }
        reload()
    }

    private func change(_ change: DictationHistoryChange, _ what: String,
                        _ write: @escaping @Sendable (DictationHistoryStore) throws -> Void) {
        generation += 1
        if loadsInFlight > 0 { journal.append((generation, change)) }
        let before = records
        change.apply(to: &records)
        if records != before { onChange?() }
        let store = self.store
        queue.async {
            do {
                try write(store)
            } catch {
                Self.log.error("History \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
