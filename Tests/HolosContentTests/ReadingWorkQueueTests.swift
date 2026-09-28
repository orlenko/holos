import Foundation
import HolosCore
import Testing
@testable import HolosContent

/// Work that waits for the test: each reading's work starts, then waits until released (or cancelled).
@MainActor private final class Gates {
    private(set) var started: [UUID] = []
    private var permits: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var arrivals: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Readings whose work throws instead of finishing.
    var failing: Set<UUID> = []
    /// Readings whose work ignores cancellation and finishes once released.
    var stubborn: Set<UUID> = []

    func work(_ id: UUID) async throws {
        started.append(id)
        arrivals.removeValue(forKey: id)?.resume()
        if stubborn.contains(id) {
            try await withCheckedThrowingContinuation { permits[id] = $0 }
        } else {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { permits[id] = $0 }
            } onCancel: {
                Task { @MainActor in self.permits.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
            }
        }
        if failing.contains(id) { throw HolosError.io("Simulated failure of \(id).") }
    }

    func waitUntilStarted(_ id: UUID) async {
        if started.contains(id) { return }
        await withCheckedContinuation { arrivals[id] = $0 }
    }

    /// Lets `id`'s work return, once it is waiting.
    func release(_ id: UUID) async {
        await waitUntilStarted(id)
        while permits[id] == nil { await Task.yield() }
        permits.removeValue(forKey: id)?.resume()
    }
}

