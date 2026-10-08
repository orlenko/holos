import AppKit
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import Testing
@testable import HolosApp

/// Joining a row to the row before it (docs/meeting-design.md §5.10), the inverse of Return's split, laid out
/// offscreen with `TurnListViewTests`' synthetic turns: row 0 is T1 "alpha beta" and T2 "gamma delta" (S1), row 1 T3
/// "epsilon zeta" (S2).
@MainActor
struct TurnListJoinTests {
    @discardableResult
    private func press(_ list: TurnListView, _ command: Selector) -> Bool {
        list.control(list.editField, textView: NSTextView(), doCommandBy: command)
    }

    /// The window's resolver over the rows shown (`ReviewWindow.joinResolution`), or `refusal` when set (the review
    /// held read-only, say). Records the joins made, with their requests.
    private func joining(_ list: TurnListView, refusal: @escaping () -> String? = { nil })
        -> () -> [(join: ReviewParagraphJoin, request: ReviewJoinRequest)] {
        var joins: [(join: ReviewParagraphJoin, request: ReviewJoinRequest)] = []
        list.resolveJoin = { request in
            if let why = refusal() { return .refused(why) }
            return ReviewWindow.joinResolution(paragraphID: request.paragraphID, forward: request.forward,
                                               paragraphs: list.paragraphs)
        }
        list.onJoin = { joins.append(($0, $1)) }
        return { joins }
    }

    /// Opens the field over word `word` of `row` with the caret at `caret` (nil: the word selected, as it opens).
    private func field(_ list: TurnListView, row: Int, word: Int, caret: Int?) {
        list.table.handleWordClick(row: row, word: word, through: word, extend: false)
        if let caret { list.editField.currentEditor()?.selectedRange = NSRange(location: caret, length: 0) }
    }

    private static let s1Joined = ReviewParagraphJoin(reassign: ["T3"], speakerID: "S1", turnID: "T3")

