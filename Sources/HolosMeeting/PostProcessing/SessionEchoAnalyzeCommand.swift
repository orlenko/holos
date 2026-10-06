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

        public init(session: URL, force: Bool = false) { self.session = session; self.force = force }
    }

    public struct Outcome: Sendable, Equatable, Encodable {
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

    /// Runs under the session's processing lease. Throws, with nothing changed, when the meeting is still recording,
    /// another process holds the lease, the audio was deleted, a saved analysis was written by a newer Voice is Local,
    /// or the audio cannot be prepared (the next run tries again). `profiles` gives people's names to the exports, and
    /// with `voiceSamples` the voice samples people have from this meeting are brought in step with what the labels
    /// now show (`VoiceProfileService.refreshSamples`, as after an edit): worked out from the files, so a mask an
    /// earlier pass saved without doing so is caught up too, and up-to-date samples cost nothing.
    public static func run(_ request: Request, voiceSamples: VoiceSampleSource,
                           profiles: SpeakerProfileStore? = nil,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        let session = request.session
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording. Stop it before analysing its echo.")
        }
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        var outcome = try await lease.withUse(for: session) {
            try analyze(request, profiles: profiles, freeSpace: freeSpace, progress: progress)
        }
        if outcome.verdict != nil, let profiles, let makeExtractor = voiceSamples.extractor {
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

    private static func analyze(_ request: Request, profiles: SpeakerProfileStore?, freeSpace: any FreeSpaceProvider,
                                progress: @escaping @Sendable (String) -> Void) throws -> Outcome {
        let session = request.session
        let manifest = try SessionArchive.readManifest(at: session)
        let meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        var outcome = Outcome(sessionID: manifest.id, analysed: false, summary: "")
        guard EchoAnalysisStage.applies(meeting: meeting, manifest: manifest) else {
            outcome.summary = "This meeting was not recorded as a call with microphone audio, so there is no echo of "
                + "the call to find. Nothing changed."
            return outcome
        }
        if try SessionFiles.audioDeleted(session: session, sessionID: manifest.id) {
            throw HolosError.unavailable("The recording's audio was deleted, so its echo can't be analysed.")
        }
        let stored: EchoMaskStore.Stored
        switch EchoAnalysisStage.saved(session: session, manifest: manifest) {
        case .current(let current) where !request.force:
            stored = current
        case .newer:
            throw HolosError.unavailable("echo/mask.json was written by a newer version of Voice is Local; update "
                                         + "Voice is Local to analyse this meeting's echo again.")
        default:
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
            return outcome
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
        return outcome
    }

    /// Microphone words in the turns `view` shows.
    private static func words(_ view: SpeakerProjection) -> Int {
        view.turns.filter { $0.track == EchoFilter.microphoneTrack }
            .flatMap(\.spans).reduce(0) { $0 + max(0, $1.end - $1.first) }
    }
}
