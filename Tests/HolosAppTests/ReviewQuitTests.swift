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

/// Closing a review window by hand with an edit typed in its field (`ReviewCloseGate`): the window stays open until
/// the edit is saved, and stays open with the field and why when the save fails (a full disk).
@MainActor
struct ReviewCloseGateTests {
    @Test func aFailedSaveOnCloseKeepsTheWindowOpenWithTheFieldAndWhy() async {
        let gate = ReviewCloseGate()
        let (stream, release) = AsyncStream<Void>.makeStream()
        var closed = 0
        var kept: [String] = []
        var saves = 0
        let save: () async -> String? = {
            saves += 1
            for await _ in stream {}
            return "The disk is full. What you typed: “Claude”."
        }
        // Nothing typed: the window closes at once.
        #expect(gate.shouldClose(typed: false, save: save, close: { closed += 1 }, keep: { kept.append($0) }))
        // Typed: not now; and asked again while it saves, still not (one save).
        #expect(!gate.shouldClose(typed: true, save: save, close: { closed += 1 }, keep: { kept.append($0) }))
        for _ in 0..<10_000 where saves == 0 { await Task.yield() }
        #expect(gate.saving)
        #expect(!gate.shouldClose(typed: false, save: save, close: { closed += 1 }, keep: { kept.append($0) }))
        release.finish()
        for _ in 0..<10_000 where gate.saving { await Task.yield() }
        // The save failed: the window stays, the field opens again with what was typed and why.
        #expect(!gate.saving && saves == 1 && closed == 0)
        #expect(kept == ["The disk is full. What you typed: “Claude”."])
    }

    @Test func aSavedEditOnCloseClosesTheWindowAfterIt() async {
        let gate = ReviewCloseGate()
        var closed = 0
        var kept: [String] = []
        #expect(!gate.shouldClose(typed: true, save: { nil }, close: { closed += 1 }, keep: { kept.append($0) }))
        for _ in 0..<10_000 where closed == 0 { await Task.yield() }
        #expect(closed == 1 && kept.isEmpty && !gate.saving)
    }
}
