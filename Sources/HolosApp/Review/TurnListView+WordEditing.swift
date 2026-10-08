import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers

/// The words being edited in a row (docs/meeting-design.md §5.10, "Editing words").
struct WordEditTarget: Equatable {
    /// The row's paragraph.
    var paragraphID: String
    /// Indices into the paragraph's words (every turn's, in order).
    var range: ClosedRange<Int>
    /// Where a ⇧-click extends from.
    var anchor: Int
    /// The words, as shown when editing began (their refs follow the saved words, `followWordEdit`).
    var words: [ReviewWord]
    /// Their text as shown, which the field started with.
    var shown: String
    /// How many of the review's word moves (`ReviewSession.wordMoves`) `words` already follow.
    var movesSeen: Int
    /// Each word as shown (`TurnListView.shownText(of:)`), which it must still read as when it is followed.
    var wordTexts: [String] = []
    /// `ReviewSession.wordsEpoch` when the field opened: words changed elsewhere since cannot be followed.
    var wordsEpoch = 0
    /// The turn the words were chosen in (overlapping turns of a row may show a word twice): a split asked from the
    /// field is that turn's, whatever copy following the words lands on.
    var turnID: String?
    /// The speaker labels' run `turnID` is of (`TurnListView.runID` when the field opened).
    var runID: String?
}

/// The field over the words being edited: the turn text's font, a bezel, and no wrapping.
final class WordEditField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        font = TurnListView.textFont
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        focusRingType = .default
        // Above the rows, which the table makes and replaces as it scrolls and reloads (never reordered: that would
        // end the editing).
        wantsLayer = true
        layer?.zPosition = 10
        setAccessibilityLabel("Edit words")
        setAccessibilityHelp("Return saves, Option-Return saves and adds it to the word list, Tab saves and edits the "
                             + "next word, Escape cancels. With nothing changed, Return with the cursor at the start "
                             + "splits the turn before the word, and at the end, after it. Delete with the cursor at "
                             + "the start of a turn joins it to the turn before, and Forward Delete at the end of a "
                             + "turn joins the next one to it.")
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { nil }

    /// The words being edited, in the table's coordinates (the field's own superview). The field is wider (at least
    /// 90 pt, with room to type), so it can lie over the next words.
    var wordsFrame: NSRect = .zero

    /// Whether the mouse-down being handled extends the selection (⇧ alone, as the table reads it).
    var extendsSelection: () -> Bool = {
        guard let event = NSApplication.shared.currentEvent, event.type == .leftMouseDown else { return false }
        return event.modifierFlags.intersection([.shift, .command, .control, .option]) == [.shift]
    }

    /// A ⇧-click on the field but beyond its words (on a word it lies over) goes to the table, which extends the
    /// selection to the word under it (`TurnTableView.mouseDown`); every other click edits the text in the field.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's (the table's) coordinates, as AppKit passes it; compared in the field's own,
        // with the words' frame brought there too, so the row the field is on never matters.
        if let superview, extendsSelection() {
            let local = convert(point, from: superview)
            if bounds.contains(local), !convert(wordsFrame, from: superview).contains(local) { return nil }
        }
        return super.hitTest(point)
    }
}

/// Edit mode of the turn list: a click on a word opens a field over it, prefilled and selected; ⇧-click or a drag in
/// the same row takes in more words, within one segment of one turn (shown words with consecutive stored indices, so
/// never across hidden echo). Return saves (`onEditWords`), ⌥Return saves and asks for the word list too, Tab and ⇧Tab
/// save and edit the next or previous word, Esc cancels; clicking elsewhere saves.
extension TurnListView: NSTextFieldDelegate {
    enum WordEditAdvance { case stay, next, previous }

    static let selectionStopped = "A selection stays within one segment of one speaker turn for now, so it stops "
        + "there. Edit the rest on its own."
    static let changedElsewhere = "The words were changed elsewhere while you edited them; nothing was saved. Click "
        + "them again."
    static let editedAcrossTurns = "These words were edited together and are now in two speaker turns, so they can be "
        + "neither edited nor reverted here; the other words of each turn can."

    /// A word as the transcript shows it (`editText`: with untimed punctuation, without a recognizer's leading space),
    /// else as the review read it (`ReviewWord.shown`). Anything that puts a field back on words compares this, never
    /// the timed text alone ("Hello." changed to "Hello?" elsewhere is another word).
    func shownText(of word: ReviewWord) -> String {
        editText?([word]) ?? word.shown
    }

