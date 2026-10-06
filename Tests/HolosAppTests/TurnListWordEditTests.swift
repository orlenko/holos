import AppKit
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import Testing
@testable import HolosApp

/// Edit mode of the review's turn list (docs/meeting-design.md §5.10, "Editing words"), laid out offscreen (the window
/// is never shown) with `TurnListViewTests`' synthetic turns: row 0 is T1 "alpha beta" and T2 "gamma delta", row 1 T3
/// "epsilon zeta"; every turn is a segment of its own.
@MainActor
struct TurnListWordEditTests {
    private struct Saved: Equatable {
        var words: [String]
        var text: String
        var addTerm: Bool
    }

    /// The list, and what it asked to save.
    private func editingList() -> (TurnListView, () -> [Saved]) {
        let list = TurnListViewTests.list()
        var saved: [Saved] = []
        list.onEditWords = { words, text, addTerm in saved.append(Saved(words: words.map(\.text), text: text,
                                                                        addTerm: addTerm)) }
        return (list, { saved })
    }

    @discardableResult
    private func press(_ list: TurnListView, _ command: Selector) -> Bool {
        list.control(list.editField, textView: NSTextView(), doCommandBy: command)
    }

    @Test func wordClicksPlayOutsideEditModeAndOpenTheFieldInside() {
        let (list, saved) = editingList()
        var played: [Double] = []
        list.onPlay = { played.append($0) }
        list.table.handleWordClick(row: 0, word: 3, through: 3, extend: false)
        #expect(played == [4])
        #expect(list.wordEdit == nil && list.editField.superview == nil)

        list.editingWords = true
        #expect(list.table.editingWords && !list.table.usesAlternatingRowBackgroundColors)
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        #expect(played == [4], "In edit mode a word click does not seek.")
        #expect(list.wordEdit?.words.map(\.text) == ["beta"])
        #expect(list.wordEdit?.words.first?.ref == WordRef(segmentID: "T1", word: 1))
        #expect(list.editField.stringValue == "beta")
        #expect(list.editField.superview === list.table)
        #expect(saved().isEmpty)
    }

