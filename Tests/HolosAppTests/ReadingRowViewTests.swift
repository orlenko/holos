import AppKit
import Foundation
import HolosContent
import Testing
@testable import HolosApp

/// The Reading list's rows (docs/design.md "Reading section"): one detail line, a fixed column of actions, and what is
/// seldom needed under ··· and the right-click menu. Invented titles and sites.
@MainActor
struct ReadingRowViewTests {
    private static func entry(_ source: ReadingSource, _ state: ReadingEntry.State) -> ReadingEntry {
        var entry = ReadingEntry(source: source, requestedVoice: nil, speed: 1)
        entry.title = "Notes on fermentation"
        entry.state = state
        return entry
    }

    private static let pdf = ReadingSource.file(URL(fileURLWithPath: "/Users/me/Almanac.pdf"))
    private static let site = ReadingSource.web(URL(string: "https://www.example.org/report")!)

    private static func row(width: CGFloat = 800) -> ReadingRowView {
        let row = ReadingRowView(identifier: NSUserInterfaceItemIdentifier("reading"))
        row.frame = NSRect(x: 0, y: 0, width: width, height: ReadingRowView.height)
        return row
    }

    private static func shown(_ row: ReadingRowView) -> [NSButton] {
        MainWindowNarrowTests.allViews(row).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func detail(_ row: ReadingRowView) -> String? {
        MainWindowNarrowTests.allViews(row).compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue).dropFirst().first
    }

    /// Where a button's column starts in the row.
    private static func column(_ button: NSButton, in row: ReadingRowView) throws -> CGFloat {
        try #require(button.superview).convert(button.frame, to: row).minX
    }

    @Test func aMadeReadingNamesItsKindAndKeepsTheFileNameAndSizeForTheTooltip() throws {
        var made = Self.entry(Self.pdf, .done)
        made.duration = 192
        made.chapters = 14
        made.voiceName = "Alba"
        let row = Self.row()
        row.show(made, activity: nil, fileProblem: nil, size: 240_000_000, playback: nil)
        let line = try #require(Self.detail(row))
        #expect(line.hasPrefix("PDF · "))
        #expect(line.hasSuffix(" · 14 chapters · Alba"))
        #expect(!line.contains("Almanac.pdf") && !line.contains("MB"), "The file's name and size are a hover away.")
        let label = try #require(MainWindowNarrowTests.allViews(row).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == line })
        #expect(label.toolTip?.hasPrefix("Almanac.pdf · 240") == true)
        #expect(Self.shown(row).map(\.title) == ["▶ Play", "Show Text", "Share…", ""])
    }

    @Test func failedAndStoppedReadingsSayWhereTheyCameFrom() {
        var failed = Self.entry(Self.site, .failed)
        failed.message = "The page could not be loaded."
        let row = Self.row()
        row.show(failed, activity: nil, fileProblem: nil, size: nil, playback: nil)
        #expect(Self.detail(row) == "example.org · The page could not be loaded.")
        #expect(Self.shown(row).map(\.title) == ["Try Again", ""])

        var stopped = Self.entry(.file(URL(fileURLWithPath: "/Users/me/Plan.docx")), .stopped)
        stopped.part = 2
        stopped.parts = 7
        row.show(stopped, activity: nil, fileProblem: nil, size: nil, playback: nil)
        #expect(Self.detail(row) == "Word · Stopped at part 2 of 7")
        #expect(Self.shown(row).map(\.title) == ["Resume", ""])
        #expect(row.moreMenu().items.map(\.title) == ["Delete…"])
    }

    @Test func theActionsLineUpDownTheList() throws {
        var made = Self.entry(Self.pdf, .done)
        made.duration = 60
        var making = Self.entry(Self.site, .rendering)
        making.title = "Lease agreement"
        var failed = Self.entry(Self.site, .failed)
        failed.message = "The page could not be loaded."
        let rows = [Self.row(), Self.row(), Self.row()]
        // In a window, so SETTINGS_RENDER_DIR can keep a picture of them.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: ReadingRowView.height * 3),
                              styleMask: [.titled], backing: .buffered, defer: false)
        for (index, row) in rows.enumerated() {
            row.frame.origin.y = ReadingRowView.height * CGFloat(2 - index)
            window.contentView?.addSubview(row)
        }
        defer { SettingsEmbeddingTests.render(window, name: "reading-rows") }
        rows[0].show(made, activity: nil, fileProblem: nil, size: nil, playback: nil)
        rows[1].show(making, activity: .rendering(part: 3, of: 19), fileProblem: nil, size: nil, playback: nil,
                     playable: true)
        rows[2].show(failed, activity: nil, fileProblem: nil, size: nil, playback: nil)
        for row in rows { row.layoutSubtreeIfNeeded() }
        let firsts = try rows.map { try Self.column(try #require(Self.shown($0).first), in: $0) }
        #expect(Set(firsts).count == 1, "Play, Play and Try Again start at the same place: \(firsts)")
        let share = try #require(Self.shown(rows[0]).first { $0.title == "Share…" })
        let stop = try #require(Self.shown(rows[1]).first { $0.title == "Stop" })
        #expect(try Self.column(share, in: rows[0]) == Self.column(stop, in: rows[1]))
        let moreMade = try #require(Self.shown(rows[0]).last)
        let moreFailed = try #require(Self.shown(rows[2]).last)
        #expect(try Self.column(moreMade, in: rows[0]) == Self.column(moreFailed, in: rows[2]))
        #expect(rows.allSatisfy { MainWindowNarrowTests.brokenConstraints(in: $0).isEmpty })
    }

    @Test func aRightClickOffersTheRowsActionsThenWhatIsUnderMore() throws {
        var made = Self.entry(Self.pdf, .done)
        made.duration = 60
        made.chapters = 3
        let row = Self.row()
        var sent: [(UUID, ReadingRowView.Action)] = []
        row.onAction = { sent.append(($0, $1)) }
        row.show(made, activity: nil, fileProblem: nil, size: nil, playback: nil)
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        let menu = try #require(row.menu(for: click))
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            == ["▶ Play", "Show Text", "Share…", "—", "Show in Finder", "Chapter Files…", "Delete…"])
        let delete = try #require(menu.items.last)
        menu.performActionForItem(at: menu.index(of: delete))
        #expect(sent.count == 1 && sent.first?.0 == made.id && sent.first?.1 == .delete)

        // Nothing to look after while it waits its turn: no ···, and the menu has only Stop.
        let queued = Self.entry(Self.site, .queued)
        row.show(queued, activity: nil, fileProblem: nil, size: nil, playback: nil)
        #expect(Self.shown(row).map(\.title) == ["Stop"])
        #expect(row.menu(for: click)?.items.map(\.title) == ["Stop"])
    }
}
