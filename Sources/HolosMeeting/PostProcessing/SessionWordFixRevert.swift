import Foundation
import HolosCore
import HolosStorage

/// Reverts one marked meeting word fix from Review, publishing a new transcript revision and an immutable speaker
/// run with the current effective edits replayed. It never diarizes audio.
enum SessionWordFixRevert {
    struct IncompletePublication: LocalizedError {
        var message: String
        /// What was published (the transcript is current; its head is owed).
        var outcome: Outcome? = nil
        var errorDescription: String? { message }
    }

    /// A published revert: the retargeted head run (same turns and edit IDs as the one it replaced), and how it moved
    /// the segment's words (the fix's words became the recognizer's own), which changes queued in Review follow.
    struct Outcome: Sendable, Equatable {
        var runID: String
        var move: ReviewWordMove
        /// The transcript the revert made current.
        var transcriptID: String? = nil
    }

    @discardableResult
    static func run(session: URL, word: WordRef, expectedTranscriptID: String, expectedRunID: String,
                    now: Date = Date()) async throws -> Outcome {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        return try await lease.withUse(for: session) {
            try await publish(session: session, word: word, expectedTranscriptID: expectedTranscriptID,
                              expectedRunID: expectedRunID, lease: lease, now: now)
        }
    }

    /// Finishes the only partial state `run` can leave: the reverted transcript is current but the preceding head
    /// still points at `expectedTranscriptID`. The old head remains the authoritative copy of every speaker edit, so
    /// rebuild and publish its retargeted replacement instead of adopting or relabelling the stale snapshot. Returns the
    /// run it published; nil when the head was already on the reverted transcript (published elsewhere).
    @discardableResult
    static func repairCurrentHead(session: URL, expectedTranscriptID: String, expectedRunID: String,
                                  now: Date = Date()) async throws -> String? {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        return try await lease.withUse(for: session) {
            let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
            do {
                let published = try await SessionArchive.withSpeakerLockAsync(at: session) { () async throws -> String? in
                    guard let current = try SessionFiles.currentTranscript(session: session),
                          current.id != expectedTranscriptID,
                          current.segments.contains(where: {
                              ($0.fixes ?? []).contains { $0.kind == .reviewRevert }
                          }) else {
                        throw HolosError.invalidInput("The reverted transcript is no longer current.")
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
                          let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot,
                                                                       to: current, now: now) else {
                        throw HolosError.invalidInput("The speaker labels cannot be repaired on the reverted words.")
                    }
                    try Task.checkCancellation()
                    try SpeakerTranscriptRetarget.stage(plan, session: session)
                    try SpeakerTranscriptRetarget.publishHead(plan, session: session, now: now)
                    return plan.run.id
                }
                await archive.releaseLock()
                return published
            } catch {
                await archive.releaseLock()
                throw error
            }
        }
    }

    private static func publish(session: URL, word: WordRef, expectedTranscriptID: String, expectedRunID: String,
                                lease: ProcessingLease, now: Date) async throws -> Outcome {
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        do {
            let outcome = try await SessionArchive.withSpeakerLockAsync(at: session) { () async throws -> Outcome in
                let current = try SessionFiles.currentTranscript(session: session)
                guard let current, current.id == expectedTranscriptID, let baseID = current.fixedFrom else {
                    throw HolosError.invalidInput("The transcript changed outside this window; reload and try again.")
                }
                let snapshot = try SpeakerSessionSnapshot.load(session: session)
                guard snapshot.run?.id == expectedRunID, snapshot.transcript.id == current.id else {
                    throw HolosError.invalidInput("The speaker labels changed outside this window; reload and try again.")
                }
                let base = try SessionFiles.transcript(id: baseID, session: session)
                let reverted = try WordFixes.reverting(word, in: current, to: base, now: now)
                guard let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot,
                                                                   to: reverted, now: now) else {
                    throw HolosError.invalidInput("The speaker labels cannot be kept on the reverted words.")
                }
                // The fix's words became the recognizer's own: their count may differ ("你好地球" is "你好" and "世界").
                guard let fixed = current.segments.first(where: { $0.id == word.segmentID })?.fixes?.first(where: {
                          ($0.kind == .correction || $0.kind == .term) && $0.first <= word.word && word.word < $0.end
                      }),
                      let restored = reverted.segments.first(where: { $0.id == word.segmentID })?.fixes?.first(where: {
                          $0.kind == .reviewRevert && $0.first == fixed.first
                      }) else {
                    throw HolosError.invalidInput("That word fix cannot be matched to the original transcript.")
                }
                let move = ReviewWordMove(segmentID: word.segmentID, replaced: fixed.first..<fixed.end,
                                          replacement: restored.first..<restored.end)
                let published = Outcome(runID: plan.run.id, move: move, transcriptID: reverted.id)
                try Task.checkCancellation()
                try SpeakerTranscriptRetarget.stage(plan, session: session)
                let counts = WordFixes.Counts(reverted)
                try await archive.recordEvent(kind: MeetingEventKind.wordsFixed, details: [
                    "transcriptID": reverted.id,
                    "base": base.id,
                    "corrections": String(counts.corrections),
                    "terms": String(counts.terms),
                    "asked": "0",
                    "reverted": "1",
                    // Made from `current`: a speaker head still owed after a crash is found and repaired from it.
                    SessionWordEdit.headFromKey: current.id,
                ])
                // Committed once the pointer names it, even when the save throws after that.
                try await TranscriptPointerSave.save(reverted, archive: archive, session: session) { error in
                    IncompletePublication(message: "The word fix was reverted, but saving it failed afterwards: "
                                          + error.localizedDescription, outcome: published)
                }
                do {
                    try SpeakerTranscriptRetarget.publishHead(plan, session: session, now: now)
                } catch {
                    throw IncompletePublication(message: "The word fix was reverted, but the speaker head could "
                                                + "not be published: \(error.localizedDescription)",
                                                outcome: published)
                }
                return published
            }
            await archive.releaseLock()
            return outcome
        } catch {
            await archive.releaseLock()
            throw error
        }
    }
}
