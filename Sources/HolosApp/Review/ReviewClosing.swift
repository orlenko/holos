import Foundation
import HolosMeeting

/// A review window as quitting closes it (`ReviewQuit`).
@MainActor
protocol ClosingReview: AnyObject {
    /// Closes it without waiting; the edit its open field holds is queued to be saved at once.
    func startClosing()
    /// Waits until it is closed and its changes are saved.
    func closeAndWait() async
}

/// Quitting with review windows open (docs/meeting-design.md §5.10, "Editing words").
enum ReviewQuit {
    /// Every review starts closing at once, so each queues the edit its open field holds before any slow close (a
    /// voice sync of another review) is waited for; then they are awaited together, at most `limit`. True when all
    /// closed in time.
    @MainActor
    static func closeAll(_ reviews: [any ClosingReview], limit: Duration) async -> Bool {
        for review in reviews { review.startClosing() }
        let closing = Task { @MainActor in
            for review in reviews { await review.closeAndWait() }
        }
        return await waitAtMost(limit, for: closing)
    }
}

/// Closing a review window by hand (its close button, ⌘W) with an edit typed in its field: the window stays open until
/// the edit is saved, and stays open when it is not, so a save that fails (a full disk) never loses what was typed.
/// Quitting, and closing before a meeting is deleted, never come here (`ClosingReview.startClosing` closes the window
/// directly): they keep their bounded wait, and log what was typed when it could not be saved.
@MainActor
final class ReviewCloseGate {
    /// The edit typed when the close was asked for is being saved: another close waits for it.
    private(set) var saving = false

    /// Whether the window may close now. With an edit typed (`typed`), no: `save` saves it (nil when saved, else why,
    /// with what was typed); then `close` closes the window, or `keep` opens the field again with what was typed and
    /// shows why, and the window stays.
    func shouldClose(typed: Bool, save: @escaping () async -> String?, close: @escaping () -> Void,
                     keep: @escaping (String) -> Void) -> Bool {
        if saving { return false }
        guard typed else { return true }
        saving = true
        Task { @MainActor in
            let refusal = await save()
            saving = false
            if let refusal { keep(refusal) } else { close() }
        }
        return false
    }
}

extension ReviewSession.TypedEdit {
    /// The open field's edit (`TurnListView.takeOpenWordEdit`) as the review takes it at a pause or a close: checked
    /// against the revision its field opened under.
    init(_ open: (words: [ReviewWord], text: String, seen: ReviewRevision)) {
        self.init(words: open.words.map(\.ref), text: open.text, seenMoves: open.seen.moves,
                  expected: open.words.map(\.shown), seenEpoch: open.seen.wordsEpoch)
    }
}

/// A word edit the field handed over that was not saved: its words as the field showed them, what was typed, the
/// revision they follow, and why (`message`, with what was typed).
struct FailedWordEdit {
    var words: [ReviewWord]
    var text: String
    var seen: ReviewRevision
    var message: String
    /// A Restore of deleted words (this segment's), not typed words: no field opens again for it, and it is never kept
    /// as an edit to type again (`UnsavedWordEdits`); its message stays in the footer.
    var restoring: String? = nil
}

/// After a close by hand stopped because edits were not saved (`ReviewWordEditCoordinator.keepAfterFailedClose`):
/// fields could not open while the close waited, so the first failed edit's field opens now, with what was typed and
/// why (`reopen`, false when its words are no longer there). Returns the others (all of them when the field could not
/// open), for the footer (`UnsavedWordEdits`).
enum ReviewCloseRecovery {
    @MainActor
    static func recover(_ failures: [FailedWordEdit], reopen: (FailedWordEdit) -> Bool) -> [FailedWordEdit] {
        guard let first = failures.first else { return [] }
        return reopen(first) ? Array(failures.dropFirst()) : failures
    }
}

/// Word edits not saved whose field could not open again (their words were not shown, another field was open, a close
/// was waiting): the footer lists each with what was typed until its field opens again (`reopenNext`; it is then the
/// field's, saved, queued, or cancelled with Esc as any field's) or the person dismisses it (`dismissNext`). The next
/// edit never clears them.
struct UnsavedWordEdits {
    private(set) var edits: [FailedWordEdit] = []

    mutating func add(_ failed: [FailedWordEdit]) { edits += failed }

    /// Opens the first one's field again (`reopen`); true when it opened, and it leaves the list.
    @MainActor
    mutating func reopenNext(_ reopen: (FailedWordEdit) -> Bool) -> Bool {
        guard let first = edits.first, reopen(first) else { return false }
        edits.removeFirst()
        return true
    }

    mutating func dismissNext() {
        if !edits.isEmpty { edits.removeFirst() }
    }

    /// The footer's lines: each edit's message (it says what was typed).
    var lines: [String] { edits.map { "⚠ Not saved: " + $0.message } }

    /// A close by hand waits: the window stays open until each one is edited again or dismissed (quitting does not
    /// wait; it logs them, `typedTexts`).
    var holdsClose: Bool { !edits.isEmpty }

    /// What was typed in each, for the quit's log.
    var typedTexts: [String] { edits.map(\.text) }
}
