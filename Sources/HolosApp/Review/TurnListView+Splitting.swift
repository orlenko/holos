import AppKit
import HolosCore
import HolosMeeting

/// A split asked for at a word as the list showed it: before `word`, or after it (`after`), with the word moves and
/// words epoch it was chosen under, so the review finds where the word is now (`ReviewSession.splitPlace`).
struct ReviewSplitRequest: Equatable {
    var word: WordRef
    var after: Bool
    /// The turn the word was chosen in (turns may overlap: the split is that turn's).
    var turnID: String?
    var movesSeen: Int
    var wordsEpoch: Int
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

/// Splitting a turn where its words are (docs/meeting-design.md §5.10): in edit mode, Return with the caret at the
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
        let typed = editField.stringValue
        guard TranscriptWordEdit.cleaned(typed) == TranscriptWordEdit.cleaned(target.shown) else { return false }
        let selection = editor.selectedRange
        let length = (typed as NSString).length
        guard selection.length == 0, selection.location == 0 || selection.location == length else { return false }
        let atStart = selection.location == 0
        let request = ReviewSplitRequest(word: atStart ? first.ref : last.ref, after: !atStart,
                                         turnID: turnID(ofWordAt: target.range.lowerBound,
                                                        in: target.paragraphID),
                                         movesSeen: target.movesSeen, wordsEpoch: target.wordsEpoch,
                                         field: .init(words: target.words, text: typed))
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
    func splitOffer(row: Int, word: ReviewWord) -> (choice: SplitChoice, refusal: String?)? {
        guard row >= 0, row < paragraphs.count else { return nil }
        let shown = paragraphWords(paragraphs[row])
        guard shown.words.first?.ref != word.ref else { return nil }
        let index = shown.words.firstIndex { $0.ref == word.ref }
        let request = ReviewSplitRequest(word: word.ref, after: false,
                                         turnID: index.map { paragraphs[row].turns[shown.turns[$0]].id },
                                         movesSeen: wordMoves.count, wordsEpoch: wordsEpoch)
        guard let resolution = resolveSplit?(request) else { return nil }
        if case .refused(let why) = resolution { return (SplitChoice(request), why) }
        return (SplitChoice(request), nil)
    }

    /// Split Turn Here chosen: the request the menu made, resolved again now (the word followed since).
    func splitChosen(_ choice: SplitChoice) {
        guard case .split(let split)? = resolveSplit?(choice.request) else { return }
        onSplit?(split, choice.request)
    }

    /// The turn of row `paragraphID` its word `index` belongs to.
    func turnID(ofWordAt index: Int, in paragraphID: String) -> String? {
        guard let paragraph = paragraphs.first(where: { $0.id == paragraphID }) else { return nil }
        let turns = paragraphWords(paragraph).turns
        return index >= 0 && index < turns.count ? paragraph.turns[turns[index]].id : nil
    }

    /// After a split: the row the second part starts (its first word `word`) is selected and shown, and its speaker
    /// pop-up opens (`openSpeakerMenu`), so its speaker can be chosen at once; it keeps the first part's until then.
    /// False when no row shown starts at `word` (a search may hide it).
    @discardableResult
    func focusSpeaker(startingAt word: WordRef) -> Bool {
        guard let row = paragraphs.firstIndex(where: { paragraphWords($0).words.first?.ref == word }) else {
            return false
        }
        select(paragraphs[row].turnIDs, scroll: true)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TurnCellView else { return false }
        window?.makeFirstResponder(cell.speakerPopUp)
        openSpeakerMenu(cell.speakerPopUp)
        return true
    }
}
