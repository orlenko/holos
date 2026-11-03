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
}
