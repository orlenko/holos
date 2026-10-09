import Synchronization

/// A small value shared between tasks and callbacks, guarded by a `Mutex`.
public final class LockedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    public init(_ value: Value) { mutex = Mutex(value) }

    public func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { value in body(&value) }
    }

    public var value: Value { withLock { $0 } }
}
