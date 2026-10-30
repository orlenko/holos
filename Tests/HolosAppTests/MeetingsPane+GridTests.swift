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

    @Test func aMeetingIsOneRowOfNameWhenDescriptionAndButtons() throws {
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
        try #require(Self.actions(pane, second.id).button(.copyPath)).performClick(nil)
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
        #expect(audio.button(.view)?.isEnabled == true)
        #expect(audio.button(.deleteAudio)?.isEnabled == true)
        let none = try Self.actions(pane, withoutAudio.id)
        #expect(none.button(.view)?.isEnabled == false, "No transcript to view.")
        #expect(none.button(.deleteAudio)?.isEnabled == false, "No audio to delete.")
        #expect(none.button(.open)?.isEnabled == true)
        #expect(none.button(.copyPath)?.isEnabled == true)

        try #require(audio.button(.deleteAudio)).performClick(nil)
        #expect(performed.count == 1)
        #expect(performed.first?.0 == .deleteAudio && performed.first?.1 == withAudio.id)
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
