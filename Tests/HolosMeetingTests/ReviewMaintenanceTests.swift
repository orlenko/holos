import Foundation
@testable import HolosMeeting
import Testing

// What a review window does while maintenance works on its meeting, the transcript files still to rewrite, and the
// waits behind them (docs/meeting-design.md §5.10, PR9).

@Test func maintenanceClosesReviewsOnlyForDeletingTheMeeting() {
    let responses = Dictionary(uniqueKeysWithValues: ReviewMaintenance.Command.allCases.map {
        ($0, ReviewMaintenance.response(to: $0))
    })
    #expect(responses[.deleteMeeting] == .close)
    #expect(responses[.cleanUp] == .unaffected, "Clean Up removes only derived/ renders, which a review never reads.")
    for command in [ReviewMaintenance.Command.recover, .labelSpeakers, .deleteAudio, .automaticRelabel] {
        guard case .readOnly(let banner)? = responses[command] else {
            Issue.record("\(command) must make the review read-only")
            continue
        }
        #expect(!banner.isEmpty)
    }
    // Every run holds a review separately, even two runs of the same command.
    let first = ReviewMaintenance.Hold(.labelSpeakers)
    #expect(first == first)
    #expect(first != ReviewMaintenance.Hold(.labelSpeakers))
    #expect(first.command == .labelSpeakers)
}

@Test func meetingsWithReviewsAreInUse() {
    let inUse = ReviewMaintenance.sessionsInUse(commands: ["A"], reviews: ["B", "C", "A"])
    #expect(inUse == ["A", "B", "C"])
    #expect(ReviewMaintenance.sessionsInUse(commands: [String](), reviews: [String]()).isEmpty)
}

@Test func pendingExportsAreKeptPerMeeting() throws {
    let suite = "holos-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let pending = PendingExports(defaults: defaults)
    #expect(pending.sessionIDs.isEmpty)
    pending.mark("A")
    pending.mark("B")
    pending.mark("A")
    #expect(pending.sessionIDs == ["A", "B"])
    #expect(PendingExports(defaults: defaults).contains("A"), "Kept for the next launch.")
    pending.clear("A")
    #expect(!pending.contains("A"))
    pending.clear("B")
    #expect(defaults.object(forKey: PendingExports.key) == nil)
}

@Test(.timeLimit(.minutes(1))) func waitAtMostReturnsWithoutAwaitingWorkThatHangs() async {
    let (stream, release) = AsyncStream<Void>.makeStream()
    defer { release.finish() }
    // A save that never finishes, and that ignores cancellation.
    let hung = Task { for await _ in stream {} }
    // Returning at all is the proof that the hung work was not awaited, and `.timeLimit` above is what enforces
    // it: had `waitAtMost` awaited the task, this call would never return and the test would fail there. A
    // wall-clock bound here measured the machine instead -- the suite starves the cooperative pool badly enough
    // that a 5 ms sleep has been seen returning after 35 s, and this failed on 2 of 3 full runs.
    #expect(!(await waitAtMost(.milliseconds(100), for: hung)))
    #expect(!hung.isCancelled, "The losing work is left running, not cancelled.")

    let quick = Task {}
    #expect(await waitAtMost(.seconds(30), for: quick))
}

@Test(.timeLimit(.minutes(1))) @MainActor func latestLoadDeliversOnlyTheNewestAndCanRetry() async {
    let load = LatestLoad<Int>()
    var results: [String] = []

    // A failed load ends: `isLoading` is false again, so the caller can try again.
    load.start({ throw CancellationError() }) { result in
        results.append((try? result.get()).map(String.init) ?? "failed")
    }
    #expect(load.isLoading)
    #expect(await eventually { !load.isLoading })
    #expect(results == ["failed"])

    // A slow load replaced by a newer one delivers nothing.
    let (stream, release) = AsyncStream<Void>.makeStream()
    load.start({
        for await _ in stream {}
        return 1
    }) { result in results.append((try? result.get()).map(String.init) ?? "failed") }
    load.start({ 2 }) { result in results.append((try? result.get()).map(String.init) ?? "failed") }
    #expect(await eventually { !load.isLoading })
    release.finish()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(results == ["failed", "2"])

    // A cancelled load delivers nothing either.
    load.start({
        try await Task.sleep(for: .seconds(30))
        return 3
    }) { result in results.append((try? result.get()).map(String.init) ?? "failed") }
    load.cancel()
    #expect(!load.isLoading)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(results == ["failed", "2"])
}