@MainActor @Suite struct ReadingWorkQueueTests {
    private func outcomeName(_ outcome: ReadingWorkQueue.Outcome) -> String {
        switch outcome {
        case .finished: "finished"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

    @Test func runsOneAtATimeInTheOrderAsked() async {
        let gates = Gates()
        let queue = ReadingWorkQueue { try await gates.work($0) }
        var ended: [(UUID, String)] = []
        queue.onEnd = { ended.append(($0, outcomeName($1))) }
        let (a, b, c) = (UUID(), UUID(), UUID())
        queue.enqueue(a)
        queue.enqueue(b)
        queue.enqueue(c)
        queue.enqueue(b)  // already waiting: ignored
        #expect(queue.running == a)
        #expect(queue.pending == [b, c])
        await gates.waitUntilStarted(a)
        #expect(gates.started == [a])
        await gates.release(a)
        await gates.release(b)
        await gates.release(c)
        await queue.waitUntilIdle()
        #expect(gates.started == [a, b, c])
        #expect(ended.map(\.0) == [a, b, c])
        #expect(ended.allSatisfy { $0.1 == "finished" })
        #expect(queue.isIdle)
    }

    @Test func stoppingAWaitingReadingTakesItOutAtOnce() async {
        let gates = Gates()
        let queue = ReadingWorkQueue { try await gates.work($0) }
        var ended: [(UUID, String)] = []
        queue.onEnd = { ended.append(($0, outcomeName($1))) }
        let (a, b, c) = (UUID(), UUID(), UUID())
        [a, b, c].forEach(queue.enqueue)
        #expect(queue.stop(b))
        #expect(queue.pending == [c])
        #expect(ended.map(\.0) == [b])
        #expect(ended.first?.1 == "stopped")
        #expect(!queue.stop(UUID()))
        await gates.release(a)
        await gates.release(c)
        await queue.waitUntilIdle()
        #expect(gates.started == [a, c])
    }

    @Test func stoppingTheRunningReadingCancelsItAndStartsTheNext() async {
        let gates = Gates()
        let queue = ReadingWorkQueue { try await gates.work($0) }
        var ended: [(UUID, String)] = []
        queue.onEnd = { ended.append(($0, outcomeName($1))) }
        let (a, b) = (UUID(), UUID())
        queue.enqueue(a)
        queue.enqueue(b)
        await gates.waitUntilStarted(a)
        #expect(queue.stop(a))
        await gates.waitUntilStarted(b)
        #expect(ended.map(\.0) == [a])
        #expect(ended.first?.1 == "stopped")
        #expect(queue.running == b)
        await gates.release(b)
        await queue.waitUntilIdle()
        #expect(ended.map(\.1) == ["stopped", "finished"])
    }

    @Test func aReadingThatFinishesAfterStopIsFinished() async {
        let gates = Gates()
        let queue = ReadingWorkQueue { try await gates.work($0) }
        var ended: [String] = []
        queue.onEnd = { ended.append(outcomeName($1)) }
        let a = UUID()
        gates.stubborn = [a]
        queue.enqueue(a)
        await gates.waitUntilStarted(a)
        queue.stop(a)
        await gates.release(a)
        await queue.waitUntilIdle()
        #expect(ended == ["finished"])
    }

    @Test func aFailureIsReportedAndTheNextStarts() async {
        let gates = Gates()
        let queue = ReadingWorkQueue { try await gates.work($0) }
        var ended: [(UUID, String)] = []
        queue.onEnd = { ended.append(($0, outcomeName($1))) }
        let (a, b) = (UUID(), UUID())
        gates.failing = [a]
        queue.enqueue(a)
        queue.enqueue(b)
        await gates.release(a)
        await gates.release(b)
        await queue.waitUntilIdle()
        #expect(ended.map(\.0) == [a, b])
        #expect(ended.map(\.1) == ["failed", "finished"])
    }

    @Test func shutDownDropsTheQueueWithoutCallbacksAndReopenTakesReadingsAgain() async {
        let gates = Gates()
        let queue = ReadingWorkQueue { try await gates.work($0) }
        var ended: [UUID] = []
        var startedIDs: [UUID] = []
        queue.onEnd = { id, _ in ended.append(id) }
        queue.onStart = { startedIDs.append($0) }
        let (a, b) = (UUID(), UUID())
        queue.enqueue(a)
        queue.enqueue(b)
        await gates.waitUntilStarted(a)
        queue.shutDown()
        #expect(queue.pending.isEmpty)
        queue.enqueue(UUID())  // refused while shutting down
        await queue.waitUntilIdle()
        #expect(ended.isEmpty)
        #expect(startedIDs == [a])

        queue.reopen()
        queue.enqueue(b)
        await gates.release(b)
        await queue.waitUntilIdle()
        #expect(ended == [b])
        #expect(startedIDs == [a, b])
    }

    /// Queued again after a cancelled quit and stopped while its old run still unwinds: the stop is reported only once
    /// that run has ended (a deletion must not remove files it may still write), and it does not run again.
    @Test func stoppingAReadingQueuedBehindItsOwnAbandonedRunWaitsForThatRun() async {
        let gates = Gates()
        let queue = ReadingWorkQueue { try await gates.work($0) }
        var events: [String] = []
        queue.onEnd = { _, outcome in events.append("end " + outcomeName(outcome)) }
        queue.onAbandonedEnd = { _ in events.append("abandoned end") }
        let a = UUID()
        queue.enqueue(a)
        await gates.waitUntilStarted(a)
        queue.shutDown()
        queue.reopen()
        queue.enqueue(a)
        #expect(queue.stop(a))
        #expect(events.isEmpty)
        #expect(queue.pending.isEmpty)
        await queue.waitUntilIdle()
        #expect(events == ["abandoned end", "end stopped"])
        #expect(gates.started == [a])
    }

    /// The quit is cancelled while the reading it stopped still unwinds: queued again, it runs again once that run
    /// has ended, and only its second run is reported.
    @Test func aReadingStoppedByAQuitThatWasCancelledRunsAgain() async {
        let gates = Gates()
        let queue = ReadingWorkQueue { try await gates.work($0) }
        var ended: [(UUID, String)] = []
        var startedIDs: [UUID] = []
        var abandonedEnds: [UUID] = []
        queue.onEnd = { ended.append(($0, outcomeName($1))) }
        queue.onStart = { startedIDs.append($0) }
        queue.onAbandonedEnd = { abandonedEnds.append($0) }
        let a = UUID()
        queue.enqueue(a)
        await gates.waitUntilStarted(a)
        queue.shutDown()
        queue.reopen()
        #expect(!queue.contains(a))
        queue.enqueue(a)
        #expect(queue.pending == [a])
        while startedIDs.count < 2 { await Task.yield() }
        await gates.release(a)
        await queue.waitUntilIdle()
        #expect(startedIDs == [a, a])
        #expect(ended.map(\.0) == [a])
        #expect(ended.first?.1 == "finished")
        // The first run's end went to `onAbandonedEnd` (the controller finishes a deletion that waited for it).
        #expect(abandonedEnds == [a])
    }

    /// The run a quit stopped finishes anyway (its file is made) after the quit was cancelled and the reading queued
    /// again: the queued run never starts (it would make the reading again, from text its success removed), and the
    /// reading ends finished. Stopped while it waited behind that run, it ends finished too.
    @Test func aReadingWhoseAbandonedRunFinishesIsNotMadeAgain() async {
        for stopWhileWaiting in [false, true] {
            let gates = Gates()
            let queue = ReadingWorkQueue { try await gates.work($0) }
            var ended: [(UUID, String)] = []
            var startedIDs: [UUID] = []
            var abandonedEnds: [UUID] = []
            queue.onEnd = { ended.append(($0, outcomeName($1))) }
            queue.onStart = { startedIDs.append($0) }
            queue.onAbandonedEnd = { abandonedEnds.append($0) }
            let (a, b) = (UUID(), UUID())
            gates.stubborn = [a]
            queue.enqueue(a)
            await gates.waitUntilStarted(a)
            queue.shutDown()
            queue.reopen()
            queue.enqueue(a)
            queue.enqueue(b)
            if stopWhileWaiting { #expect(queue.stop(a)) }
            await gates.release(a)
            await gates.release(b)
            await queue.waitUntilIdle()
            #expect(startedIDs == [a, b])
            #expect(gates.started == [a, b])
            #expect(abandonedEnds == [a])
            #expect(ended.map(\.0) == [a, b])
            #expect(ended.map(\.1) == ["finished", "finished"])
        }
    }
}