    @Test func returnSavesEscapeCancelsAndAnUnchangedFieldSavesNothing() {
        let (list, saved) = editingList()
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "Beta"
        #expect(press(list, #selector(NSResponder.insertNewline(_:))))
        #expect(saved() == [Saved(words: ["beta"], text: "Beta", addTerm: false)])
        #expect(list.wordEdit == nil && list.editField.superview == nil)

        list.table.handleWordClick(row: 0, word: 2, through: 2, extend: false)
        list.editField.stringValue = "something else"
        press(list, #selector(NSResponder.cancelOperation(_:)))
        #expect(saved().count == 1 && list.wordEdit == nil)

        list.table.handleWordClick(row: 1, word: 1, through: 1, extend: false)
        press(list, #selector(NSResponder.insertNewline(_:)))
        #expect(saved().count == 1, "Return on the words as they were saves nothing.")

        // ⌥Return: saved, and the new text asked for the word list.
        list.table.handleWordClick(row: 1, word: 0, through: 0, extend: false)
        list.editField.stringValue = "Epsilon"
        press(list, #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        #expect(saved().last == Saved(words: ["epsilon"], text: "Epsilon", addTerm: true))
        // Other commands are the field's own.
        list.table.handleWordClick(row: 1, word: 0, through: 0, extend: false)
        #expect(!press(list, #selector(NSResponder.moveLeft(_:))))
    }

    @Test func tabSavesAndEditsTheNextWordAcrossRowsAndShiftTabGoesBack() {
        let (list, saved) = editingList()
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = "Alpha"
        press(list, #selector(NSResponder.insertTab(_:)))
        #expect(saved() == [Saved(words: ["alpha"], text: "Alpha", addTerm: false)])
        #expect(list.wordEdit?.words.map(\.text) == ["beta"] && list.editField.stringValue == "beta")
        // Into the paragraph's next turn, then the next row.
        press(list, #selector(NSResponder.insertTab(_:)))
        press(list, #selector(NSResponder.insertTab(_:)))
        #expect(list.wordEdit?.words.map(\.text) == ["delta"])
        press(list, #selector(NSResponder.insertTab(_:)))
        #expect(list.wordEdit?.words.map(\.text) == ["epsilon"])
        press(list, #selector(NSResponder.insertBacktab(_:)))
        #expect(list.wordEdit?.words.map(\.text) == ["delta"])
        #expect(saved().count == 1, "Moving through unchanged words saves nothing.")
    }

    @Test func aSelectionStaysWithinOneSegmentOfOneTurn() {
        let (list, _) = editingList()
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        // ⇧-click on "delta", in the paragraph's other turn: the selection stops at "beta", and the banner says why.
        list.table.handleWordClick(row: 0, word: 3, through: 3, extend: true)
        #expect(list.wordEdit?.range == 0...1)
        #expect(list.wordEdit?.words.map(\.text) == ["alpha", "beta"])
        #expect(list.editField.stringValue == "alpha beta")
        #expect(messages.last == TurnListView.selectionStopped)
        // A drag back over the turn's words, from "beta" to "alpha".
        list.table.handleWordClick(row: 0, word: 1, through: 0, extend: false)
        #expect(list.wordEdit?.range == 0...1 && list.wordEdit?.anchor == 1)
        #expect(messages.last == .some(nil))
    }

    @Test func turningEditModeOffClosesTheFieldUnsaved() {
        let (list, saved) = editingList()
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "changed"
        list.editingWords = false
        #expect(list.wordEdit == nil && list.editField.superview == nil && saved().isEmpty)
        #expect(list.table.usesAlternatingRowBackgroundColors)
    }

    @Test func voiceOverEditsAWordAndTurnsEditModeOn() throws {
        let (list, _) = editingList()
        list.onRequestEditing = { list.editingWords = true }
        let text = try TurnListViewTests.cell(list, row: 0).bodyText
        let actions = text.accessibilityCustomActions() ?? []
        #expect(actions.map(\.name).filter { $0.hasPrefix("Edit “") }
            == ["Edit “alpha”", "Edit “beta”", "Edit “gamma”", "Edit “delta”"])
        let gamma = try #require(actions.first { $0.name == "Edit “gamma”" })
        #expect(gamma.handler?() == true)
        #expect(list.editingWords)
        #expect(list.wordEdit?.words.map(\.text) == ["gamma"])
    }

    @Test func theFieldFollowsItsWordsWhenAnEditEarlierInTheSegmentSaves() throws {
        let (list, _) = editingList()
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        // "alpha" became "al pha" meanwhile: "beta" is now word 2 of T1, at the same time.
        var words = TurnListViewTests.words
        words["T1"] = [TurnListViewTests.word("T1", 0, "al", 0), TurnListViewTests.word("T1", 1, "pha", 0.5),
                       TurnListViewTests.word("T1", 2, "beta", 1)]
        list.update(paragraphs: ReviewParagraphs.group(TurnListViewTests.turns),
                    speakers: [TurnListViewTests.speaker("S1", 1), TurnListViewTests.speaker("S2", 2)], people: [],
                    editable: true, text: { (words[$0.id] ?? []).map(\.text).joined(separator: " ") },
                    words: { words[$0.id] ?? [] }, resolve: { $0 })
        #expect(list.wordEdit?.range == 2...2)
        #expect(list.wordEdit?.words.first?.ref == WordRef(segmentID: "T1", word: 2))
        #expect(try TurnListViewTests.cell(list, row: 0).bodyText.string == "al pha beta gamma delta",
                "A changed text is shown even when its turns did not change.")
        // The words gone: the field closes and says so.
        words["T1"] = [TurnListViewTests.word("T1", 0, "alpha", 0)]
        list.update(paragraphs: ReviewParagraphs.group(TurnListViewTests.turns),
                    speakers: [TurnListViewTests.speaker("S1", 1), TurnListViewTests.speaker("S2", 2)], people: [],
                    editable: true, text: { (words[$0.id] ?? []).map(\.text).joined(separator: " ") },
                    words: { words[$0.id] ?? [] }, resolve: { $0 })
        #expect(list.wordEdit == nil)
        #expect(messages.last == TurnListView.wordsChanged)
    }
}
