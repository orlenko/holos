import AppKit
import HolosCore
import HolosMeeting

/// A split asked for at a word as the list showed it: before `word`, or after it (`after`), with the revision it was
/// chosen under, so the review finds where the word is now (`ReviewSession.splitPlace`).
struct ReviewSplitRequest: Equatable {
    var word: WordRef
    var after: Bool
    /// The turn the word was chosen in (turns may overlap: the split is that turn's).
    var turnID: String?
    /// The word moves and words epoch `word` follows, and the speaker labels' run the turns were shown from: labelled
    /// again since (a new run that did not keep them), a turn ID may name another turn, so the split is refused
    /// (`ReviewWindow.resolveSplit`).
    var seen: ReviewRevision
    /// The edit field's words and text when Return asked for the split: the field opens again over them, saying
    /// why, when the split is then refused (an edit saved meanwhile changed what it can do).
    var field: Field?

    struct Field: Equatable {
        var words: [ReviewWord]
        var text: String
    }
}

/// What a split request makes (`TurnListView.resolveSplit`): the split, or why there is none.
enum ReviewSplitResolution: Equatable {
    case split(ReviewParagraphSplit)
    case refused(String)
}

/// A Split Turn Here menu item's request, as the row showed the word when the menu opened.
final class SplitChoice: NSObject {
    let request: ReviewSplitRequest

    init(_ request: ReviewSplitRequest) { self.request = request }
}

/// Splitting a turn where its words are (docs/meeting/review-window.md §5.10): in edit mode, Return with the caret at the
/// start of the field's words and nothing changed splits the turn before them (at the end: after them); outside it, a
/// word's context menu offers Split Turn Here. The place is the word as the list showed it, with the word moves and
/// words epoch it was chosen under: the window has the review find where it is now (`resolveSplit`), so a word edit
/// saved since moves it, and words changed elsewhere refuse it; never an index read again after the words changed.
/// The split is checked as the review checks it (refused: the banner or a disabled item says why, and the field
/// stays), then made (`onSplit`: the review's undoable split, or a break of the row before a turn it holds), and the
/// second part's speaker pop-up opens (`focusSpeaker`). The Split Turn sheet stays for choosing a place by keyboard.
extension TurnListView {
    /// Return at the start of a row's first word: there is nothing before it to split from.
    static let alreadyStartsHere = "The turn already starts here. Return at the start of a later word splits the "
        + "turn before it."
    /// Return at the end of a row's last word.
    static let alreadyEndsHere = "The turn already ends here."

    /// Return in the edit field: when nothing was changed and the caret (no text selected) is at the very start of
    /// the field, the turn splits before its first word; at the very end, after its last word. Anything else is a
    /// usual Return (false).
    func splitFromField() -> Bool {
        guard let target = wordEdit, let editor = editField.currentEditor(),
              let first = target.words.first, let last = target.words.last else { return false }
        // Unchanged exactly: a space typed at the end is a change (Return then saves it, as before), never a split.
        let typed = editField.stringValue
        guard typed == target.shown else { return false }
        let selection = editor.selectedRange
        let length = (typed as NSString).length
        guard selection.length == 0, selection.location == 0 || selection.location == length else { return false }
        let atStart = selection.location == 0
        let request = ReviewSplitRequest(word: atStart ? first.ref : last.ref, after: !atStart,
                                         turnID: target.turnID ?? turnID(ofWordAt: target.range.lowerBound,
                                                                         in: target.paragraphID),
                                         seen: target.seen, field: .init(words: target.words, text: typed))
        switch resolveSplit?(request) {
        case .split(let split)?:
            cancelWordEdit()
            onSplit?(split, request)
        case .refused(let why)?:
            onEditMessage?(why)
        case nil:
            return false
        }
        return true
    }

    /// Split Turn Here on `word` of `row` (as the row shows it): nil on the row's first word, where there is nothing
    /// to split from; else the item's request, with why it cannot be made (nil when it can).
    func splitOffer(row: Int, word: ReviewWord, index: Int) -> (choice: SplitChoice, refusal: String?)? {
        guard let request = splitRequest(row: row, index: index), request.word == word.ref,
              let resolution = resolveSplit?(request) else { return nil }
        if case .refused(let why) = resolution { return (SplitChoice(request), why) }
        return (SplitChoice(request), nil)
    }

    /// A split before word `index` of `row` as the row shows it (that copy of it: overlapping turns of a row may show a
    /// word twice, and the split is its turn's): nil on the row's first word, where there is nothing to split from.
    func splitRequest(row: Int, index: Int) -> ReviewSplitRequest? {
        guard row >= 0, row < paragraphs.count else { return nil }
        return splitRequest(in: paragraphs[row], shown: paragraphWords(paragraphs[row]), index: index)
    }

