import Foundation
import Synchronization

/// Limits on the platform awaits of the stop path (docs/meeting-design.md §4.6), so a hung capture stop or speech
/// finish never keeps a recording from being saved.
public struct StopTimeouts: Sendable, Equatable {
    /// Stopping capture: 5 s.
    public var captureStop: Duration
    /// Finishing a live speech session: this base…
    public var speechFinishBase: Duration
    /// …plus this many seconds per second of audio the session was fed (0.05).
    public var speechFinishPerAudioSecond: Double

    public init(captureStop: Duration = .seconds(5), speechFinishBase: Duration = .seconds(30),
                speechFinishPerAudioSecond: Double = 0.05) {
        self.captureStop = captureStop; self.speechFinishBase = speechFinishBase
        self.speechFinishPerAudioSecond = speechFinishPerAudioSecond
    }

    public static let standard = StopTimeouts()

    /// The time allowed to finish a speech session that was fed `audioSeconds` of audio.
    public func speechFinish(audioSeconds: Double) -> Duration {
        let extra = audioSeconds.isFinite ? max(0, audioSeconds) * max(0, speechFinishPerAudioSecond) : 0
        return speechFinishBase + .milliseconds(Int64(min(extra, 86_400) * 1_000))
    }
}

/// How an operation run with `awaitWithTimeout` ended.
enum TimedOutcome<Value: Sendable>: Sendable {
    case finished(Result<Value, Error>)
    /// The limit passed first; the operation's task was cancelled and abandoned.
    case timedOut
    /// The waiting task was cancelled first; the operation's task was cancelled and abandoned.
    case cancelled
}

/// Runs `operation` in its own task and waits at most `limit` for it. On a timeout, or (when `cancellable`) when the
/// waiting task is cancelled, it stops waiting at once: the operation's task is cancelled and abandoned, even if it
/// never returns (a hung platform call). With `cancellable: false` a cancelled caller still waits up to `limit`, for
/// work that must finish either way, such as stopping capture.
///
/// With `deadline`, the wait also times out once that deadline passes, including a deadline set after the wait began.
///
/// An operation that makes something the caller must release (a speech session, say) passes `discardingLate`: when
/// the operation still succeeds after the wait gave up on it (a platform call that ignores cancellation), its value
/// goes to `discardingLate` instead of being dropped, so it is cancelled or closed rather than left running.
func awaitWithTimeout<Value: Sendable>(_ limit: Duration, cancellable: Bool = true, deadline: SharedDeadline? = nil,
                                       discardingLate: (@Sendable (Value) async -> Void)? = nil,
                                       _ operation: @escaping @Sendable () async throws -> Value) async
    -> TimedOutcome<Value> {
    let gate = OutcomeGate<Value>()
    let work = Task {
        do {
            let value = try await operation()
            if !gate.resolve(.finished(.success(value))), let discardingLate { await discardingLate(value) }
        } catch { gate.resolve(.finished(.failure(error))) }
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        gate.resolve(.timedOut)
    }
    let cutoff = deadline.map { deadline in
        Task {
            await deadline.wait()
            if !Task.isCancelled { gate.resolve(.timedOut) }
        }
    }
    let outcome = await withTaskCancellationHandler {
        await gate.wait()
    } onCancel: {
        if cancellable { gate.resolve(.cancelled) }
    }
    timer.cancel()
    cutoff?.cancel()
    if case .finished = outcome {} else { work.cancel() }
    return outcome
}

/// Waits for `task` at most `limit` and returns whether it finished in time. When the limit passes first, it returns
/// at once without awaiting the task any further; the task itself is not cancelled and keeps running (review windows
/// still saving when Holos quits, for example, go on until the process ends).
public func waitAtMost(_ limit: Duration, for task: Task<Void, Never>) async -> Bool {
    if case .finished = await awaitWithTimeout(limit, cancellable: false, { await task.value }) { return true }
    return false
}

/// A deadline that may be set after the waits it limits have begun: the stop deadline of a live track's `finish()`,
/// which also cuts short the session finishes already running (docs/meeting-design.md §4.6).
final class SharedDeadline: Sendable {
    private struct State {
        var instant: ContinuousClock.Instant?
        var waiters: [Int: CheckedContinuation<ContinuousClock.Instant?, Never>] = [:]
        /// Waits cancelled before they registered.
        var cancelled: Set<Int> = []
        var nextID = 0
    }

    private let state = Mutex(State())

    init() {}

    var instant: ContinuousClock.Instant? { state.withLock { $0.instant } }

    /// Sets the deadline and wakes every wait. Only the first call counts.
    func set(_ instant: ContinuousClock.Instant) {
        let waiters = state.withLock { state -> [CheckedContinuation<ContinuousClock.Instant?, Never>] in
            guard state.instant == nil else { return [] }
            state.instant = instant
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: instant) }
    }

    /// Returns once the deadline is set and has passed, or as soon as the calling task is cancelled.
    func wait() async {
        guard let instant = await whenSet(), !Task.isCancelled else { return }
        try? await Task.sleep(until: instant, clock: .continuous)
    }

    /// The deadline once it is set; nil when the calling task is cancelled first.
    private func whenSet() async -> ContinuousClock.Instant? {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ContinuousClock.Instant?, Never>) in
                let ready = state.withLock { state -> ContinuousClock.Instant?? in
                    if state.cancelled.remove(id) != nil { return .some(nil) }
                    if let instant = state.instant { return .some(instant) }
                    state.waiters[id] = continuation
                    return .none
                }
                if case .some(let instant) = ready { continuation.resume(returning: instant) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<ContinuousClock.Instant?, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                // Not registered yet; once the deadline is set, registering returns at once anyway.
                if state.instant == nil { state.cancelled.insert(id) }
                return nil
            }
            waiter?.resume(returning: nil)
        }
    }
}

/// The first outcome wins; `wait()` returns it.
private final class OutcomeGate<Value: Sendable>: Sendable {
    private struct State {
        var outcome: TimedOutcome<Value>?
        var waiter: CheckedContinuation<TimedOutcome<Value>, Never>?
    }

    private let state = Mutex(State())

    /// True when `outcome` is the first, so `wait()` returns it.
    @discardableResult
    func resolve(_ outcome: TimedOutcome<Value>) -> Bool {
        let (first, waiter) = state.withLock { state -> (Bool, CheckedContinuation<TimedOutcome<Value>, Never>?) in
            guard state.outcome == nil else { return (false, nil) }
            state.outcome = outcome
            defer { state.waiter = nil }
            return (true, state.waiter)
        }
        waiter?.resume(returning: outcome)
        return first
    }

    func wait() async -> TimedOutcome<Value> {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> TimedOutcome<Value>? in
                if let outcome = state.outcome { return outcome }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
