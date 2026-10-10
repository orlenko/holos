import AppKit
import HolosMeeting

/// The window as its word edits' host (`ReviewWordEditCoordinator`): the turn list's field, the footer, the toolbar,
/// the review, and the window's close.
/// (`isClosing` and `isEditingWords` are the window's own.)
extension ReviewWindow: ReviewWordEditHost {
    func turnOnEditingWords() {
        turnList.editingWords = true
    }

    func takeOpenWordEdit() -> ReviewWordEditCoordinator.OpenEdit? {
        turnList.takeOpenWordEdit()
    }

    func reopenWordEdit(_ words: [ReviewWord], typed: String, message: String, seen: ReviewRevision) -> Bool {
        turnList.reopenWordEdit(words, typed: typed, message: message, seen: seen)
    }

    func saveTypedEdit(_ edit: ReviewWordEditCoordinator.OpenEdit,
                       committed: @escaping (ReviewWordEdit) -> Void) async throws {
        _ = try await review.editWords(edit.words.map(\.ref), to: edit.text, seen: edit.seen, whileUnread: true,
                                       expecting: edit.words.map(\.shown), committed: committed)
    }

    func wordChangeFailed() {
        clearJoins()
    }

    func showProblem(_ message: String?) {
        problem = message
        refreshFooter()
    }

    func showNotice(_ message: String) {
        notice = message
        refreshFooter()
    }

    func closeSavingChanged() {
        refreshToolbar()
    }

    func closeWindow() {
        window.close()
    }
}
