import Foundation

/// Runs readings one at a time, in the order they were asked for (docs/design.md "Reading section"). Each is `work`
/// for its ID, run as a task on the main actor (the reading pipeline is main-actor isolated; speech synthesis and
/// encoding run off it). A reading can be stopped while it waits (it leaves the queue at once) or while it runs (its
/// task is cancelled; it ends as stopped once its work returns, unless it finished anyway).
@MainActor public final class ReadingWorkQueue {
    public enum Outcome: Sendable {
        case finished
        case failed(any Error)
        /// Stopped by `stop`, waiting or running.
        case stopped
    }

    public typealias Work = @MainActor (UUID) async throws -> Void

    public private(set) var pending: [UUID] = []
    public private(set) var running: UUID?
    /// Called when a reading starts, before its work.
    public var onStart: ((UUID) -> Void)?
    /// Called once for every reading that was queued, however it ended (never after `shutDown`).
    public var onEnd: ((UUID, Outcome) -> Void)?

    private let work: Work
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var shutting = false
    /// The reading that was running at `shutDown`: its end is never reported, and it can be queued again after
    /// `reopen` while it still unwinds.
    private var abandoned: UUID?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(work: @escaping Work) {
        self.work = work
    }

    public var isIdle: Bool { running == nil && pending.isEmpty }

    public func contains(_ id: UUID) -> Bool { (running == id && abandoned != id) || pending.contains(id) }

    /// Adds `id` after the others, and starts it when nothing runs. One already queued or running is left as it is.
    public func enqueue(_ id: UUID) {
        guard !shutting, !contains(id) else { return }
        pending.append(id)
        startNext()
    }

    /// Stops `id`: a waiting one leaves the queue (`onEnd` .stopped at once); a running one is cancelled (`onEnd`
    /// once its work returns). False when it is neither.
    @discardableResult public func stop(_ id: UUID) -> Bool {
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            onEnd?(id, .stopped)
            resumeIdleWaiters()
            return true
        }
        guard running == id else { return false }
        stopRequested = true
        task?.cancel()
        return true
    }

    /// Voice is Local is quitting: nothing more starts, the waiting readings are dropped, and the running one is
    /// cancelled, all without `onEnd` (the caller has saved what each becomes).
    public func shutDown() {
        shutting = true
        pending.removeAll()
        abandoned = running
        stopRequested = true
        task?.cancel()
        resumeIdleWaiters()
    }

    /// Takes readings again after `shutDown` (the quit was cancelled). The reading that was running may still be
    /// unwinding: the next one (it too, queued again) starts once it has.
    public func reopen() {
        shutting = false
    }

    /// Returns once nothing runs or waits.
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func startNext() {
        guard running == nil else { return }
        guard !shutting, !pending.isEmpty else {
            resumeIdleWaiters()
            return
        }
        let id = pending.removeFirst()
        running = id
        stopRequested = false
        onStart?(id)
        let work = self.work
        task = Task { [weak self] in
            var failure: (any Error)?
            do { try await work(id) } catch { failure = error }
            self?.finish(id, failure: failure)
        }
    }

    private func finish(_ id: UUID, failure: (any Error)?) {
        guard running == id else { return }
        // A reading that finished although it was asked to stop is finished: its file is there.
        let outcome: Outcome = failure == nil ? .finished : stopRequested ? .stopped : .failed(failure!)
        running = nil
        task = nil
        stopRequested = false
        let silent = shutting || abandoned == id
        if abandoned == id { abandoned = nil }
        if !silent { onEnd?(id, outcome) }
        startNext()
    }

    private func resumeIdleWaiters() {
        guard running == nil, pending.isEmpty || shutting else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
