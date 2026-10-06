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
        /// What `run` published, or the transcript `restore` made current.
        var outcome: Outcome? = nil
        var restored: String? = nil
        var errorDescription: String? { message }
    }

    /// A published edit.
    struct Outcome: Sendable, Equatable {
        /// The new current transcript.
        var transcriptID: String
        var heard: String
        var meant: String
        var deletion: Bool
        var before: String?
        var after: String?
    }

    /// Makes `request` on the current transcript, which must be `expectedTranscriptID` with head run `expectedRunID`
    /// (what the window showed). The words must be shown in one turn of the head's projection (the echo mask hides some
    /// microphone words, which are never edited). Nil when the text would not change; nothing is written then.
    static func run(session: URL, request: TranscriptWordEdit.Request, expectedTranscriptID: String,
                    expectedRunID: String, now: Date = Date()) async throws -> Outcome? {
        try await publishing(session: session) { archive in
            let (current, snapshot) = try expectedState(session: session, transcriptID: expectedTranscriptID,
                                                        runID: expectedRunID)
            guard let projection = snapshot.projection,
                  let turn = projection.turns.first(where: { turn in
                      turn.spans.contains {
                          $0.segmentID == request.segmentID && $0.first <= request.first && request.first < $0.end
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
            guard let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: result.transcript,
                                                               now: now) else {
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
                "transcriptID": result.transcript.id, "base": current.id, "segment": request.segmentID,
            ])
            try await archive.saveTranscript(result.transcript, writeLegacyExports: false)
            let outcome = Outcome(transcriptID: result.transcript.id, heard: result.heard, meant: result.meant,
                                  deletion: result.deletion, before: result.before, after: result.after)
            try publishHead(plan, session: session, now: now,
                            incomplete: IncompletePublication(message: "The words were edited", outcome: outcome))
            return outcome
        }
    }

    /// Undoes an edit: the current transcript must still be the edit's (`expectedTranscriptID`, head run
    /// `expectedRunID`); a copy of `previousTranscriptID` (`TranscriptWordEdit.restoring`) becomes current, with the
    /// speaker labels and their effective edits carried over. Returns the restored transcript's ID.
    static func restore(session: URL, previousTranscriptID: String, expectedTranscriptID: String,
                        expectedRunID: String, now: Date = Date()) async throws -> String {
        try await publishing(session: session) { archive in
            let (current, snapshot) = try expectedState(session: session, transcriptID: expectedTranscriptID,
                                                        runID: expectedRunID)
            let previous = try SessionFiles.transcript(id: previousTranscriptID, session: session)
            let restored = TranscriptWordEdit.restoring(previous, now: now)
            guard let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: restored,
                                                               now: now) else {
                throw HolosError.invalidInput("The speaker labels cannot be kept on the words as they were.")
            }
            try Task.checkCancellation()
            try SpeakerTranscriptRetarget.stage(plan, session: session)
            try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
                "transcriptID": restored.id, "base": current.id, "undo": "1",
            ])
            try await archive.saveTranscript(restored, writeLegacyExports: false)
            try publishHead(plan, session: session, now: now,
                            incomplete: IncompletePublication(message: "The edit was undone", restored: restored.id))
            return restored.id
        }
    }

    /// Finishes the only partial state `run` and `restore` can leave: the edited (or restored) transcript is current,
    /// journaled as edited from `expectedTranscriptID`, but the head still has run `expectedRunID` on that transcript.
    /// The old head remains the authoritative copy of every speaker edit, so its retargeted replacement is published.
    static func repairCurrentHead(session: URL, expectedTranscriptID: String, expectedRunID: String,
                                  now: Date = Date()) async throws {
        try await publishing(session: session) { _ in
            guard let current = try SessionFiles.currentTranscript(session: session), current.id != expectedTranscriptID,
                  try SessionArchive.readEvents(at: session).events.last(where: {
                      $0.kind == MeetingEventKind.transcriptEdited && $0.details["transcriptID"] == current.id
                  })?.details["base"] == expectedTranscriptID else {
                throw HolosError.invalidInput("The edited transcript is no longer current.")
            }
            guard let head = try SpeakerAnalysis.headState(session: session, transcript: current) else {
                throw HolosError.invalidInput("The speaker head to repair is missing.")
            }
            if head.sameTranscript { return }
            guard head.runID == expectedRunID else {
                throw HolosError.invalidInput("The speaker labels changed while they were being repaired.")
            }
            let snapshot = try SpeakerSessionSnapshot.load(session: session)
            guard snapshot.transcript.id == expectedTranscriptID,
                  let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: current,
                                                               now: now) else {
                throw HolosError.invalidInput("The speaker labels cannot be repaired on the edited words.")
            }
            try Task.checkCancellation()
            try SpeakerTranscriptRetarget.stage(plan, session: session)
            try SpeakerTranscriptRetarget.publishHead(plan, session: session, now: now)
        }
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
