import Foundation

/// One replaceable background load whose result only counts while it is the newest (the review window's playback
/// audio, docs/meeting-design.md §5.10).
///
/// `start` cancels the load before it; `isLoading` is true from `start` until the newest load delivers its result,
/// failed or not, or `cancel` is called, so a failed load can be started again. A load that was replaced or cancelled
/// delivers nothing and changes nothing, even when it finishes later.
@MainActor public final class LatestLoad<Value> {
    public private(set) var isLoading = false
    private var task: Task<Void, Never>?
    private var generation = 0

    public init() {}

    /// Runs `operation` off the main actor and passes its result to `completion` on the main actor, unless another
    /// `start` or a `cancel` came first.
    public func start(_ operation: @escaping @Sendable () async throws -> sending Value,
                      completion: @escaping @MainActor (Result<Value, any Error>) -> Void) {
        cancel()
        let current = generation
        isLoading = true
        task = Task { [weak self] in
            let result: Result<Value, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == current else { return }
            self.task = nil
            self.isLoading = false
            completion(result)
        }
    }

    /// Cancels the running load; it delivers nothing.
    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
    }
}
