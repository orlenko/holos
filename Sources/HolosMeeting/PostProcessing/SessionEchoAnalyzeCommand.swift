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

    /// Test hook: while set (a task-local value), called after the labels are rebuilt and before the speaker lock is
    /// taken to publish them.
    @TaskLocal static var beforePublish: (@Sendable () throws -> Void)?

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

        progress("Rebuilding the speaker labels…")
        guard let relabel = try applyMask(stored.mask, session: session, profiles: profiles, found: found) else {
            outcome.summary = found + " The meeting has no speaker labels yet; labelling its speakers (voiceislocal "
                + "session diarize) will use the analysis."
            return outcome
        }
        outcome.microphoneTurnsBefore = relabel.before.turns.filter { $0.track == EchoFilter.microphoneTrack }.count
        let head = relabel.after ?? relabel.before
        outcome.microphoneTurnsAfter = head.turns.filter { $0.track == EchoFilter.microphoneTrack }.count
        outcome.acousticEchoWords = acousticWords(head)
        outcome.keptEdits = relabel.carried.edits.count
        outcome.droppedEdits = relabel.carried.droppedEditIDs.count

        // Also when the labels did not change: an earlier run may have published them and then failed to write the
        // files (the rewrite only writes files that differ).
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
        guard let rebuilt = relabel.after else {
            outcome.summary = found + (stored.mask == nil ? " The speaker labels were left as they are."
                : " The speaker labels already leave that echo out. Nothing else changed.") + exportsNote
            return outcome
        }
        log.notice("Session \(manifest.id, privacy: .public): speaker labels rebuilt without acoustic echo (run \(rebuilt.id, privacy: .public))")
        outcome.runID = rebuilt.id
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

    /// What `applyMask` found and did.
    struct Relabel {
        /// The head run before.
        var before: DiarizationRun
        /// The head run published, nil when the mask changed nothing.
        var after: DiarizationRun?
        var carried: SpeakerEditReplay.Result
    }

    /// Takes the echo `mask` finds (nil: no echo) out of the head run's own turns (`SpeakerRunBuilder.rebuild`) and,
    /// when that changes them, publishes the result with the head's edits carried (`SpeakerEditReplay`) and its voice
    /// suggestions copied. Nil when the meeting has no usable labels. The caller holds the processing lease; also
    /// used by post-processing for a call whose labels were edited (§5.11). Throws, with nothing written, when the
    /// speaker edits cannot all be read or the labels change meanwhile; `found` starts those messages.
    static func applyMask(_ mask: AcousticEchoMask?, session: URL, profiles: SpeakerProfileStore?,
                          found: String) throws -> Relabel? {
        // The journal's length is taken before the snapshot reads it, so a line appended in between (even one this
        // build cannot read) is caught at the publish.
        let journalBytes = try journalLength(session)
        let snapshot = try SpeakerSessionSnapshot.load(session: session)
        guard let run = snapshot.run, let projection = snapshot.projection else { return nil }
        guard snapshot.journal.isComplete else {
            throw HolosError.incomplete(found + " The speaker edits cannot all be read, so the speaker labels were "
                                        + "not rebuilt; the analysis is saved.")
        }
        let rebuilt = SpeakerRunBuilder.rebuild(run, transcript: snapshot.transcript, acousticEcho: mask)
        guard rebuilt.turns != run.turns || rebuilt.droppedWords != run.droppedWords
            || rebuilt.speakers != run.speakers else {
            return Relabel(before: run, after: nil, carried: SpeakerEditReplay.Result())
        }
        let carried = SpeakerEditReplay.carry(edits: snapshot.journal.edits, effective: projection.appliedEditIDs,
                                              from: run, to: rebuilt, transcript: snapshot.transcript)
        try beforePublish?()
        try SessionArchive.withSpeakerLock(at: session) {
            // An editor or a relabel may have written since the snapshot: replace nothing then. The journal must be
            // the very one the edits were carried from: complete (no torn, corrupt or newer line), the same lines,
            // and the same length on disk.
            let journal = try SessionSpeakerStore.readEdits(session: session)
            guard try SessionSpeakerStore.readHead(session: session)?.runID == run.id, journal.isComplete,
                  journal == snapshot.journal, try journalLength(session) == journalBytes else {
                throw HolosError.unavailable(found + " The speaker labels changed meanwhile, so they were not "
                                             + "rebuilt; run the command again.")
            }
            try SessionSpeakerStore.writeRun(rebuilt, session: session)
            if !carried.edits.isEmpty { try SessionSpeakerStore.appendEdits(carried.edits, session: session) }
            if let profiles { carryRecognition(from: run, to: rebuilt, session: session, store: profiles) }
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: rebuilt.id), session: session)
        }
        return Relabel(before: run, after: rebuilt, carried: carried)
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

    /// Copies the old run's recognition result (voice suggestions) to the rebuilt run, whose speakers keep their IDs.
    /// The caller holds the speaker lock; `profiles.lock` is taken inside it (the §1.7 order, as `RecognizeStage`
    /// does), so a forget either landed before and is reflected (the old file read here was already scrubbed, and
    /// every person the store no longer holds is removed), or lands after and cleans the new file too. Nothing is
    /// copied while recognition may not be used (`VoiceProfileService.recognitionAllowed`: Remember voices off, or a
    /// forget still on its way), or when the people or the old result cannot be read; the next relabel compares
    /// voices again.
    private static func carryRecognition(from run: DiarizationRun, to rebuilt: DiarizationRun, session: URL,
                                         store: SpeakerProfileStore) {
        do {
            try store.withLockedDatabase { database in
                guard VoiceProfileService.recognitionAllowed(in: database, store: store),
                      var result = try SessionSpeakerStore.readRecognition(runID: run.id, session: session) else {
                    return
                }
                let known = Set(database.profiles.map(\.id))
                _ = result.removeProfiles { !known.contains($0) }
                result.runID = rebuilt.id
                result.createdAt = rebuilt.createdAt
                try SessionSpeakerStore.writeRecognition(result, session: session)
            }
        } catch {
            log.error("Run \(rebuilt.id, privacy: .public): voice suggestions not carried over: \(ProcessSpawner.logCategory(error), privacy: .public)")
        }
    }

    /// The edit journal's size in bytes; 0 when there is none.
    private static func journalLength(_ session: URL) throws -> Int64 {
        var info = stat()
        guard lstat(SessionPaths.edits(session).path, &info) == 0 else {
            let code = errno
            guard code == ENOENT else {
                throw HolosError.io("Cannot inspect the speaker edits: \(String(cString: strerror(code))).")
            }
            return 0
        }
        return Int64(info.st_size)
    }

    private static func acousticWords(_ run: DiarizationRun) -> Int {
        run.droppedWords.filter { $0.reason == EchoFilter.acousticReason }
            .flatMap(\.spans).reduce(0) { $0 + max(0, $1.end - $1.first) }
    }
}
