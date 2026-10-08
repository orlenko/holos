import AppKit
import HolosCore
import HolosMeeting

/// A join asked at a row's edge as the list showed it: the row (`paragraphID`, its first turn's ID) joins the row
/// before it, or with `forward` the row after it joins this one. The window finds those rows among all it groups (a
/// search may hide the one before) and checks the join then (`ReviewWindow.resolveJoin`).
struct ReviewJoinRequest: Equatable {
    var paragraphID: String
    /// Forward Delete at the row's end: the row after it joins it. False: Backspace at its start, or the menu.
    var forward: Bool
    /// The word at the edge the join was asked at (the row's first word; its last, `forward`): from the field, the
    /// field opens there again once the rows are one, with the caret where the rows met.
    var word: WordRef
    /// The turn `word` was chosen in (overlapping turns may show a word twice).
    var turnID: String?
    /// How many of the review's word moves `word` follows, and the words epoch it was chosen under: a word edit
    /// saved before the join's speaker change moves it (the field opens where it is then); words changed elsewhere
    /// leave no place to open it.
    var movesSeen = 0
    var wordsEpoch = 0
    /// The speaker labels' run the rows were shown from: labelled again since (a new run that did not keep them), a
    /// turn ID may name another turn, so the join is refused.
    var runID: String?
    /// Asked from the edit field (Backspace, forward Delete), which opens again where the rows met.
    var fromField = false
}

/// What a join request makes (`TurnListView.resolveJoin`): the join, why there is none, or nothing to join with.
enum ReviewJoinResolution: Equatable {
    case join(ReviewParagraphJoin)
    case refused(String)
    /// No row before it (the meeting's first; its last, forward): the field says so, the menu offers no join.
    case nothing(String)
}

/// A Join With Previous Turn menu item's (or VoiceOver action's) request, as the row was shown when it was offered.
final class JoinChoice: NSObject {
    let request: ReviewJoinRequest

    init(_ request: ReviewJoinRequest) { self.request = request }
}

/// Joining a row to the row before it, the inverse of Return's split (docs/meeting-design.md §5.10), as removing the
/// line break between two paragraphs of text: in edit mode, Backspace with the caret at the very start of a row's
/// first word and nothing changed joins that row to the row before it, and forward Delete at the very end of a row's
/// last word joins the row after it; outside edit mode, a row's first word offers Join With Previous Turn in its
/// context menu and VoiceOver's actions. The later row's turns take the earlier row's speaker (the review's undoable
/// assignment, as the row's pop-up makes it) and the window joins the rows whatever kept them apart (a break made
/// here, a split's second part, the time gap: `ReviewParagraphBreaks.join`). Anywhere else Backspace and Delete edit
/// the text as always.
extension TurnListView {
    static let joinTitle = "Join With Previous Turn"
    /// The menu item's tooltip.
    static let joinHelp = "This turn joins the one before it and takes its speaker."
    /// Backspace at the start of the meeting's first row.
    static let nothingBefore = "This is the meeting's first turn; there is no turn before it to join."
    /// Forward Delete at the end of the meeting's last row.
    static let nothingAfter = "This is the meeting's last turn; there is no turn after it to join."
    /// After a join that changed no speaker (nothing saved, so Undo has nothing to take back).
    static let joined = "Joined with the turn before. Return here splits it again."
    /// After a join that gave the later turn the earlier one's speaker.
    static let joinedSpeaker = "Joined: the turn took the speaker of the one before. ⌘Z gives it its own speaker back."

    /// Backspace (forward Delete, `forward`) in the edit field: when nothing was changed and the caret (no text
    /// selected) is at the very start of the row's first word (at the very end of its last word), the rows join there.
    /// Anything else is the field's own (false).
    func joinFromField(forward: Bool) -> Bool {
        guard let target = wordEdit, let editor = editField.currentEditor(),
              let first = target.words.first, let last = target.words.last,
              let paragraph = paragraphs.first(where: { $0.id == target.paragraphID }) else { return false }
        // Unchanged exactly, as Return's split asks.
        let typed = editField.stringValue
        guard typed == target.shown else { return false }
        let selection = editor.selectedRange
        let length = (typed as NSString).length
        guard selection.length == 0, selection.location == (forward ? length : 0) else { return false }
        // The row's edge, not a word or turn inside it (turns inside a row already read as one).
        let count = paragraphWords(paragraph).words.count
        guard forward ? target.range.upperBound == count - 1 : target.range.lowerBound == 0 else { return false }
        let request = ReviewJoinRequest(paragraphID: target.paragraphID, forward: forward,
                                        word: forward ? last.ref : first.ref,
                                        turnID: target.turnID ?? turnID(ofWordAt: target.range.lowerBound,
                                                                        in: target.paragraphID),
                                        movesSeen: target.movesSeen, wordsEpoch: target.wordsEpoch,
                                        runID: target.runID, fromField: true)
        switch resolveJoin?(request) {
        case .join(let join)?:
            cancelWordEdit()
            onJoin?(join, request)
        case .refused(let why)?, .nothing(let why)?:
            onEditMessage?(why)
        case nil:
            return false
        }
        return true
    }

    /// Join With Previous Turn on word `index` of `row`: only on its first word, and not on the meeting's first row;
    /// else the item's request, with why it cannot be made (nil when it can).
    func joinOffer(row: Int, index: Int) -> (choice: JoinChoice, refusal: String?)? {
        guard index == 0, let request = joinRequest(row: row), let resolution = resolveJoin?(request) else { return nil }
        switch resolution {
        case .join: return (JoinChoice(request), nil)
        case .refused(let why): return (JoinChoice(request), why)
        case .nothing: return nil
        }
    }

    /// The join of `row` to the row before it, at its first word as the row shows it; nil for a row without words.
    func joinRequest(row: Int) -> ReviewJoinRequest? {
        guard row >= 0, row < paragraphs.count else { return nil }
        let paragraph = paragraphs[row]
        let shown = paragraphWords(paragraph)
        guard let first = shown.words.first, let turn = shown.turns.first else { return nil }
        return ReviewJoinRequest(paragraphID: paragraph.id, forward: false, word: first.ref,
                                 turnID: paragraph.turns[turn].id, movesSeen: wordMoves.count,
                                 wordsEpoch: wordsEpoch, runID: runID)
    }

    /// Join With Previous Turn chosen: the request the menu made, resolved again now. Refused now (the review turned
    /// read-only, the speakers labelled again while the menu was open), the window says why.
    func joinChosen(_ choice: JoinChoice) {
        switch resolveJoin?(choice.request) {
        case .join(let join)?: onJoin?(join, choice.request)
        case .refused(let why)?, .nothing(let why)?: onJoinRefused?(why)
        case nil: break
        }
    }
}
