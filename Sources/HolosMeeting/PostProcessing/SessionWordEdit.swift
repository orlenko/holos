import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// Publishes a word edit made in Review (docs/meeting-design.md §5.10, "Editing words"), and its undo: new transcript
/// revisions (`TranscriptWordEdit`) and an immutable speaker run with the current effective edits replayed, under the
/// same lease and locks as `SessionWordFixRevert`. It never diarizes audio.
enum SessionWordEdit {
    /// The transcript was published but the speaker head was not (`repairCurrentHead` finishes it).
    struct IncompletePublication: LocalizedError {
        var message: String
        /// What `run` published, or what `restore` made current (its run was staged, not published).
        var outcome: Outcome? = nil
        var restored: Restored? = nil
        var errorDescription: String? { message }
    }

    /// A published edit.
    struct Outcome: Sendable, Equatable {
        /// The new current transcript.
        var transcriptID: String
        /// The retargeted head run (same turns and edit IDs as the one it replaced).
        var runID: String
        var heard: String
        var meant: String
        var deletion: Bool
        var before: String?
        var after: String?
        var move: ReviewWordMove
        /// The move the speaker labels were mapped by (`TranscriptWordEdit.Result.labelsMove`); its undo maps them back
        /// by its inverse.
        var labelsMove: ReviewWordMove
        /// `heard` holds words deleted earlier (`TranscriptWordEdit.Result.holdsDeleted`).
        var holdsDeleted = false
    }

    /// A published undo.
    struct Restored: Sendable, Equatable {
        var transcriptID: String
        var runID: String
    }

