import Foundation
import HolosCore
import HolosStorage

/// Reverts one marked meeting word fix from Review, publishing a new transcript revision and an immutable speaker
/// run with the current effective edits replayed. It never diarizes audio.
enum SessionWordFixRevert {
    struct IncompletePublication: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func run(session: URL, word: WordRef, expectedTranscriptID: String, expectedRunID: String,
                    now: Date = Date()) async throws {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        try await lease.withUse(for: session) {
            try await publish(session: session, word: word, expectedTranscriptID: expectedTranscriptID,
                              expectedRunID: expectedRunID, lease: lease, now: now)
        }
    }

    /// Finishes the only partial state `run` can leave: the reverted transcript is current but the preceding head
    /// still points at `expectedTranscriptID`. The old head remains the authoritative copy of every speaker edit, so
    /// rebuild and publish its retargeted replacement instead of adopting or relabelling the stale snapshot.
    static func repairCurrentHead(session: URL, expectedTranscriptID: String, expectedRunID: String,
                                  now: Date = Date()) async throws {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        try await lease.withUse(for: session) {
            let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
            do {
                try await SessionArchive.withSpeakerLockAsync(at: session) {
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
                    if head.sameTranscript { return }
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
                }
                await archive.releaseLock()
            } catch {
                await archive.releaseLock()
                throw error
            }
        }
    }

    private static func publish(session: URL, word: WordRef, expectedTranscriptID: String, expectedRunID: String,
                                lease: ProcessingLease, now: Date) async throws {
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        do {
            try await SessionArchive.withSpeakerLockAsync(at: session) {
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
                ])
                try await archive.saveTranscript(reverted, writeLegacyExports: false)
                do {
                    try SpeakerTranscriptRetarget.publishHead(plan, session: session, now: now)
                } catch {
                    throw IncompletePublication(message: "The word fix was reverted, but the speaker head could "
                                                + "not be published: \(error.localizedDescription)")
                }
            }
            await archive.releaseLock()
        } catch {
            await archive.releaseLock()
            throw error
        }
    }
}
