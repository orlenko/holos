import AppKit
import Foundation
import HolosCore
import HolosMeeting
import Testing
@testable import HolosApp

/// Several meetings selected in the Meetings section (`MeetingsPane`), in the real main window laid out offscreen and
/// never shown, on made-up meetings in temporary folders: ranges and ⌘A skip the day headers, the selection is kept by
/// meeting ID when the list is read again, deletions act on every selected meeting that allows them (and skip the
/// others with the reason), a row's menu follows the Finder's rule, and the line under the buttons sums them up.
@MainActor
struct MeetingsMultiSelectTests {
    @Test func aRangeOverADayHeaderSelectsTheMeetingsOnBothSides() throws {
        let fixture = try Fixture()
        let table = fixture.table
        // ⇧-click from B to D: AppKit proposes the rows between, the header among them.
        let proposed = IndexSet(fixture.row("B")...fixture.row("D"))
        #expect(proposed.contains { fixture.isHeader($0) }, "A day header lies between B and D.")
        let range = fixture.pane.tableView(table, selectionIndexesForProposedSelection: proposed)
        table.selectRowIndexes(range, byExtendingSelection: false)
        #expect(fixture.pane.selectedSessionIDs == ["B", "C", "D"])

        // ⇧↓ from B goes on to C, past the header.
        fixture.select(["B"])
        table.keyDown(with: try Fixture.key(125, shift: true))
        #expect(fixture.pane.selectedSessionIDs == ["B", "C"])
        #expect(!table.selectedRowIndexes.contains { fixture.isHeader($0) })

        // ⌘A: every meeting, no header.
        table.selectAll(nil)
        #expect(fixture.pane.selectedSessionIDs == ["R", "A", "B", "C", "D", "E"])
        #expect(!table.selectedRowIndexes.contains { fixture.isHeader($0) })
    }

    @Test func theSelectionIsKeptByMeetingIDWhenTheListIsReadAgain() throws {
        let fixture = try Fixture()
        fixture.select(["B", "E"])
        // A new meeting comes first and A is gone: the rows move, the selection stays with B and E.
        let refreshed = [Fixture.meeting("N", hoursAgo: 0)] + fixture.meetings.filter { $0.id != "A" }
        fixture.pane.show(refreshed, people: [:], freeBytes: nil)
        #expect(fixture.pane.selectedSessionIDs == ["B", "E"])
        // A badge changes (a command starts on E): still the same two.
        fixture.pane.update(running: ["E": "Labelling speakers…"])
        #expect(fixture.pane.selectedSessionIDs == ["B", "E"])
    }

    @Test func afterTheSelectedMeetingsAreDeletedTheNextOneIsSelected() throws {
        let fixture = try Fixture()
        fixture.select(["B", "C"])
        fixture.pane.show(fixture.meetings.filter { !["B", "C"].contains($0.id) }, people: [:], freeBytes: nil)
        #expect(fixture.pane.selectedSessionIDs == ["D"])
        // The last meeting: the one before it.
        fixture.select(["E"])
        fixture.pane.show(fixture.meetings.filter { ["A", "D"].contains($0.id) }, people: [:], freeBytes: nil)
        #expect(fixture.pane.selectedSessionIDs == ["D"])
    }

    /// Rows A, B, C, D with A and C deleted together: B is selected whether a refresh lands between the two deletions
    /// or both go in one, and a meeting chosen while the deletion runs is kept.
    @Test(arguments: [true, false])
    func afterADeletionOfSeveralTheSelectionDoesNotDependOnRefreshTiming(refreshBetween: Bool) throws {
        let fixture = try Fixture()
        fixture.select(["A", "C"])
        fixture.pane.bulkDeletionStarted(["A", "C"])
        if refreshBetween {
            fixture.pane.show(fixture.meetings.filter { $0.id != "A" }, people: [:], freeBytes: nil)
            #expect(fixture.pane.selectedSessionIDs == ["C"])
        }
        let afterBoth = fixture.meetings.filter { !["A", "C"].contains($0.id) }
        fixture.pane.show(afterBoth, people: [:], freeBytes: nil)
        #expect(fixture.pane.selectedSessionIDs.isEmpty, "Chosen once the deletion ended, not from what is left now.")
        fixture.pane.bulkDeletionEnded()
        fixture.pane.show(afterBoth, people: [:], freeBytes: nil)
        #expect(fixture.pane.selectedSessionIDs == ["B"])

        // A meeting the user chose meanwhile stays selected.
        fixture.pane.show(fixture.meetings, people: [:], freeBytes: nil)
        fixture.select(["A", "C"])
        fixture.pane.bulkDeletionStarted(["A", "C"])
        fixture.pane.show(fixture.meetings.filter { $0.id != "A" }, people: [:], freeBytes: nil)
        fixture.select(["E"])
        fixture.pane.show(afterBoth, people: [:], freeBytes: nil)
        fixture.pane.bulkDeletionEnded()
        fixture.pane.show(afterBoth, people: [:], freeBytes: nil)
        #expect(fixture.pane.selectedSessionIDs == ["E"])
    }

