import Synchronization

/// A queue with one consumer task and any number of producers that never wait. Its capacity is measured by
/// `cost` (seconds of audio, or a count): a push that would exceed it is refused, except into an empty queue or with
/// `force`.
final class WorkQueue<Element: Sendable>: Sendable {
    private struct State {
        var items: [Element] = []
        var head = 0
        var load = 0.0
        var closed = false
    }

    private let capacity: Double
    private let cost: @Sendable (Element) -> Double
    private let state = Mutex(State())
    private let wake: AsyncStream<Void>.Continuation
    /// Only the one consumer waits on it, never from two tasks at once.
    private let wakeups: AsyncStream<Void>

    init(capacity: Double, cost: @escaping @Sendable (Element) -> Double) {
        self.capacity = capacity
        self.cost = cost
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeups = stream
        wake = continuation
    }

    /// False when the queue is closed, or full and not `force`d.
    @discardableResult
    func push(_ element: Element, force: Bool = false) -> Bool {
        let amount = cost(element)
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            if !force, state.load > 0, state.load + amount > capacity { return false }
            state.items.append(element)
            state.load += amount
            return true
        }
        if accepted { wake.yield() }
        return accepted
    }

    /// The next element; nil once the queue is closed and empty, or when the consuming task is cancelled.
    func next() async -> Element? {
        var wakeIterator = wakeups.makeAsyncIterator()
        while true {
            let taken = state.withLock { state -> (Element?, Bool) in
                guard state.head < state.items.count else {
                    state.items.removeAll(keepingCapacity: true)
                    state.head = 0
                    state.load = 0
                    return (nil, state.closed)
                }
                let element = state.items[state.head]
                state.head += 1
                state.load = max(0, state.load - cost(element))
                if state.head > 256, state.head * 2 > state.items.count {
                    state.items.removeFirst(state.head)
                    state.head = 0
                }
                return (element, false)
            }
            if let element = taken.0 { return element }
            if taken.1 { return nil }
            if await wakeIterator.next() == nil { return nil }
        }
    }

    /// No more pushes. With `discardingQueued`, elements still queued are dropped too.
    func close(discardingQueued: Bool = false) {
        state.withLock { state in
            state.closed = true
            if discardingQueued {
                state.items.removeAll()
                state.head = 0
                state.load = 0
            }
        }
        wake.yield()
    }

    /// The cost of the elements waiting.
    var load: Double { state.withLock { $0.load } }

    var isEmpty: Bool { state.withLock { $0.head >= $0.items.count } }

    var isClosed: Bool { state.withLock { $0.closed } }
}
