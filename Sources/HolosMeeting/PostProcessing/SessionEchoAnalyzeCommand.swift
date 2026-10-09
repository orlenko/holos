import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// What `voiceislocal session echo-analyze` does (docs/meeting-design.md §5.11), as a library call: a call's acoustic
/// echo analysis is saved in `echo/`, and the transcript files are written again from the labels as they now show
/// (the projection hides the echo). Nothing else changes: the speaker labels, their edits, the transcript and its word
/// fixes stay as they are on disk.
public enum SessionEchoAnalyzeCommand {
    public struct Request: Sendable {
        public var session: URL
        /// Analyse again even when the saved analysis is of this audio.
        public var force: Bool
        /// The background-job lock held for the whole run (`DeepTranscriptionLock`, kind `echo`): the command passes
        /// `DeepTranscriptionLock.url`, so it runs alone with final transcripts and summaries on this Mac, and a run
        /// that outlived the app that started it is seen as busy after a relaunch. Nil takes none (tests).
        public var jobLock: URL?

        public init(session: URL, force: Bool = false, jobLock: URL? = nil) {
            self.session = session; self.force = force; self.jobLock = jobLock
        }
    }

    /// What `voiceislocal session echo-analyze --json` prints, and what the app reads from it.
    public struct Outcome: Sendable, Equatable, Codable {
        public var sessionID: String
        /// Nil for a meeting the analysis does not apply to (not a call, or no microphone audio).
        public var verdict: EchoAnalysis.Verdict?
        public var delay: EchoAnalysis.DelayFit?
        /// The analysis ran now; false when the saved one of this audio was used.
        public var analysed: Bool
        public var analysisSeconds: Double?
        /// Microphone turns shown without and with the echo hidden, and the microphone words hidden; nil without
        /// speaker labels.
        public var microphoneTurnsBefore: Int?
        public var microphoneTurnsAfter: Int?
        public var hiddenWords: Int?
        /// One paragraph for the terminal; names no people and quotes no transcript text.
        public var summary: String
        /// 0, or 3 when the analysis was saved but the transcript files or a voice sample could not be brought in
        /// step (the summary says which; as Recover's warnings).
        public var exitCode: Int32 = 0
    }

    /// What the command says when Ctrl-C or SIGTERM stopped it (`run` threw `CancellationError`).
    public static let cancellationMessage = "Stopped. Run the command again to finish: an analysis already saved is "
        + "kept, and the transcript files and voice samples are brought in step with it."

