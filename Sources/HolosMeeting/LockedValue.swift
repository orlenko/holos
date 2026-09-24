import Synchronization

/// A small value shared between tasks and callbacks, guarded by a `Mutex`.
final class LockedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { value in body(&value) }
    }

    var value: Value { withLock { $0 } }
}
