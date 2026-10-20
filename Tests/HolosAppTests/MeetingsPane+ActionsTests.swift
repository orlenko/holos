import AppKit
import HolosCore
import HolosMeeting
import HolosTestSupport
import Testing
@testable import HolosApp

@MainActor
struct MeetingsPaneActionsTests {
    @Test func startRecordingUsesTheInjectedMenuActionAndFollowsRecorderAvailability() throws {
        let temp = try TemporaryDirectory("meeting-start-action")
        defer { temp.remove() }
        let (window, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 601, height: 560), root: temp.url)
        var starts = 0
        pane.onStartRecording = { starts += 1 }
        let button = try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Start Recording…" })
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(starts == 1)
        pane.update(meetingState: MeetingRecordingControlsTests.active(.recording))
        #expect(!button.isEnabled)
        pane.startRecording()
        #expect(starts == 1, "An action arriving after recording starts is refused.")
        pane.update(meetingState: .idle)
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(starts == 2)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(MainWindowNarrowTests.brokenConstraints(in: pane.view).isEmpty)
    }

    @Test func anOpenMeetingKeepsItsAdvancedActionsWhenItsTitleLeavesTheSearch() throws {
        let temp = try TemporaryDirectory("meeting-menu-search")
        defer { temp.remove() }
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        var summary = SessionSummary(id: "generated-id", directory: temp.url, name: "First title", createdAt: .now,
                                     source: .system, state: .complete, manifestStatus: "complete", liveness: .exited)
        pane.show([summary], people: [:], freeBytes: nil)
        let search = try #require(pane.searchField)
        search.stringValue = "First"
        _ = NSApplication.shared.sendAction(try #require(search.action), to: search.target, from: search)
        pane.showLive(sessionID: summary.id, directory: temp.url)
        summary.name = "Second title"
        pane.show([summary], people: [:], freeBytes: nil)
        let menu = try #require(pane.advancedMenu(sessionID: summary.id))
        #expect(menu.items.contains { $0.title == "Clean Up" })
        #expect(menu.items.contains { $0.title == "Rename…" })
        #expect(pane.selectedSessionIDs == [summary.id])
        pane.showList()
    }
}
