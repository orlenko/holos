import Foundation
import Testing
@testable import HolosMeeting

/// `ReviewExportScheduler`: when the review rewrites a meeting's transcript files.
@MainActor
struct ReviewExportSchedulerTests {
    /// Pending from a change saved until the rewrite succeeds; a failure keeps it pending and says why; a writer that
    /// rewrote the files itself leaves nothing pending.
    @Test func pendingFromAChangeSavedUntilTheFilesAreWritten() {
        let scheduler = ReviewExportScheduler(delay: .seconds(60))
        scheduler.canRun = { false }
        #expect(!scheduler.pending && scheduler.problem == nil)
        scheduler.changesSaved(exportsWritten: false)
        #expect(scheduler.pending)
        scheduler.failed("Not written.")
        #expect(scheduler.pending && scheduler.problem == "Not written.")
        scheduler.regenerated()
        #expect(!scheduler.pending && scheduler.problem == nil)
        scheduler.schedule()
        scheduler.failed("Not written.")
        scheduler.changesSaved(exportsWritten: true)
        #expect(!scheduler.pending && scheduler.problem == nil)
        scheduler.schedule()
        scheduler.cancel()
        #expect(scheduler.pending, "Stopping the timer leaves the files pending.")
    }

    /// Scheduled while the review can run, the timer queues the rewrite after the delay; the files stay pending until
    /// the rewrite reports back.
    @Test(.timeLimit(.minutes(1))) func aTimerQueuesTheRewrite() async {
        let scheduler = ReviewExportScheduler(delay: .zero)
        let (fired, fire) = AsyncStream<Void>.makeStream()
        scheduler.fire = { fire.yield() }
        scheduler.schedule()
        // Replaced at once: still one timer.
        scheduler.schedule()
        var iterator = fired.makeAsyncIterator()
        await iterator.next()
        #expect(scheduler.pending)
    }
}
