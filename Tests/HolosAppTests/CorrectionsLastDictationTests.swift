import AppKit
import Foundation
import Testing
@testable import HolosApp

/// Corrections' Last Dictation, in place of the menu bar's Correct Last Dictation… (docs/design.md "Menu bar menu").
/// Invented text.
@MainActor
struct CorrectionsLastDictationTests {
    private static func pane() -> CorrectionsPane {
        let words = WordListView(onAdd: { _ in .init(message: "", unadded: []) }, onRemove: { _ in "" },
                                 onSetHeardAs: { _, _ in "" })
        return CorrectionsPane(onLearn: { _, _, _ in nil }, onAdd: { _, _ in true }, onRemove: { _ in true },
                               onReplace: { _, _, _ in true }, wordList: words, onShow: {})
    }

    private static func button(_ pane: CorrectionsPane) throws -> NSButton {
        try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Last Dictation" })
    }

    private static func box(_ pane: CorrectionsPane) throws -> NSTextView {
        try #require(MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSTextView }.first)
    }

    private static func lunch(into pane: CorrectionsPane) {
        pane.load(transcript: "lunch at noon", recognized: "lunch at noon", dictation: UUID(),
                  title: CorrectionsPane.lastDictationTitle, corrections: [])
    }

    @Test func itReplacesWhatTheBoxHeldWhenAsked() throws {
        let pane = Self.pane()
        #expect(try Self.button(pane).isHidden, "Hidden until the app can load the last dictation.")
        pane.onLoadLast = {
            Self.lunch(into: pane)
            return true
        }
        pane.load(transcript: "an older note", recognized: "an older note", dictation: UUID(), title: "Dictation",
                  corrections: [])
        try Self.box(pane).string = "an older note, edited"
        #expect(try !Self.button(pane).isHidden)
        try Self.button(pane).performClick(nil)
        #expect(try Self.box(pane).string == "lunch at noon")
    }

    @Test func withNoDictationSinceLaunchTheBoxIsKept() throws {
        let pane = Self.pane()
        pane.onLoadLast = { false }
        pane.load(transcript: "an older note", recognized: "an older note", dictation: UUID(), title: "Dictation",
                  corrections: [])
        try Self.box(pane).string = "an older note, edited"
        try Self.button(pane).performClick(nil)
        #expect(try Self.box(pane).string == "an older note, edited", "Nothing to load: the edit stays.")
        #expect(try Self.box(pane).isEditable)
        let feedback = MainWindowNarrowTests.allViews(pane.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(feedback.contains { $0.hasPrefix("No dictation since Voice is Local started.") })
    }

    @Test func anEmptyBoxTakesADictationMadeSinceWhenShown() throws {
        let pane = Self.pane()
        var made = false
        pane.onLoadLast = {
            guard made else { return false }
            Self.lunch(into: pane)
            return true
        }
        pane.load(transcript: "", recognized: "", dictation: nil, title: CorrectionsPane.lastDictationTitle,
                  corrections: [])
        pane.sectionDidShow()
        #expect(try !Self.box(pane).isEditable, "Still no dictation.")
        made = true
        pane.sectionDidShow()
        #expect(try Self.box(pane).string == "lunch at noon")

        try Self.box(pane).string = "lunch at one"
        pane.load(transcript: "an older note", recognized: "an older note", dictation: UUID(), title: "Dictation",
                  corrections: [])
        pane.sectionDidShow()
        #expect(try Self.box(pane).string == "an older note", "A box with text keeps it when shown.")
    }
}