    /// The paragraph's words (every turn's, in order) and the index of the turn each belongs to.
    func paragraphWords(_ paragraph: ReviewParagraph) -> (words: [ReviewWord], turns: [Int]) {
        var all: [ReviewWord] = []
        var turns: [Int] = []
        for (index, turn) in paragraph.turns.enumerated() {
            let turnWords = words(turn)
            all += turnWords
            turns += Array(repeating: index, count: turnWords.count)
        }
        return (all, turns)
    }

    /// Opens the field over words `from`…`through` of `row` (either order), or with `extend` over the words from the
    /// open field's anchor to `through` in the same row. The selection stops at the end of the anchor's segment and
    /// turn, and at hidden words (the banner says so).
    func beginEditing(row: Int, from: Int, through: Int, extend: Bool) {
        guard editingWords, editable, canEditWords, row >= 0, row < paragraphs.count else { return }
        let paragraph = paragraphs[row]
        let (all, turns) = paragraphWords(paragraph)
        guard from >= 0, through >= 0, from < all.count, through < all.count else { return }
        var anchor = from
        /// What was typed before a ⇧-click grew the selection: it stays in the field.
        var typed: String?
        // A ⇧-click grows the open field's selection from where it began.
        let extending = extend && wordEdit?.paragraphID == paragraph.id
        if extending, let open = wordEdit {
            anchor = open.anchor
        } else if wordEdit != nil {
            // Clicking elsewhere while the field is open saves what it holds first.
            commitWordEdit(addTerm: false, advance: .stay)
        }
        extendingWordEdit = false
        var lower = anchor
        var upper = anchor
        func joins(_ index: Int, _ neighbour: Int) -> Bool {
            turns[index] == turns[anchor] && all[index].ref.segmentID == all[anchor].ref.segmentID
                && abs(all[index].ref.word - all[neighbour].ref.word) == 1 && all[index].revertible
        }
        while upper < through, joins(upper + 1, upper) { upper += 1 }
        while lower > through, joins(lower - 1, lower) { lower -= 1 }
        // Words edited together that a relabel put in two turns (`ReviewWord.revertible`: an edit takes in all of them,
        // across the turns), and words known not to be editable (corrected while recording, an older fix in their
        // segment): no field opens, and the banner says why. A ⇧-click growing an open field onto them leaves that field
        // as it was, with what was typed and where.
        if let refusal = all[anchor].revertible ? editRefusal?(Array(all[lower...upper])) : Self.editedAcrossTurns {
            if extending { keepFieldAfterRefusedExtension() }
            onEditMessage?(refusal)
            return
        }
        if extending, let open = wordEdit {
            // Grown: the field starts again with the words it now covers, unless something was typed in it.
            let text = editField.stringValue
            if TranscriptWordEdit.cleaned(text) != TranscriptWordEdit.cleaned(open.shown) { typed = text }
            closeEditField()
        }
        let stopped = through > upper || through < lower
        onEditMessage?(stopped ? Self.selectionStopped : nil)
        openField(row: row, paragraph: paragraph, words: all, range: lower...upper, anchor: anchor)
        if let typed {
            editField.stringValue = typed
            editField.currentEditor()?.selectedRange = NSRange(location: (typed as NSString).length, length: 0)
        }
    }

    private func openField(row: Int, paragraph: ReviewParagraph, words all: [ReviewWord], range: ClosedRange<Int>,
                           anchor: Int) {
        // The words' text as the transcript has it (with the punctuation the recognizer did not time), else as shown.
        let shown = editText?(Array(all[range]))
            ?? textView(row: row)?.shownText(from: range.lowerBound, through: range.upperBound)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? all[range].map(\.text).joined(separator: " ")
        let owner = paragraphWords(paragraph).turns
        wordEdit = WordEditTarget(paragraphID: paragraph.id, range: range, anchor: anchor, words: Array(all[range]),
                                  shown: shown, movesSeen: wordMoves.count, wordTexts: all[range].map(shownText(of:)),
                                  wordsEpoch: wordsEpoch,
                                  turnID: range.lowerBound < owner.count ? paragraph.turns[owner[range.lowerBound]].id
                                      : nil, runID: runID)
        editField.stringValue = shown
        if editField.superview !== table { table.addSubview(editField) }
        positionEditField(row: row, range: range)
        table.scrollToVisible(editField.frame.insetBy(dx: 0, dy: -12))
        window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectAll(nil)
    }

