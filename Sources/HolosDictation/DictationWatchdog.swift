import Foundation

/// The one timeout `DictationController` runs at a time: startup (until listening) or finalization (after release).
///
/// Invariants:
/// 1. At most one timeout is pending: starting one cancels the one before, and `cancel` cancels it.
/// 2. A cancelled timeout never calls its handler, even when its sleep returns anyway (a cancelled sleep can still
///    return, as a platform callback can).
/// 3. A handler that does run may still be late; it checks that its utterance is still in the timed phase
///    (`DictationController` invariant 2).
@MainActor
final class DictationWatchdog {
    private let startupTimeout: TimeInterval
    private let finalizationTimeout: TimeInterval
    private let sleep: @MainActor (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    /// A timeout that is not finite and positive falls back to its default (120 s startup, 30 s finalization).
    init(startupTimeout: TimeInterval, finalizationTimeout: TimeInterval,
         sleep: @escaping @MainActor (Duration) async throws -> Void) {
        self.startupTimeout = startupTimeout.isFinite && startupTimeout > 0 ? startupTimeout : 120
        self.finalizationTimeout = finalizationTimeout.isFinite && finalizationTimeout > 0 ? finalizationTimeout : 30
        self.sleep = sleep
    }

    func startStartup(_ fire: @escaping @MainActor () -> Void) { start(startupTimeout, fire) }

    func startFinalization(_ fire: @escaping @MainActor () -> Void) { start(finalizationTimeout, fire) }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func start(_ timeout: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        task?.cancel()  // invariant 1
        let sleep = sleep
        task = Task {
            try? await sleep(.seconds(timeout))
            guard !Task.isCancelled else { return }  // invariant 2
            fire()
        }
    }
}