    /// Runs under the background-job lock (`Request.jobLock`) and the session's processing lease. Throws, with nothing
    /// changed, when another job holds the lock (`DeepTranscriptionLock.busyMessage`), the meeting is still recording,
    /// another process holds the lease, the audio was deleted and there is no saved analysis of it to use (or `force`
    /// asks for a new one), a saved analysis was written by a newer Voice is Local, or the audio cannot be prepared
    /// (the next run tries again). With the audio deleted and a saved analysis of it, nothing is analysed: the
    /// transcript files are written again, and samples the labels now show differently are removed (none can be
    /// computed again). `profiles` gives people's names to the exports, and with `voiceSamples` the voice samples
    /// people have from this meeting are brought in step with what the labels now show
    /// (`VoiceProfileService.refreshSamples`, as after an edit): worked out from the files, so a mask an earlier pass
    /// saved without doing so is caught up too, and up-to-date samples cost nothing.
    ///
    /// Cancelled (Ctrl-C, or SIGTERM when the app needs the Mac for a meeting), it throws `CancellationError`: before
    /// it starts, or before the voice samples (whose recomputing can take minutes on a long call), and while they are
    /// extracted. The analysis and the transcript rewrite before that are short and not cut short; each leaves files
    /// a later run reads as done or still owed (the mask saved in one step; the exports recorded `pending` until all
    /// are written; the samples saved together, or not at all), so `EchoCatchUpSchedule.needsAnalysis` still finds
    /// what was not finished.
    public static func run(_ request: Request, voiceSamples: VoiceSampleSource,
                           profiles: SpeakerProfileStore? = nil,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        let session = request.session
        var held: DeepTranscriptionLock.Taken?
        if let jobLock = request.jobLock {
            let sessionID = (try? SessionArchive.readManifest(at: session).id)
                ?? session.deletingPathExtension().lastPathComponent
            guard let taken = try DeepTranscriptionLock.take(
                DeepTranscriptionLock.Holder(pid: getpid(), sessionID: sessionID, force: request.force,
                                             kind: DeepTranscriptionLock.Holder.echoKind), at: jobLock) else {
                throw HolosError.unavailable(DeepTranscriptionLock.busyMessage)
            }
            held = taken
        }
        defer { held?.release() }
        try Task.checkCancellation()
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording. Stop it before analysing its echo.")
        }
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        let result = try await lease.withUse(for: session) {
            try analyze(request, profiles: profiles, freeSpace: freeSpace, progress: progress)
        }
        var outcome = result.outcome
        if outcome.verdict != nil, let profiles, var makeExtractor = voiceSamples.extractor {
            // Without audio no sample can be computed again: one the labels now show differently is removed.
            if result.audioDeleted { makeExtractor = { _ in nil } }
            // Stopped now, the samples are still out of step with the saved mask: the next run brings them in step.
            try Task.checkCancellation()
            do {
                try await VoiceProfileService.refreshSamplesIfLearned(session: session, makeExtractor: makeExtractor,
                                                                      store: profiles)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome.summary += " A voice sample learned from this meeting could not be updated ("
                    + "\(error.localizedDescription)); run the command again."
                outcome.exitCode = 3
            }
        }
        return outcome
    }

    /// The outcome, and whether the meeting's audio was deleted (its saved analysis was used as it is).
    private static func analyze(_ request: Request, profiles: SpeakerProfileStore?, freeSpace: any FreeSpaceProvider,
                                progress: @escaping @Sendable (String) -> Void) throws
        -> (outcome: Outcome, audioDeleted: Bool) {
        let session = request.session
        let manifest = try SessionArchive.readManifest(at: session)
        let meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        var outcome = Outcome(sessionID: manifest.id, analysed: false, summary: "")
        guard EchoAnalysisStage.applies(meeting: meeting, manifest: manifest) else {
            outcome.summary = "This meeting was not recorded as a call with microphone audio, so there is no echo of "
                + "the call to find. Nothing changed."
            return (outcome, false)
        }
        // With the audio deleted, a saved analysis of it is still used (Delete Audio keeps echo/): the transcript
        // files are written again for it (after a new word rule, say), but nothing can be analysed again.
        let audioDeleted = try SessionFiles.audioDeleted(session: session, sessionID: manifest.id)
        let stored: EchoMaskStore.Stored
        switch EchoAnalysisStage.saved(session: session, manifest: manifest) {
        case .current(let current) where !request.force:
            stored = current
        case .newer:
            throw HolosError.unavailable("echo/mask.json was written by a newer version of Voice is Local; update "
                                         + "Voice is Local to analyse this meeting's echo again.")
        default:
            if audioDeleted {
                throw HolosError.unavailable("The recording's audio was deleted, so its echo can't be analysed.")
            }
            stored = try EchoAnalysisStage.analyzeSession(session: session, manifest: manifest, freeSpace: freeSpace,
                                                          progress: progress)
            outcome.analysed = true
        }
        outcome.verdict = stored.record.verdict
        outcome.delay = stored.record.delay
        outcome.analysisSeconds = stored.record.seconds
        let found = EchoAnalysisStage.message(stored.record)

        // A meeting recorded or imported without a transcript has nothing more to show or write; the analysis is
        // saved all the same.
        let noLabels = found + " The meeting has no speaker labels yet; once its speakers are labelled, they are "
            + "shown without the echo."
        guard try SessionArchive.currentTranscriptID(at: session) != nil else {
            outcome.summary = noLabels
            return (outcome, audioDeleted)
        }
        // What the labels now show: the same run and edits, with and without the echo hidden. Without labels (none
        // made yet, as after post-processing without speaker models) the summary says so.
        let snapshot = try SpeakerSessionSnapshot.load(session: session)
        if let run = snapshot.run, let view = snapshot.projection {
            let plain = SpeakerProjection.make(run: run, transcript: snapshot.transcript,
                                               edits: snapshot.journal.edits, recognition: nil, profileNames: [:])
            outcome.microphoneTurnsBefore = plain.turns.filter { $0.track == EchoFilter.microphoneTrack }.count
            outcome.microphoneTurnsAfter = view.turns.filter { $0.track == EchoFilter.microphoneTrack }.count
            outcome.hiddenWords = words(plain) - words(view)
            outcome.summary = found + " The labels show \(outcome.microphoneTurnsBefore ?? 0) → "
                + "\(outcome.microphoneTurnsAfter ?? 0) microphone turns, \(outcome.hiddenWords ?? 0) microphone "
                + "words hidden as echo."
        } else {
            outcome.summary = noLabels
        }

        // The transcript files, with or without labels, record the mask they were written with (§5.11).
        progress("Writing transcript files…")
        do {
            try SessionExports.regenerate(session: session, people: profiles)
        } catch {
            outcome.summary += " The transcript files could not be rewritten (\(error.localizedDescription)); run "
                + "the command again, or use Update Transcript Files in the app."
            outcome.exitCode = 3
        }
        return (outcome, audioDeleted)
    }

    /// Microphone words in the turns `view` shows.
    private static func words(_ view: SpeakerProjection) -> Int {
        view.turns.filter { $0.track == EchoFilter.microphoneTrack }
            .flatMap(\.spans).reduce(0) { $0 + max(0, $1.end - $1.first) }
    }
}