    @Test func deleteMeetingOnSeveralRunsOnThoseThatAllowItAndSkipsTheOthers() throws {
        var bulk: [(MeetingsPane.Action, MeetingBulkPlan)] = []
        var single: [(MeetingsPane.Action, String)] = []
        let fixture = try Fixture(perform: { single.append(($0, $1.id)) })
        fixture.pane.performBulk = { bulk.append(($0, $1)) }
        fixture.pane.update(running: ["C": "Cleaning up…"])
        fixture.select(["R", "A", "C", "D"])
        let delete = try fixture.button("Delete Meeting…")
        #expect(delete.isEnabled)
        delete.performClick(nil)
        #expect(single.isEmpty, "Several selected: no single deletion.")
        let (action, plan) = try #require(bulk.first)
        #expect(action == .deleteMeeting)
        #expect(plan.action == .deleteMeeting)
        #expect(plan.targets.map(\.id) == ["A", "D"])
        #expect(plan.skipped.map(\.meeting.id) == ["R", "C"])
        #expect(plan.skipText == "2 of the selected meetings are skipped: 1 being recorded, "
                + "1 that Voice is Local is working on.")
        #expect(plan.confirmationTitle == "Delete 2 meetings?")

        // ⌘⌫ in the list does the same.
        fixture.table.keyDown(with: try Fixture.key(51, command: true))
        #expect(bulk.count == 2)
        #expect(bulk.last?.1.targets.map(\.id) == ["A", "D"])

        // Delete Audio…: D has none left.
        try fixture.button("Delete Audio…").performClick(nil)
        let audio = try #require(bulk.last?.1)
        #expect(audio.action == .deleteAudio)
        #expect(audio.targets.map(\.id) == ["A"])
        #expect(audio.skipped.map(\.reason) == [.recording, .inUse, .noAudio])

