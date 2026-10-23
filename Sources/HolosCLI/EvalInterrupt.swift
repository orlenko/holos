import Foundation
import HolosCore
import HolosMeeting

/// Runs work so that Ctrl-C (or SIGTERM) cancels it, and a second one quits at once.
enum EvalInterrupt {
    nonisolated(unsafe) static var lastExitCode: Int32 = 130

    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let work = CancellableStart<T>()
        let interrupt = InterruptCancellation(notice: {
            Console.error("Stopping… (press Ctrl-C again to quit at once)")
        }) { work.cancel() }
        defer { interrupt.restore() }
        do {
            let value = try await work.start(operation).value
            // An interrupt that came while the work was finishing anyway still stops the command: a preparation
            // that returned is never followed by an upload after "Stopping…".
            if interrupt.signal != nil { throw CancellationError() }
            return value
        } catch {
            if let signal = interrupt.signal { lastExitCode = InterruptLatch.exitCode(for: signal) }
            throw error
        }
    }
}
