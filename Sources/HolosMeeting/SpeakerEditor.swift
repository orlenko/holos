import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// What `SpeakerEditor` saved, and what the caller must do next.
public struct SpeakerEditResult: Sendable {
    /// The session after the edit (loaded once the speaker lock was released; it may include later edits).
    public var snapshot: SpeakerSessionSnapshot
    /// True when the batch changed a turn's speaker, turn boundaries, merges, exclusions, or links of a
    /// speaker whose profile has a sample from this session (PR10 sets it; always false before PR10).
    /// The caller must then `await VoiceProfileService.refreshSamples(session:extractor:store:)`.
    public var needsSampleRefresh: Bool

    public init(snapshot: SpeakerSessionSnapshot, needsSampleRefresh: Bool = false) {
        self.snapshot = snapshot; self.needsSampleRefresh = needsSampleRefresh
    }
}

/// The only writer of a session's speaker edit journal for people's edits (docs/meeting-design.md §4.9, §5.7): the
/// CLI now, the review window later. A real compare-and-append: the caller passes the projection it showed the user
/// (`view`), and a batch made on a view that no longer matches the session is refused, writing nothing, instead of
/// editing a different turn or overwriting a newer name.
///
/// Locking (§1.7): the journal is appended under the session's speaker lock, which is held only to read the head and
/// the journal, compare, and append (milliseconds). The run and its transcript are immutable files, so they are read
/// before the lock is taken. Exports are regenerated after the lock is released (they take it themselves).
public enum SpeakerEditor {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "speakers")

    /// The refusal when the session no longer matches the caller's view.
    public static let changedMessage = "Speaker labels changed since this view was loaded; reload."

    /// §4.9. Under the speaker lock: loads the current snapshot; refuses the batch (nothing written) when the
    /// head run is not `view.runID` or any action's fingerprint on `view` (applied sequentially) differs from the
    /// current state; checks every target exists (throws invalidInput otherwise); appends all lines with one
    /// batchID in one write. Then releases the lock and regenerates exports unless told not to.
    /// Throws unavailable when there is no head run.
    ///
    /// Details:
    /// - Each line's `expected` is `fingerprint(for:)` of its action on the view with the batch's earlier actions
    ///   applied (`SpeakerProjection.applying`), which the current state must reproduce exactly. A `revert` has no
    ///   fingerprint; instead its target edit must be in the same state (applied, reverted, or refused) in the view
    ///   and in the session.
    /// - An action the projection would refuse on the current state (a speaker or turn that does not exist, a split
    ///   at a turn's first word, a merge of a speaker into itself, a `newSpeaker` ID that exists or does not start
    ///   with "user:", …) refuses the whole batch with `HolosError.invalidInput`, so no line is ever written stale.
    /// - An empty batch is refused (`invalidInput`); `source` must not be empty.
    /// - A head run that cannot be used (missing or damaged, or its transcript is) refuses the edit (`unavailable`).
    /// - Once the lines are appended, a failure to load the result or to regenerate the exports throws
    ///   `HolosError.incomplete` saying the change was saved.
    @discardableResult
    public static func apply(_ actions: [SpeakerEditAction], view: SpeakerProjection, session: URL, source: String,
                             regenerateExports: Bool = true,
                             profileNames: [String: String] = [:]) throws -> SpeakerEditResult {
        guard !actions.isEmpty else { throw HolosError.invalidInput("There is no speaker change to save.") }
        try requireSource(source)
        let preloaded = readRun(view.runID, session: session)
        let saved = try SessionArchive.withSpeakerLock(at: session) { () throws -> [SpeakerEdit] in
            let base = try currentBase(view: view, session: session, preloaded: preloaded, profileNames: profileNames)
            var viewState = view
            var current = base.projection
            let batchID = UUID().uuidString
            let at = Date()
            var edits: [SpeakerEdit] = []
            edits.reserveCapacity(actions.count)
            for action in actions {
                let expected = viewState.fingerprint(for: action)
                guard expected == current.fingerprint(for: action) else { throw refusedStaleView(base.run) }
                if case .revert(let target) = action,
                   EditStatus(target, in: viewState) != EditStatus(target, in: current) {
                    throw refusedStaleView(base.run)
                }
                let id = UUID().uuidString
                let next = current.applying(action, editID: id)
                if let stale = next.staleEdits.first(where: { $0.editID == id }) {
                    throw refusal(action, reason: stale.reason, on: current)
                }
                edits.append(SpeakerEdit(id: id, baseRunID: base.run.id, at: at, source: source, action: action,
                                         expected: expected, batchID: batchID))
                current = next
                viewState = viewState.applying(action, editID: id)
            }
            try SessionSpeakerStore.appendEdits(edits, session: session)
            log.info("Session \(base.run.sessionID, privacy: .public): saved \(edits.count, privacy: .public) speaker edits (batch \(batchID, privacy: .public), run \(base.run.id, privacy: .public))")
            return edits
        }
        return try finish(saved, session: session, regenerateExports: regenerateExports, profileNames: profileNames)
    }

    /// Appends a revert for every edit of `view.lastUndoableBatchID` (same refusal rules).
    ///
    /// Details:
    /// - Refused with `invalidInput` when the view has nothing to undo.
    /// - Refused, writing nothing, with `changedMessage` when the head run is not `view.runID`, when the session's
    ///   newest undoable batch is no longer the view's (someone edited or undid since), or when the lines of that
    ///   batch in effect differ between the view and the session.
    /// - Only the batch's lines in effect are reverted, in journal order, as one new batch; a revert carries no
    ///   fingerprint (§4.9). Reverts are never undone themselves (there is no redo), so repeated calls walk back
    ///   through earlier batches.
    @discardableResult
    public static func undoLast(view: SpeakerProjection, session: URL, source: String,
                                regenerateExports: Bool = true) throws -> SpeakerEditResult {
        try requireSource(source)
        guard let batchID = view.lastUndoableBatchID else {
            throw HolosError.invalidInput("There is no speaker change to undo.")
        }
        let preloaded = readRun(view.runID, session: session)
        let saved = try SessionArchive.withSpeakerLock(at: session) { () throws -> [SpeakerEdit] in
            let base = try currentBase(view: view, session: session, preloaded: preloaded, profileNames: [:])
            guard base.projection.lastUndoableBatchID == batchID else { throw refusedStaleView(base.run) }
            let lines = Set(base.journal.edits
                .filter { $0.baseRunID == base.run.id && ($0.batchID ?? $0.id) == batchID }
                .map(\.id))
            let targets = base.projection.appliedEditIDs.filter(lines.contains)
            guard !targets.isEmpty, targets == view.appliedEditIDs.filter(lines.contains) else {
                throw refusedStaleView(base.run)
            }
            var current = base.projection
            let revertBatch = UUID().uuidString
            let at = Date()
            var edits: [SpeakerEdit] = []
            edits.reserveCapacity(targets.count)
            for target in targets {
                let action = SpeakerEditAction.revert(editID: target)
                let id = UUID().uuidString
                let next = current.applying(action, editID: id)
                if let stale = next.staleEdits.first(where: { $0.editID == id }) {
                    throw refusal(action, reason: stale.reason, on: current)
                }
                edits.append(SpeakerEdit(id: id, baseRunID: base.run.id, at: at, source: source, action: action,
                                         expected: current.fingerprint(for: action), batchID: revertBatch))
                current = next
            }
            // Nothing applies after the newest batch, so undoing it can only take its own lines out; a line that
            // could not be applied before must not come back into effect either.
            let undone = Set(targets)
            guard current.appliedEditIDs == base.projection.appliedEditIDs.filter({ !undone.contains($0) }) else {
                throw HolosError.invalidInput("Undoing the last change would also bring back an earlier change that "
                                              + "could not be applied, so nothing was undone.")
            }
            try SessionSpeakerStore.appendEdits(edits, session: session)
            log.info("Session \(base.run.sessionID, privacy: .public): undid batch \(batchID, privacy: .public) with \(edits.count, privacy: .public) reverts (batch \(revertBatch, privacy: .public))")
            return edits
        }
        return try finish(saved, session: session, regenerateExports: regenerateExports, profileNames: [:])
    }

    // MARK: - Private

    /// The head run with its transcript and the current journal, read under the speaker lock.
    private struct Base {
        let run: DiarizationRun
        let journal: EditJournal
        /// The run with the whole journal applied (no recognition: fingerprints and validity never depend on it).
        let projection: SpeakerProjection
    }

    /// A run and the transcript its turns reference, read before the speaker lock is taken.
    private struct RunFiles {
        let run: DiarizationRun
        let transcript: Transcript
    }

    /// Runs and transcript revisions are immutable, so the view's run can be read before the lock; the head check
    /// under the lock decides whether it is still the one in use. Errors are kept for that check to report, since a
    /// run that moved on is better reported as a changed view than as a damaged file.
    private static func readRun(_ runID: String, session: URL) -> Result<RunFiles, any Error> {
        Result {
            let run: DiarizationRun
            do {
                run = try SessionSpeakerStore.readRun(id: runID, session: session)
            } catch let error where SessionFiles.isDamage(error) {
                throw HolosError.unavailable("The speaker labels are missing or damaged. Label speakers again.")
            }
            let transcript: Transcript
            do {
                transcript = try SessionFiles.transcript(id: run.transcriptID, session: session)
            } catch let error where SessionFiles.isDamage(error) {
                throw HolosError.unavailable(
                    "The transcript the speaker labels were made from is missing or damaged. Label speakers again.")
            }
            if let problem = SpeakerSessionSnapshot.spanProblem(run: run, transcript: transcript) {
                throw HolosError.unavailable(problem)
            }
            return RunFiles(run: run, transcript: transcript)
        }
    }

    /// Caller holds the speaker lock. Throws unavailable when there is no head run or it is not the view's.
    private static func currentBase(view: SpeakerProjection, session: URL, preloaded: Result<RunFiles, any Error>,
                                    profileNames: [String: String]) throws -> Base {
        guard let head = try SessionSpeakerStore.readHead(session: session) else {
            throw HolosError.unavailable("This meeting has no speaker labels to edit yet. Label speakers first.")
        }
        guard head.runID == view.runID else {
            log.notice("Refused a speaker edit made on run \(view.runID, privacy: .public); the head is now run \(head.runID, privacy: .public)")
            throw HolosError.unavailable(changedMessage)
        }
        let files = try preloaded.get()
        let journal = try SessionSpeakerStore.readEdits(session: session)
        let projection = SpeakerProjection.make(run: files.run, transcript: files.transcript, edits: journal.edits,
                                                recognition: nil, profileNames: profileNames)
        return Base(run: files.run, journal: journal, projection: projection)
    }

    /// Loads the result after the lock is released and regenerates the exports when asked. The lines are saved
    /// by then, so a failure here says so.
    private static func finish(_ saved: [SpeakerEdit], session: URL, regenerateExports: Bool,
                               profileNames: [String: String]) throws -> SpeakerEditResult {
        let snapshot: SpeakerSessionSnapshot
        do {
            snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: profileNames)
        } catch {
            log.error("Saved \(saved.count, privacy: .public) speaker edits, then could not reload the session: \(error.localizedDescription, privacy: .private)")
            throw HolosError.incomplete("The speaker change was saved, but the speaker labels could not be "
                                        + "reloaded: \(error.localizedDescription)")
        }
        if regenerateExports {
            do {
                try SessionExports.regenerate(session: session, profileNames: profileNames)
            } catch {
                log.error("Saved \(saved.count, privacy: .public) speaker edits, then could not rewrite the exports: \(error.localizedDescription, privacy: .private)")
                throw HolosError.incomplete("The speaker change was saved, but the exports could not be rewritten: "
                                            + "\(error.localizedDescription) Export the transcript again to update them.")
            }
        }
        return SpeakerEditResult(snapshot: snapshot, needsSampleRefresh: false)
    }

    private static func requireSource(_ source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HolosError.invalidInput("A speaker edit needs a source (app or cli).")
        }
    }

    private static func refusedStaleView(_ run: DiarizationRun) -> HolosError {
        log.notice("Session \(run.sessionID, privacy: .public): refused a speaker edit made on an outdated view of run \(run.id, privacy: .public)")
        return HolosError.unavailable(changedMessage)
    }

    /// Where an edit stands in a projection; a revert must see its target in the same state in the view and now.
    private enum EditStatus: Equatable {
        case applied, reverted, refused, other

        init(_ editID: String, in projection: SpeakerProjection) {
            if projection.appliedEditIDs.contains(editID) {
                self = .applied
            } else if projection.revertedEditIDs.contains(editID) {
                self = .reverted
            } else if projection.staleEdits.contains(where: { $0.editID == editID }) {
                self = .refused
            } else {
                self = .other
            }
        }
    }

    /// The error for an action the projection refuses on the current state (`reason` is its `StaleEdit.reason`).
    static func refusal(_ action: SpeakerEditAction, reason: String, on projection: SpeakerProjection) -> HolosError {
        switch reason {
        case "speaker not found":
            let listed = Set(projection.speakers.map(\.id))
            let missing = referencedSpeakers(action).filter { !listed.contains($0) }
            if !missing.isEmpty {
                return HolosError.invalidInput("There is no speaker \(missing.joined(separator: ", ")) in this "
                                               + "meeting's speaker labels; name one that is listed.")
            }
        case "turn not found":
            let listed = Set(projection.turns.map(\.id))
            let missing = referencedTurns(action).filter { !listed.contains($0) }
            if !missing.isEmpty {
                return HolosError.invalidInput("There is no turn \(missing.joined(separator: ", ")) in this "
                                               + "meeting's speaker labels; name one that is listed.")
            }
        default:
            break
        }
        if case .revert(let target) = action {
            return HolosError.invalidInput("Cannot undo edit \(target): \(reason).")
        }
        return HolosError.invalidInput("This speaker change cannot be made: \(reason).")
    }

    /// Speakers an action requires to exist (not the one `newSpeaker` creates).
    private static func referencedSpeakers(_ action: SpeakerEditAction) -> [String] {
        switch action {
        case .rename(let speakerID, _), .linkProfile(let speakerID, _), .rejectProfile(let speakerID, _):
            [speakerID]
        case .merge(let from, let into):
            from == into ? [from] : [from, into]
        case .reassignTurns(_, let to):
            to.map { [$0] } ?? []
        case .splitTurn, .newSpeaker, .excludeFromEnrollment, .revert:
            []
        }
    }

    private static func referencedTurns(_ action: SpeakerEditAction) -> [String] {
        var seen = Set<String>()
        let turns: [String]
        switch action {
        case .reassignTurns(let turnIDs, _), .newSpeaker(_, _, let turnIDs), .excludeFromEnrollment(let turnIDs):
            turns = turnIDs
        case .splitTurn(let turnID, _):
            turns = [turnID]
        case .rename, .linkProfile, .rejectProfile, .merge, .revert:
            turns = []
        }
        return turns.filter { seen.insert($0).inserted }
    }
}
