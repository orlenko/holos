import AppKit
import HolosCore
@testable import HolosMeeting
import HolosTestSupport
import Testing
@testable import HolosApp

@MainActor
struct ReviewWindowEmbeddingTests {
    @Test(.timeLimit(.minutes(1)), arguments: [NSSize(width: 601, height: 560), NSSize(width: 1280, height: 800)])
    func theReviewStaysInsideTheMeetingAndBackSavesAndReturnsToTheList(size: NSSize) async throws {
        let temp = try TemporaryDirectory("inline-review")
        defer { temp.remove() }
        let (review, session) = try await ReviewWindowJoinTests().open(
            [.init(speaker: "system:S1", start: 0, words: ["Generated", "sample", "words."])], root: temp.url)
        let (host, pane) = try LiveMeetingViewTests.meetings(size: size, root: temp.url)
        let id = review.sessionID
        let summary = SessionSummary(id: id, directory: session, name: "Generated meeting", createdAt: .now,
                                     source: .system, state: .complete, manifestStatus: "complete",
                                     speakerState: .labelled, runID: review.review.projection.runID, liveness: .exited)
        pane.show([summary], people: [:], freeBytes: nil)
        pane.showLive(sessionID: id, directory: session)
        #expect(pane.installReview(review))
        host.contentView?.layoutSubtreeIfNeeded()
        #expect(await eventually {
            host.contentView?.layoutSubtreeIfNeeded()
            let cell = review.turnList.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            return (cell?.frame.width ?? .infinity) <= review.turnList.bounds.width + 1
        })
        #expect(review.window === host)
        #expect(review.turnList.table.window === host)
        #expect(!review.surface.ownedWindow.isVisible)
        #expect(review.turnList.table.enclosingScrollView?.frame.height ?? 0 >= 180)
        #expect(review.turnList.table.tableColumns.first?.width ?? 0 <= review.turnList.bounds.width + 1)
        SettingsEmbeddingTests.render(host, name: "inline-review-\(Int(size.width))")
        review.setEditMode(true)
        review.turnList.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        review.turnList.editField.stringValue = "Edited"
        pane.showList()
        #expect(pane.activeMeetingID == id, "Back waits while the typed correction saves.")
        #expect(await eventually { pane.selectedSessionIDs == [id] })
        await review.closeAndWait()
        #expect(pane.activeMeetingID == nil)
        #expect(pane.selectedSessionIDs == [id])
        #expect(review.review.words(of: "T1").first?.shown == "Edited")
    }

    @Test(.timeLimit(.minutes(1)))
    func aReviewWhoseSectionIsDetachedCanRetryWhenItReturns() async throws {
        let temp = try TemporaryDirectory("review-return")
        defer { temp.remove() }
        let (review, session) = try await ReviewWindowJoinTests().open(
            [.init(speaker: "system:S1", start: 0, words: ["Generated", "words."])], root: temp.url)
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        pane.showLive(sessionID: review.sessionID, directory: session)
        pane.view.removeFromSuperview()
        pane.live?.contentState.requestedReview = true
        #expect(!pane.installReview(review))
        #expect(pane.live?.contentState.requestedReview == false)
        let returned = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                                styleMask: [.titled], backing: .buffered, defer: true)
        returned.contentView = pane.view
        #expect(pane.installReview(review))
        #expect(review.window === returned)
        pane.showList()
        await review.closeAndWait()
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeferredCloseUsesTheReviewHostWhenItsSectionIsHidden() async throws {
        let temp = try TemporaryDirectory("review-hidden-close")
        defer { temp.remove() }
        let (review, session) = try await ReviewWindowJoinTests().open(
            [.init(speaker: "system:S1", start: 0, words: ["Generated", "words."])], root: temp.url)
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        let host = ClosingHost(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                               styleMask: [.titled], backing: .buffered, defer: true)
        host.contentView = pane.view
        pane.showLive(sessionID: review.sessionID, directory: session)
        #expect(pane.installReview(review))
        let (stream, release) = AsyncStream<Void>.makeStream()
        review.review.beforeEdit = { for await _ in stream {} }
        review.setEditMode(true)
        review.turnList.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        review.turnList.editField.stringValue = "Edited"
        host.contentView = NSView()
        #expect(pane.view.window == nil)
        #expect(!pane.sectionShouldClose())
        #expect(host.closeRequests == 0)
        release.finish()
        #expect(await eventually { host.closeRequests == 1 })
        await review.closeAndWait()
        #expect(review.review.words(of: "T1").first?.shown == "Edited")
    }

    @Test(.timeLimit(.minutes(1)))
    func theMainWindowRoutesRestoreDeletedWordsAndValidatesItsCurrentMeeting() async throws {
        let temp = try TemporaryDirectory("review-restore-menu")
        defer { temp.remove() }
        let (review, session) = try await ReviewWindowJoinTests().open(
            [.init(speaker: "system:S1", start: 0, words: ["Generated", "words."])], root: temp.url)
        let (host, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        let controller = try #require(host.delegate as? MainWindowController)
        pane.showLive(sessionID: review.sessionID, directory: session)
        #expect(pane.installReview(review))
        let words = review.review.words(of: "T1")
        #expect(!words.isEmpty)
        _ = try await review.review.editWords(words.map(\.ref), to: "", seen: review.review.revision)
        let ready = await eventually { !review.restorableDeletedWords.isEmpty }
        try #require(ready)
        var offered: NSMenu?
        review.openRestoreMenu = { menu, _ in offered = menu }
        let item = NSMenuItem(title: "Restore Deleted Words…",
                              action: #selector(MainWindowController.restoreDeletedWords(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(item))
        controller.restoreDeletedWords(item)
        #expect(offered?.items.count == 1)
        controller.select(.settings)
        #expect(!controller.validateMenuItem(item))
        review.startClosing()
        await review.closeAndWait()
    }

    private final class ClosingHost: NSWindow {
        var closeRequests = 0
        override func performClose(_ sender: Any?) { closeRequests += 1 }
    }

}