    /// `splitRequest(row:index:)` for every word of `row`, its words worked out once (VoiceOver's actions list one per
    /// word).
    func splitRequests(row: Int) -> [ReviewSplitRequest?] {
        guard row >= 0, row < paragraphs.count else { return [] }
        let shown = paragraphWords(paragraphs[row])
        return shown.words.indices.map { splitRequest(in: paragraphs[row], shown: shown, index: $0) }
    }

    private func splitRequest(in paragraph: ReviewParagraph, shown: (words: [ReviewWord], turns: [Int]),
                              index: Int) -> ReviewSplitRequest? {
        guard index > 0, index < shown.words.count, index < shown.turns.count else { return nil }
        return ReviewSplitRequest(word: shown.words[index].ref, after: false,
                                  turnID: paragraph.turns[shown.turns[index]].id,
                                  seen: revision)
    }

    /// Split Turn Here chosen: the request the menu made, resolved again now (the word followed since). Refused now
    /// (an edit replaced the word while the menu was open, words changed elsewhere), the window says why.
    func splitChosen(_ choice: SplitChoice) {
        switch resolveSplit?(choice.request) {
        case .split(let split)?: onSplit?(split, choice.request)
        case .refused(let why)?: onSplitRefused?(why)
        case nil: break
        }
    }

    /// Opens the field over the word at `ref` (where it is shown now), with its own text, the caret at its start (or
    /// end, `atEnd`), and `message` in the banner: a split asked from the field whose word an edit replaced meanwhile.
    /// `inTurn`: the turn the field was opened in, whose copy of the word it opens over (when that turn is shown).
    @discardableResult
    func reopenField(at ref: WordRef, atEnd: Bool, message: String, inTurn: String? = nil) -> Bool {
        guard editingWords, editable, canEditWords, wordEdit == nil else { return false }
        // Only that turn's copy, never another turn's standing in (a search hiding the turn: the caller clears it).
        let turn = inTurn
        for (row, paragraph) in paragraphs.enumerated() {
            let shown = paragraphWords(paragraph)
            guard let index = shown.words.indices.first(where: {
                shown.words[$0].ref == ref && (turn == nil || paragraph.turns[shown.turns[$0]].id == turn)
            }) else { continue }
            beginEditing(row: row, from: index, through: index, extend: false)
            guard wordEdit != nil else { return false }
            let length = (editField.stringValue as NSString).length
            editField.currentEditor()?.selectedRange = NSRange(location: atEnd ? length : 0, length: 0)
            onEditMessage?(message)
            return true
        }
        return false
    }

    /// Whether the keyboard is in a text field (a word's edit field, a speaker's name, the search field): a split that
    /// finishes then opens no pop-up, which would end that editing (saving a word half typed, dropping a name not yet
    /// saved).
    var typingElsewhere: Bool {
        wordEdit != nil || (window?.firstResponder as? NSText)?.isFieldEditor == true
    }

    /// The turn of row `paragraphID` its word `index` belongs to.
    func turnID(ofWordAt index: Int, in paragraphID: String) -> String? {
        guard let paragraph = paragraphs.first(where: { $0.id == paragraphID }) else { return nil }
        let turns = paragraphWords(paragraph).turns
        return index >= 0 && index < turns.count ? paragraph.turns[turns[index]].id : nil
    }

    /// After a split: the row the second part starts (its first word `word`; its first turn `turnID` when known, else
    /// a part split from `splitOf`) is selected and shown, and its speaker pop-up opens (`openSpeakerMenu`), so its
    /// speaker can be chosen at once; it keeps the first part's until then. Overlapping turns may start two rows at
    /// one word: the turn decides, and a row of another turn is never taken for it. False when no row shown starts
    /// there with that turn (a search may hide it).
    @discardableResult
    func focusSpeaker(startingAt word: WordRef, turnID: String? = nil, splitOf: String? = nil) -> Bool {
        // Typing elsewhere since the split was asked (the split took a while): never pulled away from it.
        guard !typingElsewhere else { return false }
        let starting = paragraphs.indices.filter { paragraphWords(paragraphs[$0]).words.first?.ref == word }
        let chosen = starting.first { row in
            let first = paragraphs[row].turns[0].id
            if let turnID { return first == turnID }
            if let splitOf { return first.hasPrefix(splitOf + "/") }
            return true
        }
        guard let row = chosen else { return false }
        select(paragraphs[row].turnIDs, scroll: true)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TurnCellView else { return false }
        window?.makeFirstResponder(cell.speakerPopUp)
        openSpeakerMenu(cell.speakerPopUp)
        return true
    }
}
