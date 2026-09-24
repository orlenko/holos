import Synchronization

/// A task that can be cancelled before it exists. A command installs its interrupt handling with `cancel` as the
/// action first, then calls `start`: a signal that arrives in between is never lost, because a `start` after `cancel`
/// begins the work already cancelled and runs none of it (`holos session import`).
public final class CancellableStart<Success: Sendable>: Sendable {
    private struct State {
        var task: Task<Success, any Error>?
        var cancelled = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Cancels the task `start` made, or the one it will make.
    public func cancel() {
        let task = state.withLock { state -> Task<Success, any Error>? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }

    /// Starts `operation` in a new task, once. After `cancel`, the task is cancelled from the start and throws
    /// `CancellationError` without running `operation`.
    public func start(_ operation: @escaping @Sendable () async throws -> Success) -> Task<Success, any Error> {
        state.withLock { state in
            precondition(state.task == nil, "start is called once")
            let cancelledBefore = state.cancelled
            let task = Task {
                if cancelledBefore { throw CancellationError() }
                return try await operation()
            }
            if cancelledBefore { task.cancel() }
            state.task = task
            return task
        }
    }
}
