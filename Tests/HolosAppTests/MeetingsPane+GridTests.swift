import AppKit
import HolosAppModel
import HolosCore
import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing
@testable import HolosApp

@MainActor
struct MeetingsPaneGridTests {
    private static func meeting(_ id: String, in root: URL, chunks: Int = 3,
                                transcript: String? = "t") throws -> SessionSummary {
        let directory = root.appendingPathComponent("\(id).holos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionSummary(id: id, directory: directory, name: "Planning \(id)", createdAt: .now, source: .system,
                              state: .complete, manifestStatus: "complete", savedSeconds: 600, chunkCount: chunks,
                              transcriptID: transcript, speakerState: .labelled, liveness: .exited)
    }

    private static func actions(_ pane: MeetingsPane, _ id: String) throws -> MeetingRowActionsView {
        let row = try #require(pane.rowIndex(of: id))
        let column = try #require(pane.table.tableColumns.firstIndex { MeetingGridColumn($0) == .actions })
        return try #require(pane.table.view(atColumn: column, row: row, makeIfNecessary: true)
            as? MeetingRowActionsView)
    }

    private static func item(_ kind: MeetingRowActionsView.Kind, in actions: MeetingRowActionsView) throws -> NSMenuItem {
        try #require(actions.menu().items.first { $0.title == kind.title })
    }

    private static func choose(_ kind: MeetingRowActionsView.Kind, in actions: MeetingRowActionsView) throws {
        let menu = actions.menu()
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == kind.title }))
    }

    @Test func aMeetingIsOneRowOfNameWhenDescriptionAndActions() throws {
        let temp = try TemporaryDirectory("meeting-grid-columns")
        defer { temp.remove() }
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 601, height: 560), root: temp.url)
        let summary = try Self.meeting("a", in: temp.url)
        pane.show([summary], people: [summary.id: ["Alex", "Sam"]], freeBytes: nil)
        #expect(pane.table.tableColumns.compactMap(MeetingGridColumn.init) == MeetingGridColumn.allCases)
        let row = try #require(pane.rowIndex(of: summary.id))
        #expect(pane.table.rect(ofRow: row).height < 40, "One line per meeting, not a card.")
        #expect(pane.table.view(atColumn: 0, row: row, makeIfNecessary: true) is MeetingRowView)
        let description = try #require(pane.table.view(atColumn: 2, row: row, makeIfNecessary: true)
            as? MeetingTextCell)
        #expect(description.textField?.stringValue == "Alex and Sam", "Without a summary, the people it names.")
        let visible = pane.table.enclosingScrollView?.contentView.bounds.width ?? 0
        #expect(pane.table.frame.width <= visible + 1, "The columns fit the window at its narrowest.")
        let when = try #require(pane.table.tableColumns.first { MeetingGridColumn($0) == .when })
        #expect(when.isHidden == (visible < MeetingGridColumn.whenHiddenBelow))
    }

    @Test func aWideWindowShowsWhenEachMeetingWas() throws {
        let temp = try TemporaryDirectory("meeting-grid-wide")
        defer { temp.remove() }
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1280, height: 800), root: temp.url)
        pane.show([try Self.meeting("a", in: temp.url)], people: [:], freeBytes: nil)
        let visible = pane.table.enclosingScrollView?.contentView.bounds.width ?? 0
        #expect(visible >= MeetingGridColumn.whenHiddenBelow)
        #expect(pane.table.tableColumns.first { MeetingGridColumn($0) == .when }?.isHidden == false)
        #expect(pane.table.frame.width <= visible + 1)
    }

    @Test func copyPathPutsTheMeetingFolderOnThePasteboard() throws {
        let temp = try TemporaryDirectory("meeting-grid-copy")
        defer { temp.remove() }
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        let pasteboard = NSPasteboard(name: .init("holos-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pane.listState.pasteboard = pasteboard
        let first = try Self.meeting("a", in: temp.url)
        let second = try Self.meeting("b", in: temp.url)
        pane.show([first, second], people: [:], freeBytes: nil)
        pane.table.selectRowIndexes(IndexSet(integer: try #require(pane.rowIndex(of: first.id))),
                                    byExtendingSelection: false)
        try Self.choose(.copyPath, in: Self.actions(pane, second.id))
        #expect(pasteboard.string(forType: .string) == second.directory.path, "The row's own meeting, not the selection.")
    }

    @Test func viewAndDeleteAudioFollowTheMeeting() throws {
        let temp = try TemporaryDirectory("meeting-grid-buttons")
        defer { temp.remove() }
        var performed: [(MeetingsPane.Action, String)] = []
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url,
                                                          perform: { performed.append(($0, $1.id)) })
        let withAudio = try Self.meeting("a", in: temp.url)
        let withoutAudio = try Self.meeting("b", in: temp.url, chunks: 0, transcript: nil)
        let exports = SessionPaths.exports(withAudio.directory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("# Planning\n".utf8).write(to: SessionPaths.export("md", in: withAudio.directory))
        pane.show([withAudio, withoutAudio], people: [:], freeBytes: nil)

        let audio = try Self.actions(pane, withAudio.id)
        #expect(try Self.item(.view, in: audio).isEnabled)
        #expect(try Self.item(.deleteAudio, in: audio).isEnabled)
        let none = try Self.actions(pane, withoutAudio.id)
        #expect(try !Self.item(.view, in: none).isEnabled, "No transcript to view.")
        #expect(try !Self.item(.deleteAudio, in: none).isEnabled, "No audio to delete.")
        #expect(none.openButton.isEnabled)
        #expect(try Self.item(.copyPath, in: none).isEnabled)

        try Self.choose(.deleteAudio, in: audio)
        #expect(performed.count == 1)
        #expect(performed.first?.0 == .deleteAudio && performed.first?.1 == withAudio.id)
    }

    @Test func aRowShowsItsActionsOnlyWhileSelectedOrUnderThePointer() throws {
        let temp = try TemporaryDirectory("meeting-grid-reveal")
        defer { temp.remove() }
        let (window, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        let first = try Self.meeting("a", in: temp.url)
        let second = try Self.meeting("b", in: temp.url)
        pane.show([first, second], people: [:], freeBytes: nil)
        window.contentView?.layoutSubtreeIfNeeded()
        pane.table.selectRowIndexes(IndexSet(integer: try #require(pane.rowIndex(of: first.id))),
                                    byExtendingSelection: false)
        #expect(try Self.actions(pane, first.id).revealed)
        #expect(try !Self.actions(pane, second.id).revealed)
        pane.table.selectRowIndexes(IndexSet(integer: try #require(pane.rowIndex(of: second.id))),
                                    byExtendingSelection: false)
        #expect(try !Self.actions(pane, first.id).revealed)
        #expect(try Self.actions(pane, second.id).revealed)

        let index = try #require(pane.rowIndex(of: first.id))
        let row = try #require(pane.table.rowView(atRow: index, makeIfNecessary: true) as? MeetingTableRowView)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                                        userData: nil))
        row.mouseEntered(with: enter)
        #expect(try Self.actions(pane, first.id).revealed)
        row.mouseExited(with: enter)
        #expect(try !Self.actions(pane, first.id).revealed)

        // Several selected: not on each of them, only under the pointer.
        pane.table.selectAll(nil)
        #expect(try !Self.actions(pane, first.id).revealed)
        #expect(try !Self.actions(pane, second.id).revealed)
        row.mouseEntered(with: enter)
        #expect(try Self.actions(pane, first.id).revealed)
    }

    @Test func voiceOverReachesARowsActionsAndTellsItsButtonsApart() throws {
        let temp = try TemporaryDirectory("meeting-grid-voiceover")
        defer { temp.remove() }
        var performed: [(MeetingsPane.Action, String)] = []
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url,
                                                          perform: { performed.append(($0, $1.id)) })
        let first = try Self.meeting("a", in: temp.url)
        let second = try Self.meeting("b", in: temp.url)
        pane.show([first, second], people: [:], freeBytes: nil)
        let index = try #require(pane.rowIndex(of: second.id))
        let name = try #require(pane.table.view(atColumn: 0, row: index, makeIfNecessary: true))
        let actions = name.accessibilityCustomActions() ?? []
        #expect(actions.map(\.name) == ["Open", "View Transcript", "Copy Path", "Delete Audio…", "Delete Meeting…"])
        _ = actions.last?.handler?()
        #expect(performed.first?.0 == .deleteMeeting && performed.first?.1 == second.id, "Unselected: its own meeting.")
        let cell = try Self.actions(pane, second.id)
        #expect(cell.openButton.accessibilityLabel() == "Open Planning b")
        #expect(cell.moreButton.accessibilityLabel() == "More actions for Planning b")
    }

    /// The list is rebuilt under an open menu: a reused cell must not turn its choice to another meeting.
    @Test func aRowsMenuKeepsItsMeetingWhenTheCellIsReused() throws {
        let temp = try TemporaryDirectory("meeting-grid-reused")
        defer { temp.remove() }
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        let pasteboard = NSPasteboard(name: .init("holos-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pane.listState.pasteboard = pasteboard
        let first = try Self.meeting("a", in: temp.url)
        let second = try Self.meeting("b", in: temp.url)
        pane.show([first, second], people: [:], freeBytes: nil)
        let actions = try Self.actions(pane, first.id)
        let menu = actions.menu()
        _ = actions.showing([.open, .copyPath], title: second.displayTitle, action: pane.actionHandler(second.id))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Copy Path" }))
        #expect(pasteboard.string(forType: .string) == first.directory.path)
    }

    @Test func theSelectionsMenuHoldsAdvancedAndItsDeletion() throws {
        let temp = try TemporaryDirectory("meeting-grid-header")
        defer { temp.remove() }
        var performed: [(MeetingsPane.Action, String)] = []
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url,
                                                          perform: { performed.append(($0, $1.id)) })
        let summary = try Self.meeting("a", in: temp.url)
        pane.show([summary], people: [:], freeBytes: nil)
        #expect(!pane.selectionActions.isEnabled, "Nothing selected.")
        pane.table.selectRowIndexes(IndexSet(integer: try #require(pane.rowIndex(of: summary.id))),
                                    byExtendingSelection: false)
        #expect(pane.selectionActions.isEnabled)
        #expect(pane.statusText.hasPrefix("Planning a · 10 min"))
        let menu = try #require(pane.selectionMenu())
        #expect(!menu.autoenablesItems, "An action the policy refuses shows off.")
        #expect(menu.items.contains { $0.title == "Rename…" })
        #expect(menu.items.contains { $0.title == "View Transcript" })
        let delete = try #require(menu.items.last)
        #expect(delete.title == "Delete Meeting…")
        menu.performActionForItem(at: menu.index(of: delete))
        #expect(performed.map(\.1) == [summary.id])
    }

    @Test func anEmptyListLeavesStartRecordingToTheEmptyView() throws {
        let temp = try TemporaryDirectory("meeting-grid-empty")
        defer { temp.remove() }
        let (_, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: temp.url)
        pane.show([], people: [:], freeBytes: nil)
        let shown = MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSButton }
            .filter { $0.title == "Start Recording…" && !$0.isHiddenOrHasHiddenAncestor }
        #expect(shown.count == 1)
        pane.show([try Self.meeting("a", in: temp.url)], people: [:], freeBytes: nil)
        let afterwards = MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSButton }
            .filter { $0.title == "Start Recording…" && !$0.isHiddenOrHasHiddenAncestor }
        #expect(afterwards.count == 1, "Beside the search now.")
    }

    @Test func dontAskAgainIsRememberedAndAskingIsTheDefault() throws {
        let suite = "holos-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MeetingAudioPreferences(defaults: defaults)
        #expect(preferences.confirmsDeletion)
        preferences.confirmsDeletion = false
        #expect(!MeetingAudioPreferences(defaults: defaults).confirmsDeletion)
    }

    @Test func settingsTurnTheCleanupOnAndAskingBackOn() throws {
        let suite = "holos-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MeetingAudioPreferences(defaults: defaults)
        preferences.confirmsDeletion = false
        let view = MeetingAudioSettingsView(preferences: preferences)
        #expect(view.cleanupToggle.state == .off)
        #expect(!view.daysStepper.isEnabled, "The days wait for the cleanup to be on.")
        #expect(view.daysField.integerValue == 7)
        view.cleanupToggle.performClick(nil)
        #expect(preferences.cleanupAfterDays == 7)
        #expect(view.daysStepper.isEnabled)
        view.daysStepper.integerValue = 14
        view.daysStepper.sendAction(view.daysStepper.action, to: view.daysStepper.target)
        #expect(preferences.cleanupAfterDays == 14)
        #expect(view.daysField.integerValue == 14)
        #expect(view.confirmToggle.state == .off)
        view.confirmToggle.performClick(nil)
        #expect(preferences.confirmsDeletion)
    }
}
