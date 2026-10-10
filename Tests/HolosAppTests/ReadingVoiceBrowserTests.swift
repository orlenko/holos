import AppKit
import HolosSynthesis
import Testing
@testable import HolosApp

@MainActor @Suite struct ReadingVoiceBrowserTests {
    private func browser() -> ReadingVoiceBrowser {
        ReadingVoiceBrowser(catalog: ReadingVoiceList(voices: [
            VoiceDescriptor(id: "ava", name: "Ava", language: "en-US", quality: "premium"),
            VoiceDescriptor(id: "zoe", name: "Zoe", language: "en-US", quality: "enhanced"),
        ], installed: []), selectedID: "ava", showNaturalHint: true)
    }

    @discardableResult
    private func press(_ browser: ReadingVoiceBrowser, _ command: Selector) -> Bool {
        browser.control(browser.search, textView: NSTextView(), doCommandBy: command)
    }

    @Test func arrowsBrowseReturnChoosesAndEscapeCancels() {
        let browser = browser()
        var chosen: [String?] = []
        var cancelled = false
        browser.onChoose = { chosen.append($0) }
        browser.onCancel = { cancelled = true }
        #expect(press(browser, #selector(NSResponder.moveDown(_:))))
        #expect(chosen.isEmpty)
        #expect(browser.table.selectedRow == 1)
        #expect(press(browser, #selector(NSResponder.insertNewline(_:))))
        #expect(chosen == ["zoe"])
        chosen.removeAll()
        #expect(press(browser, #selector(NSResponder.cancelOperation(_:))))
        #expect(cancelled && chosen.isEmpty)
    }

    @Test func noMatchesCannotCommitAHiddenVoiceAndClearingSearchRestoresTheList() {
        let browser = browser()
        var chosen: [String?] = []
        browser.onChoose = { chosen.append($0) }
        browser.search.stringValue = "not a voice"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.search))
        #expect(browser.visibleItems.isEmpty && browser.table.selectedRow == -1)
        press(browser, #selector(NSResponder.insertNewline(_:)))
        #expect(chosen.isEmpty)
        browser.search.stringValue = ""
        browser.refreshResults()
        #expect(browser.visibleItems.map(\.id) == ["ava", "zoe"])
    }

    @Test func returnAndEscapeAlsoWorkWhenTheTableHasFocus() throws {
        let browser = browser()
        var chosen: [String?] = []
        var cancelled = false
        browser.onChoose = { chosen.append($0) }
        browser.onCancel = { cancelled = true }
        for code in [UInt16(36), 53] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            browser.table.keyDown(with: event)
        }
        #expect(chosen == ["ava"])
        #expect(cancelled)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func thePickerFitsInABoundedPopover(appearance: NSAppearance.Name) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let browser = browser()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = browser
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(browser.search.frame.width > 250)
        #expect(browser.table.visibleRect.height >= 200)
        #expect(browser.table.tableColumns.first?.width ?? 0 > 300)
        #expect(browser.view.bounds.width == 360)
        #expect(browser.view.fittingSize.height < 500)
        SettingsEmbeddingTests.render(window, name: "voice-picker-\(appearance.rawValue)")
    }
}
