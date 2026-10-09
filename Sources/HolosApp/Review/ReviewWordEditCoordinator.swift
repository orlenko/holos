import Foundation
import HolosMeeting

/// What `ReviewWordEditCoordinator` needs of its window (`ReviewWindow`, `ReviewWindow+WordEdits`). No AppKit in it, so
/// tests drive the coordinator with a fake.
@MainActor
protocol ReviewWordEditHost: AnyObject {
    /// The window began closing without asking (quitting, a close before the meeting is deleted): its close saves what
    /// is left.
    var isClosing: Bool { get }
    /// Edit mode is on.
    var isEditingWords: Bool { get }
    /// Turns edit mode on for a field opening again after a close by hand that stopped.
    func turnOnEditingWords()
    /// Takes the open field's edit (closing the field); nil when none is open or nothing was typed.
    func takeOpenWordEdit() -> ReviewWordEditCoordinator.OpenEdit?
    /// Opens the field over `words` again with `typed`, the caret at its end and `message` in the banner, where the
    /// words are now after the word moves since `seen`; false when they are not shown as they were.
    func reopenWordEdit(_ words: [ReviewWord], typed: String, message: String, seen: ReviewRevision) -> Bool
    /// Saves `edit` in the review and waits for it (`ReviewSession.editWords`); `committed` runs once it is saved.
    func saveTypedEdit(_ edit: ReviewWordEditCoordinator.OpenEdit,
                       committed: @escaping (ReviewWordEdit) -> Void) async throws
    /// A word change failed: every join goes (they are only how rows read).
    func wordChangeFailed()
    /// The footer's problem line (nil: none).
    func showProblem(_ message: String?)
    /// The footer's notice line.
    func showNotice(_ message: String)
    /// Whether a field may open changed (a close by hand began or stopped saving).
    func closeSavingChanged()
    /// Closes the window (a close by hand whose edits were all saved).
    func closeWindow()
}

/// The Review window's word edits once the field hands them over (docs/meeting-design.md §5.10, "Editing words"):
/// each one queued and followed until it saves (`track`), refused edits opened again or kept with what was typed
/// (`unsaved`), and a close by hand that saves them all first (`shouldClose`). No AppKit; the window is its `host`.
///
/// Invariants:
/// 1. Every word change (an edit, a Restore of deleted words) goes through `track`: it is queued in the review before
///    anything awaits, and listed in `pending` until its save ends.
/// 2. A close by hand (`shouldClose`) is refused while `unsaved` holds an edit, and otherwise waits for `pending` and the
///    open field's edit through `closeGate`. While that close saves, `savingForClose` is true: no field opens and no
///    word change starts (the window's `canEditWordsNow`).
/// 3. What was typed is never dropped: an edit that is not saved opens its field again with it, or is kept in `unsaved`
///    (or in the close's outcome while a close by hand saves).
/// 4. The open field's edit a close by hand took is held (`heldOpenEdit`) until that close saves it or the window's own
///    close takes it (`takeHeldEdit`), exactly once.
@MainActor
final class ReviewWordEditCoordinator {
    /// The open field's edit as `TurnListView.takeOpenWordEdit` hands it over, with the revision its field opened under.
    typealias OpenEdit = (words: [ReviewWord], text: String, seen: ReviewRevision)

    static let unsavedBeforeClose = "Some words you edited were not saved. Edit them again or dismiss each one, then "
        + "close the window."

    private weak var host: (any ReviewWordEditHost)?
    /// A close by hand waits for the edit typed in the field to be saved (`shouldClose`).
    private let closeGate = ReviewCloseGate()
    /// Word edits the field handed over that are still saving, in the order they were made: each ends with the edit
    /// when it was not saved (`FailedWordEdit`), nil when it was. A close by hand waits for them too.
    private var pending: [(id: UUID, saving: Task<FailedWordEdit?, Never>)] = []
    /// The field's edit a close by hand took and has not queued yet (it waits for the edits before it).
    private var heldOpenEdit: OpenEdit?
    /// Word edits not saved whose field could not open again: in the footer until reopened or dismissed.
    private(set) var unsaved = UnsavedWordEdits()

    init(host: any ReviewWordEditHost) {
        self.host = host
    }

    /// A close by hand is saving the edits before it (invariant 2): no field opens meanwhile.
    var savingForClose: Bool { closeGate.saving }

    // MARK: - Word changes

