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
func awaitWithTimeout<Value: Sendable>(_ limit: Duration, cancellable: Bool = true,
                                       _ operation: @escaping @Sendable () async throws -> Value) async
    -> TimedOutcome<Value> {
    let gate = OutcomeGate<Value>()
    let work = Task {
        do { gate.resolve(.finished(.success(try await operation()))) }
        catch { gate.resolve(.finished(.failure(error))) }
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        gate.resolve(.timedOut)
    }
    let outcome = await withTaskCancellationHandler {
        await gate.wait()
    } onCancel: {
        if cancellable { gate.resolve(.cancelled) }
    }
    timer.cancel()
    if case .finished = outcome {} else { work.cancel() }
    return outcome
}

/// The first outcome wins; `wait()` returns it.
private final class OutcomeGate<Value: Sendable>: Sendable {
    private struct State {
        var outcome: TimedOutcome<Value>?
        var waiter: CheckedContinuation<TimedOutcome<Value>, Never>?
    }

    private let state = Mutex(State())

    func resolve(_ outcome: TimedOutcome<Value>) {
        let waiter = state.withLock { state -> CheckedContinuation<TimedOutcome<Value>, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: outcome)
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
