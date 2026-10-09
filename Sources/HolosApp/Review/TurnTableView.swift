import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers

private final class WordFixChoice: NSObject {
    let word: WordRef
    init(_ word: WordRef) { self.word = word }
}

/// The turn table: the number keys go to the window, everything else to the table (the window takes Space and the
/// playback keys before they get here). A plain single click on a word of a turn's text selects the turn and plays
/// from that word; in edit mode (`editingWords`), a click, a ⇧-click, or a drag over words edits them instead.
final class TurnTableView: NSTableView {
    /// 1–9: assign the selection to the speaker with that number.
    var onDigit: ((Int) -> Void)?
    /// A word was clicked: the session time it starts at.
    var onWordClick: ((Double) -> Void)?
    /// Edit mode: words clicked do not play, they are edited.
    var editingWords = false
    /// Edit mode: words `from`…`to` (indices into the row's words, either order) of `row` were clicked or dragged
    /// over; `extend`: with ⇧, the selection being edited grows to them.
    var onWordEditClick: ((_ row: Int, _ from: Int, _ to: Int, _ extend: Bool) -> Void)?
    /// Revert the automatic fix under a contextual-menu word.
    var onRevertFix: ((WordRef) -> Void)?
    /// The deleted words a row's menu offers to restore (`TurnListView.deletedWordsOffer`).
    var deletedWordsOffer: ((_ row: Int) -> [ReviewDeletedWords])?
    /// Restore Deleted “…” chosen: the segment whose words come back.
    var onRestoreDeleted: ((String) -> Void)?
    /// Return or Enter: play the selected turn (the keyboard's way to what a click on its timestamp does).
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers {
            if characters.count == 1, let digit = Int(characters), (1...9).contains(digit) {
                onDigit?(digit)
                return
            }
            if characters == "\r" || characters == "\u{3}" {
                onReturn?()
                return
            }
        }
        // ↑/↓, Page Up/Down, Home/End scroll the list as the reader moves: following playback holds off as for a
        // scroll with the mouse.
        switch event.specialKey {
        case .upArrow?, .downArrow?, .pageUp?, .pageDown?, .home?, .end?: onKeyboardScroll?()
        default: break
        }
        super.keyDown(with: event)
    }

    /// The reader moved through the list with the keyboard.
    var onKeyboardScroll: (() -> Void)?

    /// Edit mode, before a click is handled: `extend` (⇧) keeps the open field's words to grow from; any other click
    /// saves it first. Then `onEditClickEnded` once the click was handled.
    var onEditClickBegan: ((_ extend: Bool) -> Void)?
    var onEditClickEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if editingWords { onEditClickBegan?(modifiers == [.shift]) }
        defer { if editingWords { onEditClickEnded?() } }
        // Selection first (the table tracks the mouse until it is released), as for any click on a row.
        super.mouseDown(with: event)
        var end = point
        if let up = NSApplication.shared.currentEvent, up.type == .leftMouseUp, up.window === window {
            end = convert(up.locationInWindow, from: nil)
        }
        let dragged = abs(end.x - point.x) > 4 || abs(end.y - point.y) > 4
        let row = row(at: point)
        guard event.clickCount == 1, row >= 0,
              let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView,
              let word = cell.bodyText.wordIndex(atPoint: cell.bodyText.convert(point, from: self)) else { return }
        if editingWords {
            // ⇧ extends what is being edited; a drag within the row takes the words it went over.
            guard modifiers.isEmpty || modifiers == [.shift] else { return }
            var last = word
            if dragged, self.row(at: end) == row,
               let other = cell.bodyText.wordIndex(atPoint: cell.bodyText.convert(end, from: self)) {
                last = other
            }
            handleWordClick(row: row, word: word, through: last, extend: modifiers == [.shift])
            return
        }
        // ⇧/⌘ clicks extend the selection, a double click is a second click on the same word, and a drag selects
        // rows: none of them plays.
        guard modifiers.isEmpty, !dragged else { return }
        handleWordClick(row: row, word: word, through: word, extend: false)
    }

    /// Words `word`…`last` of `row` were clicked: edited in edit mode, else played from `word`.
    func handleWordClick(row: Int, word: Int, through last: Int, extend: Bool) {
        if editingWords {
            onWordEditClick?(row, word, last, extend)
            return
        }
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: true) as? TurnCellView,
              let start = cell.bodyText.reviewWord(at: word)?.start else { return }
        onWordClick?(start)
    }

    /// Split Turn Here on `word` (the clicked word as the row shows it) of `row`: nil when no split is offered there
    /// (the row's first word), else the item's request and why it cannot be made (nil when it can).
    var splitOffer: ((_ row: Int, _ word: ReviewWord, _ index: Int) -> (choice: SplitChoice, refusal: String?)?)?
    /// Split Turn Here chosen: the split the menu offered, as it was when the menu opened.
    var onSplitChosen: ((SplitChoice) -> Void)?
    /// Join With Previous Turn on `row`'s first word: nil when none is offered (another word, the meeting's first
    /// row), else the item's request and why it cannot be made (nil when it can).
    var joinOffer: ((_ row: Int, _ index: Int) -> (choice: JoinChoice, refusal: String?)?)?
    /// Join With Previous Turn chosen: the join the menu offered.
    var onJoinChosen: ((JoinChoice) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView else {
            return super.menu(for: event)
        }
        let inText = cell.bodyText.convert(point, from: self)
        let menu = wordMenu(row: row, cell: cell, word: cell.bodyText.word(at: inText),
                            index: cell.bodyText.wordIndex(atPoint: inText))
        return menu.items.isEmpty ? super.menu(for: event) : menu
    }

    /// A word's context menu: Revert its automatic fix (when it can be), Restore Deleted “…” for each segment whose
    /// words were all deleted near the row's turns (`deletedWordsOffer`), and Split Turn Here (the turn splits before
    /// the word, word `index` of the row; disabled, saying why, when it cannot).
    func wordMenu(row: Int, cell: TurnCellView, word: ReviewWord?, index: Int?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let word, cell.bodyText.canRevertFix, let fix = word.fix, word.revertible,
           cell.bodyText.canRevert(fix, at: word.ref) {
            let item = NSMenuItem(title: "Revert to “\(TranscriptWordEdit.cleaned(fix.heard))”",
                                  action: #selector(revertFix(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = WordFixChoice(word.ref)
            menu.addItem(item)
        }
        for deleted in deletedWordsOffer?(row) ?? [] {
            let item = NSMenuItem(title: TurnTextView.restoreTitle(deleted), action: #selector(restoreDeleted(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = deleted.segmentID
            item.toolTip = TurnTextView.restoreHelp
            menu.addItem(item)
        }
        // Not in edit mode, where Return at a word's start splits: a field open on another word is never left behind.
        if !editingWords, let word, let index, let offer = splitOffer?(row, word, index) {
            let item = NSMenuItem(title: "Split Turn Here", action: #selector(splitHere(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = offer.choice
            item.isEnabled = offer.refusal == nil
            item.toolTip = offer.refusal ?? "The turn splits before this word; the second part keeps the speaker "
                + "until you change it."
            menu.addItem(item)
        }
        if let item = joinMenuItem(row: row, word: word, index: index) { menu.addItem(item) }
        return menu
    }

    @objc private func revertFix(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? WordFixChoice else { return }
        onRevertFix?(choice.word)
    }

    @objc private func restoreDeleted(_ sender: NSMenuItem) {
        guard let segmentID = sender.representedObject as? String else { return }
        onRestoreDeleted?(segmentID)
    }

    @objc private func splitHere(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SplitChoice else { return }
        onSplitChosen?(choice)
    }
}
