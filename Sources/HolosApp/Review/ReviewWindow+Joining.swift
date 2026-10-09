import AppKit
import HolosCore
import HolosMeeting

/// Joining rows (`TurnListView+Joining`): the window checks a join asked at a row's edge, makes it, and drops every
/// join on Undo, a change that fails, or a relabel. Its stored state (`paragraphBreaks`, `allParagraphs`,
/// `joinsCleared`, `revertsSeen`) stays in `ReviewWindow`.
extension ReviewWindow {
    /// What a join asked at a row's edge makes now (`TurnListView.resolveJoin`): checked as a split is (the review
    /// editable, the same labels run), then found among every row grouped (`joinResolution`).
    func resolveJoin(_ request: ReviewJoinRequest) -> ReviewJoinResolution {
        // Held read-only (a maintenance command, labels that could not be reread): no join, as no split.
        guard review.isEditable else {
            return .refused(review.pauseReason ?? review.reloadProblem ?? "This meeting cannot be changed right now.")
        }
        if let seen = request.seen.runID, seen != review.projection.runID,
           !review.keepsTurns(of: seen, in: review.projection.runID) {
            return .refused(Self.joinRelabelled)
        }
        return Self.joinResolution(paragraphID: review.resolvedTurnID(request.paragraphID), forward: request.forward,
                                   paragraphs: allParagraphs)
    }

    static let joinRelabelled = "The speakers were labelled again since; try the join again."
    static let joinNotShown = "That turn no longer starts a row; try the join again."

    /// `resolveJoin`'s rule over every row grouped (`paragraphs`, before a search filters them): the row
    /// `paragraphID` joins the row before it (with `forward`, the row after it joins it). Nothing to join with at the
    /// meeting's first row (last, `forward`); refused when no row starts with that turn any more.
    static func joinResolution(paragraphID: String, forward: Bool,
                               paragraphs: [ReviewParagraph]) -> ReviewJoinResolution {
        guard let index = paragraphs.firstIndex(where: { $0.id == paragraphID }) else { return .refused(joinNotShown) }
        let earlier = forward ? index : index - 1
        guard earlier >= 0 else { return .nothing(TurnListView.nothingBefore) }
        guard earlier + 1 < paragraphs.count else { return .nothing(TurnListView.nothingAfter) }
        return .join(ReviewParagraphs.join(paragraphs[earlier + 1], to: paragraphs[earlier]))
    }

    /// Makes `join`: the window joins each turn of the later row to the paragraph before it
    /// (`ReviewParagraphBreaks.join`, never saved; every turn, so the row stays whole through its new speaker), and
    /// when the rows' speakers differ, the later row's turns take the earlier row's speaker through the review's
    /// assignment (undoable with ⌘Z and learned from as any made with the row's pop-up), refused when the meeting was
    /// labelled again since the rows were shown. Joins are only how rows read, with the simplest life: made at once,
    /// and all dropped on any Undo, any change that fails, and any relabel (`clearJoins`). Then, asked from the field,
    /// the field opens again where the rows met (the caret at the start of the later row's first word, or at the end
    /// of the earlier row's last word for forward Delete), where that word is after the word edits saved meanwhile
    /// (`joinBoundary`), so typing goes on there; asked from the menu, the joined row is selected. VoiceOver hears
    /// that the rows were joined. Nothing of that once the joins were dropped meanwhile (⌘Z pressed, say).
    func applyJoin(_ join: ReviewParagraphJoin, request: ReviewJoinRequest) {
        let runID = review.projection.runID
        // The rows the join was asked on: labelled again since, a turn or speaker ID may name another now.
        let seenRun = request.seen.runID ?? runID
        let sameLabels = { [review] in
            seenRun == review.projection.runID || review.keepsTurns(of: seenRun, in: review.projection.runID)
        }
        guard sameLabels() else {
            problem = Self.joinRelabelled
            refreshFooter()
            return
        }
        let turns = join.turnIDs.compactMap { id in review.projection.turns.first { $0.id == id } }
        guard !turns.isEmpty else { return }
        // A word's field opened since the join was asked (the speaker change took a while): it keeps the keyboard.
        let fieldsOpened = turnList.fieldsOpened
        let message = join.reassign.isEmpty ? TurnListView.joined : TurnListView.joinedSpeaker
        let finish = { [weak self] in
            guard let self else { return }
            self.refresh()
            if NSWorkspace.shared.isVoiceOverEnabled {
                NSAccessibility.post(element: self.window, notification: .announcementRequested, userInfo: [
                    .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            }
            guard !self.turnList.typingElsewhere, self.turnList.fieldsOpened == fieldsOpened else { return }
            if request.fromField, self.turnList.editingWords, self.reopenJoinField(request, message: message) { return }
            self.turnList.select([self.review.resolvedTurnID(join.turnID)], scroll: true)
        }
        // Made here, as a row break is: what the footer said of an earlier change goes.
        clearTransientMessages()
        for turn in turns { paragraphBreaks.join(turn, runID: runID) }
        guard !join.reassign.isEmpty else {
            finish()
            return
        }
        refresh()
        let cleared = joinsCleared
        let target: ReviewAssignTarget = join.speakerID.map { .speaker($0) } ?? .unknown
        perform { [weak self] review in
            // Checked again as the assignment is queued: a reload may have adopted a relabel since.
            guard sameLabels() else { throw HolosError.invalidInput(Self.joinRelabelled) }
            try await review.assign(join.reassign, to: target)
            // Dropped meanwhile (⌘Z pressed, a change failed) or relabelled since (its turn IDs may name other turns
            // now): no field, no announcement.
            guard let self, self.joinsCleared == cleared, sameLabels() else { return }
            finish()
        }
    }

    /// Drops every join (Undo, a change that failed, a relabel): rows read as they group on their own again.
    func clearJoins() {
        joinsCleared += 1
        guard !paragraphBreaks.joins.isEmpty else { return }
        paragraphBreaks.clearJoins()
        refresh()
    }

    /// Opens the field again where a join from it met the rows: `request.word`, followed through the word moves saved
    /// since it was chosen (a word edit queued before the join's speaker change saves first), at the same edge; at a
    /// word deleted meanwhile, the start of the word after it, else the end of the one before. Nothing when the words
    /// were changed elsewhere since.
    private func reopenJoinField(_ request: ReviewJoinRequest, message: String) -> Bool {
        guard request.seen.wordsEpoch == review.wordsEpoch,
              let place = Self.joinBoundary(request.word, atEnd: request.forward,
                                            through: review.shownWordMoves.dropFirst(request.seen.moves)) else {
            return false
        }
        let turnID = request.turnID.map(review.resolvedTurnID)
        if turnList.reopenField(at: place.word, atEnd: place.atEnd, message: message, inTurn: turnID) { return true }
        guard !place.atEnd, place.word.word > 0 else { return false }
        return turnList.reopenField(at: WordRef(segmentID: place.word.segmentID, word: place.word.word - 1),
                                    atEnd: true, message: message, inTurn: turnID)
    }

    /// Where the edge of `word` (its start; its end, `atEnd`) is after `moves`, as for a split
    /// (`splitBoundary`).
    static func joinBoundary(_ word: WordRef, atEnd: Bool,
                             through moves: ArraySlice<ReviewWordMove>) -> (word: WordRef, atEnd: Bool)? {
        splitBoundary(ReviewWord(ref: word, text: "", start: 0), atEnd: atEnd, through: moves)
    }
}