    /// The one way a word change (an edit, or a Restore of deleted words: `restoring` its segment) is made and
    /// followed: `queue` queues it in the review at once, before anything else runs, so a close or a quit right after
    /// finds it there (saved before the review closes, listed by `unsavedWordEdits` meanwhile), never only in a task
    /// of the window's; `saved` runs once it is committed (`ReviewSession`'s `committed`, also when the labels could
    /// not be reread afterwards: the change stands); it is tracked until it ends (`pending`), so closing the window by
    /// hand waits for it and stays open when it is not saved; `ended` runs then.
    func track(
        _ words: [ReviewWord], text: String, seen: ReviewRevision, restoring: String? = nil,
        saved: @escaping (ReviewWordEdit) -> Void, ended: (() -> Void)? = nil,
        queue: (@escaping (ReviewWordEdit) -> Void) throws -> (@MainActor () async throws -> ReviewWordEdit?)?
    ) {
        let id = UUID()
        let flag = SavedFlag()
        let committed: (ReviewWordEdit) -> Void = { edit in
            flag.value = true
            saved(edit)
        }
        let queued: Result<(@MainActor () async throws -> ReviewWordEdit?)?, any Error>
        do {
            queued = .success(try queue(committed))
        } catch {
            queued = .failure(error)
        }
        let saving: Task<FailedWordEdit?, Never> = Task { [weak self] () async -> FailedWordEdit? in
            guard let self else { return nil }
            let refusal: String? = await self.save(words, to: text, queued: queued, saved: flag, seen: seen,
                                                   restoring: restoring)
            self.pending.removeAll { $0.id == id }
            ended?()
            return refusal.map {
                FailedWordEdit(words: words, text: text, seen: seen, message: $0, restoring: restoring)
            }
        }
        pending.append((id, saving))
    }

    /// Whether a word edit was saved (`ReviewSession.queueWordEdit`'s `committed`), read when it then throws.
    private final class SavedFlag {
        var value = false
    }

    /// `track`'s save, already queued (`queued`): nil when saved (also when its labels could not be reread after it:
    /// the edit stands, and ⌥Return's term is still added), else why, with what was typed (the field opens again with
    /// it when its words are still there). Made on the words as the field showed them: never over words changed
    /// elsewhere since.
    private func save(_ words: [ReviewWord], to text: String,
                      queued: Result<(@MainActor () async throws -> ReviewWordEdit?)?, any Error>,
                      saved: SavedFlag, seen: ReviewRevision, restoring: String?) async -> String? {
        do {
            if let wait = try queued.get() { _ = try await wait() }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            host?.wordChangeFailed()
            if saved.value {
                host?.showProblem(error.localizedDescription)
                return nil
            }
            // A Restore: nothing was typed, no field to open again or edit to keep; the footer says why.
            if restoring != nil {
                let message = Self.restoreFailed(error)
                host?.showProblem(message)
                return message
            }
            let message = TranscriptWordEdit.withTyped(error.localizedDescription, text)
            // Where its words are now: through the moves saved since, never across words changed elsewhere.
            let reopened = host?.reopenWordEdit(words, typed: text, message: message, seen: seen) ?? false
            // Reopened: said once, in the banner over the field that holds what was typed, as every other refusal of
            // an edit is (`reopenWordEdit`). Not reopened: in the footer, kept until reopened or dismissed (the next
            // edit never clears it); a close waiting for it keeps it itself (`keepAfterFailedClose`).
            if !reopened {
                if !closeGate.saving {
                    unsaved.add([FailedWordEdit(words: words, text: text, seen: seen, message: message)])
                }
                host?.showProblem(message)
            }
            return message
        }
    }

    /// What the footer says of a Restore of deleted words that was not saved.
    static func restoreFailed(_ error: any Error) -> String {
        "The deleted words were not restored: " + error.localizedDescription
    }

    // MARK: - Edits not saved

    /// "Edit Again": the first edit not saved opens its field with what was typed; false when its words are no longer
    /// shown as they were.
    func reopenNextUnsaved() -> Bool {
        unsaved.reopenNext { failed in
            host?.reopenWordEdit(failed.words, typed: failed.text, message: failed.message, seen: failed.seen) ?? false
        }
    }

    /// "Dismiss": the first edit not saved goes.
    func dismissNextUnsaved() {
        unsaved.dismissNext()
    }

    // MARK: - Closing

