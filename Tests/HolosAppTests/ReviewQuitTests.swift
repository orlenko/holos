import Foundation
import Testing
@testable import HolosApp

/// Quitting with review windows open (`ReviewQuit.closeAll`): every window starts closing, and so queues the edit its
/// open field holds, before any slow close is waited for.
@MainActor
struct ReviewQuitTests {
    /// A review window whose close waits for `gate` (a voice sync still running, say).
    private final class Review: ClosingReview {
        private(set) var started = false
        private let gate: AsyncStream<Void>?

        init(gate: AsyncStream<Void>? = nil) { self.gate = gate }

        func startClosing() { started = true }

        func closeAndWait() async {
            guard let gate else { return }
            for await _ in gate {}
        }
    }

    @Test func everyReviewStartsClosingBeforeASlowOneIsWaitedFor() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let slow = Review(gate: gate)
        let typed = Review()
        let quitting = Task { await ReviewQuit.closeAll([slow, typed], limit: .seconds(600)) }
        for _ in 0..<10_000 where !typed.started { await Task.yield() }
        // The slow window goes first and has not finished; the other's open edit was queued all the same.
        #expect(slow.started && typed.started)
        release.finish()
        #expect(await quitting.value)
    }

    @Test func aCloseThatCannotFinishLetsTheQuitGoOn() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let stuck = Review(gate: gate)
        #expect(await ReviewQuit.closeAll([stuck], limit: .milliseconds(1)) == false)
        #expect(stuck.started)
        release.finish()
    }
}
