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
        list.onEditWords = { words, text, addTerm, _ in saved.append(Saved(words: words.map(\.text), text: text,
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

    /// Closing the window ends no editing: the window takes what the open field holds, for the review's close to save.
    @Test func closingTakesWhatTheOpenFieldHolds() {
        let (list, saved) = editingList()
        list.editingWords = true
        #expect(list.takeOpenWordEdit() == nil, "No field open.")
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        #expect(list.takeOpenWordEdit() == nil, "Nothing typed.")
        #expect(list.wordEdit == nil && list.editField.superview == nil)

        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "Beta"
        let taken = list.takeOpenWordEdit()
        #expect(taken?.words.map(\.ref) == [WordRef(segmentID: "T1", word: 1)] && taken?.text == "Beta")
        #expect(taken?.movesSeen == 0)
        #expect(list.wordEdit == nil && list.editField.superview == nil)
        // The field closed without saving on its own: only the close saves it, once.
        list.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                   object: list.editField))
        #expect(saved().isEmpty)
    }

    /// A word known not to be editable (corrected while recording, say): no field opens, and the banner says why.
    @Test func aWordThatCannotBeEditedOpensNoFieldAndSaysWhy() {
        let (list, _) = editingList()
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        list.editRefusal = { words in words.contains { $0.text == "beta" } ? "Corrected while recording." : nil }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        #expect(list.wordEdit == nil && list.editField.superview == nil)
        #expect(messages.last == "Corrected while recording.")
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        #expect(list.wordEdit?.words.map(\.text) == ["alpha"])
    }

    /// Typed in the field, then a ⇧-click onto a word that cannot be edited (corrected while recording): the field
    /// stays as it was, with what was typed, and the banner says why.
    @Test func aRefusedShiftClickLeavesTheFieldAsItWas() {
        let (list, saved) = editingList()
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        list.editRefusal = { words in words.contains { $0.text == "beta" } ? "Corrected while recording." : nil }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = "Alfa"
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: true)
        #expect(list.wordEdit?.words.map(\.text) == ["alpha"] && list.editField.superview != nil)
        #expect(list.editField.stringValue == "Alfa" && saved().isEmpty)
        #expect(messages.last == "Corrected while recording.")
        // An extension that is allowed still grows it, keeping what was typed.
        list.editRefusal = nil
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: true)
        #expect(list.wordEdit?.words.map(\.text) == ["alpha", "beta"] && list.editField.stringValue == "Alfa")
    }

    /// A save refused or failed after Return: the field opens again over the words with what was typed.
    @Test func aRefusedSaveOpensTheFieldAgainWithWhatWasTyped() throws {
        let (list, saved) = editingList()
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "Beta"
        press(list, #selector(NSResponder.insertNewline(_:)))
        #expect(saved().count == 1 && list.wordEdit == nil)
        let beta = try #require(TurnListViewTests.words["T1"]?[1])
        #expect(list.reopenWordEdit([beta], typed: "Beta", message: "Could not save. What you typed: “Beta”."))
        #expect(list.wordEdit?.words.map(\.text) == ["beta"] && list.editField.stringValue == "Beta")
        #expect(messages.last == "Could not save. What you typed: “Beta”.")
        // Another field open meanwhile (Tab went on): it stays; the message carries what was typed.
        list.cancelWordEdit()
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        #expect(!list.reopenWordEdit([beta], typed: "Beta", message: "Could not save."))
        #expect(list.wordEdit?.words.map(\.text) == ["alpha"])
    }

    /// The word-list term after an edit is what was typed, never the words the edit took in around it.
    @Test func theTermOfferedIsWhatWasTyped() {
        // Only "York" of an automatic "New York" (heard "knew work") became "Yorkshire": the edit's text is
        // "New Yorkshire", the recognizer's words for "York" alone are not known.
        let partial = ReviewWordEdit(heard: "knew work", meant: "New Yorkshire", typed: "Yorkshire")
        let added = ReviewWindow.wordListTerm(after: partial, add: true, isDictionaryWord: { _ in false })
        #expect(added?.term == "Yorkshire" && added?.heardAs == nil)
        let offered = ReviewWindow.wordListTerm(after: partial, add: false, isDictionaryWord: { _ in false })
        #expect(offered?.term == "Yorkshire" && offered?.heardAs == nil)
        // The whole recognized word edited: "often heard as" what the recognizer wrote.
        let whole = ReviewWordEdit(heard: "cloud", meant: "Claude", typed: "Claude", typedHeard: "cloud")
        let term = ReviewWindow.wordListTerm(after: whole, add: true, isDictionaryWord: { _ in false })
        #expect(term?.term == "Claude" && term?.heardAs == "cloud")
    }

    /// A term keeps the punctuation that belongs to it, and loses the sentence's, the same way when ⌥Return adds it as
    /// when it is offered.
    @Test func theTermKeepsItsOwnPunctuation() {
        let cases = [("C#", "C#"), ("C++", "C++"), (".NET", ".NET"), ("Node.js", "Node.js"), ("GitHub,", "GitHub"),
                     ("Claude.", "Claude"), ("“C#,”", "C#")]
        for (typed, expected) in cases {
            let edit = ReviewWordEdit(heard: "see sharp", meant: typed, typed: typed, typedHeard: "see sharp")
            for add in [true, false] {
                let term = ReviewWindow.wordListTerm(after: edit, add: add, isDictionaryWord: { _ in false })
                #expect(term?.term == expected, "\(typed), add: \(add)")
            }
        }
        // A case-only change gives no "often heard as": the heard words are cleaned as the term is, so "c#" is never
        // the broader "c".
        for (heard, typed, expected) in [("c#", "C#", "C#"), ("c++", "C++", "C++"), (".net", ".NET", ".NET"),
                                         ("github,", "GitHub", "GitHub")] {
            let edit = ReviewWordEdit(heard: heard, meant: typed, typed: typed, typedHeard: heard)
            for add in [true, false] {
                let term = ReviewWindow.wordListTerm(after: edit, add: add, isDictionaryWord: { _ in false })
                #expect(term?.term == expected && term?.heardAs == nil, "\(heard) → \(typed), add: \(add)")
            }
        }
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

    /// The field over "alpha" is at least 90 pt wide, so it lies over "beta": a ⇧-click there reaches the table (which
    /// extends the selection to "beta"); a plain click there, and any click on "alpha", edits the field's text.
    @Test func aShiftClickOnTheFieldOverTheNextWordReachesTheTable() throws {
        let (list, _) = editingList()
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        let text = try TurnListViewTests.cell(list, row: 0).bodyText
        let field = list.editField
        func hit(onWord index: Int, shift: Bool) throws -> NSView? {
            let rect = try #require(text.rect(ofWord: index))
            let point = list.table.convert(NSPoint(x: rect.midX, y: rect.midY), from: text)
            if index == 1 { #expect(field.frame.contains(point), "The field lies over “beta”.") }
            field.extendsSelection = { shift }
            let container = try #require(list.table.superview)
            return container.hitTest(container.convert(point, from: list.table))
        }
        func inField(_ view: NSView?) -> Bool { view.map { $0 === field || $0.isDescendant(of: field) } ?? false }
        let shiftOnBeta = try hit(onWord: 1, shift: true)
        #expect(!inField(shiftOnBeta) && shiftOnBeta.map { $0 === list.table || $0.isDescendant(of: list.table) } == true)
        #expect(inField(try hit(onWord: 1, shift: false)), "A plain click places the caret in the field.")
        #expect(inField(try hit(onWord: 0, shift: true)), "On the edited words, the field keeps it.")
        // The table's handler then takes "beta" in.
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: true)
        #expect(list.wordEdit?.words.map(\.text) == ["alpha", "beta"])
    }

    /// The same on a lower row ("epsilon zeta", row 1): the field and the words compare in the table's coordinates.
    @Test func aShiftClickOnTheFieldReachesTheTableOnALowerRow() throws {
        let (list, _) = editingList()
        list.editingWords = true
        list.table.handleWordClick(row: 1, word: 0, through: 0, extend: false)
        #expect(list.wordEdit?.words.map(\.text) == ["epsilon"])
        let text = try TurnListViewTests.cell(list, row: 1).bodyText
        let field = list.editField
        let container = try #require(list.table.superview)
        func hit(onWord index: Int, shift: Bool) throws -> NSView? {
            let rect = try #require(text.rect(ofWord: index))
            let point = list.table.convert(NSPoint(x: rect.midX, y: rect.midY), from: text)
            #expect(field.frame.contains(point), "The field lies over word \(index).")
            field.extendsSelection = { shift }
            return container.hitTest(container.convert(point, from: list.table))
        }
        func inField(_ view: NSView?) -> Bool { view.map { $0 === field || $0.isDescendant(of: field) } ?? false }
        #expect(field.frame.minY > 0, "A lower row.")
        let shiftOnZeta = try hit(onWord: 1, shift: true)
        #expect(!inField(shiftOnZeta) && shiftOnZeta.map { $0 === list.table || $0.isDescendant(of: list.table) } == true)
        #expect(inField(try hit(onWord: 1, shift: false)))
        #expect(inField(try hit(onWord: 0, shift: true)))
    }

    /// Only Esc drops what was typed: turning edit mode off saves it.
    @Test func turningEditModeOffSavesTheFieldAndEscDropsIt() {
        let (list, saved) = editingList()
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "changed"
        list.editingWords = false
        #expect(list.wordEdit == nil && list.editField.superview == nil)
        #expect(saved().map(\.text) == ["changed"] && saved().map(\.words) == [["beta"]])
        #expect(list.table.usesAlternatingRowBackgroundColors)
        // Nothing typed: nothing saved.
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editingWords = false
        #expect(saved().count == 1)
        // Esc.
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "dropped"
        press(list, #selector(NSResponder.cancelOperation(_:)))
        #expect(list.wordEdit == nil && saved().count == 1)
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

    /// The transcript changed after labelling (`canEditWords` off): no "Edit" action is offered, and one VoiceOver
    /// still holds from before reports that nothing happened.
    @Test func voiceOverOffersNoEditWhileWordsCannotBeEdited() throws {
        let (list, _) = editingList()
        list.onRequestEditing = { list.editingWords = true }
        let text = try TurnListViewTests.cell(list, row: 0).bodyText
        let held = try #require(text.accessibilityCustomActions()?.first { $0.name == "Edit “beta”" })
        list.canEditWords = false
        let actions = text.accessibilityCustomActions() ?? []
        #expect(!actions.contains { $0.name.hasPrefix("Edit “") })
        #expect(actions.contains { $0.name.hasPrefix("Play from “beta”") }, "Playing still works.")
        #expect(held.handler?() == false)
        #expect(list.wordEdit == nil && !list.editingWords)
    }

    /// The list shown with `words` and the review's word `moves`.
    /// A search for "alpha": Tab saved its edit ("Alfa") and opened the next field; the saved edit leaves the row with
    /// no match, so the search filters it away. What was typed in the next field is still saved.
    @Test func aFieldWhoseRowASearchFiltersAwayIsStillSaved() {
        let (list, saved) = editingList()
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = "Alfa"
        press(list, #selector(NSResponder.insertTab(_:)))
        #expect(list.wordEdit?.words.map(\.text) == ["beta"])
        list.editField.stringValue = "Beta"
        var words = TurnListViewTests.words
        words["T1"] = [TurnListViewTests.word("T1", 0, "Alfa", 0), TurnListViewTests.word("T1", 1, "beta", 1)]
        let unmatched = ReviewParagraphs.group(TurnListViewTests.turns).filter { !$0.turnIDs.contains("T1") }
        update(list, words: words, moves: [ReviewWordMove(segmentID: "T1", replaced: 0..<1, replacement: 0..<1)],
               paragraphs: unmatched)
        #expect(list.wordEdit == nil)
        #expect(saved().map(\.text) == ["Alfa", "Beta"] && saved().map(\.words) == [["alpha"], ["beta"]])
    }

    private func update(_ list: TurnListView, words: [String: [ReviewWord]], moves: [ReviewWordMove],
                        paragraphs: [ReviewParagraph]? = nil) {
        list.update(paragraphs: paragraphs ?? ReviewParagraphs.group(TurnListViewTests.turns),
                    speakers: [TurnListViewTests.speaker("S1", 1), TurnListViewTests.speaker("S2", 2)], people: [],
                    editable: true, text: { (words[$0.id] ?? []).map(\.text).joined(separator: " ") },
                    words: { words[$0.id] ?? [] }, resolve: { $0 }, wordMoves: moves)
    }

    /// Words edited together that a relabel put in two turns: no Revert (it would be refused), and the tooltip says
    /// to edit each turn's words directly. Another fixed word keeps its Revert.
    @Test func wordsEditedTogetherNowInTwoTurnsOfferNoRevert() throws {
        let (list, _) = editingList()
        let split = TranscriptWordFix(first: 1, end: 3, heard: "bet a", kind: .reviewEdit)
        let fixed = TranscriptWordFix(first: 1, end: 2, heard: "delt", kind: .correction)
        func word(_ turn: String, _ index: Int, _ text: String, _ start: Double, fix: TranscriptWordFix? = nil,
                  revertible: Bool = true) -> ReviewWord {
            ReviewWord(ref: WordRef(segmentID: turn, word: index), text: text, start: start, fix: fix,
                       revertible: revertible)
        }
        update(list, words: [
            // The edited text ("Beta"): a changed text reloads the row, as the relabel's new turns do.
            "T1": [word("T1", 0, "alpha", 0), word("T1", 1, "Beta", 1, fix: split, revertible: false)],
            "T2": [word("T2", 0, "gamma", 3), word("T2", 1, "delta", 4, fix: fixed)],
            "T3": [word("T3", 0, "epsilon", 6), word("T3", 1, "zeta", 7)],
        ], moves: [])
        let text = try TurnListViewTests.cell(list, row: 0).bodyText
        let names = (text.accessibilityCustomActions() ?? []).map(\.name)
        #expect(!names.contains("Revert to “bet a”"))
        #expect(names.contains("Revert to “delt”"))
        #expect(!names.contains("Edit “Beta”") && names.contains("Edit “alpha”"))
        #expect(text.reviewWord(at: 1)?.revertible == false, "The context menu offers no Revert either.")
        #expect(text.reviewWord(at: 3)?.revertible == true)
        let storage = try #require(text.textStorage)
        let beta = (storage.string as NSString).range(of: "Beta")
        let tip = try #require(storage.attribute(.toolTip, at: beta.location, effectiveRange: nil) as? String)
        #expect(tip.hasSuffix("(" + TurnTextView.notRevertible + ")"))
        // An edit of them would be refused too (it takes in all the words edited together): no field opens, and the
        // banner says why. The turn's other words open as usual.
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        #expect(list.wordEdit == nil && messages.last == TurnListView.editedAcrossTurns)
        list.table.handleWordClick(row: 0, word: 0, through: 1, extend: false)
        #expect(list.wordEdit?.words.map(\.text) == ["alpha"], "A selection stops before them.")
        #expect(messages.last == TurnListView.selectionStopped)
    }

    /// After the transcript changed under the labels (`canEditWords` off), no fix can be reverted (an edit's Revert is
    /// another edit, an automatic fix's publishes new words under the labels; both would be refused): neither VoiceOver
    /// nor the context menu offers it.
    @Test func revertIsOfferedOnlyWhileWordsCanBeEdited() throws {
        let (list, _) = editingList()
        let edited = TranscriptWordFix(first: 1, end: 2, heard: "bet", kind: .reviewEdit, heardWords: 1)
        let fixed = TranscriptWordFix(first: 1, end: 2, heard: "delt", kind: .correction, heardWords: 1)
        update(list, words: [
            "T1": [ReviewWord(ref: WordRef(segmentID: "T1", word: 0), text: "alpha", start: 0),
                   ReviewWord(ref: WordRef(segmentID: "T1", word: 1), text: "Beta", start: 1, fix: edited)],
            "T2": [ReviewWord(ref: WordRef(segmentID: "T2", word: 0), text: "gamma", start: 3),
                   ReviewWord(ref: WordRef(segmentID: "T2", word: 1), text: "delta", start: 4, fix: fixed)],
            "T3": [ReviewWord(ref: WordRef(segmentID: "T3", word: 0), text: "epsilon", start: 6),
                   ReviewWord(ref: WordRef(segmentID: "T3", word: 1), text: "zeta", start: 7)],
        ], moves: [])
        let text = try TurnListViewTests.cell(list, row: 0).bodyText
        func names() -> [String] { (text.accessibilityCustomActions() ?? []).map(\.name) }
        #expect(names().contains("Revert to “bet”") && names().contains("Revert to “delt”"))
        let beta = WordRef(segmentID: "T1", word: 1), delta = WordRef(segmentID: "T2", word: 1)
        // A segment refusing every revert (an older automatic fix that cannot be counted): its Revert is not offered,
        // the other segment's is.
        list.revertRefusal = { $0.segmentID == "T2" ? TranscriptWordEdit.olderFix.localizedDescription : nil }
        #expect(names().contains("Revert to “bet”") && !names().contains("Revert to “delt”"))
        #expect(text.canRevert(edited, at: beta) && !text.canRevert(fixed, at: delta), "The context menu too.")
        list.revertRefusal = nil
        list.canEditWords = false
        #expect(!names().contains("Revert to “bet”") && !names().contains("Revert to “delt”"))
        #expect(!text.canRevert(edited, at: beta) && !text.canRevert(fixed, at: delta),
                "The context menu follows the same rule.")
    }

    @Test func theFieldFollowsItsWordsWhenAnEditEarlierInTheSegmentSaves() throws {
        let (list, saved) = editingList()
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        // "alpha" became "al pha" meanwhile: "beta" is now word 2 of T1.
        var words = TurnListViewTests.words
        words["T1"] = [TurnListViewTests.word("T1", 0, "al", 0), TurnListViewTests.word("T1", 1, "pha", 0.5),
                       TurnListViewTests.word("T1", 2, "beta", 1)]
        var moves = [ReviewWordMove(segmentID: "T1", replaced: 0..<1, replacement: 0..<2)]
        update(list, words: words, moves: moves)
        #expect(list.wordEdit?.range == 2...2)
        #expect(list.wordEdit?.words.first?.ref == WordRef(segmentID: "T1", word: 2))
        #expect(try TurnListViewTests.cell(list, row: 0).bodyText.string == "al pha beta gamma delta",
                "A changed text is shown even when its turns did not change.")
        // The words gone (changed elsewhere, with no move): the field closes, and what was typed is queued as an edit
        // (the review refuses it, saying what was typed, when its words are not there).
        list.editField.stringValue = "Beta"
        words["T1"] = [TurnListViewTests.word("T1", 0, "alpha", 0)]
        moves = []
        update(list, words: words, moves: moves)
        #expect(list.wordEdit == nil)
        #expect(saved().map(\.text) == ["Beta"] && saved().map(\.words) == [["beta"]])
    }

    @Test func tabAfterADeletionKeepsTheNextFieldOpenOnTheMergedWord() {
        let (list, saved) = editingList()
        var seen: [Int] = []
        list.onEditWords = { _, _, _, movesSeen in seen.append(movesSeen) }
        list.editingWords = true
        // "alpha" deleted, Tab: the field opens on "beta" before the save ends.
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = ""
        press(list, #selector(NSResponder.insertTab(_:)))
        #expect(list.wordEdit?.words.map(\.text) == ["beta"])
        list.editField.stringValue = "Beta"
        // Saved: "alpha" merged into "beta", which starts where "alpha" did and is word 0 now.
        var words = TurnListViewTests.words
        words["T1"] = [TurnListViewTests.word("T1", 0, "beta", 0)]
        update(list, words: words, moves: [ReviewWordMove(segmentID: "T1", replaced: 0..<1, replacement: 0..<0)])
        #expect(list.wordEdit?.words.first?.ref == WordRef(segmentID: "T1", word: 0))
        #expect(list.editField.stringValue == "Beta", "What was typed stays.")
        press(list, #selector(NSResponder.insertNewline(_:)))
        #expect(seen == [0, 1], "The second edit names the words as they are after the first was saved.")
        #expect(saved().isEmpty)
    }

    @Test func aFieldOnAWordAnEditReplacedClosesKeepingWhatWasTyped() {
        let (list, saved) = editingList()
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "Beta."
        // An edit of "alpha beta" into "alpha beta gamma" saved meanwhile: word 1 is still "beta", but it was
        // replaced, so the field is not moved onto whatever is there now.
        var words = TurnListViewTests.words
        words["T1"] = ["alpha", "beta", "gamma"].enumerated().map { TurnListViewTests.word("T1", $0, $1, Double($0)) }
        update(list, words: words, moves: [ReviewWordMove(segmentID: "T1", replaced: 0..<2, replacement: 0..<3)])
        // Queued as an edit of the words as they were (the review's queue refuses it, saying what was typed).
        #expect(list.wordEdit == nil && saved().map(\.text) == ["Beta."])
        #expect(messages.allSatisfy { $0 == nil })
    }

    @Test func theFieldFollowsItsWordsWhenTheTextRewraps() throws {
        let (list, _) = editingList()
        // A paragraph of 14 words, on one or two lines at first.
        var words = TurnListViewTests.words
        words["T2"] = (0..<12).map { TurnListViewTests.word("T2", $0, "word\($0)", 3 + Double($0) * 0.2) }
        update(list, words: words, moves: [])
        list.layoutSubtreeIfNeeded()
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 13, through: 13, extend: false)
        #expect(list.wordEdit?.words.map(\.text) == ["word11"])
        let before = list.editField.frame
        // Narrower: the row's text wraps onto more lines, and "word11" goes down.
        list.window?.setContentSize(NSSize(width: 480, height: 600))
        list.layoutSubtreeIfNeeded()
        let cell = try TurnListViewTests.cell(list, row: 0)
        let word = try #require(cell.bodyText.rect(ofWord: 13))
        let origin = list.table.convert(word.origin, from: cell.bodyText)
        #expect(list.table.tableColumns[0].width < 500)
        #expect(cell.bodyText.frame.width < 200)
        #expect(list.editField.frame.origin.y != before.origin.y)
        #expect(abs(list.editField.frame.minX - (origin.x - 4)) < 0.5 && abs(list.editField.frame.minY - (origin.y - 3)) < 0.5)
    }

    @Test func growingTheSelectionKeepsWhatWasTyped() {
        let (list, saved) = editingList()
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = "Alpha Beta"
        list.editClickBegan(extend: true)
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: true)
        list.editClickEnded()
        #expect(list.wordEdit?.range == 0...1 && list.editField.stringValue == "Alpha Beta")
        press(list, #selector(NSResponder.insertNewline(_:)))
        #expect(saved() == [Saved(words: ["alpha", "beta"], text: "Alpha Beta", addTerm: false)])
        // Nothing typed: the field starts again with the words it now covers.
        list.table.handleWordClick(row: 1, word: 0, through: 0, extend: false)
        list.table.handleWordClick(row: 1, word: 1, through: 1, extend: true)
        #expect(list.editField.stringValue == "epsilon zeta")
    }

    @Test func aMergedWordFromAnAppleTranscriptIsFollowedByWhatItShows() {
        let (list, saved) = editingList()
        var words = TurnListViewTests.words
        // Apple's ranges: " beta" carries the space before it.
        words["T1"] = [TurnListViewTests.word("T1", 0, "alpha", 0), TurnListViewTests.word("T1", 1, " beta", 1)]
        update(list, words: words, moves: [])
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = ""
        press(list, #selector(NSResponder.insertTab(_:)))
        #expect(list.wordEdit?.words.map(\.text) == [" beta"] && list.editField.stringValue == "beta")
        list.editField.stringValue = "Beta"
        // Saved: "alpha" merged into "beta", whose range no longer starts with a space.
        words["T1"] = [TurnListViewTests.word("T1", 0, "beta", 0)]
        update(list, words: words, moves: [ReviewWordMove(segmentID: "T1", replaced: 0..<1, replacement: 0..<0)])
        #expect(list.wordEdit?.words.first?.ref == WordRef(segmentID: "T1", word: 0))
        #expect(list.editField.stringValue == "Beta")
        #expect(saved().count == 1)
    }

    @Test func theFieldStartsWithTheWordsTextAsTheTranscriptHasIt() {
        let (list, _) = editingList()
        // The review gives a word's text with the punctuation the recognizer did not time.
        list.editText = { words in words.map(\.text) == ["beta"] ? "beta." : nil }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        #expect(list.editField.stringValue == "beta.")
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        #expect(list.editField.stringValue == "alpha")
    }

    @Test func noFieldOpensWhileWordsCannotBeEdited() {
        let (list, saved) = editingList()
        var played: [Double] = []
        list.onPlay = { played.append($0) }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "Beta"
        // The transcript changed after labelling: the open field closes, what was typed is queued (the review refuses
        // it, saying what was typed), and none opens.
        list.canEditWords = false
        #expect(list.wordEdit == nil && saved().map(\.text) == ["Beta"])
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        #expect(list.wordEdit == nil && played.isEmpty)
    }

    /// Tab saved one edit and opened the next field; the first edit's labels could not be reread, so the review turned
    /// read-only: the open field's text is handed over to be queued (it waits for the reread), never only shown.
    @Test func aFieldOpenWhenTheReviewTurnsReadOnlyIsKeptAsAnEdit() {
        let (list, saved) = editingList()
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        var kept: [([String], String)] = []
        list.onKeepWordEdit = { words, text, _ in kept.append((words.map(\.text), text)) }
        list.editingWords = true
        list.table.handleWordClick(row: 0, word: 1, through: 1, extend: false)
        list.editField.stringValue = "Beta"
        list.canEditWords = false
        #expect(list.wordEdit == nil && saved().isEmpty)
        #expect(kept.count == 1 && kept.first?.0 == ["beta"] && kept.first?.1 == "Beta")
        #expect(messages.allSatisfy { $0 == nil }, "Nothing is left only in the banner.")
        // A field holding nothing new is closed with nothing to keep.
        list.canEditWords = true
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.canEditWords = false
        #expect(list.wordEdit == nil && kept.count == 1)
    }

    @Test func editModeTurnsOnOnlyWhileTheReviewIsEditable() {
        #expect(ReviewWindow.editModeAfterToggle(on: false, editable: true))
        #expect(!ReviewWindow.editModeAfterToggle(on: false, editable: false), "Read-only: ⌘E does not turn it on.")
        #expect(!ReviewWindow.editModeAfterToggle(on: true, editable: false), "It can always be turned off.")
        #expect(!ReviewWindow.editModeAfterToggle(on: true, editable: true))
    }
}
