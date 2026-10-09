import Foundation
import HolosCore
import HolosMeeting
import HolosTestSupport
import Testing
@testable import HolosApp

/// `ReviewWordEditCoordinator` without a window: a fake host records what the coordinator asks of it. Words and text
/// are made up.
@MainActor
struct ReviewWordEditCoordinatorTests {
    private final class Host: ReviewWordEditHost {
        var isClosing = false
        var isEditingWords = false
        /// What `takeOpenWordEdit` hands over (once).
        var openEdit: ReviewWordEditCoordinator.OpenEdit?
        /// Whether the field opens again over the words.
        var reopens = false
        /// Holds `saveTypedEdit` until finished; its outcome.
        var holdSave: AsyncStream<Void>?
        var saveFails = false
        private(set) var reopened: [(text: String, message: String)] = []
        private(set) var saved: [String] = []
        private(set) var problems: [String?] = []
        private(set) var notices: [String] = []
        private(set) var failures = 0
        private(set) var savingChanges = 0
        private(set) var closed = 0

        func turnOnEditingWords() { isEditingWords = true }

        func takeOpenWordEdit() -> ReviewWordEditCoordinator.OpenEdit? {
            defer { openEdit = nil }
            return openEdit
        }

        func reopenWordEdit(_ words: [ReviewWord], typed: String, message: String, seen: ReviewRevision) -> Bool {
            guard reopens else { return false }
            reopened.append((typed, message))
            return true
        }

        func saveTypedEdit(_ edit: ReviewWordEditCoordinator.OpenEdit,
                           committed: @escaping (ReviewWordEdit) -> Void) async throws {
            if let holdSave { for await _ in holdSave {} }
            if saveFails { throw HolosError.unavailable("The disk is full.") }
            saved.append(edit.text)
        }

        func wordChangeFailed() { failures += 1 }
        func showProblem(_ message: String?) { problems.append(message) }
        func showNotice(_ message: String) { notices.append(message) }
        func closeSavingChanged() { savingChanges += 1 }
        func closeWindow() { closed += 1 }
    }

    private let word = ReviewWord(ref: WordRef(segmentID: "S", word: 0), text: "amber", start: 0)

    /// Queues an edit whose save throws `error` (after `committed` when `committedFirst`).
    private func failingEdit(_ coordinator: ReviewWordEditCoordinator, text: String, restoring: String? = nil,
                             committedFirst: Bool = false, ended: @escaping () -> Void) {
        coordinator.track([word], text: text, seen: ReviewRevision(), restoring: restoring, saved: { _ in },
                          ended: ended) { committed in
            {
                if committedFirst {
                    committed(ReviewWordEdit(heard: "amber", meant: text, deletion: false, before: nil, after: nil))
                }
                throw HolosError.unavailable("The disk is full.")
            }
        }
    }

    /// A refused edit whose words are still shown opens its field again with what was typed; nothing is kept.
    @Test(.timeLimit(.minutes(1))) func aRefusedEditOpensItsFieldAgain() async {
        let host = Host()
        host.reopens = true
        let coordinator = ReviewWordEditCoordinator(host: host)
        var ended = false
        failingEdit(coordinator, text: "Amber") { ended = true }
        #expect(await eventually { ended })
        #expect(host.failures == 1)
        #expect(host.reopened.map(\.text) == ["Amber"] && host.reopened.first?.message.contains("Amber") == true)
        #expect(!coordinator.unsaved.holdsClose && host.problems.isEmpty)
    }

    /// A refused edit whose field cannot open again is kept with what was typed, which holds a close by hand: the
    /// close is refused with a notice until it is dismissed.
    @Test(.timeLimit(.minutes(1))) func aRefusedEditThatCannotReopenHoldsTheClose() async {
        let host = Host()
        let coordinator = ReviewWordEditCoordinator(host: host)
        var ended = false
        failingEdit(coordinator, text: "Amber") { ended = true }
        #expect(await eventually { ended })
        #expect(coordinator.unsaved.typedTexts == ["Amber"])
        #expect(host.problems.count == 1 && host.problems.first??.contains("Amber") == true)
        #expect(!coordinator.shouldClose())
        #expect(host.notices == [ReviewWordEditCoordinator.unsavedBeforeClose])
        coordinator.dismissNextUnsaved()
        #expect(coordinator.shouldClose())
    }

