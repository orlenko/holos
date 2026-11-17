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