        // One meeting selected: the single deletion, as before.
        fixture.select(["A"])
        try fixture.button("Delete Meeting…").performClick(nil)
        #expect(single.map(\.1) == ["A"])
        #expect(bulk.count == 3)
    }

    @Test func whileADeletionOfSeveralRunsItsMeetingsWaitAsInUse() throws {
        let fixture = try Fixture()
        // The app reserves them in its meetings in use (`MeetingBulkRun.reserve`), which the list shows.
        fixture.pane.update(running: ["A": "Waiting to move to the Trash…", "B": "Moving to the Trash…"])
        fixture.pane.update(bulkStatus: "Moving 1 of 2 meetings to the Trash…")
        fixture.select(["A"])
        #expect(try !fixture.button("Delete Meeting…").isEnabled)
        #expect(fixture.pane.statusText.hasPrefix("Moving 1 of 2 meetings to the Trash…"))
        let a = try #require(fixture.meetings.first { $0.id == "A" })
        #expect(fixture.pane.badges(a, livePhase: nil).contains { $0.text == "Waiting to move to the Trash…" })
        fixture.pane.update(running: [:])
        fixture.pane.update(bulkStatus: nil)
        #expect(try fixture.button("Delete Meeting…").isEnabled)
        #expect(!fixture.pane.statusText.contains("Moving"))
    }

    @Test func severalSelectedShowASummaryAndOnlyTheActionsForAll() throws {
        let fixture = try Fixture()
        fixture.select(["A", "B", "C"])
        #expect(fixture.pane.statusText == "3 meetings selected · 1 h 30 min · 300 MB")
        #expect(fixture.pane.selectionAnnouncement == "3 meetings selected")
        for title in ["Show in Finder", "Delete Meeting…", "Delete Audio…"] {
            #expect(try fixture.button(title).isEnabled, "\(title)")
        }
        for title in ["Review…", "Live Transcript", "Recover…", "Label Speakers", "Open Transcript",
                      "Save Transcript As…"] {
            #expect(try !fixture.button(title).isEnabled, "\(title) is for one meeting")
        }
        fixture.select(["A"])
        #expect(fixture.pane.selectionAnnouncement == nil)
        #expect(!fixture.pane.statusText.contains("selected"))
    }

    @Test func aRowsMenuActsOnTheSelectionWhenTheRowIsInIt() throws {
        let fixture = try Fixture()
        fixture.select(["A", "B", "C"])
        let menu = NSMenu()
        // On a selected row: the selection stays, and the menu is about all three.
        fixture.pane.fill(menu, clickedRow: fixture.row("B"))
        #expect(fixture.pane.selectedSessionIDs == ["A", "B", "C"])
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Show 3 in Finder", "Delete Audio of 3 Meetings…", "Delete 3 Meetings…"])
        let disabled = menu.items.filter { !$0.isSeparatorItem && !$0.isEnabled }
        #expect(disabled.isEmpty)
        // On another row: that row alone, with its own menu.
        fixture.pane.fill(menu, clickedRow: fixture.row("E"))
        #expect(fixture.pane.selectedSessionIDs == ["E"])
        #expect(menu.items.contains { $0.title == "Rename…" })
        #expect(menu.items.contains { $0.title == "Delete Meeting…" })
        // On a header: nothing.
        fixture.pane.fill(menu, clickedRow: try #require(fixture.headers.first))
        #expect(menu.items.isEmpty)
        #expect(fixture.pane.selectedSessionIDs == ["E"])
    }

    // MARK: - Fixture

    /// The Meetings section in the main window with made-up meetings: A, B today; C, D (no audio left) 40 days ago;
    /// E 400 days ago; R being recorded (first in the list).
    @MainActor
    struct Fixture {
        let pane: MeetingsPane
        let table: NSTableView
        let meetings: [SessionSummary]

        init(perform: @escaping (MeetingsPane.Action, SessionSummary) -> Void = { _, _ in }) throws {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("multisel-\(UUID().uuidString)")
            pane = MeetingsPane(root: root, perform: perform, openReview: { _ in },
                                beginUsing: { _, _ in true }, endUsing: { _ in },
                                liveHeader: { _, _ in
                                    LiveMeetingHeader(name: "Weekly planning", phase: .recording, detail: "0:01:00")
                                })
            let controller = MainWindowController(autosave: nil) { [pane] section in
                section == .meetings ? pane : NSViewController()
            }
            controller.window.setContentSize(NSSize(width: 900, height: 900))
            controller.select(.meetings)
            SettingsEmbeddingTests.retained.append(controller)
            meetings = [Self.meeting("R", hoursAgo: 0, state: .recording, liveness: .capturing),
                        Self.meeting("A", hoursAgo: 0), Self.meeting("B", hoursAgo: 0),
                        Self.meeting("C", hoursAgo: 40 * 24), Self.meeting("D", hoursAgo: 40 * 24, audioDeleted: true),
                        Self.meeting("E", hoursAgo: 400 * 24)]
            pane.show(meetings, people: [:], freeBytes: nil)
            controller.window.contentView?.layoutSubtreeIfNeeded()
            table = try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSTableView }.first)
        }

        static func meeting(_ id: String, hoursAgo: Double, state: SessionState = .complete,
                            liveness: RecorderLiveness = .exited, audioDeleted: Bool = false) -> SessionSummary {
            SessionSummary(id: id, directory: URL(fileURLWithPath: "/nonexistent/multisel/\(id).holos"),
                           name: "Planning \(id)", createdAt: Date().addingTimeInterval(-hoursAgo * 3600),
                           source: .microphoneAndSystem, state: state, manifestStatus: state.rawValue,
                           savedSeconds: 1_800, chunkCount: 60, transcriptID: "T", speakerState: .labelled,
                           liveness: liveness, bytes: 100_000_000, audioDeleted: audioDeleted)
        }

        func isHeader(_ row: Int) -> Bool { pane.tableView(table, isGroupRow: row) }

        var headers: [Int] { (0..<table.numberOfRows).filter(isHeader) }

        /// The row of meeting `id`.
        func row(_ id: String) -> Int { pane.rowIndex(of: id) ?? -1 }

        /// Selects the meetings `ids` as clicks would.
        func select(_ ids: [String]) {
            let rows = ids.map(row)
            let proposed = IndexSet(rows)
            table.selectRowIndexes(pane.tableView(table, selectionIndexesForProposedSelection: proposed),
                                   byExtendingSelection: false)
        }

        func button(_ title: String) throws -> NSButton {
            try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSButton }
                .first { $0.title == title })
        }

        /// A key press in the window (125: ↓, 51: ⌫).
        static func key(_ code: UInt16, shift: Bool = false, command: Bool = false) throws -> NSEvent {
            var flags: NSEvent.ModifierFlags = []
            if shift { flags.insert(.shift) }
            if command { flags.insert(.command) }
            let scalar = try #require(UnicodeScalar(code == 125 ? NSDownArrowFunctionKey : 0x7F))
            let characters = String(Character(scalar))
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: code))
        }
    }
}
