import Testing
@testable import HolosDesktop

@Suite struct SelectedTextTests {
    @Test func aSelectionIsTrimmedAndABlankOneIsNone() {
        #expect(SelectedText.cleaned("  Some words.\n") == "Some words.")
        #expect(SelectedText.cleaned(" \n\t") == nil)
    }

    @Test func eachRefusalSaysWhatToDo() {
        #expect(SelectedTextError.noSelection(app: "Notes").localizedDescription.hasPrefix("No selected text found in Notes."))
        #expect(SelectedTextError.noSelection(app: nil).localizedDescription.hasPrefix("No selected text found."))
        #expect(SelectedTextError.accessibilityNotGranted.localizedDescription.contains("Accessibility"))
        #expect(ChordHotkeyError.taken("⌃⌥⌘R").localizedDescription.contains("another app"))
        #expect(ChordHotkey.readSelection.title == "⌃⌥⌘R")
    }
}
