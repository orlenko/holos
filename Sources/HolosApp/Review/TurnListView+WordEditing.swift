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
                             + "next word, Escape cancels.")
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { nil }
}

/// Edit mode of the turn list: a click on a word opens a field over it, prefilled and selected; ⇧-click or a drag in
/// the same row takes in more words, within one segment of one turn (shown words with consecutive stored indices, so
/// never across hidden echo). Return saves (`onEditWords`), ⌥Return saves and asks for the word list too, Tab and ⇧Tab
/// save and edit the next or previous word, Esc cancels; clicking elsewhere saves.
extension TurnListView: NSTextFieldDelegate {
    enum WordEditAdvance { case stay, next, previous }

    static let selectionStopped = "A selection stays within one segment of one speaker turn for now, so it stops "
        + "there. Edit the rest on its own."
    static let wordsChanged = "The words being edited changed meanwhile; click them again."

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
        guard editingWords, editable, row >= 0, row < paragraphs.count else { return }
        let paragraph = paragraphs[row]
        let (all, turns) = paragraphWords(paragraph)
        guard from >= 0, through >= 0, from < all.count, through < all.count else { return }
        var anchor = from
        if extend, let open = wordEdit, open.paragraphID == paragraph.id {
            // The selection grows from where it began; the field starts again with the words it now covers.
            anchor = open.anchor
            closeEditField()
        } else if wordEdit != nil {
            // Clicking elsewhere while the field is open saves what it holds first.
            commitWordEdit(addTerm: false, advance: .stay)
        }
        extendingWordEdit = false
        var lower = anchor
        var upper = anchor
        func joins(_ index: Int, _ neighbour: Int) -> Bool {
            turns[index] == turns[anchor] && all[index].ref.segmentID == all[anchor].ref.segmentID
                && abs(all[index].ref.word - all[neighbour].ref.word) == 1
        }
        while upper < through, joins(upper + 1, upper) { upper += 1 }
        while lower > through, joins(lower - 1, lower) { lower -= 1 }
        let stopped = through > upper || through < lower
        onEditMessage?(stopped ? Self.selectionStopped : nil)
        openField(row: row, paragraph: paragraph, words: all, range: lower...upper, anchor: anchor)
    }

    private func openField(row: Int, paragraph: ReviewParagraph, words all: [ReviewWord], range: ClosedRange<Int>,
                           anchor: Int) {
        let shown = textView(row: row)?.shownText(from: range.lowerBound, through: range.upperBound)
            ?? all[range].map(\.text).joined(separator: " ")
        wordEdit = WordEditTarget(paragraphID: paragraph.id, range: range, anchor: anchor, words: Array(all[range]),
                                  shown: shown, movesSeen: wordMoves.count)
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
            onEditWords?(target.words, typed, addTerm, target.movesSeen)
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
    /// changes its time), and a word no move touched must still read the same. When they cannot be found the field
    /// closes, and what was typed in it is shown in the banner rather than lost.
    func followWordEdit() {
        guard let target = wordEdit else { return }
        guard editingWords, editable, let row = paragraphs.firstIndex(where: { $0.id == target.paragraphID }) else {
            loseWordEdit()
            return
        }
        let all = paragraphWords(paragraphs[row]).words
        let followed = ReviewSession.follow(target.words.map(\.ref), through: wordMoves.dropFirst(target.movesSeen))
        var refs: [WordRef] = []
        for ref in followed.refs where refs.last != ref { refs.append(ref) }
        guard let first = refs.first, let start = all.firstIndex(where: { $0.ref == first }),
              start + refs.count <= all.count,
              zip(refs, all[start...]).allSatisfy({ $0 == $1.ref }),
              followed.replaced || zip(target.words, all[start...]).allSatisfy({ $0.text == $1.text }) else {
            loseWordEdit()
            return
        }
        let range = start...(start + refs.count - 1)
        let shift = start - target.range.lowerBound
        wordEdit?.range = range
        wordEdit?.anchor = min(max(target.anchor + shift, range.lowerBound), range.upperBound)
        wordEdit?.words = Array(all[range])
        wordEdit?.movesSeen = wordMoves.count
        positionEditField(row: row, range: range)
    }

    /// The open field's words are gone: it closes, keeping what was typed in the banner when it was changed.
    private func loseWordEdit() {
        guard let target = wordEdit else { return }
        let typed = editField.stringValue
        cancelWordEdit()
        let changed = TranscriptWordEdit.cleaned(typed) != TranscriptWordEdit.cleaned(target.shown)
        onEditMessage?(changed ? Self.wordsChanged + " What you typed: “\(TranscriptWordEdit.cleaned(typed))”."
                               : Self.wordsChanged)
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
        if !editingWords { cancelWordEdit() }
        table.needsDisplay = true
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === editField, wordEdit != nil else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let option = NSApplication.shared.currentEvent?.modifierFlags.contains(.option) == true
            commitWordEdit(addTerm: option, advance: .stay)
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commitWordEdit(addTerm: true, advance: .stay)
        case #selector(NSResponder.cancelOperation(_:)):
            cancelWordEdit()
        case #selector(NSResponder.insertTab(_:)):
            commitWordEdit(addTerm: false, advance: .next)
        case #selector(NSResponder.insertBacktab(_:)):
            commitWordEdit(addTerm: false, advance: .previous)
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

    /// A click in the list in edit mode is about to be handled (`TurnTableView.mouseDown`).
    func editClickBegan(extend: Bool) {
        guard wordEdit != nil else { return }
        if extend {
            extendingWordEdit = true
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
