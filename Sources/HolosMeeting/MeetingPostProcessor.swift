import Darwin
import Foundation
import HolosAudio
import HolosCore
import HolosSpeakers
import HolosStorage
import os
import Synchronization

/// Runs post-processing for a finished session under `lease`. Never throws: failures come back as a
/// `.failed` record with a message.
public typealias PostProcessHook = @Sendable (_ session: URL, _ lease: ProcessingLease,
    _ progress: @escaping @Sendable (PostProcessingProgress) -> Void) async -> PostProcessingRecord

public struct PostProcessingOptions: Sendable, Equatable {
    public var speakers: SpeakerCountHint?
    /// Relabel even when the head run has edits. Names and links carry over (§4.9).
    public var force: Bool
    public var keepDerived: Bool
    /// Overrides meeting.json `othersInRoom` for this run.
    public var othersInRoom: Bool?
    /// Hidden engine settings for evaluation, e.g. ["exclusiveSegments": "true"]; recorded in the run.
    public var engineOverrides: [String: String]
    /// Write speakers/voice/<runID>.json even when "Remember voices" is off (hidden; evaluation sessions only).
    public var forceVoiceData: Bool
    /// The stop reason when called right after a recording; `diskLow` skips rendering.
    public var stopReason: StopReason?
    /// The meeting's languages for this run, the preferred one first (`voiceislocal session languages`): the
    /// transcript is merged from one transcription in each (docs/meeting-design.md §4.14). Nil: meeting.json's, unless
    /// the current transcript was already merged for languages asked for this way. `force` also lets it replace a
    /// transcript whose speaker labels were edited.
    public var languages: [String]?

    public init(speakers: SpeakerCountHint? = nil, force: Bool = false, keepDerived: Bool = false,
                othersInRoom: Bool? = nil, engineOverrides: [String: String] = [:], forceVoiceData: Bool = false,
                stopReason: StopReason? = nil, languages: [String]? = nil) {
        self.speakers = speakers; self.force = force; self.keepDerived = keepDerived
        self.othersInRoom = othersInRoom; self.engineOverrides = engineOverrides
        self.forceVoiceData = forceVoiceData; self.stopReason = stopReason; self.languages = languages
    }
}