    /// Saves what the field holds (when it changed) and closes it; then edits the next or previous word.
    func commitWordEdit(addTerm: Bool, advance: WordEditAdvance) {
        guard let target = wordEdit else { return }
        let typed = editField.stringValue
        closeEditField()
        if TranscriptWordEdit.cleaned(typed) != TranscriptWordEdit.cleaned(target.shown) {
            onEditWords?(target.words, typed, addTerm, target.movesSeen, target.wordsEpoch)
        }
        guard advance != .stay, let row = paragraphs.firstIndex(where: { $0.id == target.paragraphID }) else { return }
        let count = paragraphWords(paragraphs[row]).words.count
        switch advance {
        case .next:
            if target.range.upperBound + 1 < count {
                beginEditing(row: row, from: target.range.upperBound + 1, through: target.range.upperBound + 1,
                             extend: false)
            } else if row + 1 < paragraphs.count {
                beginEditing(row: row + 1, from: 0, through: 0, extend: false)
            }
        case .previous:
            if target.range.lowerBound > 0 {
                beginEditing(row: row, from: target.range.lowerBound - 1, through: target.range.lowerBound - 1,
                             extend: false)
            } else if row > 0 {
                let last = paragraphWords(paragraphs[row - 1]).words.count - 1
                if last >= 0 { beginEditing(row: row - 1, from: last, through: last, extend: false) }
            }
        case .stay:
            break
        }
    }

    /// A save of `words` was refused or failed before it was made: the field opens over them again with what was
    /// typed, and the banner says why. False (nothing opens) when another field is open or the words no longer read
    /// as they did; the window's message then carries what was typed. `caret`: where the caret goes in the text (a
    /// split asked from the field reopens with the caret where Return found it); nil, at the end. `inTurn`: the turn the
    /// field was opened in, whose copy of the words it reopens over (overlapping turns may show them twice).
    @discardableResult
    func reopenWordEdit(_ words: [ReviewWord], typed: String, message: String, movesSeen: Int? = nil,
                        wordsEpoch seenEpoch: Int? = nil, caret: Int? = nil, inTurn: String? = nil) -> Bool {
        guard editingWords, editable, canEditWords, wordEdit == nil,
              let firstWord = words.first, let lastWord = words.last else { return false }
        // The words where they are now: followed through the word moves saved since the field took them
        // (`movesSeen`), never across words changed elsewhere (`wordsEpoch`), which no move describes.
        if let seenEpoch, seenEpoch != wordsEpoch { return false }
        var first = firstWord.ref, last = lastWord.ref
        if let movesSeen, movesSeen < wordMoves.count {
            let followed = ReviewSession.follow([first, last], through: wordMoves.dropFirst(movesSeen))
            guard !followed.replaced, followed.refs.count == 2 else { return false }
            first = followed.refs[0]
            last = followed.refs[1]
        }
        // Only that turn's copy, never another turn's standing in (a search hiding the turn: the caller clears it).
        let turn = inTurn
        for (row, paragraph) in paragraphs.enumerated() {
            let shown = paragraphWords(paragraph)
            let all = shown.words
            let inIt = { (index: Int) in turn == nil || paragraph.turns[shown.turns[index]].id == turn }
            guard let from = all.indices.first(where: { all[$0].ref == first && inIt($0) }),
                  let through = all.indices.first(where: { $0 >= from && all[$0].ref == last && inIt($0) }),
                  all[from...through].map(\.shown) == words.map(\.shown) else { continue }
            beginEditing(row: row, from: from, through: through, extend: false)
            guard wordEdit != nil else { return false }
            editField.stringValue = typed
            let length = (typed as NSString).length
            editField.currentEditor()?.selectedRange = NSRange(location: min(max(caret ?? length, 0), length),
                                                                length: 0)
            onEditMessage?(message)
            return true
        }
        return false
    }

    /// The window is closing (AppKit ends no editing then): closes the field and hands over what it holds to be saved
    /// before the review closes; nil when nothing was typed. `wordsEpoch` is the one the field opened under: every save
    /// compares it, never the review's at the time of the save.
    func takeOpenWordEdit() -> (words: [ReviewWord], text: String, movesSeen: Int, wordsEpoch: Int)? {
        guard let target = wordEdit else { return nil }
        let typed = editField.stringValue
        closeEditField()
        guard TranscriptWordEdit.cleaned(typed) != TranscriptWordEdit.cleaned(target.shown) else { return nil }
        return (target.words, typed, target.movesSeen, target.wordsEpoch)
    }

    /// Closes the field without saving.
    func cancelWordEdit() {
        guard wordEdit != nil else { return }
        closeEditField()
    }

