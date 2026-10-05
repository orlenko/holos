import Foundation
import HolosAudio
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// What `voiceislocal session echo-analyze` does (docs/meeting-design.md §5.11), as a library call: a call recorded
/// before the acoustic echo analysis existed gets its mask, and its speaker labels are rebuilt on the diarization
/// they already have (`SpeakerRunBuilder.rebuild`, no new diarizer pass), dropping the echo the way post-processing
/// now does. Speaker IDs stay, so names, links and rejections carry as they are, and turn-level edits carry by their
/// words (`SpeakerEditReplay`). The transcript, its word fixes and the meeting's name are not touched.
public enum SessionEchoAnalyzeCommand {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")

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
        /// The new head run, when the speaker labels were rebuilt.
        public var runID: String?
        /// Microphone words the new labels leave out as acoustic echo (`EchoFilter.acousticReason`).
        public var acousticEchoWords: Int
        public var microphoneTurnsBefore: Int?
        public var microphoneTurnsAfter: Int?
        /// Speaker edits carried to the new labels, and those that no longer apply.
        public var keptEdits: Int
        public var droppedEdits: Int
        /// One paragraph for the terminal; names no people and quotes no transcript text.
        public var summary: String
    }

    /// Runs under the session's processing lease. Throws, with nothing changed, when the meeting is still recording,
    /// another process holds the lease, the audio was deleted, or a saved file was written by a newer Voice is Local;
    /// and, with the analysis saved but the labels kept, when the speaker edits cannot all be read or the labels
    /// change while it runs. `profiles` gives people's names to the rewritten exports.
    public static func run(_ request: Request, profiles: SpeakerProfileStore? = nil,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        let session = request.session
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording. Stop it before analysing its echo.")
        }
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        return try await lease.withUse(for: session) {
            try analyze(request, profiles: profiles, freeSpace: freeSpace, progress: progress)
        }
    }

    private static func analyze(_ request: Request, profiles: SpeakerProfileStore?, freeSpace: any FreeSpaceProvider,
                                progress: @escaping @Sendable (String) -> Void) throws -> Outcome {
        let session = request.session
        let manifest = try SessionArchive.readManifest(at: session)
        let meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        var outcome = Outcome(sessionID: manifest.id, analysed: false, acousticEchoWords: 0, keptEdits: 0,
                              droppedEdits: 0, summary: "")
        guard EchoAnalysisStage.applies(meeting: meeting, manifest: manifest) else {
            outcome.summary = "This meeting was not recorded as a call with microphone audio, so there is no echo of "
                + "the call to find. Nothing changed."
            return outcome
        }
        if try SessionFiles.audioDeleted(session: session, sessionID: manifest.id) {
            throw HolosError.unavailable("The recording's audio was deleted, so its echo can't be analysed.")
        }

        var stored: EchoMaskStore.Stored?
        switch EchoAnalysisStage.saved(session: session, manifest: manifest) {
        case .current(let current) where !request.force:
            stored = current
        case .newer:
            throw HolosError.unavailable("echo/mask.json was written by a newer version of Voice is Local; update "
                                         + "Voice is Local to analyse this meeting's echo again.")
        default:
            break
        }
        if stored == nil {
            stored = try analyzeAudio(session: session, manifest: manifest, freeSpace: freeSpace, progress: progress)
            outcome.analysed = true
        }
        guard let stored else { return outcome }
        outcome.verdict = stored.record.verdict
        outcome.delay = stored.record.delay
        outcome.analysisSeconds = stored.record.seconds
        let found = EchoAnalysisStage.message(stored.record)

        // The labels, rebuilt on their own diarization with the mask.
        let snapshot = try SpeakerSessionSnapshot.load(session: session)
        guard let run = snapshot.run, let projection = snapshot.projection else {
            outcome.summary = found + " The meeting has no speaker labels yet; labelling its speakers (voiceislocal "
                + "session diarize) will use the analysis."
            return outcome
        }
        guard snapshot.journal.isComplete else {
            throw HolosError.incomplete(found + " The speaker edits cannot all be read, so the speaker labels were "
                                        + "not rebuilt; the analysis is saved.")
        }
        progress("Rebuilding the speaker labels…")
        let rebuilt = SpeakerRunBuilder.rebuild(run, transcript: snapshot.transcript, acousticEcho: stored.mask)
        outcome.microphoneTurnsBefore = run.turns.filter { $0.track == EchoFilter.microphoneTrack }.count
        guard rebuilt.turns != run.turns || rebuilt.droppedWords != run.droppedWords
            || rebuilt.speakers != run.speakers else {
            outcome.microphoneTurnsAfter = outcome.microphoneTurnsBefore
            outcome.acousticEchoWords = acousticWords(run)
            outcome.summary = found + " The speaker labels already leave that echo out. Nothing else changed."
            return outcome
        }
        let carried = SpeakerEditReplay.carry(edits: snapshot.journal.edits, effective: projection.appliedEditIDs,
                                              from: run, to: rebuilt, transcript: snapshot.transcript)
        var recognition = try? SessionSpeakerStore.readRecognition(runID: run.id, session: session)
        recognition?.runID = rebuilt.id
        recognition?.createdAt = rebuilt.createdAt
        try SessionArchive.withSpeakerLock(at: session) {
            // An editor or a relabel may have written since the snapshot: replace nothing then.
            guard try SessionSpeakerStore.readHead(session: session)?.runID == run.id,
                  try SessionSpeakerStore.readEdits(session: session).edits.count == snapshot.journal.edits.count else {
                throw HolosError.unavailable(found + " The speaker labels changed meanwhile, so they were not "
                                             + "rebuilt; run the command again.")
            }
            try SessionSpeakerStore.writeRun(rebuilt, session: session)
            if !carried.edits.isEmpty { try SessionSpeakerStore.appendEdits(carried.edits, session: session) }
            if let recognition { try SessionSpeakerStore.writeRecognition(recognition, session: session) }
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: rebuilt.id), session: session)
        }
        log.notice("Session \(manifest.id, privacy: .public): speaker labels rebuilt without acoustic echo (run \(rebuilt.id, privacy: .public))")
        outcome.runID = rebuilt.id
        outcome.microphoneTurnsAfter = rebuilt.turns.filter { $0.track == EchoFilter.microphoneTrack }.count
        outcome.acousticEchoWords = acousticWords(rebuilt)
        outcome.keptEdits = carried.edits.count
        outcome.droppedEdits = carried.droppedEditIDs.count

        progress("Writing transcript files…")
        var exportsNote = ""
        do {
            let names = profiles.map { VoiceProfileService.profileNames(store: $0) } ?? [:]
            _ = try SessionExports.regenerate(session: session, profileNames: names,
                                              applyRecognition: profiles.map {
                                                  VoiceProfileService.recognitionAllowed(store: $0)
                                              } ?? true)
        } catch {
            exportsNote = " The transcript files could not be rewritten (\(error.localizedDescription)); Update "
                + "Transcript Files in the app writes them."
        }
        let edits = outcome.keptEdits + outcome.droppedEdits
        let editsNote = edits == 0 ? ""
            : " Kept \(outcome.keptEdits) of \(edits) speaker \(edits == 1 ? "edit" : "edits")"
                + (outcome.droppedEdits > 0
                    ? "; \(outcome.droppedEdits) no longer \(outcome.droppedEdits == 1 ? "applies" : "apply") to the "
                        + "new turns." : ".")
        outcome.summary = found + " Rebuilt the speaker labels (run \(rebuilt.id.prefix(8))…): "
            + "\(outcome.microphoneTurnsBefore ?? 0) → \(outcome.microphoneTurnsAfter ?? 0) microphone turns, "
            + "\(outcome.acousticEchoWords) words left out as echo." + editsNote + exportsNote
        return outcome
    }

    /// Renders both tracks to `derived/`, analyses them, saves `echo/`, and deletes `derived/`.
    private static func analyzeAudio(session: URL, manifest: SessionManifest, freeSpace: any FreeSpaceProvider,
                                     progress: @escaping @Sendable (String) -> Void) throws -> EchoMaskStore.Stored {
        let tracks = EchoAnalysisStage.renderTracks(manifest: manifest)
        guard !tracks.isEmpty else {
            return try EchoAnalysisStage.analyze(session: session, manifest: manifest, microphone: nil, system: nil)
        }
        try AtomicFile.removeTree(["derived"], in: session)
        defer {
            do {
                try AtomicFile.removeTree(["derived"], in: session)
            } catch {
                log.error("Session \(manifest.id, privacy: .public): cannot delete derived/: \(error.localizedDescription, privacy: .private)")
            }
        }
        let seconds = tracks.reduce(0) { $0 + TrackRenderer.renderedSeconds(manifest: manifest, track: $1) }
        if let free = try? freeSpace.availableBytes(at: SessionPaths.derived(session)),
           !SpeakerAnalysis.renderAllowed(freeBytes: free, renderSeconds: seconds) {
            throw HolosError.unavailable("Not enough disk space to prepare the audio. Free some space, then try again.")
        }
        var renders: [String: RenderedTrack] = [:]
        for track in tracks {
            progress(track == "system" ? "Preparing the system audio…" : "Preparing the microphone audio…")
            renders[track] = try TrackRenderer.render(session: session, manifest: manifest, track: track,
                                                      to: SessionPaths.render(track: track, in: session))
        }
        progress("Finding microphone echo…")
        return try EchoAnalysisStage.analyze(session: session, manifest: manifest, microphone: renders["mic"],
                                             system: renders["system"])
    }

    private static func acousticWords(_ run: DiarizationRun) -> Int {
        run.droppedWords.filter { $0.reason == EchoFilter.acousticReason }
            .flatMap(\.spans).reduce(0) { $0 + max(0, $1.end - $1.first) }
    }
}
