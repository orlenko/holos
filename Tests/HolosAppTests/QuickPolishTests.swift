import AppKit
import HolosCore
import Testing
@testable import HolosApp

/// Small views the design review asked to read better: the sidebar's status card, a narrow History row, the word
/// list's hint and the edit-mode banner. Laid out offscreen, never shown.
@MainActor
struct QuickPolishTests {
    private var windows: [NSWindow] = []
    private static let long = "Listening — release Right Option to finish, and press Esc to cancel it instead"

    @Test func theStatusCardWrapsItsMessageInsteadOfCuttingItOff() {
        let card = StatusCardView(frame: NSRect(x: 0, y: 0, width: 180, height: 60))
        card.update(MainStatus(tone: .busy, title: "Dictating", message: "Ready"))
        card.layoutSubtreeIfNeeded()
        let short = card.fittingSize.height
        card.update(MainStatus(tone: .busy, title: "Dictating", message: Self.long))
        card.layoutSubtreeIfNeeded()
        #expect(card.fittingSize.height > short + 8, "A long message takes more than one line.")
    }

    private mutating func headerFrames(width: CGFloat, badge: String, app: String) throws -> (app: NSTextField, time: NSTextField, badge: BadgeLabel) {
        let row = HistoryRowView(identifier: NSUserInterfaceItemIdentifier("row"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 56), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = row
        windows.append(window)
        let kind: DictationRecord.OutcomeKind = badge == "Not inserted" ? .needsCopy : .inserted
        let record = DictationRecord(id: UUID(), date: Date(), app: app, language: "en-US", text: "Words.", heard: "Words.",
                                     outcome: .init(kind: kind), seconds: 2)
        row.show(record, time: "08:05")
        row.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()  // the badge's width follows the row's on the first pass
        let views = MainWindowNarrowTests.allViews(row)
        let labels = views.compactMap { $0 as? NSTextField }
        return (try #require(labels.first { $0.stringValue == app }), try #require(labels.first { $0.stringValue == "08:05" }),
                try #require(views.compactMap { $0 as? BadgeLabel }.first))
    }

    @Test mutating func aNarrowHistoryRowKeepsTheAppAndTimeAndTheBadgeBecomesADot() throws {
        let narrow = try headerFrames(width: 148, badge: "Not inserted", app: "Safari")
        #expect(narrow.badge.compact)
        #expect(narrow.badge.frame.width <= 12)
        #expect(narrow.badge.frame.height <= 24)
        #expect(narrow.badge.toolTip == "Not inserted")
        #expect(narrow.time.frame.width >= narrow.time.intrinsicContentSize.width - 0.5, "The time is never clipped.")
        #expect(narrow.app.frame.width >= narrow.app.intrinsicContentSize.width - 0.5, "A short name shows whole.")
        let wide = try headerFrames(width: 380, badge: "Not inserted", app: "Safari")
        #expect(!wide.badge.compact)
        #expect(wide.badge.frame.width > 40)
    }

    @Test func theWordListHintShowsOnOneRow() {
        #expect(WordListView.hintRow(selected: [], count: 0) == nil)
        #expect(WordListView.hintRow(selected: [], count: 3) == 0)
        #expect(WordListView.hintRow(selected: [2], count: 3) == 2)
        #expect(WordListView.hintRow(selected: [1, 2], count: 3) == 1)
    }

    @Test func theWordListExplanationIsBehindItsHelpButton() {
        #expect(WordListView.noteHelp.contains("Often heard as"))
        #expect(!WordListView.noteHelp.contains("voiceislocal"), "Terminal commands stay in the docs.")
    }

    @Test func theEditBannerIsShortAndKeepsEveryKeyBehindItsHelpButton() {
        let banner = EditModeBanner(frame: NSRect(x: 0, y: 0, width: 760, height: 40))
        #expect(EditModeBanner.usual.count < 80)
        for key in ["⇧-click", "⌥Return", "Tab", "Esc", "(← first)", "(→ first)", "Space"] {
            #expect(EditModeBanner.keys.contains(key), "\(key)")
        }
        #expect(banner.helpButton.text == EditModeBanner.keys)
        #expect(banner.helpButton.accessibilityHelp() == EditModeBanner.keys)
        #expect(banner.helpButton.accessibilityLabel() == "Editing keys")
        banner.show(message: "Could not save.")
        #expect(banner.label.stringValue == "Could not save.")
        banner.show(message: nil)
        #expect(banner.label.stringValue == EditModeBanner.usual)
    }

    @Test func anEmptyHistorySaysHowToStartAndOffersTurningDictationOn() {
        func content(unreadable: Bool = false, hidden: Int = 0, recording: Bool = true, off: Bool) -> SectionEmptyView.Content {
            HistoryPane.emptyContent(unreadable: unreadable, hidden: hidden, recording: recording, dictationOff: off,
                                     shortcut: "Right Option")
        }
        let off = content(off: true)
        #expect(off.action == "Turn On Dictation")
        #expect(off.text.contains("Right Option"))
        let on = content(off: false)
        #expect(on.action == nil)
        #expect(on.title == "No dictations yet")
        #expect(on.text.contains("Right Option"))
        // History itself being off, or the file unreadable, is what the section has to say, whatever dictation does.
        #expect(content(recording: false, off: true).title == "History is off")
        #expect(content(recording: false, off: true).action == nil)
        #expect(content(unreadable: true, off: true).title == "History could not be read")
        #expect(content(hidden: 2, off: true).text.contains("2 dictations were"))
    }

    @Test func theMainWindowTellsHistoryWhenDictationIsOff() throws {
        let actions = HistoryPane.Actions(copy: { _ in true }, correct: { _ in }, delete: { _ in }, clear: {},
                                          audioURL: { _ in nil }, rerun: { _ in throw CancellationError() }, update: { _, _ in })
        let pane = HistoryPane(actions: actions)
        let controller = try MainWindowNarrowTests.window(on: .history, sidebarHidden: false, pane: pane)
        pane.update(records: [], retention: .standard, problem: nil, hidden: 0, unreadable: false)
        func shown() -> [String] {
            MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSButton }
                .filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.title)
        }
        controller.updateStatus(MainStatus(tone: .off, title: "Dictation off", message: ""))
        #expect(shown().contains("Turn On Dictation"))
        controller.updateStatus(MainStatus(tone: .ready, title: "Dictation ready", message: ""))
        #expect(!shown().contains("Turn On Dictation"))
    }