    private func closeEditField() {
        // Cleared first: the field ending its editing below must not save again.
        wordEdit = nil
        onEditMessage?(nil)
        let hadFocus = window?.firstResponder === editField.currentEditor() || window?.firstResponder === editField
        editField.abortEditing()
        editField.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(table) }
    }

    /// After the rows were updated: the open field follows its words through the review's word moves (an edit saved
    /// earlier in the segment, say the one Tab left, moves their stored indices; a deletion merged into one of them
    /// changes its time), and must still read the same. A word an edit replaced, and words that cannot be found (a
    /// search filtered their row away), close the field, and what was typed in it is queued as an edit
    /// (`keepWordEdit`), never lost.
    func followWordEdit() {
        guard let target = wordEdit else { return }
        // The words were changed elsewhere since the field opened (no word move says where its words went): the same
        // place may now hold other words reading the same. The field closes, saying what was typed; nothing is saved.
        guard target.wordsEpoch == wordsEpoch else {
            let typed = editField.stringValue
            closeEditField()
            let changed = TranscriptWordEdit.cleaned(typed) != TranscriptWordEdit.cleaned(target.shown)
            onEditMessage?(changed ? Self.changedElsewhere + TranscriptWordEdit.typedNote(typed) : Self.changedElsewhere)
            return
        }
        guard editingWords, editable, canEditWords,
              let row = paragraphs.firstIndex(where: { $0.id == target.paragraphID }) else {
            keepWordEdit()
            return
        }
        let shownWords = paragraphWords(paragraphs[row])
        let all = shownWords.words
        let followed = ReviewSession.follow(target.words.map(\.ref), through: wordMoves.dropFirst(target.movesSeen))
        var refs: [WordRef] = []
        for ref in followed.refs where refs.last != ref { refs.append(ref) }
        // The copy in the field's turn (overlapping turns of a row may show a word twice), else the first one shown,
        // whose turn the field then has (Return at its start splits the turn under it).
        let turnAt = { (index: Int) -> String? in
            index < shownWords.turns.count ? self.paragraphs[row].turns[shownWords.turns[index]].id : nil
        }
        let first = refs.first
        let start = all.indices.first { all[$0].ref == first && (target.turnID == nil || turnAt($0) == target.turnID) }
            ?? all.firstIndex { $0.ref == first }
        // A word an edit replaced is never followed onto another word: the field closes, keeping what was typed.
        guard !followed.replaced, first != nil, let start,
              start + refs.count <= all.count,
              zip(refs, all[start...]).allSatisfy({ $0 == $1.ref }),
              zip(target.wordTexts, all[start...]).allSatisfy({ $0 == shownText(of: $1) }) else {
            keepWordEdit()
            return
        }
        let range = start...(start + refs.count - 1)
        let shift = start - target.range.lowerBound
        wordEdit?.range = range
        wordEdit?.anchor = min(max(target.anchor + shift, range.lowerBound), range.upperBound)
        wordEdit?.words = Array(all[range])
        wordEdit?.wordTexts = all[range].map(shownText(of:))
        wordEdit?.movesSeen = wordMoves.count
        wordEdit?.turnID = turnAt(start) ?? target.turnID
        positionEditField(row: row, range: range)
    }

    /// The open field closes for any reason but Esc (its row filtered away by a search, its words moved or gone, edit
    /// mode turned off, the review turned read-only): what was typed is never dropped. It is queued as an edit
    /// (`onKeepWordEdit`, else `onEditWords`): the review's queue waits for a hold, follows the words through the
    /// moves since, and a refusal opens the field again with what was typed, or shows it in the banner.
    func keepWordEdit() {
        guard wordEdit != nil, let open = takeOpenWordEdit() else { return }
        if let keep = onKeepWordEdit {
            keep(open.words, open.text, open.movesSeen, open.wordsEpoch)
        } else {
            onEditWords?(open.words, open.text, false, open.movesSeen, open.wordsEpoch)
        }
    }

    /// Puts the open field back over its words after the rows' widths or heights changed.
    func repositionWordEdit() {
        guard let target = wordEdit, let row = paragraphs.firstIndex(where: { $0.id == target.paragraphID }) else {
            return
        }
        // The rows take the new column width before the words are measured.
        table.tile()
        positionEditField(row: row, range: target.range)
    }

    /// Puts the field over the words: from the first word, as wide as they are (at least a little wider, at most the
    /// rest of the line), one line high.
    private func positionEditField(row: Int, range: ClosedRange<Int>) {
        // Row heights and widths noted since are laid out first.
        table.layoutSubtreeIfNeeded()
        guard let text = textView(row: row), let first = text.rect(ofWord: range.lowerBound),
              let last = text.rect(ofWord: range.upperBound) else { return }
        let sameLine = abs(last.minY - first.minY) < 1
        let wordsWidth = sameLine ? last.maxX - first.minX : text.bounds.width - first.minX
        let width = min(max(wordsWidth + 28, 90), max(90, text.bounds.width - first.minX + 8))
        let origin = table.convert(NSPoint(x: first.minX, y: first.minY), from: text)
        editField.frame = NSRect(x: origin.x - 4, y: origin.y - 3, width: width, height: first.height + 6)
        // The words' own extent (on their first line): a ⇧-click beyond it reaches the word under it.
        editField.wordsFrame = NSRect(x: origin.x - 4, y: origin.y - 3, width: wordsWidth + 4,
                                      height: first.height + 6)
    }

    private func textView(row: Int) -> TurnTextView? {
        guard row < table.numberOfRows,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TurnCellView else { return nil }
        // A column resized a moment ago may not have reached the row's view yet: measured at the size the table gives
        // it, as the next layout will.
        let size = table.frameOfCell(atColumn: 0, row: row).size
        if size.width > 0, size.height > 0, cell.frame.size != size { cell.setFrameSize(size) }
        cell.layoutSubtreeIfNeeded()
        if let layout = cell.bodyText.layoutManager, let container = cell.bodyText.textContainer {
            layout.ensureLayout(for: container)
        }
        return cell.bodyText
    }

    /// Edit mode turned on or off: the text's pointer, the list's tint, and an open field (closed without saving).
    func editingWordsChanged() {
        table.editingWords = editingWords
        table.usesAlternatingRowBackgroundColors = !editingWords
        table.backgroundColor = editingWords ? NSColor.controlAccentColor.withAlphaComponent(0.06)
            : .controlBackgroundColor
        for row in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView)?.bodyText.editingWords
                = editingWords
        }
        // Edit mode turned off with the field open: what was typed is saved (only Esc drops it).
        if !editingWords { keepWordEdit() }
        table.needsDisplay = true
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === editField, wordEdit != nil else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let option = NSApplication.shared.currentEvent?.modifierFlags.contains(.option) == true
            // Return at the start (or end) of the words with nothing changed splits the turn there.
            if !option, splitFromField() { return true }
            commitWordEdit(addTerm: option, advance: .stay)
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commitWordEdit(addTerm: true, advance: .stay)
        case #selector(NSResponder.cancelOperation(_:)):
            cancelWordEdit()
        case #selector(NSResponder.insertTab(_:)):
            commitWordEdit(addTerm: false, advance: .next)
        case #selector(NSResponder.insertBacktab(_:)):
            commitWordEdit(addTerm: false, advance: .previous)
        // Backspace at the very start of a row (forward Delete at its very end) with nothing changed joins the rows
        // there; anywhere else they edit the text as always.
        case #selector(NSResponder.deleteBackward(_:)):
            return joinFromField(forward: false)
        case #selector(NSResponder.deleteForward(_:)):
            return joinFromField(forward: true)
        default:
            return false
        }
        return true
    }

    /// The field lost the keyboard (a click elsewhere): what it holds is saved, unless a ⇧-click is growing it.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === editField, wordEdit != nil, !extendingWordEdit else { return }
        commitWordEdit(addTerm: false, advance: .stay)
    }

    /// A ⇧-click could not grow the field (`beginEditing`): it stays open as it was, with the keyboard, what was
    /// typed, and the selection it had when the click came.
    private func keepFieldAfterRefusedExtension() {
        guard wordEdit != nil, editField.superview != nil else { return }
        let selection = selectionBeforeExtension
        selectionBeforeExtension = nil
        if window?.firstResponder !== editField.currentEditor() { window?.makeFirstResponder(editField) }
        if let selection, let editor = editField.currentEditor(),
           NSMaxRange(selection) <= (editField.stringValue as NSString).length {
            editor.selectedRange = selection
        }
    }

    /// A click in the list in edit mode is about to be handled (`TurnTableView.mouseDown`).
    func editClickBegan(extend: Bool) {
        guard wordEdit != nil else { return }
        if extend {
            extendingWordEdit = true
            // Kept in case the selection cannot grow and the field stays as it was.
            selectionBeforeExtension = editField.currentEditor()?.selectedRange
        } else {
            commitWordEdit(addTerm: false, advance: .stay)
        }
    }

    /// The click was handled: a ⇧-click that grew nothing (it missed the words) saves the field as any click would.
    func editClickEnded() {
        guard extendingWordEdit else { return }
        extendingWordEdit = false
        if wordEdit != nil { commitWordEdit(addTerm: false, advance: .stay) }
    }
}
