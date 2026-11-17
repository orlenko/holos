import AppKit
import Testing
@testable import HolosApp

/// The menu bar menu's Start and Stop items, and Check for Updates… in the app's own menu (docs/design.md "Menu bar
/// menu").
@MainActor
struct MenuBarItemTests {
    private final class Target: NSObject {
        @objc func act() {}
    }

    @Test func startAndStopStandOutInRedAndBold() throws {
        let target = Target()
        let start = MenuBarItem.prominent("Start Meeting Recording…", symbol: "record.circle.fill", target: target,
                                          action: #selector(Target.act))
        #expect(start.title == "Start Meeting Recording…", "VoiceOver and keyboard search read the plain title.")
        #expect(start.isEnabled && start.target === target && start.action == #selector(Target.act))
        #expect(start.image != nil)
        let font = try #require(start.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(start.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil,
                "An enabled item keeps the menu's own text colour, light or dark.")

        let stopping = MenuBarItem.prominent("Stop and Save…", symbol: "stop.circle.fill", target: target,
                                             action: #selector(Target.act), enabled: false)
        #expect(!stopping.isEnabled)
        #expect(stopping.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == .disabledControlTextColor)
    }

    @Test func checkForUpdatesIsInTheAppMenuOnlyWhenTheBuildCanUpdate() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func appMenu(_ updates: Bool) throws -> [String] {
            try #require(AppKeyboard.mainMenu(checkForUpdates: updates).items.first?.submenu).items.map(\.title)
        }
        #expect(try appMenu(true).prefix(2) == ["About Voice is Local", "Check for Updates…"])
        #expect(try !appMenu(false).contains("Check for Updates…"))
        let check = try #require(AppKeyboard.mainMenu(checkForUpdates: true).items.first?.submenu?.items[1])
        #expect(check.action == Selector(("checkForUpdates")))
    }
}

/// Corrections' Last Dictation, in place of the menu's Correct Last Dictation…: History off or on, it puts the newest
/// dictation in the box.
@MainActor
struct CorrectionsLastDictationTests {
    @Test func lastDictationIsHiddenUntilTheAppLoadsItAndThenAsksForIt() throws {
        let words = WordListView(onAdd: { _ in .init(message: "", unadded: []) }, onRemove: { _ in "" },
                                 onSetHeardAs: { _, _ in "" })
        let pane = CorrectionsPane(onLearn: { _, _, _ in nil }, onAdd: { _, _ in true }, onRemove: { _ in true },
                                   onReplace: { _, _, _ in true }, wordList: words, onShow: {})
        func button() throws -> NSButton {
            try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSButton }
                .first { $0.title == "Last Dictation" })
        }
        #expect(try button().isHidden)
        var asked = 0
        pane.onLoadLast = {
            asked += 1
            pane.load(transcript: "lunch at noon", recognized: "lunch at noon", dictation: UUID(),
                      title: CorrectionsPane.lastDictationTitle, corrections: [])
        }
        pane.load(transcript: "an older note", recognized: "an older note", dictation: UUID(), title: "Dictation",
                  corrections: [])
        let box = try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSTextView }.first)
        box.string = "an older note, edited"
        #expect(try !button().isHidden)
        try button().performClick(nil)
        #expect(asked == 1)
        #expect(box.string == "lunch at noon", "The newest dictation replaces what the box held, as asked.")
    }
}