    /// A close by hand (the window's close button, ⌘W), with the window not closing already: whether it closes now.
    /// Edits not saved whose fields could not open again keep it open (closing would drop what was typed; the footer
    /// offers Edit Again or Dismiss for each). An edit typed in the field, or edits handed over and still saving
    /// (Return, then ⌘W at once), are saved first; the window then closes, or stays open when one is not saved (its own
    /// failure opens its field again, or says what was typed).
    func shouldClose() -> Bool {
        // A close already saving decides itself.
        if unsaved.holdsClose, !closeGate.saving {
            host?.showNotice(Self.unsavedBeforeClose)
            return false
        }
        let open = closeGate.saving ? nil : host?.takeOpenWordEdit()
        // Held until it is queued, with the revision its field opened under: a quit meanwhile closes the review with it
        // (`takeHeldEdit`); words changed elsewhere since the field opened refuse it.
        if let open { heldOpenEdit = open }
        let waiting: [Task<FailedWordEdit?, Never>] = closeGate.saving ? [] : pending.map(\.saving)
        let outcome = CloseSaveOutcome()
        let save: () async -> String? = { [weak self] in
            await self?.saveBeforeClose(open != nil, after: waiting, outcome: outcome)
        }
        let close: () -> Void = { [weak self] in self?.host?.closeWindow() }
        let keep: (String) -> Void = { [weak self] message in
            self?.keepAfterFailedClose(outcome: outcome, message: message)
        }
        let closesNow = closeGate.shouldClose(typed: open != nil || !waiting.isEmpty, save: save, close: close,
                                              keep: keep)
        // Saving first: no field opens until the window closes, or stays open (invariant 2).
        if !closesNow { host?.closeSavingChanged() }
        return closesNow
    }

    /// The field's edit a close by hand took and has not saved yet, for the window's own close to queue (invariant 4).
    func takeHeldEdit() -> OpenEdit? {
        defer { heldOpenEdit = nil }
        return heldOpenEdit
    }

    /// What a close by hand found when it saved (`saveBeforeClose`): every edit not saved, in the order they were made
    /// (those handed over before, then the open field's).
    private final class CloseSaveOutcome {
        var failures: [FailedWordEdit] = []
    }

    /// Before a close by hand: waits for the edits handed over (in the order they were made), then saves the open
    /// field's (`tookOpenEdit`). Nil when all were saved, else every refusal, each with what was typed. While it waits
    /// no field can open (invariant 2), so each edit not saved is kept (`outcome`) for when the window stays open.
    private func saveBeforeClose(_ tookOpenEdit: Bool, after waiting: [Task<FailedWordEdit?, Never>],
                                 outcome: CloseSaveOutcome) async -> String? {
        for edit in waiting {
            if let failed = await edit.value { outcome.failures.append(failed) }
        }
        // Unless the window's close took it meanwhile (quitting), which queues it itself.
        if tookOpenEdit, host?.isClosing == false, let open = heldOpenEdit {
            heldOpenEdit = nil
            if let refusal = await saveTypedEdit(open) {
                outcome.failures.append(FailedWordEdit(words: open.words, text: open.text, seen: open.seen,
                                                       message: refusal))
            }
        }
        return outcome.failures.isEmpty ? nil : outcome.failures.map(\.message).joined(separator: " ")
    }

    /// A close by hand stopped because edits were not saved: fields may open again, so the first one's field opens with
    /// what was typed and why, and the footer says every other one, each with what was typed
    /// (`ReviewCloseRecovery`).
    private func keepAfterFailedClose(outcome: CloseSaveOutcome, message: String) {
        // Quitting closed the window meanwhile: its close saves (or logs) what is left.
        guard let host, !host.isClosing else { return }
        // Fields may open again (the close by hand ended).
        host.closeSavingChanged()
        // Restores not saved have nothing typed to keep: the footer says why (`problem`).
        let typed = outcome.failures.filter { $0.restoring == nil }
        let restores = outcome.failures.filter { $0.restoring != nil }.map(\.message)
        if !typed.isEmpty, !host.isEditingWords { host.turnOnEditingWords() }
        let others = ReviewCloseRecovery.recover(typed) { failed in
            // Where its words are now: through the moves saved since, never across words changed elsewhere.
            host.reopenWordEdit(failed.words, typed: failed.text, message: failed.message, seen: failed.seen)
        }
        // The others stay in the footer, each with what was typed, until reopened or dismissed.
        unsaved.add(others)
        host.showProblem(outcome.failures.isEmpty ? message : restores.isEmpty ? nil : restores.joined(separator: " "))
    }

    /// Saves an edit typed in the field and waits for it: nil when saved (also when its labels could not be reread
    /// after it: the edit stands), else why, with what was typed.
    private func saveTypedEdit(_ edit: OpenEdit) async -> String? {
        guard let host else { return nil }
        var saved = false
        do {
            try await host.saveTypedEdit(edit) { _ in saved = true }
            return nil
        } catch {
            // A change that failed: every join goes, as for any other (`save`).
            host.wordChangeFailed()
            return saved ? nil : TranscriptWordEdit.withTyped(error.localizedDescription, edit.text)
        }
    }
}
