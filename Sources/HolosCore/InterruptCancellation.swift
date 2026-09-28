import Darwin
import Dispatch
import Synchronization

/// What the first SIGINT or SIGTERM does: runs `cancel` once and remembers which signal it was.
/// Kept apart from the signal sources so the cancel path can be tested without delivering signals.
public final class InterruptLatch: Sendable {
    private let fired = Mutex<Int32?>(nil)
    private let cancel: @Sendable () -> Void

    public init(cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
    }

    /// The signal that arrived first, or nil when none has.
    public var signal: Int32? { fired.withLock { $0 } }

    /// The exit status for a process ended by `signal` (130 for SIGINT, 143 for SIGTERM).
    public static func exitCode(for signal: Int32) -> Int32 { 128 + signal }

    /// Records `signal`, then runs `before` and `cancel`, the first time only. Returns whether this
    /// was the first.
    @discardableResult public func fire(_ signal: Int32, before: () -> Void = {}) -> Bool {
        let first = fired.withLock { value -> Bool in
            guard value == nil else { return false }
            value = signal
            return true
        }
        guard first else { return false }
        before()
        cancel()
        return true
    }
}

/// While it exists, SIGINT and SIGTERM fire `latch` once instead of ending the process; after that
/// first signal (or `restore()`) they end it as usual, so a second Ctrl-C quits at once.
public final class InterruptCancellation: Sendable {
    public let latch: InterruptLatch
    private let sources: [any DispatchSourceSignal]

    /// `notice` runs on the first signal, before `cancel`.
    public init(notice: @escaping @Sendable () -> Void = {}, cancel: @escaping @Sendable () -> Void) {
        let latch = InterruptLatch(cancel: cancel)
        self.latch = latch
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                latch.fire(number) {
                    notice()
                    Darwin.signal(SIGINT, SIG_DFL)
                    Darwin.signal(SIGTERM, SIG_DFL)
                }
            }
            source.resume()
            return source
        }
    }

    /// The signal that cancelled the work, or nil.
    public var signal: Int32? { latch.signal }

    public func restore() {
        for source in sources { source.cancel() }
        Darwin.signal(SIGINT, SIG_DFL)
        Darwin.signal(SIGTERM, SIG_DFL)
    }

    deinit { for source in sources { source.cancel() } }
}