    /// History's list at the narrowest window, the tightest place an empty view goes.
    @Test(arguments: [(false, 0, true), (true, 0, true), (false, 2, true), (false, 0, false)])
    func emptyHistoryFitsTheNarrowestList(unreadable: Bool, hidden: Int, recording: Bool) throws {
        let actions = HistoryPane.Actions(copy: { _ in true }, correct: { _ in }, delete: { _ in }, clear: {},
                                          audioURL: { _ in nil }, rerun: { _ in throw CancellationError() }, update: { _, _ in })
        let pane = HistoryPane(actions: actions)
        let controller = try MainWindowNarrowTests.window(on: .history, sidebarHidden: true, pane: pane)
        controller.updateStatus(MainStatus(tone: .off, title: "Dictation off", message: ""))
        let retention = recording ? HistoryRetention.standard : HistoryRetention.off
        pane.update(records: [], retention: retention, problem: nil, hidden: hidden, unreadable: unreadable)
        let content = try #require(controller.window.contentView)
        for _ in 0..<3 { content.layoutSubtreeIfNeeded() }  // wrapped labels take their width, then their height
        let empty = try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? SectionEmptyView }.first)
        let list = try #require(empty.superview)
        #expect(!empty.isHidden)
        #expect(list.bounds.insetBy(dx: -0.5, dy: -0.5).contains(empty.frame), "\(empty.frame) in \(list.bounds)")
        #expect(empty.frame.width > 100, "The text uses the column's width, not a stale narrow one.")
        let parts = MainWindowNarrowTests.allViews(empty).filter { $0 is NSTextField || $0 is NSImageView || $0 is NSButton }
        for view in parts where !view.isHiddenOrHasHiddenAncestor {
            // Alignment rectangles: a symbol's image and a text field draw a little outside theirs.
            let frame = try #require(view.superview).convert(view.alignmentRect(forFrame: view.frame), to: empty)
            #expect(empty.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(view) at \(frame) in \(empty.bounds)")
            if let label = view as? NSTextField {
                #expect(label.frame.height + 0.5 >= label.intrinsicContentSize.height, "\(label.stringValue) is cut off.")
            }
        }
    }

    @Test func aDictationWithNoAudioShowsNoAudioRowAndMissingAudioSaysSo() {
        let detail = HistoryDetailView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        func shownTexts() -> [String] {
            MainWindowNarrowTests.allViews(detail).compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
        }
        func runAgain() -> NSButton? {
            MainWindowNarrowTests.allViews(detail).compactMap { $0 as? NSButton }.first { $0.title == "Run Again" }
        }
        detail.showAudio(.missing("The audio is no longer on this Mac."), running: false)
        #expect(shownTexts().contains("The audio is no longer on this Mac."))
        detail.showAudio(.available(playing: false, time: "0:00 / 0:07"), running: false)
        #expect(runAgain()?.isHiddenOrHasHiddenAncestor == false)
        detail.showAudio(.none, running: false)
        #expect(!shownTexts().contains("0:00 / 0:07"))
        #expect(runAgain()?.isEnabled == false, "A hidden button must not answer its shortcut.")
    }
}
