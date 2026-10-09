import Foundation

/// How long an `eventually` loop may keep polling. `timeout` is a budget of *polling* time, not of wall-clock
/// time: when a 5 ms sleep returns far later than it asked for, the cooperative thread pool was starved, and the
/// work the condition is waiting for was stalled exactly as hard as the poll was. A stall costs the budget what the
/// poll asked for (at most four intervals), so the wait grows with the load instead of expiring under it;
/// `hardDeadline` still ends a wait for something that is never coming. A cancelled wait spends the whole budget:
/// a cancelled `Task.sleep` returns at once, and charging what it cost would leave the loop spinning.
public struct PollBudget: Sendable {
    public static let defaultInterval = Duration.milliseconds(5)

    private let clock = ContinuousClock()
    private let hardDeadline: ContinuousClock.Instant
    private let timeout: Duration
    private let interval: Duration
    private var spent = Duration.zero

    /// `interval` is how long each poll waits. A loop that samples something short-lived passes a finer one; it
    /// changes how often the condition is looked at, not how much load the budget tolerates.
    public init(timeout: Duration, interval: Duration = PollBudget.defaultInterval) {
        self.timeout = timeout
        self.interval = interval
        hardDeadline = ContinuousClock().now.advanced(by: max(timeout * 4, .seconds(60)))
    }

    public var isSpent: Bool { spent >= timeout || clock.now >= hardDeadline }

    /// Waits one interval and charges the budget for it, never more than four intervals of scheduling jitter.
    public mutating func poll() async {
        let before = clock.now
        do {
            try await Task.sleep(for: interval)
            spent += min(before.duration(to: clock.now), interval * 4)
        } catch {
            // Cancelled: swift-testing has given up on this test. The budget ends with the wait.
            spent = timeout
        }
    }
}

/// Polls `condition` every 5 ms, in the caller's isolation, until it holds or the poll budget runs out, and returns
/// its last value. The default budget is generous so a heavily loaded machine still passes; a condition that holds
/// returns at once, so only a failing test waits that long.
public func eventually(timeout: Duration = .seconds(30), isolation: isolated (any Actor)? = #isolation,
                       _ condition: () -> Bool) async -> Bool {
    var budget = PollBudget(timeout: timeout)
    while !budget.isSpent {
        if condition() { return true }
        await budget.poll()
    }
    return condition()
}
