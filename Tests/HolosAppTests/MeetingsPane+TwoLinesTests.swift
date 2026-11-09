import AppKit
import HolosCore
import HolosMeeting
import HolosTestSupport
import Testing
@testable import HolosApp

/// The Meetings list beside a call's window: each meeting on two lines, with its start time, and back to one line
/// when the window widens. Invented meetings.
@MainActor
struct MeetingsPaneTwoLinesTests {
    private static func meeting(_ id: String, in root: URL) throws -> SessionSummary {
        let directory = root.appendingPathComponent("\(id).holos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionSummary(id: id, directory: directory, name: "Planning \(id)",
                              createdAt: Date().addingTimeInterval(-3600), source: .system, state: .complete,
                              manifestStatus: "complete", savedSeconds: 600, chunkCount: 3, transcriptID: "t",
                              speakerState: .labelled, liveness: .exited)
    }

    /// The visible text of the meeting's cell in `kind`'s column.
    private static func shownText(_ pane: MeetingsPane, _ id: String,
                                  in kind: MeetingGridColumn = .name) throws -> [String] {
        let row = try #require(pane.rowIndex(of: id))
        let column = try #require(pane.table.tableColumns.firstIndex { MeetingGridColumn($0) == kind })
        let cell = try #require(pane.table.view(atColumn: column, row: row, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        return MainWindowNarrowTests.allViews(cell).compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }.map(\.stringValue)
    }

    private static func hidden(_ pane: MeetingsPane, _ kind: MeetingGridColumn) -> Bool? {
        pane.table.tableColumns.first { MeetingGridColumn($0) == kind }?.isHidden
    }

    @Test func aNarrowListShowsEachMeetingOnTwoLinesAndWideningMakesItOne() throws {
        let temp = try TemporaryDirectory("meeting-two-lines")
        defer { temp.remove() }
        let (window, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 400, height: 560), root: temp.url)
        let summary = try Self.meeting("a", in: temp.url)
        pane.show([summary], people: [summary.id: ["Alex", "Sam"]], freeBytes: nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let visible = pane.table.enclosingScrollView?.contentView.bounds.width ?? 0
        #expect(visible < MeetingGridColumn.twoLinesBelow)
        #expect(Self.hidden(pane, .when) == true && Self.hidden(pane, .description) == true)
        let row = try #require(pane.rowIndex(of: summary.id))
        #expect(pane.table.rect(ofRow: row).height == MeetingRowView.twoLineHeight)
        let start = MeetingListFormat.shortStart(summary.createdAt, now: Date())
        #expect(try Self.shownText(pane, summary.id) == ["Planning a", "10 min · Alex and Sam"])
        let name = try #require(pane.table.view(atColumn: 0, row: row, makeIfNecessary: true))
        #expect(name.toolTip?.hasPrefix(MeetingListFormat.detailLine(summary, people: ["Alex", "Sam"], now: Date()))
            == true, "The tooltip says when, how long and who, whole.")
        #expect(try Self.shownText(pane, summary.id, in: .actions) == [start], "At the row's right end.")
        #expect(pane.startButton.title == "Record…")
        #expect(pane.startButton.toolTip == "Start Recording…")
        let broken = MainWindowNarrowTests.brokenConstraints(in: pane.view)
        #expect(broken.isEmpty, "\(broken)")
        #expect(pane.table.frame.width <= visible + 1, "The columns fit the list.")
        SettingsEmbeddingTests.render(window, name: "meetings-two-lines")

        window.setContentSize(.init(width: 1000, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(Self.hidden(pane, .when) == false && Self.hidden(pane, .description) == false)
        let wide = try #require(pane.rowIndex(of: summary.id))
        #expect(pane.table.rect(ofRow: wide).height == MeetingRowView.height)
        #expect(try Self.shownText(pane, summary.id) == ["Planning a"], "The columns say the rest.")
        #expect(try Self.shownText(pane, summary.id, in: .actions).isEmpty)
        #expect(pane.startButton.title == "Start Recording…")
    }

    @Test func theStartTimeGivesWayToOpenOnTheSelectedMeeting() throws {
        let temp = try TemporaryDirectory("meeting-two-lines-selected")
        defer { temp.remove() }
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 400, height: 560), root: temp.url)
        let summary = try Self.meeting("b", in: temp.url)
        pane.show([summary], people: [:], freeBytes: nil)
        let start = MeetingListFormat.shortStart(summary.createdAt, now: Date())
        #expect(try Self.shownText(pane, summary.id) == ["Planning b", "10 min"], "No summary or people: the length.")
        #expect(try Self.shownText(pane, summary.id, in: .actions) == [start])
        let row = try #require(pane.rowIndex(of: summary.id))
        pane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let column = try #require(pane.table.tableColumns.firstIndex { MeetingGridColumn($0) == .actions })
        let actions = try #require(pane.table.view(atColumn: column, row: row, makeIfNecessary: true)
            as? MeetingRowActionsView)
        #expect(actions.revealed && !actions.openButton.isHiddenOrHasHiddenAncestor)
        #expect(try Self.shownText(pane, summary.id, in: .actions).isEmpty, "Open and ··· take its place.")
    }
}
