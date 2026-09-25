import Foundation
import Testing

// The suite's waiters poll on a `PollBudget` rather than on a wall clock, because the suite starves the
// cooperative thread pool and a stalled poll says nothing about the work it is waiting for. What the budget must
// not do is outlive the test it belongs to: a cancelled `Task.sleep` returns at once, so a budget that charged
// what the sleep cost would spin on the condition until its hard deadline.

@Test(.timeLimit(.minutes(1))) @MainActor
func aCancelledPollBudgetStopsWaitingInsteadOfSpinning() async {
    // A budget long enough that spinning through it would take minutes, cancelled as soon as it is under way.
    let started = SharedValue(false)
    let polls = SharedValue(0)
    let elapsed = SharedValue(Duration.zero)
    let task = Task.detached {
        var budget = PollBudget(timeout: .seconds(300))
        let clock = ContinuousClock()
        let from = clock.now
        started.set(true)
        while !budget.isSpent {
            polls.update { $0 += 1 }
            await budget.poll()
        }
        elapsed.set(from.duration(to: clock.now))
    }
    #expect(await eventually(timeout: .seconds(10)) { started.value })
    task.cancel()
    await task.value
    #expect(elapsed.value < .seconds(60),
            "A cancelled wait ends; it does not spin to the hard deadline. Took \(elapsed.value).")
    #expect(polls.value < 100_000, "It stops polling rather than spinning on the condition. Polled \(polls.value).")
}
