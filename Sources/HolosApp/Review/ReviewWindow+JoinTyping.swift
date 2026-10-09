import AppKit
import HolosCore
import HolosMeeting

/// Where keys held for a join were typed (`TypingHold`): the word at the edge where the rows met, as the field showed
/// it, the caret's side of it, and the revision the word follows. A field that does not open again leaves what they
/// typed as an edit of this word.
struct JoinTypingPlace {
    var word: ReviewWord
    /// The word's text as the field showed it (`TurnListView.shownText(of:)`).
    var text: String
    /// The caret was at the word's end (forward Delete); else at its start.
    var atEnd: Bool
    var seen: ReviewRevision
}

/// Keys typed while a join's speaker change saves (`applyJoin`, `TypingHold`): replayed into the field when it opens
/// again at the join; otherwise kept as an edit of the word at the join, so what was typed is never lost. Kept in
/// `unsavedEdits` (the footer offers Edit Again or Dismiss, and a close by hand waits) when the join is dropped or the
/// field does not open, or queued as an edit when the window closes (`queueHeldTyping`).
extension ReviewWindow {
    static let typingNotPlaced = "The field did not open again after the join, so this waits here."

    /// Opens a hold for the keys typed while `request`'s join saves its speaker change; nil when the word at its edge
    /// is not shown. A hold still open (another join saving) ends first, and its keys stay an edit of its own word.
    func beginTypingHold(for request: ReviewJoinRequest) -> Int? {
        guard let word = shownWord(request.word, inTurn: request.turnID) else { return nil }
        let place = JoinTypingPlace(word: word, text: turnList.shownText(of: word), atEnd: request.forward,
                                    seen: request.seen)
        let opened = window.typingHold.begin(place) { [weak self] in self?.turnList.editingWords == true }
        if let ended = opened.ended { keepHeldTyping(ended) }
        return opened.id
    }

    /// Ends hold `hold` (nil: none) and hands its keys over: replayed into the field just opened at the join
    /// (`reopened`), as typed there; else kept as an edit of the word at the join (`keepHeldTyping`).
    func handOverTyping(_ hold: Int?, reopened: Bool) {
        guard let hold, let held = window.typingHold.end(hold) else { return }
        guard reopened else {
            keepHeldTyping(held)
            return
        }
        // One by one, as typed: a key that joins again (Backspace) opens a new hold, which takes the keys after it.
        for key in held.keys { window.replay(key) }
    }

    /// Drops every join without refreshing (`clearJoins`, or `refresh` when an undo was saved): a join still saving
    /// opens no field now, so the keys held for it are handed over at once and keys typed from now on go where they
    /// always go.
    func dropJoins() {
        joinsCleared += 1
        handOverTyping(window.typingHold.current, reopened: false)
        paragraphBreaks.clearJoins()
    }

    /// The window is closing: keys still held are queued as an edit of the word at the join, so the close saves them
    /// as it saves an open field's typing (a close by hand waits for it; a quit's close saves or logs it).
    func queueHeldTyping() {
        guard let hold = window.typingHold.current, let held = window.typingHold.end(hold),
              let edit = Self.heldEdit(held) else { return }
        editWords([held.place.word], to: edit, addTerm: false, seen: held.place.seen)
    }

    /// What `held` typed into its word's text, nil when that leaves the word as it was.
    static func heldEdit(_ held: TypingHold<JoinTypingPlace>.Held) -> String? {
        let place = held.place
        let text = HeldTyping.apply(held.keys.map { ($0.characters, $0.modifierFlags) }, to: place.text,
                                    caret: place.atEnd ? place.text.count : 0)
        return TranscriptWordEdit.cleaned(text) == TranscriptWordEdit.cleaned(place.text) ? nil : text
    }

    /// Keeps what `held` typed as an edit not saved of the word at the join: in the footer with Edit Again, which
    /// opens the field there with it, until edited again or dismissed; a close by hand waits for it.
    private func keepHeldTyping(_ held: TypingHold<JoinTypingPlace>.Held) {
        guard let text = Self.heldEdit(held) else { return }
        unsavedEdits.add([FailedWordEdit(words: [held.place.word], text: text, seen: held.place.seen,
                                         message: Self.typingNotPlaced + TranscriptWordEdit.typedNote(text))])
        refreshFooter()
    }

    /// The word `ref` as the rows show it, in turn `turnID` when given (overlapping turns may show a word twice).
    private func shownWord(_ ref: WordRef, inTurn turnID: String?) -> ReviewWord? {
        for paragraph in turnList.paragraphs {
            let shown = turnList.paragraphWords(paragraph)
            if let index = shown.words.indices.first(where: {
                shown.words[$0].ref == ref && (turnID == nil || paragraph.turns[shown.turns[$0]].id == turnID)
            }) {
                return shown.words[index]
            }
        }
        return nil
    }
}
