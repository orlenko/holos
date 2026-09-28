import Foundation
import HolosCore
import os

/// The dictation history the app keeps (docs/design.md "Dictation history"): the records in memory for the History
/// section, and every file operation on one serial queue off the main actor (`DictationHistoryStore`), in the order
/// they were asked for. A change shows at once; a write that then fails is reported (`problem`, `onFailure`) and the
/// records are read again from the file, so what History shows never differs from what is kept. Quitting waits for
/// the queue (`flush`), so a dictation just recorded, deleted, or cleared reaches the file first. Nothing here logs
/// dictated text.
@MainActor
public final class DictationHistoryService {
    /// What `flush` found.
    public enum FlushResult: Sendable, Equatable {
        /// Every operation asked for finished and was written.
        case written
        /// Every operation finished, but at least one write failed since the last flush.
        case failed
        /// The time ran out with operations still queued or running.
        case timedOut
    }

    private nonisolated static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "history")
    public nonisolated let store: DictationHistoryStore
    private nonisolated let queue = DispatchQueue(label: "ca.orlenko.holos.history", qos: .utility)
    /// Whether a write failed since the last flush; read and written only on `queue`.
    private nonisolated let queueState = QueueState()
    private let defaults: UserDefaults
    /// Oldest first, as stored.
    public private(set) var records: [DictationRecord] = []
    /// Dictations a newer Voice is Local recorded in the file: not shown, but kept on this Mac until Clear History.
    public private(set) var newerLines = 0
    /// Everything the file keeps that Clear History deletes: `records` and `newerLines`.
    public var keptCount: Int { records.count + newerLines }
    /// The last read of the file failed: what it holds is unknown (it may still keep dictations), so Clear History
    /// and History Off's offer to clear stay available.
    public var unreadable: Bool { readProblem != nil }
    /// What is wrong with the history, as a sentence for the History section and the status (no dictated text): a
    /// write that failed (cleared once a write asked for after it succeeds), else a read that failed (cleared once a
    /// read succeeds).
    public var problem: String? { writeProblem ?? readProblem }
    private var writeProblem: String?
    private var readProblem: String?
    /// The generation of the change whose write failed (`writeProblem`).
    private var problemGeneration: Int?
    /// Bumped by every change made here.
    private var generation = 0
    /// The changes made while a reload reads the file, by generation: each reload applies the ones made after it
    /// was asked for to what it read, since the file may not have had them yet. Emptied when no reload is reading;
    /// a change whose write failed is taken out.
    private var journal: [(generation: Int, change: DictationHistoryChange)] = []
    private var loadsInFlight = 0
    /// Run once no reload is reading (`whenLoaded`).
    private var loadWaiters: [() -> Void] = []
    private var dailySweep: Task<Void, Never>?
    /// Called on the main actor whenever `records` or `problem` changed.
    public var onChange: (() -> Void)?
    /// Called on the main actor when a write failed, with `problem`.
    public var onFailure: ((String) -> Void)?

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

    /// Waits, at most `timeout` seconds, for every file operation asked for so far to finish. For quitting: a queued
    /// append, delete, or clear must reach the file before the process exits.
    public nonisolated func flush(timeout: TimeInterval) -> FlushResult {
        let done = DispatchSemaphore(value: 0)
        let state = queueState
        let outcome = FlushOutcome()
        queue.async {
            outcome.failed = state.takeFailure()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return .timedOut }
        return outcome.failed ? .failed : .written
    }

    /// Returns once every file operation asked for so far has finished.
    public func flushed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Runs `body` once no reload is reading the file (at once when none is), so `records`, `newerLines`, and
    /// `unreadable` say what the file holds: for a question about them (History Off offers to clear what is kept)
    /// asked before the launch load finished. A load that failed counts as finished; `unreadable` then says so.
    public func whenLoaded(_ body: @escaping () -> Void) {
        guard loadsInFlight > 0 else {
            body()
            return
        }
        loadWaiters.append(body)
    }

    /// Rereads the file (the command line may have cleared it). Changes made here while it reads are applied to
    /// what it read, never lost. The returned task ends once the records are updated.
    @discardableResult
    public func reload() -> Task<Void, Never> {
        let asked = generation
        loadsInFlight += 1
        let store = self.store
        let (stream, continuation) = AsyncStream.makeStream(of: LoadResult.self)
        // Queued now, so it reads the file after every operation asked for before it and before any asked after.
        queue.async {
            do {
                continuation.yield(.read(try store.load()))
            } catch {
                Self.log.error("Cannot read the history: \(error.localizedDescription, privacy: .public)")
                continuation.yield(.failed(error.localizedDescription))
            }
            continuation.finish()
        }
        return Task { [weak self] in
            var result = LoadResult.failed("The read did not finish.")
            for await value in stream { result = value }
            self?.loaded(result, asked: asked)
        }
    }

    private enum LoadResult: Sendable {
        case read(DictationHistoryStore.Contents)
        case failed(String)
    }

    private func loaded(_ result: LoadResult, asked: Int) {
        loadsInFlight -= 1
        let newer = journal.filter { $0.generation > asked }.map(\.change)
        switch result {
        case .read(let contents):
            var merged = contents.records
            for change in newer { change.apply(to: &merged) }
            records = merged
            // A clear asked for after this read also deletes the newer build's lines.
            newerLines = newer.contains(.clear) ? 0 : contents.newerLines
            readProblem = nil
            onChange?()
        case .failed(let error):
            // Not an empty history: what the file keeps is unknown, and the History section and status say so.
            let wasReadable = readProblem == nil
            readProblem = "History could not be read (\(error)); dictations may still be kept on this Mac. "
                + "Clear History deletes them."
            onChange?()
            if wasReadable, writeProblem == nil, let problem { onFailure?(problem) }
        }
        guard loadsInFlight == 0 else { return }
        journal.removeAll()
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter() }
    }

    /// Records a finished dictation, unless History is off.
    public func add(_ record: DictationRecord) {
        guard retention.records else { return }
        change(.add(record), failure: "This dictation could not be saved in History.") { try $0.append(record) }
    }

    public func delete(_ id: UUID) {
        change(.delete(id), failure: "The dictation could not be deleted; it is still kept on this Mac.") {
            try $0.delete(id: id)
        }
    }

    public func clear() {
        change(.clear, failure: "History could not be cleared; the dictations are still kept on this Mac.") {
            try $0.clear()
        }
    }

    /// Removes what the retention setting no longer keeps (and compacts the file), then reloads.
    public func sweep(now: Date = Date()) {
        let cutoff = retention.cutoff(now: now) ?? .distantPast
        change(.sweep(before: cutoff), failure: "Old dictations could not be removed from History.") {
            try $0.sweep(before: cutoff)
        }
        reload()
    }

    private func change(_ change: DictationHistoryChange, failure: String,
                        _ write: @escaping @Sendable (DictationHistoryStore) throws -> Void) {
        generation += 1
        let generation = self.generation
        if loadsInFlight > 0 { journal.append((generation, change)) }
        let before = (records, newerLines)
        change.apply(to: &records)
        if change == .clear { newerLines = 0 }
        if records != before.0 || newerLines != before.1 { onChange?() }
        let store = self.store
        let state = queueState
        queue.async { [weak self] in
            do {
                try write(store)
                Task { @MainActor in self?.writeSucceeded(generation: generation) }
            } catch {
                Self.log.error("History write failed: \(error.localizedDescription, privacy: .public)")
                state.noteFailure()
                let text = failure + " " + error.localizedDescription
                Task { @MainActor in self?.writeFailed(generation: generation, text) }
            }
        }
    }

    /// A write failed: the change it was for no longer counts, and the records are read again from the file, so a
    /// failed delete or clear shows its dictations again and a failed append is not shown as kept.
    private func writeFailed(generation: Int, _ text: String) {
        journal.removeAll { $0.generation == generation }
        writeProblem = text
        problemGeneration = generation
        onChange?()
        onFailure?(text)
        reload()
    }

    /// A write asked for after the one that failed has succeeded: the history works again, so the write problem
    /// clears.
    private func writeSucceeded(generation: Int) {
        guard let failed = problemGeneration, generation > failed else { return }
        writeProblem = nil
        problemGeneration = nil
        onChange?()
    }
}

/// `DictationHistoryService`'s state on its queue.
private final class QueueState: @unchecked Sendable {
    /// Only touched on the service's queue.
    private var failed = false

    func noteFailure() { failed = true }

    func takeFailure() -> Bool {
        defer { failed = false }
        return failed
    }
}

/// What a flush read on the queue; read by the waiting thread after the semaphore.
private final class FlushOutcome: @unchecked Sendable {
    var failed = false
}