    /// Makes `request` on the current transcript, which must be `expectedTranscriptID` with head run `expectedRunID`
    /// (what the window showed). The words must be shown in one turn of the head's projection (the echo mask hides some
    /// microphone words, which are never edited). Nil when the text would not change; nothing is written then.
    static func run(session: URL, request: TranscriptWordEdit.Request, expectedTranscriptID: String,
                    expectedRunID: String, now: Date = Date()) async throws -> Outcome? {
        try await publishing(session: session) { archive in
            let (current, snapshot) = try expectedState(session: session, transcriptID: expectedTranscriptID,
                                                        runID: expectedRunID)
            // The one turn holding every requested word (turns may overlap; the first holding the first word may not
            // hold the rest).
            guard let projection = snapshot.projection,
                  let turn = projection.turns.first(where: { turn in
                      (request.first..<request.end).allSatisfy { word in
                          turn.spans.contains {
                              $0.segmentID == request.segmentID && $0.first <= word && word < $0.end
                          }
                      }
                  }) else {
                throw HolosError.invalidInput("Those words are not shown in the review any more; reload and try again.")
            }
            let base = try current.fixedFrom.map { try SessionFiles.transcript(id: $0, session: session) }
            let editable: (Int) -> Bool = { word in
                turn.spans.contains { $0.segmentID == request.segmentID && $0.first <= word && word < $0.end }
            }
            guard let result = try TranscriptWordEdit.editing(request, in: current, base: base, editable: editable,
                                                              now: now) else { return nil }
            // Every word the edit replaces (with any it took in) belongs to the same turns, so the labels map back on
            // its undo exactly; overlapping turns holding only some of them refuse it.
            guard TranscriptWordEdit.sameOwners(result.labelsMove.replaced, segmentID: request.segmentID,
                                                turns: projection.turns.map(\.spans)) else {
                throw TranscriptWordEdit.overlappingTurns
            }
            guard let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: result.transcript,
                                                               move: result.labelsMove, now: now) else {
                throw HolosError.invalidInput("The speaker labels cannot be kept on the edited words.")
            }
            try Task.checkCancellation()
            try SpeakerTranscriptRetarget.stage(plan, session: session)
            if let newBase = result.base, let base {
                try await archive.saveTranscriptRevision(newBase)
                try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
                    "transcriptID": newBase.id, "base": base.id, "segment": request.segmentID,
                ])
            }
            try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
                "transcriptID": result.transcript.id, "base": current.id, headFromKey: current.id,
            ].merging(details(of: result.labelsMove), uniquingKeysWith: { first, _ in first }))
            let outcome = Outcome(transcriptID: result.transcript.id, runID: plan.run.id, heard: result.heard,
                                  meant: result.meant, deletion: result.deletion, before: result.before,
                                  after: result.after, move: result.move, labelsMove: result.labelsMove,
                                  holdsDeleted: result.holdsDeleted)
            try await save(result.transcript, archive: archive, session: session,
                           incomplete: IncompletePublication(message: "The words were edited", outcome: outcome))
            try publishHead(plan, session: session, now: now,
                            incomplete: IncompletePublication(message: "The words were edited", outcome: outcome))
            return outcome
        }
    }

    /// Undoes an edit: the current transcript must still be the edit's (`expectedTranscriptID`, head run
    /// `expectedRunID`); a copy of `previousTranscriptID` (`TranscriptWordEdit.restoring`) becomes current, with the
    /// speaker labels and their effective edits carried over. `move`: the edit's `labelsMove` undone (`inverse`), which
    /// maps the labels' words. Returns the restored transcript and its run.
    static func restore(session: URL, previousTranscriptID: String, expectedTranscriptID: String,
                        expectedRunID: String, move: ReviewWordMove, now: Date = Date()) async throws -> Restored {
        try await publishing(session: session) { archive in
            let (current, snapshot) = try expectedState(session: session, transcriptID: expectedTranscriptID,
                                                        runID: expectedRunID)
            let previous = try SessionFiles.transcript(id: previousTranscriptID, session: session)
            let restored = TranscriptWordEdit.restoring(previous, now: now)
            guard let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: restored,
                                                               move: move, now: now) else {
                throw HolosError.invalidInput("The speaker labels cannot be kept on the words as they were.")
            }
            try Task.checkCancellation()
            try SpeakerTranscriptRetarget.stage(plan, session: session)
            try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
                "transcriptID": restored.id, "base": current.id, headFromKey: current.id, "undo": "1",
            ].merging(details(of: move), uniquingKeysWith: { first, _ in first }))
            let published = Restored(transcriptID: restored.id, runID: plan.run.id)
            try await save(restored, archive: archive, session: session,
                           incomplete: IncompletePublication(message: "The edit was undone", restored: published))
            try publishHead(plan, session: session, now: now,
                            incomplete: IncompletePublication(message: "The edit was undone", restored: published))
            return published
        }
    }

    /// Finishes the only partial state `run` and `restore` can leave: the edited (or restored) transcript is current,
    /// journaled as edited from `expectedTranscriptID`, but the head still has run `expectedRunID` on that transcript.
    /// The old head remains the authoritative copy of every speaker edit, so its retargeted replacement is published.
    /// Returns the run it published; nil when the head was already on the edited transcript (published elsewhere).
    @discardableResult
    static func repairCurrentHead(session: URL, expectedTranscriptID: String, expectedRunID: String,
                                  now: Date = Date()) async throws -> String? {
        try await publishing(session: session) { _ -> String? in
            guard let current = try SessionFiles.currentTranscript(session: session), current.id != expectedTranscriptID,
                  let edited = try editedEvent(of: current.id, session: session),
                  edited.base == expectedTranscriptID else {
                throw HolosError.invalidInput("The edited transcript is no longer current.")
            }
            guard let head = try SpeakerAnalysis.headState(session: session, transcript: current) else {
                throw HolosError.invalidInput("The speaker head to repair is missing.")
            }
            if head.sameTranscript { return nil }
            guard head.runID == expectedRunID else {
                throw HolosError.invalidInput("The speaker labels changed while they were being repaired.")
            }
            let snapshot = try SpeakerSessionSnapshot.load(session: session)
            guard snapshot.transcript.id == expectedTranscriptID,
                  let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: current,
                                                               move: edited.move, now: now) else {
                throw HolosError.invalidInput("The speaker labels cannot be repaired on the edited words.")
            }
            try Task.checkCancellation()
            try SpeakerTranscriptRetarget.stage(plan, session: session)
            try SpeakerTranscriptRetarget.publishHead(plan, session: session, now: now)
            return plan.run.id
        }
    }

    /// Post-processing (`MeetingPostProcessor`, before any stage may replace the transcript or relabel): finishes a
    /// word edit, its undo, or an automatic fix's revert whose transcript became current but whose speaker head was
    /// never published (the app quit or crashed in between). The old head is still the only copy of the speaker edits,
    /// so its retargeted replacement is published from it; relabelling over it would lose turn-level edits. Returns
    /// true when it published a head. Nothing is done unless the journal says `transcript` was made in Review from the
    /// head run's transcript (`editedEvent`).
    static func repairPendingHead(session: URL, transcript: Transcript, lease: ProcessingLease,
                                  now: Date = Date()) async throws -> Bool {
        guard let state = try SpeakerAnalysis.headState(session: session, transcript: transcript),
              !state.sameTranscript, let run = state.run,
              let edited = try editedEvent(of: transcript.id, session: session),
              edited.base == run.transcriptID else { return false }
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        do {
            let repaired = try await SessionArchive.withSpeakerLockAsync(at: session) { () async throws -> Bool in
                guard try SessionFiles.currentTranscript(session: session)?.id == transcript.id,
                      let head = try SpeakerAnalysis.headState(session: session, transcript: transcript),
                      head.runID == run.id else {
                    throw HolosError.invalidInput("The speaker labels changed while they were being repaired.")
                }
                if head.sameTranscript { return false }
                let snapshot = try SpeakerSessionSnapshot.load(session: session)
                guard snapshot.transcript.id == run.transcriptID,
                      let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: transcript,
                                                                   move: edited.move, now: now) else {
                    throw HolosError.invalidInput("The speaker labels cannot be kept on the words edited in Review.")
                }
                try Task.checkCancellation()
                try SpeakerTranscriptRetarget.stage(plan, session: session)
                try SpeakerTranscriptRetarget.publishHead(plan, session: session, now: now)
                return true
            }
            await archive.releaseLock()
            return repaired
        } catch {
            await archive.releaseLock()
            throw error
        }
    }

    /// The journal detail every Review change that moves the transcript pointer (an edit, its undo, an automatic fix's
    /// revert) records with the transcript it was made from, whatever its event's kind: a speaker head it still owes
    /// is found from it (`repairPendingHead`).
    static let headFromKey = "headFrom"

    /// The latest Review change that made `transcriptID` current (an edit or undo, `transcriptEdited`; an automatic
    /// fix's revert, `wordsFixed` with `headFrom`), nil when none did: the transcript it was made from, and its word
    /// move (an edit's; nil for a revert, or in a journal written before moves were recorded: the labels are then
    /// mapped by time).
    static func editedEvent(of transcriptID: String, session: URL) throws -> (base: String, move: ReviewWordMove?)? {
        guard let details = try SessionArchive.readEvents(at: session).events.last(where: {
            $0.details["transcriptID"] == transcriptID
                && ($0.details[headFromKey] != nil || $0.kind == MeetingEventKind.transcriptEdited)
        })?.details, let base = details[headFromKey] ?? details["base"] else { return nil }
        // No move recorded (a revert, or a journal from before moves were): the labels are mapped by time.
        let keys = ["segment", "replaced", "replacement"]
        guard keys.contains(where: { details[$0] != nil }) else { return (base, nil) }
        // Recorded: exactly as `details(of:)` writes it, or the event is damaged (never read another way).
        guard let segment = details["segment"], !segment.isEmpty, let replaced = parseRange(details["replaced"]),
              let replacement = parseRange(details["replacement"]) else {
            throw HolosError.invalidInput("A word edit in this meeting's event log is damaged, so the speaker labels "
                                          + "cannot be kept on its words.")
        }
        return (base, ReviewWordMove(segmentID: segment, replaced: replaced, replacement: replacement))
    }

    /// A word range as `details(of:)` writes it: two unsigned decimal numbers joined by one "-", the first not above
    /// the second ("3-5"). Anything else ("-1-2", "3-", "3-5-7", "+3-5", " 3-5", numbers past `Int`) is nil.
    static func parseRange(_ text: String?) -> Range<Int>? {
        guard let text else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }),
              let lower = Int(parts[0]), let upper = Int(parts[1]), lower <= upper else { return nil }
        return lower..<upper
    }

    /// A word move as `transcriptEdited` details record it.
    private static func details(of move: ReviewWordMove) -> [String: String] {
        ["segment": move.segmentID,
         "replaced": "\(move.replaced.lowerBound)-\(move.replaced.upperBound)",
         "replacement": "\(move.replacement.lowerBound)-\(move.replacement.upperBound)"]
    }

    // MARK: - Publication

    /// `body` holding the processing lease, the writer lock, and the speaker lock, in that order.
    private static func publishing<T>(session: URL, _ body: (SessionArchive) async throws -> T) async throws -> T {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        return try await lease.withUse(for: session) {
            let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
            do {
                let value = try await SessionArchive.withSpeakerLockAsync(at: session) { try await body(archive) }
                await archive.releaseLock()
                return value
            } catch {
                await archive.releaseLock()
                throw error
            }
        }
    }

    /// The current transcript and the labels, refused unless they are the ones the window showed.
    private static func expectedState(session: URL, transcriptID: String, runID: String) throws
        -> (Transcript, SpeakerSessionSnapshot) {
        guard let current = try SessionFiles.currentTranscript(session: session), current.id == transcriptID else {
            throw HolosError.invalidInput("The transcript changed outside this window; reload and try again.")
        }
        let snapshot = try SpeakerSessionSnapshot.load(session: session)
        guard snapshot.run?.id == runID, snapshot.transcript.id == current.id else {
            throw HolosError.invalidInput("The speaker labels changed outside this window; reload and try again.")
        }
        return (current, snapshot)
    }

    /// Makes `transcript` current (`TranscriptPointerSave`). A save that throws once the pointer already names it (the
    /// rename was done, a later step failed) did publish it: that is `incomplete` (its head is still owed), never a
    /// refusal.
    private static func save(_ transcript: Transcript, archive: SessionArchive, session: URL,
                             incomplete: IncompletePublication) async throws {
        try await TranscriptPointerSave.save(transcript, archive: archive, session: session) { error in
            var failure = incomplete
            failure.message += ", but saving it failed afterwards: " + error.localizedDescription
            return failure
        }
    }

    /// Publishes the head; on failure throws `incomplete`, whose message is what was done.
    private static func publishHead(_ plan: SpeakerTranscriptRetarget.Plan, session: URL, now: Date,
                                    incomplete: IncompletePublication) throws {
        do {
            try SpeakerTranscriptRetarget.publishHead(plan, session: session, now: now)
        } catch {
            var failure = incomplete
            failure.message += ", but the speaker head could not be published: " + error.localizedDescription
            throw failure
        }
    }
}
