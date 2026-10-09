import Foundation

extension SessionArchive {
    /// Runs `body` with the session's archive open for maintenance (`openForMaintenance(at:lease:)`: the caller's
    /// lease, the writer lock taken with a 1 s retry), then releases the writer lock (`releaseLock()`) on every way
    /// out: a return, a throw, or a cancellation the body throws. Opening it can throw; then `body` does not run and
    /// there is nothing to release. The lock is held for the body only, so the scope ends where the lock must be let
    /// go; a caller that must release it earlier ends the scope there.
    public nonisolated static func withMaintenanceArchive<T>(at directory: URL, lease: ProcessingLease,
                                                             _ body: (SessionArchive) async throws -> T)
        async throws -> T {
        let archive = try openForMaintenance(at: directory, lease: lease)
        // Swift 6.2 (the package's tools version) cannot await in a `defer`, so both exits release it explicitly.
        let value: T
        do {
            value = try await body(archive)
        } catch {
            await archive.releaseLock()
            throw error
        }
        await archive.releaseLock()
        return value
    }
}