/// Speaker labelling and exports for a finished session (docs/meeting-design.md §4.7).
///
/// Stages, in order: 0 checks and `postprocess.json` `running`; 1 `transcript` (the current revision); 1b
/// `languages` for a meeting in several languages: the audio transcribed again in each language and the transcript
/// merged passage by passage, which becomes current (§4.14; nothing is recorded for one language);
/// 2 track policies; 3 the head decision (an edited head of this transcript is kept unless `force`); 4 `render` each
/// diarized track to `derived/<track>-16k.caf`; 5 `diarize` them one at a time and map the times back to the
/// session; 6 `align`: build and publish the run (no voice embeddings; `speakers/voice/` only with
/// `forceVoiceData`) with names carried over; 7 `recognize` (PR10); 8 `export`; 9 delete `derived/` and write the
/// final record.
public struct MeetingPostProcessor: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")

    let diarizer: (any SpeakerDiarizer)?
    let options: PostProcessingOptions
    let freeSpace: any FreeSpaceProvider
    let profiles: SpeakerProfileStore?
    let languageDetection: LanguageDetectionDependencies

    /// `diarizer == nil` (speaker models not installed) gives speaker-less exports and the setup hint.
    /// `freeSpace` measures the volume before rendering. With `profiles` (PR10) whose "Remember voices" is on and
    /// some person has voice samples, stage 7 compares the new run's speakers with them (distances only), and the
    /// exports show people's current names; without it nothing is recognized. `languages` transcribes and tells
    /// languages apart for a meeting in several (stage 1b); it is used only for such a meeting.
    public init(diarizer: (any SpeakerDiarizer)? = nil, options: PostProcessingOptions = .init(),
                freeSpace: any FreeSpaceProvider = VolumeFreeSpace(), profiles: SpeakerProfileStore? = nil,
                languages: LanguageDetectionDependencies = .live) {
        self.diarizer = diarizer; self.options = options; self.freeSpace = freeSpace; self.profiles = profiles
        self.languageDetection = languages
    }

    /// Runs every stage for one finished session under `lease` (nil: acquire one, retry 1 s) and returns the
    /// final postprocess.json record. Throws only when it cannot start (still recording, lease held elsewhere,
    /// unreadable manifest, a postprocess.json written by a newer Holos or that cannot be read now); stage failures
    /// are recorded in the returned record.
    ///
    /// A given lease must be this session's and not released; it stays held afterwards (the caller releases it).
    /// The lock is held for the whole run even if the caller releases the lease meanwhile. A cancelled run deletes
    /// `derived/` (unless `keepDerived`), records `failed` ("Post-processing was cancelled."), and throws
    /// `CancellationError`; nothing it had not finished publishing appears. A cancellation that arrives after the new
    /// head is published is honoured once the exports are written from it; the record then names that run.
    public func run(session: URL, lease: ProcessingLease?,
                    progress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> PostProcessingRecord {
        let startedAt = Date()
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording. Stop it before labelling speakers.")
        }
        let owned = lease == nil ? try SessionArchive.acquireProcessingLease(at: session) : nil
        defer { owned?.release() }
        guard let held = lease ?? owned else {
            throw HolosError.unavailable("Another Voice is Local process is processing this session.")
        }
        return try await held.withUse(for: session) {
            try await start(session: session, lease: held, startedAt: startedAt, progress: progress)
        }
    }

    // MARK: - Stages 0 and 9

    private func start(session: URL, lease: ProcessingLease, startedAt: Date,
                       progress: @escaping @Sendable (PostProcessingProgress) -> Void) async throws -> PostProcessingRecord {
        let manifest = try SessionArchive.readManifest(at: session)
        // The record is replaced from the first write on: one written by a newer Holos is refused (schema rule 3,
        // §1.6), never overwritten. A damaged one is replaced.
        do {
            _ = try SessionFiles.postProcessingRecord(session: session, manifest: manifest)
        } catch let error where SessionFiles.isDamage(error) {
            Self.log.error("Session \(manifest.id, privacy: .public): replacing an unusable postprocess.json: \(error.localizedDescription, privacy: .private)")
        }
        // Read before anything is written, so an audio-deleted.json from a newer Holos is refused (`unavailable`)
        // rather than read as audio that is still there; stage 4 reads it again.
        _ = try SessionFiles.audioDeleted(session: session, sessionID: manifest.id)
        // A recorder that died leaves a status that is not exited; say so before labelling (§4.7 stage 0).
        do { try RecorderChannel.markDeadRecorderExited(session: session) } catch {
            Self.log.error("Session \(manifest.id, privacy: .public): cannot check the recorder status: \(error.localizedDescription, privacy: .public)")
        }
        try clearDerived(session)
        let journal = ProcessingJournal(
            session: session,
            record: PostProcessingRecord(sessionID: manifest.id, state: .running, pid: getpid(), startedAt: startedAt,
                                         updatedAt: Date()),
            forward: progress)
        try journal.begin()
        Self.log.notice("Session \(manifest.id, privacy: .public): post-processing started")
        var final: PostProcessingRecord
        do {
            final = try await stages(session: session, manifest: manifest, journal: journal, lease: lease)
        } catch is CancellationError {
            finishDerived(session, manifestID: manifest.id)
            var record = journal.current
            record.state = .failed
            record.progress = nil
            record.message = "Post-processing was cancelled."
            record.updatedAt = Date()
            journal.finish(record)
            Self.log.notice("Session \(manifest.id, privacy: .public): post-processing cancelled")
            throw CancellationError()
        }
        finishDerived(session, manifestID: manifest.id)
        final.progress = nil
        final.updatedAt = Date()
        journal.finish(final)
        Self.log.notice("Session \(manifest.id, privacy: .public): post-processing \(final.state.rawValue, privacy: .public)")
        return final
    }

    /// Stage 0: a leftover `derived/` from an earlier run is deleted (never following a link in its place).
    private func clearDerived(_ session: URL) throws {
        try AtomicFile.removeTree(["derived"], in: session)
    }

    /// Stage 9: `derived/` is deleted whatever happened, unless `keepDerived`.
    private func finishDerived(_ session: URL, manifestID: String) {
        guard !options.keepDerived else { return }
        do {
            try AtomicFile.removeTree(["derived"], in: session)
        } catch {
            Self.log.error("Session \(manifestID, privacy: .public): cannot delete derived/: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Stages 1–8

    private func stages(session: URL, manifest: SessionManifest, journal: ProcessingJournal,
                        lease: ProcessingLease) async throws -> PostProcessingRecord {
        let recorder = StageRecorder(journal: journal)

        // Stage 1: the current transcript.
        var started = recorder.begin(.transcript, message: "Reading the transcript…")
        let current: Transcript?
        do {
            current = try SessionFiles.currentTranscript(session: session)
        } catch let error where !(error is CancellationError) {
            recorder.end(.transcript, .failed, error.localizedDescription, since: started)
            return recorder.finalRecord(state: .failed, message: "Cannot read the transcript: \(error.localizedDescription)")
        }
        if let current {
            recorder.end(.transcript, .succeeded, since: started)
            journal.update { $0.transcriptID = current.id }
        } else if options.languages == nil {
            recorder.end(.transcript, .skipped, "This meeting has no transcript.", since: started)
            return recorder.finalRecord(state: .skipped,
                                        message: "This meeting has no transcript, so there is nothing to label.")
        } else {
            // Languages asked for by name (`voiceislocal session languages`) transcribe the saved audio of a meeting
            // recorded or imported without a transcript, and make the first one (§4.14).
            recorder.end(.transcript, .skipped, "This meeting has no transcript yet; it is made from the saved audio.",
                         since: started)
        }

        // Stage 1b: a meeting in several languages (§4.14), before the speakers, so they are labelled on the final text.
        let languages = try await LanguageStage.run(
            LanguageStage.Request(session: session, manifest: manifest, transcript: current, lease: lease,
                                  requested: options.languages, force: options.force),
            dependencies: languageDetection, recorder: recorder)
        guard let transcript = languages.transcript else {
            let message = languages.problem ?? "This meeting has no transcript, so there is nothing to label."
            return recorder.finalRecord(state: .failed, message: message)
        }
        if transcript.id != current?.id { journal.update { $0.transcriptID = transcript.id } }

        // Stages 2–7. Languages asked for by name (`voiceislocal session languages`) that left the transcript as it
        // was also leave its speaker labels as they are, edited or not (§4.14).
        let speakers: SpeakerResult
        if options.languages != nil, transcript.id == current?.id,
           let kept = keptLabels(session: session, manifest: manifest, transcript: transcript, recorder: recorder) {
            speakers = kept
        } else {
            speakers = try await labelSpeakers(session: session, manifest: manifest, transcript: transcript,
                                               recorder: recorder)
        }
        // Once a new head is published, the exports are written from it before a cancellation is honoured, so the
        // head and the exports never disagree.
        if !speakers.published { try Task.checkCancellation() }

        // Stage 8: exports (the speaker lock taken in stage 6 was released there).
        started = recorder.begin(.export, message: "Writing transcript files…")
        do {
            let names = profiles.map { VoiceProfileService.profileNames(store: $0) } ?? [:]
            let result = try SessionExports.regenerate(session: session, profileNames: names,
                                                       applyRecognition: profiles.map {
                                                           VoiceProfileService.recognitionAllowed(store: $0)
                                                       } ?? true)
            let moved = result.movedAside.count
            recorder.end(.export, .succeeded,
                         moved == 0 ? nil : "Moved \(moved) edited transcript \(moved == 1 ? "file" : "files") aside.",
                         since: started)
        } catch let error where !(error is CancellationError) {
            recorder.end(.export, .failed, error.localizedDescription, since: started)
            return recorder.finalRecord(state: .failed, message: "Cannot write the transcript files: \(error.localizedDescription)",
                                        runID: speakers.runID, othersInRoom: speakers.othersInRoom)
        }
        try Task.checkCancellation()
        // A language that could not be detected, like a speaker stage that failed, makes the result partial; the
        // speakers' own message follows a language problem when they were labelled.
        let problems = [languages.problem, speakers.problem].compactMap { $0 }
        if !problems.isEmpty {
            let message = (problems + (speakers.problem == nil ? [speakers.message].compactMap { $0 } : []))
                .joined(separator: " ")
            return recorder.finalRecord(state: .partial, message: message, runID: speakers.runID,
                                        othersInRoom: speakers.othersInRoom)
        }
        let notes = [languages.note, speakers.message].compactMap { $0 }
        return recorder.finalRecord(state: .succeeded, message: notes.isEmpty ? nil : notes.joined(separator: " "),
                                    runID: speakers.runID, othersInRoom: speakers.othersInRoom)
    }

    /// What the speaker stages left for the final record.
    private struct SpeakerResult {
        /// The head run the exports use, when it was built from this transcript.
        var runID: String?
        var othersInRoom: Bool?
        /// A speaker stage failed or was skipped for a reason that makes the state `partial`.
        var problem: String?
        /// The message of a `succeeded` record.
        var message: String?
        /// Stage 6 published a new head (`runID`).
        var published = false
    }

    /// Stages 2–7. Every failure is recorded as a stage outcome; only cancellation throws.
    /// The people store's forget counter, or nil with no store (and nil when it cannot be read, which compares
    /// equal to itself, so a store that is unreadable throughout a pass does not stop it writing).
    private func forgetEpochNow() -> Int? {
        guard let profiles else { return nil }
        return (try? profiles.load().forgetEpoch) ?? nil
    }

    /// Whether a forget is still on its way through the meetings. A pass that started after such a forget's store
    /// write sees no change in the counter, yet its clean-up may pass this meeting before the pass publishes, so
    /// the voice file waits for it either way.
    private func aForgetIsStillCleaning() -> Bool {
        guard let profiles else { return false }
        guard let pending = try? profiles.pendingForgets() else { return true }
        if pending.contains(where: { $0.kind != .merge }) { return true }
        // A forget of a newer Holos is not in that list: this build cannot decode its line, and that build can
        // scrub this meeting and finish while this pass runs.
        return (try? profiles.forgetJournalHasUnreadableLines()) ?? true
    }

    /// The speaker labels of `transcript` kept as they are (stages 4–6 recorded as skipped), when they were built from
    /// it and can still be shown; nil otherwise, so speakers are labelled as usual.
    private func keptLabels(session: URL, manifest: SessionManifest, transcript: Transcript,
                            recorder: StageRecorder) -> SpeakerResult? {
        guard let head = try? SpeakerAnalysis.headState(session: session, transcript: transcript),
              let runID = head.usableRunID else { return nil }
        let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest)
        let othersInRoom = options.othersInRoom ?? meeting?.othersInRoom
        if let othersInRoom { recorder.journal.update { $0.othersInRoom = othersInRoom } }
        recorder.skip([.render, .diarize, .align], SpeakerAnalysis.transcriptUnchanged)
        return SpeakerResult(runID: runID, othersInRoom: othersInRoom, message: SpeakerAnalysis.transcriptUnchanged)
    }

    private func labelSpeakers(session: URL, manifest: SessionManifest, transcript: Transcript,
                               recorder: StageRecorder) async throws -> SpeakerResult {
        // Stage 2: track policies.
        let meeting: MeetingInfo
        do {
            meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        } catch let error where !(error is CancellationError) {
            let message = "Cannot read meeting.json: \(error.localizedDescription)"
            recorder.skip([.render, .diarize, .align], message)
            return SpeakerResult(problem: message)
        }
        // Rendering and diarizing take a while, and this pass may write a voice file (evaluation sessions only).
        // A forget that lands meanwhile has already cleaned this meeting, so what this pass computed must not be
        // written afterwards: the epoch it started with is compared again under the speaker lock at the publish.
        let forgetEpoch = forgetEpochNow()
        // And whether one was already on its way through the meetings: such a forget can reach this meeting and
        // finish while this pass is still rendering, leaving nothing pending and the counter unchanged at the
        // publish, so neither test would catch it on its own.
        let forgetWasCleaning = aForgetIsStillCleaning()
        let othersInRoom = options.othersInRoom ?? meeting.othersInRoom
        recorder.journal.update { $0.othersInRoom = othersInRoom }
        var result = SpeakerResult(othersInRoom: othersInRoom)
        let plans = SpeakerAnalysis.trackPlans(transcript: transcript, manifest: manifest, meeting: meeting,
                                               othersInRoom: othersInRoom)
        let diarized = plans.filter(\.isDiarized).map(\.track)

        // Stage 3: the head decision.
        let head: SpeakerAnalysis.HeadState?
        do {
            head = try SpeakerAnalysis.headState(session: session, transcript: transcript)
        } catch let error where !(error is CancellationError) {
            let message = "Cannot read the current speaker labels: \(error.localizedDescription)"
            recorder.skip([.render, .diarize, .align], message)
            result.problem = message
            return result
        }
        if let head, head.needsForce(options.force) {
            recorder.skip([.render, .diarize, .align], SpeakerAnalysis.editedHead)
            result.runID = head.usableRunID
            result.problem = SpeakerAnalysis.editedHead
            return result
        }

        // Stages 4 and 5: render and diarize the diarized tracks.
        var outputs: [String: DiarizerOutput] = [:]
        var engine: DiarizationEngineInfo?
        if diarized.isEmpty {
            recorder.skip([.render, .diarize], SpeakerAnalysis.noTrackToLabel)
        } else if let diarizer {
            let audioDeleted: Bool
            do {
                audioDeleted = try SessionFiles.audioDeleted(session: session, sessionID: manifest.id)
            } catch let error where !(error is CancellationError) {
                let message = "Cannot read audio-deleted.json: \(error.localizedDescription)"
                recorder.skip([.render, .diarize, .align], message)
                result.runID = head?.usableRunID
                result.problem = message
                return result
            }
            if audioDeleted {
                recorder.skip([.render, .diarize, .align], SpeakerAnalysis.audioDeleted)
                result.runID = head?.usableRunID
                result.problem = SpeakerAnalysis.audioDeleted
                return result
            }
            let rendered: [RenderedTrack]
            switch try render(diarized, session: session, manifest: manifest, recorder: recorder) {
            case .success(let tracks):
                rendered = tracks
            case .failure(let failure):
                recorder.skip([.diarize, .align], failure.message)
                result.runID = head?.usableRunID
                result.problem = failure.message
                return result
            }
            let hint = SpeakerAnalysis.speakerHint(options: options, meeting: meeting, diarizedTracks: diarized.count)
            switch try await diarize(rendered, diarizer: diarizer, hint: hint, recorder: recorder) {
            case .success(let diarization):
                outputs = diarization.outputs
                engine = diarization.engine
            case .failure(let failure):
                recorder.skip([.align], failure.message)
                result.runID = head?.usableRunID
                result.problem = failure.message
                return result
            }
            // Renders are no longer needed; free the space before the rest.
            finishDerived(session, manifestID: manifest.id)
        } else {
            recorder.skip([.render, .diarize, .align], SpeakerAnalysis.modelsMissing)
            result.runID = head?.usableRunID
            result.message = result.runID == nil ? SpeakerAnalysis.modelsMissingRecord
                : SpeakerAnalysis.modelsMissingKeptLabels
            return result
        }
        try Task.checkCancellation()

        // Stage 6: build the run (pure) and publish it under the speaker lock.
        let started = recorder.begin(.align, message: "Matching speakers to the transcript…")
        let built = SpeakerRunBuilder.build(
            sessionID: manifest.id, transcript: transcript,
            tracks: plans.map { SpeakerRunBuilder.TrackInput(track: $0.track, policy: $0.policy, output: outputs[$0.track]) },
            engine: engine, parameters: SpeakerAnalysis.alignmentParameters(meeting: meeting))
        // Building a long meeting's run takes a while; a cancellation meanwhile publishes nothing.
        try Task.checkCancellation()
        do {
            switch try SpeakerAnalysis.publish(built, session: session, transcript: transcript, force: options.force,
                                               writeVoiceData: options.forceVoiceData,
                                               voiceDataStillWanted: {
                                                   self.forgetEpochNow() == forgetEpoch && !forgetWasCleaning
                                                       && !self.aForgetIsStillCleaning()
                                               }) {
            case .keptEditedHead(let runID):
                recorder.end(.align, .skipped, SpeakerAnalysis.editedHead, since: started)
                result.runID = runID
                result.problem = SpeakerAnalysis.editedHead
            case .published(let publication):
                var notes: [String] = []
                if let carry = publication.carry, let text = SpeakerAnalysis.carryMessage(carry) { notes.append(text) }
                if publication.previousUnreadable { notes.append(SpeakerAnalysis.previousUnreadable) }
                recorder.end(.align, .succeeded, notes.isEmpty ? nil : notes.joined(separator: " "), since: started)
                result.runID = publication.run.id
                result.published = true
                // A cancelled run's record (built from the journal) still names the head it published.
                recorder.journal.update { $0.runID = publication.run.id }
                result.message = ([SpeakerAnalysis.labelledMessage(publication.run)] + notes).joined(separator: " ")
            }
        } catch let error where !(error is CancellationError) {
            recorder.end(.align, .failed, error.localizedDescription, since: started)
            result.runID = head?.usableRunID
            result.problem = "Cannot save the speaker labels: \(error.localizedDescription)"
        }

        // Stage 7: recognition on the in-memory voice data of the run just published (never persisted here).
        if result.published, let profiles {
            let started = recorder.begin(.recognize, message: "Comparing voices…")
            switch RecognizeStage.run(built.run, voiceData: built.voiceData, session: session, store: profiles) {
            case .skipped(let message):
                recorder.end(.recognize, .skipped, message, since: started)
            case .recognized(let recognition):
                recorder.end(.recognize, .succeeded, RecognizeStage.message(recognition), since: started)
            case .failed(let message):
                recorder.end(.recognize, .failed, message, since: started)
                // The labels are saved; only the suggestions are missing, which makes the record partial.
                result.problem = ([result.message].compactMap { $0 } + [message]).joined(separator: " ")
            }
        }
        return result
    }

    /// Why a speaker stage stopped the ones after it; `message` goes to the record (state `partial`).
    private struct StageFailure: Error {
        var message: String
    }

    /// Stage 4, with the stage recorded. Fails when rendering is not allowed (a `diskLow` stop, or too little free
    /// space) or a track cannot be rendered.
    private func render(_ tracks: [String], session: URL, manifest: SessionManifest,
                        recorder: StageRecorder) throws -> Result<[RenderedTrack], StageFailure> {
        let first = tracks.first ?? "mic"
        let started = recorder.begin(.render, track: first,
                                     message: "Preparing \(SpeakerAnalysis.trackLabel(first)) audio…")
        let seconds = tracks.reduce(0) { $0 + TrackRenderer.renderedSeconds(manifest: manifest, track: $1) }
        var allowed = options.stopReason != .diskLow
        if allowed {
            do {
                let free = try freeSpace.availableBytes(at: SessionPaths.derived(session))
                allowed = SpeakerAnalysis.renderAllowed(freeBytes: free, renderSeconds: seconds)
            } catch {
                // Unmeasurable: try; a render that runs out of space fails and publishes nothing.
                Self.log.error("Cannot measure free space before rendering: \(error.localizedDescription, privacy: .private)")
            }
        }
        guard allowed else {
            recorder.end(.render, .skipped, SpeakerAnalysis.noDiskSpace, since: started)
            return .failure(StageFailure(message: SpeakerAnalysis.noDiskSpace))
        }
        var rendered: [RenderedTrack] = []
        do {
            for track in tracks {
                let message = "Preparing \(SpeakerAnalysis.trackLabel(track)) audio…"
                recorder.progress(.render, track: track, fraction: 0, message: message)
                let journal = recorder.journal
                rendered.append(try TrackRenderer.render(
                    session: session, manifest: manifest, track: track,
                    to: SessionPaths.render(track: track, in: session),
                    progress: { fraction in
                        journal.progress(PostProcessingProgress(stage: .render, track: track, fraction: fraction,
                                                                message: message))
                    }))
            }
        } catch let error where !(error is CancellationError) {
            recorder.end(.render, .failed, error.localizedDescription, since: started)
            return .failure(StageFailure(
                message: "Cannot prepare the audio for speaker labelling: \(error.localizedDescription)"))
        }
        recorder.end(.render, .succeeded, since: started)
        return .success(rendered)
    }

    /// Stage 5, with the stage recorded: one track at a time, times mapped back to the session timeline.
    private func diarize(_ rendered: [RenderedTrack], diarizer: any SpeakerDiarizer, hint: SpeakerCountHint?,
                         recorder: StageRecorder) async throws
        -> Result<(outputs: [String: DiarizerOutput], engine: DiarizationEngineInfo), StageFailure> {
        let first = rendered.first?.track ?? "mic"
        let started = recorder.begin(.diarize, track: first,
                                     message: "Labelling speakers (\(SpeakerAnalysis.trackLabel(first)))…")
        do {
            var engine = try await diarizer.engineInfo()
            // Hidden overrides are recorded in the run; the engine's own report of a setting wins.
            engine.configuration.merge(options.engineOverrides) { reported, _ in reported }
            var outputs: [String: DiarizerOutput] = [:]
            for track in rendered {
                try Task.checkCancellation()
                let message = "Labelling speakers (\(SpeakerAnalysis.trackLabel(track.track)))…"
                recorder.progress(.diarize, track: track.track, fraction: 0, message: message)
                let journal = recorder.journal
                let name = track.track
                let output = try await diarizer.diarize(
                    DiarizationRequest(audio: track.url, track: track.track, speakers: hint),
                    progress: { fraction in
                        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : nil
                        journal.progress(PostProcessingProgress(stage: .diarize, track: name, fraction: clamped,
                                                                message: message))
                    })
                outputs[track.track] = RenderTimeMap.map(output, map: track.timeMap)
            }
            recorder.end(.diarize, .succeeded, since: started)
            return .success((outputs, engine))
        } catch let error where !(error is CancellationError) {
            recorder.end(.diarize, .failed, error.localizedDescription, since: started)
            return .failure(StageFailure(message: "Speaker labelling failed: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Stage bookkeeping

/// The stage outcomes of one run, kept in the journal as they happen. Used by one task.
final class StageRecorder {
    let journal: ProcessingJournal
    private var outcomes: [StageOutcome] = []
    private let clock = ContinuousClock()

    init(journal: ProcessingJournal) { self.journal = journal }

    /// Reports the stage as started and returns its start time.
    func begin(_ stage: PostProcessingStage, track: String? = nil, message: String) -> ContinuousClock.Instant {
        journal.progress(PostProcessingProgress(stage: stage, track: track, fraction: 0, message: message))
        return clock.now
    }

    func progress(_ stage: PostProcessingStage, track: String?, fraction: Double?, message: String) {
        journal.progress(PostProcessingProgress(stage: stage, track: track, fraction: fraction, message: message))
    }

    func end(_ stage: PostProcessingStage, _ result: StageResult, _ message: String? = nil,
             since started: ContinuousClock.Instant) {
        let duration = started.duration(to: clock.now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        append(StageOutcome(stage: stage, result: result, message: message, seconds: seconds))
    }

    /// Records each stage as skipped (it did not run) with `message`.
    func skip(_ stages: [PostProcessingStage], _ message: String) {
        for stage in stages { append(StageOutcome(stage: stage, result: .skipped, message: message)) }
    }

    func finalRecord(state: PostProcessingState, message: String?, runID: String? = nil,
                     othersInRoom: Bool? = nil) -> PostProcessingRecord {
        var record = journal.current
        record.state = state
        record.stages = outcomes
        record.message = message
        record.runID = runID
        if let othersInRoom { record.othersInRoom = othersInRoom }
        return record
    }

    private func append(_ outcome: StageOutcome) {
        outcomes.append(outcome)
        let snapshot = outcomes
        journal.update { $0.stages = snapshot }
    }
}

/// Keeps `postprocess.json` current: written at once on every stage change and outcome, and for progress within a
/// stage at most once per 250 ms. Every progress report is also passed to the caller's callback. A failed write is
/// logged; the run goes on (the returned record is authoritative).
final class ProcessingJournal: Sendable {
    private struct State {
        var record: PostProcessingRecord
        var lastWrite: ContinuousClock.Instant?
        var loggedFailure = false
    }

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    static let progressInterval: Duration = .milliseconds(250)

    private let url: URL
    private let forward: @Sendable (PostProcessingProgress) -> Void
    private let state: Mutex<State>

    init(session: URL, record: PostProcessingRecord,
         forward: @escaping @Sendable (PostProcessingProgress) -> Void) {
        url = SessionPaths.postprocess(session)
        self.forward = forward
        state = Mutex(State(record: record))
    }

    var current: PostProcessingRecord { state.withLock { $0.record } }

    /// The first write (`running`); a failure means post-processing cannot start.
    func begin() throws {
        let record = state.withLock { $0.record }
        try AtomicFile.writeJSON(record, to: url)
        state.withLock { $0.lastWrite = .now }
    }

    func progress(_ progress: PostProcessingProgress) {
        forward(progress)
        state.withLock { state in
            let previous = state.record.progress
            state.record.progress = progress
            state.record.updatedAt = Date()
            let stageChanged = previous?.stage != progress.stage || previous?.track != progress.track
                || previous?.message != progress.message
            let now = ContinuousClock.now
            let due = state.lastWrite.map { $0.duration(to: now) >= Self.progressInterval } ?? true
            if stageChanged || due { write(&state, now: now) }
        }
    }

    func update(_ change: (inout PostProcessingRecord) -> Void) {
        state.withLock { state in
            change(&state.record)
            state.record.updatedAt = Date()
            write(&state, now: .now)
        }
    }

    /// Writes the final record.
    func finish(_ record: PostProcessingRecord) {
        state.withLock { state in
            state.record = record
            write(&state, now: .now)
        }
    }

    private func write(_ state: inout State, now: ContinuousClock.Instant) {
        do {
            try AtomicFile.writeJSON(state.record, to: url)
            state.lastWrite = now
        } catch {
            if !state.loggedFailure {
                state.loggedFailure = true
                Self.log.error("Cannot update postprocess.json: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
