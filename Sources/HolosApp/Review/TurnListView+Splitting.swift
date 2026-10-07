import AppKit
import HolosCore
import HolosMeeting

/// Splitting a turn where its words are (docs/meeting-design.md §5.10): in edit mode, Return with the caret at the
/// start of the field's words and nothing changed splits the turn before them (at the end: after them); outside it, a
/// word's context menu offers Split Turn Here. Either way the split is the window's (`onSplit`: the review's
/// `split`, undoable, or a paragraph break when the word starts a turn of the row), checked first as the review checks
/// it (`splitRefusal`), and the second part's speaker pop-up opens so it can be given its speaker at once
/// (`focusSpeaker`). The Split Turn sheet stays for choosing a place without the mouse on the words.
extension TurnListView {
    /// Return at the start of a turn's words: there is nothing before them to split from.
    static let alreadyStartsHere = "The turn already starts here. Return at the start of a later word splits the "
        + "turn before it."
    /// Return at the end of a row's last word.
    static let alreadyEndsHere = "The turn already ends here."

    /// What splitting `paragraph` before its word `index` (into the row's words) does; nil before its first word or
    /// past its words.
    func split(of paragraph: ReviewParagraph, before index: Int) -> ReviewParagraphSplit? {
        ReviewParagraphs.split(paragraph, words: paragraph.turns.map(words), at: index)
    }

    /// Return in the edit field: when nothing was changed and the caret (no text selected) is at the very start of
    /// the field, the turn splits before its first word; at the very end, after its last word. Anything else is a
    /// usual Return (false). A split that cannot be made says why in the banner, and the field stays open.
    func splitFromField() -> Bool {
        guard let target = wordEdit, let editor = editField.currentEditor() else { return false }
        let typed = editField.stringValue
        guard TranscriptWordEdit.cleaned(typed) == TranscriptWordEdit.cleaned(target.shown) else { return false }
        let selection = editor.selectedRange
        let length = (typed as NSString).length
        guard selection.length == 0, selection.location == 0 || selection.location == length,
              let row = paragraphs.firstIndex(where: { $0.id == target.paragraphID }) else { return false }
        let atStart = selection.location == 0
        let paragraph = paragraphs[row]
        let index = atStart ? target.range.lowerBound : target.range.upperBound + 1
        guard let split = split(of: paragraph, before: index) else {
            onEditMessage?(atStart ? Self.alreadyStartsHere : Self.alreadyEndsHere)
            return true
        }
        if let refusal = splitRefusal?(split) {
            onEditMessage?(refusal)
            return true
        }
        cancelWordEdit()
        onSplit?(split)
        return true
    }

    /// Split Turn Here on word `word` of `row`: nil when none is offered (the row's first word), else why it cannot be
    /// made (nil inside when it can).
    func splitOffer(row: Int, word: Int) -> String?? {
        guard row >= 0, row < paragraphs.count, let split = split(of: paragraphs[row], before: word) else { return nil }
        return .some(splitRefusal?(split) ?? nil)
    }

    /// Split Turn Here chosen.
    func splitHere(row: Int, word: Int) {
        guard row >= 0, row < paragraphs.count, let split = split(of: paragraphs[row], before: word),
              splitRefusal?(split) == nil else { return }
        onSplit?(split)
    }

    /// After a split: the row the second part starts (its first word `word`) is selected and shown, and its speaker
    /// pop-up opens (`openSpeakerMenu`), so its speaker can be chosen at once; it keeps the first part's until then.
    /// False when no row starts at `word`.
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