    /// Backspace with the caret at the very start of a row's first word, nothing changed: the row joins the row before
    /// it, taking its speaker (S2's T3 goes to S1). The field closes; the window opens it again where the rows met.
    @Test func backspaceAtTheStartOfARowJoinsItToTheRowBefore() throws {
        let list = TurnListViewTests.list()
        let joins = joining(list)
        list.editingWords = true
        field(list, row: 1, word: 0, caret: 0)
        #expect(press(list, #selector(NSResponder.deleteBackward(_:))))
        #expect(joins().map(\.join) == [Self.s1Joined])
        let epsilon = try #require(TurnListViewTests.words["T3"]?[0]).ref
        #expect(joins().first?.request == ReviewJoinRequest(paragraphID: "T3", forward: false, word: epsilon,
                                                            turnID: "T3", runID: nil, fromField: true))
        #expect(list.wordEdit == nil, "Nothing was typed: the field closed.")
    }

    /// Forward Delete with the caret at the very end of a row's last word joins the row after it.
    @Test func forwardDeleteAtTheEndOfARowJoinsTheNextRowToIt() throws {
        let list = TurnListViewTests.list()
        let joins = joining(list)
        list.editingWords = true
        field(list, row: 0, word: 3, caret: ("delta" as NSString).length)
        #expect(press(list, #selector(NSResponder.deleteForward(_:))))
        #expect(joins().map(\.join) == [Self.s1Joined])
        let delta = try #require(TurnListViewTests.words["T2"]?[1]).ref
        #expect(joins().first?.request.forward == true && joins().first?.request.word == delta)
        #expect(joins().first?.request.turnID == "T2")
    }

    /// Anywhere but a row's edge, with the word selected, or with something typed, Backspace and Delete are the
    /// field's own: they edit the text as always, and nothing joins.
    @Test func backspaceAndDeleteElsewhereEditTheTextAsAlways() {
        let list = TurnListViewTests.list()
        let joins = joining(list)
        list.editingWords = true
        // Inside a word.
        field(list, row: 1, word: 0, caret: 2)
        #expect(!press(list, #selector(NSResponder.deleteBackward(_:))))
        #expect(!press(list, #selector(NSResponder.deleteForward(_:))))
        list.cancelWordEdit()
        // The word selected, as the field opens: Backspace deletes it.
        field(list, row: 1, word: 0, caret: nil)
        #expect(!press(list, #selector(NSResponder.deleteBackward(_:))))
        list.cancelWordEdit()
        // At the start of a word inside a row, even one that starts a turn ("gamma", T2): they read as one already.
        field(list, row: 0, word: 2, caret: 0)
        #expect(!press(list, #selector(NSResponder.deleteBackward(_:))))
        list.cancelWordEdit()
        field(list, row: 0, word: 1, caret: 0)
        #expect(!press(list, #selector(NSResponder.deleteBackward(_:))))
        list.cancelWordEdit()
        // Backspace at the end of a row, forward Delete at its start.
        field(list, row: 0, word: 3, caret: 0)
        #expect(!press(list, #selector(NSResponder.deleteForward(_:))))
        list.cancelWordEdit()
        field(list, row: 1, word: 0, caret: ("epsilon" as NSString).length)
        #expect(!press(list, #selector(NSResponder.deleteBackward(_:))))
        list.cancelWordEdit()
        // Something typed: the field edits it.
        field(list, row: 1, word: 0, caret: nil)
        list.editField.stringValue = "Epsilon"
        list.editField.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
        #expect(!press(list, #selector(NSResponder.deleteBackward(_:))))
        #expect(joins().isEmpty)
    }

    /// Nothing to join with (the meeting's first row; its last, forward), the review held read-only, edit mode off:
    /// no join. At the meeting's edges and when refused, the banner says why and the field stays.
    @Test func noJoinAtTheMeetingsEdgesWhileReadOnlyOrOutsideEditMode() {
        let list = TurnListViewTests.list()
        var refusal: String?
        let joins = joining(list, refusal: { refusal })
        var messages: [String?] = []
        list.onEditMessage = { messages.append($0) }
        // Outside edit mode no field is open: the keys are the table's.
        #expect(!press(list, #selector(NSResponder.deleteBackward(_:))))
        list.editingWords = true
        field(list, row: 0, word: 0, caret: 0)
        #expect(press(list, #selector(NSResponder.deleteBackward(_:))))
        #expect(messages.last == TurnListView.nothingBefore && list.wordEdit != nil)
        list.cancelWordEdit()
        field(list, row: 1, word: 1, caret: ("zeta" as NSString).length)
        #expect(press(list, #selector(NSResponder.deleteForward(_:))))
        #expect(messages.last == TurnListView.nothingAfter && list.wordEdit != nil)
        list.cancelWordEdit()
        refusal = "This meeting cannot be changed right now."
        field(list, row: 1, word: 0, caret: 0)
        #expect(press(list, #selector(NSResponder.deleteBackward(_:))))
        #expect(messages.last == refusal && list.wordEdit != nil)
        list.cancelWordEdit()
        #expect(joins().isEmpty)
        // Edit mode off: the field closed with it.
        list.editingWords = false
        #expect(list.wordEdit == nil && !press(list, #selector(NSResponder.deleteBackward(_:))))
    }

    /// The window finds the rows among all it groups (a search may hide the one before): the first row shown is not
    /// the meeting's first then, and a row no longer starting with that turn is refused.
    @Test func theRowBeforeIsFoundAmongEveryRowGrouped() {
        let all = ReviewParagraphs.group(TurnListViewTests.turns)
        #expect(ReviewWindow.joinResolution(paragraphID: "T3", forward: false, paragraphs: all) == .join(Self.s1Joined))
        #expect(ReviewWindow.joinResolution(paragraphID: "T1", forward: true, paragraphs: all) == .join(Self.s1Joined))
        #expect(ReviewWindow.joinResolution(paragraphID: "T1", forward: false, paragraphs: all)
            == .nothing(TurnListView.nothingBefore))
        #expect(ReviewWindow.joinResolution(paragraphID: "T3", forward: true, paragraphs: all)
            == .nothing(TurnListView.nothingAfter))
        #expect(ReviewWindow.joinResolution(paragraphID: "T2", forward: false, paragraphs: all)
            == .refused(ReviewWindow.joinNotShown))
    }

    /// After the join the rows are one, and the field opens again where they met (`reopenField` at the request's
    /// word): the caret at the start of "epsilon", right after "delta", so typing goes on there. Backspace there is
    /// inside the row now: the field's own. Forward Delete's field opens at the end of "delta".
    @Test func theCaretEndsWhereTheRowsMet() throws {
        let list = TurnListViewTests.list()
        let joins = joining(list)
        list.editingWords = true
        field(list, row: 1, word: 0, caret: 0)
        press(list, #selector(NSResponder.deleteBackward(_:)))
        let request = try #require(joins().first?.request)
        // As the window shows it once the speaker change is in: T3 is S1's and joined to the row before.
        var turns = TurnListViewTests.turns
        turns[2] = TurnListViewTests.turn("T3", "S1", 6, 8)
        let joined = ReviewParagraphs.group(turns, joins: ["T3"])
        list.update(paragraphs: joined, speakers: [TurnListViewTests.speaker("S1", 1)], people: [], editable: true,
                    text: { (TurnListViewTests.words[$0.id] ?? []).map(\.text).joined(separator: " ") },
                    words: { TurnListViewTests.words[$0.id] ?? [] }, resolve: { $0 })
        #expect(list.paragraphs.map(\.turnIDs) == [["T1", "T2", "T3"]])
        #expect(list.reopenField(at: request.word, atEnd: request.forward, message: TurnListView.joinedSpeaker,
                                 inTurn: request.turnID))
        #expect(list.wordEdit?.words.map(\.text) == ["epsilon"] && list.wordEdit?.range == 4...4)
        #expect(list.editField.currentEditor()?.selectedRange == NSRange(location: 0, length: 0))
        #expect(!press(list, #selector(NSResponder.deleteBackward(_:))), "Inside the row now: nothing more joins.")
        list.cancelWordEdit()
        let delta = try #require(TurnListViewTests.words["T2"]?[1]).ref
        #expect(list.reopenField(at: delta, atEnd: true, message: TurnListView.joined, inTurn: "T2"))
        #expect(list.editField.currentEditor()?.selectedRange == NSRange(location: 5, length: 0))
        #expect(!press(list, #selector(NSResponder.deleteForward(_:))))
        #expect(joins().count == 1)
    }

    /// Return splits a turn, Backspace at the start of its second part joins it back: the same speaker, so only the
    /// window joins the rows (nothing saved); they read as before. Return there again splits them as before.
    @Test func aSplitJoinedBackReadsAsBeforeAndSplitsAgain() throws {
        let list = TurnListViewTests.list()
        let joins = joining(list)
        // T1 split before "beta": its second part "T1/e" starts a row of its own, joined by T2.
        var turns = TurnListViewTests.turns
        turns.insert(TurnListViewTests.turn("T1/e", "S1", 1, 2), at: 1)
        var words = TurnListViewTests.words
        let beta = try #require(words["T1"]?[1])
        words["T1"] = [try #require(TurnListViewTests.words["T1"]?[0])]
        words["T1/e"] = [beta]
        var breaks = ReviewParagraphBreaks()
        func show() {
            let active = breaks.active(in: turns, runID: "R1")
            list.update(paragraphs: ReviewParagraphs.group(turns, breaks: active, joins: breaks.joins),
                        speakers: [TurnListViewTests.speaker("S1", 1), TurnListViewTests.speaker("S2", 2)],
                        people: [], editable: true, text: { (words[$0.id] ?? []).map(\.text).joined(separator: " ") },
                        words: { words[$0.id] ?? [] }, resolve: { $0 })
        }
        show()
        #expect(list.paragraphs.map(\.turnIDs) == [["T1"], ["T1/e", "T2"], ["T3"]])
        list.editingWords = true
        field(list, row: 1, word: 0, caret: 0)
        press(list, #selector(NSResponder.deleteBackward(_:)))
        let join = try #require(joins().first?.join)
        #expect(join == ReviewParagraphJoin(reassign: [], speakerID: "S1", turnID: "T1/e"))
        breaks.join(try #require(turns.first { $0.id == join.turnID }), runID: "R1")
        show()
        #expect(list.paragraphs.map(\.turnIDs) == [["T1", "T1/e", "T2"], ["T3"]])
        // Return at the start of "beta" again: the place starts T1/e's turn, so the row breaks there.
        var splits: [ReviewParagraphSplit] = []
        list.resolveSplit = { _ in
            ReviewWindow.splitResolution(.turnStart(turnID: "T1/e"), paragraphs: list.paragraphs) { _, _ in nil }
        }
        list.onSplit = { split, _ in splits.append(split) }
        field(list, row: 0, word: 1, caret: 0)
        press(list, #selector(NSResponder.insertNewline(_:)))
        #expect(splits == [.breakBefore(turnID: "T1/e")])
        breaks.insert(before: try #require(turns.first { $0.id == "T1/e" }), runID: "R1")
        show()
        #expect(list.paragraphs.map(\.turnIDs) == [["T1"], ["T1/e", "T2"], ["T3"]])
    }

    /// Outside edit mode, a row's first word offers Join With Previous Turn in its context menu: not on another word,
    /// not on the meeting's first row, not in edit mode (Backspace joins there). Refused, it is disabled saying why;
    /// chosen anyway once refused, the window says why.
    @Test func theWordMenuJoinsWithThePreviousTurn() throws {
        let list = TurnListViewTests.list()
        var refusal: String?
        let joins = joining(list, refusal: { refusal })
        var refused: [String] = []
        list.onJoinRefused = { refused.append($0) }
        func menu(row: Int, _ index: Int) throws -> NSMenu {
            let cell = try TurnListViewTests.cell(list, row: row)
            return list.table.wordMenu(row: row, cell: cell, word: cell.bodyText.reviewWord(at: index), index: index)
        }
        func joinItem(row: Int, _ index: Int) throws -> NSMenuItem? {
            try menu(row: row, index).items.first { $0.title == TurnListView.joinTitle }
        }
        #expect(try joinItem(row: 0, 0) == nil, "The meeting's first row.")
        #expect(try joinItem(row: 1, 1) == nil, "Not the row's first word.")
        let item = try #require(try joinItem(row: 1, 0))
        #expect(item.isEnabled && item.toolTip == TurnListView.joinHelp)
        let action = try #require(item.action)
        _ = (item.target as AnyObject?)?.perform(action, with: item)
        #expect(joins().map(\.join) == [Self.s1Joined])
        #expect(joins().first?.request.fromField == false)
        refusal = "This meeting cannot be changed right now."
        let disabled = try #require(try joinItem(row: 1, 0))
        #expect(!disabled.isEnabled && disabled.toolTip == refusal)
        list.joinChosen(try #require(disabled.representedObject as? JoinChoice))
        #expect(joins().count == 1 && refused == ["This meeting cannot be changed right now."])
        list.editingWords = true
        #expect(try joinItem(row: 1, 0) == nil)
    }

    /// VoiceOver reaches it through the text's actions: "Join With Previous Turn" on a row that has a row before it,
    /// none on the meeting's first row nor in edit mode.
    @Test func voiceOverJoinsWithThePreviousTurn() throws {
        let list = TurnListViewTests.list()
        var refusal: String?
        let joins = joining(list, refusal: { refusal })
        var refused: [String] = []
        list.onJoinRefused = { refused.append($0) }
        func joinActions(row: Int) throws -> [NSAccessibilityCustomAction] {
            (try TurnListViewTests.cell(list, row: row).bodyText.accessibilityCustomActions() ?? [])
                .filter { $0.name == TurnListView.joinTitle }
        }
        #expect(try joinActions(row: 0).isEmpty)
        let action = try #require(try joinActions(row: 1).first)
        #expect(try joinActions(row: 1).count == 1)
        #expect(action.handler?() == true)
        #expect(joins().map(\.join) == [Self.s1Joined])
        // Refused once chosen: why, and no join.
        refusal = "Not now."
        #expect(try #require(try joinActions(row: 1).first).handler?() == true)
        #expect(joins().count == 1 && refused == ["Not now."])
        list.editingWords = true
        #expect(try joinActions(row: 1).isEmpty)
    }
}