    /// An edit saved before its labels could not be reread stands: the footer says what failed, nothing is kept; a
    /// Restore that fails says so, and is never kept as typing.
    @Test(.timeLimit(.minutes(1))) func savedEditsAndRestoresAreNeverKept() async {
        let host = Host()
        let coordinator = ReviewWordEditCoordinator(host: host)
        var ended = 0
        failingEdit(coordinator, text: "Amber", committedFirst: true) { ended += 1 }
        failingEdit(coordinator, text: "", restoring: "S") { ended += 1 }
        #expect(await eventually { ended == 2 })
        #expect(host.problems.count == 2)
        #expect(host.problems.last == ReviewWordEditCoordinator.restoreFailed(HolosError.unavailable("The disk is full.")))
        #expect(!coordinator.unsaved.holdsClose && host.reopened.isEmpty)
    }

    /// A close by hand with nothing typed and nothing saving closes at once.
    @Test func aCloseWithNothingTypedClosesAtOnce() {
        let host = Host()
        let coordinator = ReviewWordEditCoordinator(host: host)
        #expect(coordinator.shouldClose())
        #expect(!coordinator.savingForClose && host.savingChanges == 0)
    }

    /// A close by hand with an edit typed saves it first: no field opens meanwhile (`savingForClose`), and the window
    /// closes once it is saved.
    @Test(.timeLimit(.minutes(1))) func aCloseSavesTheOpenEditThenCloses() async {
        let host = Host()
        let (hold, release) = AsyncStream<Void>.makeStream()
        host.holdSave = hold
        host.openEdit = ([word], "Amber", ReviewRevision())
        let coordinator = ReviewWordEditCoordinator(host: host)
        #expect(!coordinator.shouldClose())
        #expect(coordinator.savingForClose && host.savingChanges == 1)
        #expect(!coordinator.shouldClose(), "A second close waits for the first.")
        release.finish()
        #expect(await eventually { host.closed == 1 })
        #expect(host.saved == ["Amber"] && !coordinator.savingForClose)
    }

    /// The open edit's save fails during a close by hand: the window stays, edit mode turns on, and the field opens
    /// again with what was typed.
    @Test(.timeLimit(.minutes(1))) func aCloseWhoseSaveFailsKeepsTheWindowAndTheTyping() async {
        let host = Host()
        host.saveFails = true
        host.reopens = true
        host.openEdit = ([word], "Amber", ReviewRevision())
        let coordinator = ReviewWordEditCoordinator(host: host)
        #expect(!coordinator.shouldClose())
        #expect(await eventually { !coordinator.savingForClose && host.savingChanges == 2 })
        #expect(host.closed == 0 && host.failures == 1 && host.isEditingWords)
        #expect(host.reopened.map(\.text) == ["Amber"])
        #expect(!coordinator.unsaved.holdsClose)
    }

    /// The window starts closing on its own (quitting) while a close by hand waits: its close takes the held edit,
    /// once, and the close by hand saves nothing.
    @Test(.timeLimit(.minutes(1))) func aQuitTakesTheEditACloseByHandHolds() async {
        let host = Host()
        host.openEdit = ([word], "Amber", ReviewRevision())
        let coordinator = ReviewWordEditCoordinator(host: host)
        var ended = false
        // An edit handed over before, still saving, holds the close by hand back.
        let (hold, release) = AsyncStream<Void>.makeStream()
        coordinator.track([word], text: "Amb", seen: ReviewRevision(), saved: { _ in }, ended: { ended = true }) { _ in
            { for await _ in hold {}; return nil }
        }
        #expect(!coordinator.shouldClose())
        host.isClosing = true
        #expect(coordinator.takeHeldEdit()?.text == "Amber")
        #expect(coordinator.takeHeldEdit() == nil)
        release.finish()
        #expect(await eventually { ended && !coordinator.savingForClose })
        #expect(host.saved.isEmpty)
    }
}
