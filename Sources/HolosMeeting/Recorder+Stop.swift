import Foundation
import HolosCore
import HolosStorage
import os

extension Recorder {
    // MARK: - Stop path

    /// §4.6 steps 1–9.
    func stopPath() async throws -> RecordingOutcome {
        let stopReason = machine.stopReason ?? (writerFailed.value ? .captureFailed : .requested)
        // A meeting stopped while paused keeps the Mac awake again for transcription and labelling (§4.4).
        holdPower(true)
        await setPhase(.stopping)
        answerRequestsWhileStopping()
        // 1. Stop capture, drain the consumer, let the pump drain into the writer, close every chunk. A failed stop is a
        // capture error (a timeout only records captureFailed); a CancellationError from it is a cancellation.
        if let failure = await stopCurrentCapture() { recordingError = recordingError ?? failure }
        pump.finish()
        if let writerTask {
            do { try await writerTask.value } catch { recordingError = recordingError ?? error }
        }
        do { try await writer.finish() } catch { recordingError = recordingError ?? error }
        if Task.isCancelled { cancelled = true }
        // Audio is durable: a second signal now ends processing at once.
        dependencies.stop.restoreDefaultHandlers()
        if stopReason == .startFailed, !cancelled, recordingError == nil {
            try await failStart()
        }
        var savedAudio = false
        if recordingError == nil {
            do {
                let saved = try SessionArchive.readManifest(at: archive.directory)
                savedAudio = !saved.chunks.isEmpty
                if saved.chunks.isEmpty {
                    if !cancelled { recordingError = HolosError.incomplete("No audio buffers were captured.") }
                } else {
                    for track in tracks where !saved.chunks.contains(where: { $0.track == track }) {
                        reporter.message("No \(track) audio buffers arrived; that source track is empty.")
                    }
                }
            } catch { recordingError = error }
        }
        if let recordingError {
            for feed in live.values { await feed.cancel() }
            await recordEvent(MeetingEventKind.captureFailed, ["error": recordingError.localizedDescription])
            try? await archive.finish(status: ArchiveStatus.incomplete, keepingLock: true)
            archiveOpen = false
            await exitStatus(RecorderExit(archiveStatus: ArchiveStatus.incomplete, reason: stopReason,
                                    message: recordingError.localizedDescription))
            Self.log.error("Session \(self.archive.id, privacy: .public) stopped with a capture error; saved audio is kept")
            if cancelled { throw CancellationError() }
            throw HolosError.incomplete("Recording stopped with an error: \(recordingError.localizedDescription). Saved audio: \(archive.directory.path)")
        }
        // Without transcription, the saved audio can be transcribed later (`voiceislocal session retranscribe`).
        let untranscribed = options.recordOnly ? ArchiveStatus.audioOnly : ArchiveStatus.transcriptionIncomplete
        if cancelled {
            try await finishCancelled(status: savedAudio ? untranscribed : ArchiveStatus.incomplete)
        }
        Self.log.notice("Session \(self.archive.id, privacy: .public) stopped capture (\(stopReason.rawValue, privacy: .public))")
        try await archive.setStatus(ArchiveStatus.processing)
        await setPhase(.transcribing)
        reporter.message("Audio saved. Finishing transcription; Ctrl-C exits processing and preserves the audio archive.")
        // 2–3. Finish live speech; replay only what it missed, and merge at word level.
        var segments: [TranscriptSegment] = []
        var transcriptErrors: [String] = []
        var transcriptionCancelled = false
        for track in options.recordOnly ? [] : tracks {
            if Task.isCancelled { break }
            guard let feed = live[track] else { continue }
            let result = await feed.finish()
            if Task.isCancelled { break }
            guard let behindFrom = result.behindFrom else {
                segments += result.segments
                continue
            }
            let coverage = TranscriptCoverage.coverageEnd(live: result.segments, behindFrom: behindFrom)
            var replayed: [TranscriptSegment] = []
            do {
                reporter.message("Processing saved \(track) audio…")
                // Every speech call of the replay has a time limit (§1.3), like the live finish before it.
                replayed = try await TrackReplayer.replay(directory: archive.directory, track: track,
                    locale: options.locale, backend: options.backend, contextualStrings: options.vocabulary,
                    from: max(0, coverage - 2), makeSpeech: dependencies.makeSpeech, timeouts: dependencies.timeouts)
            } catch let partial as ReplayIncomplete {
                // Speech stopped answering or failed: keep what it transcribed; the track is incomplete.
                replayed = partial.segments
                transcriptErrors.append("\(track): \(partial.localizedDescription)")
            } catch {
                // A cancelled replay is a cancellation, not a transcription failure.
                if error is CancellationError || Task.isCancelled {
                    transcriptionCancelled = true
                    break
                }
                transcriptErrors.append("\(track): \(error.localizedDescription)")
            }
            segments += TranscriptCoverage.merge(live: result.segments, replayed: replayed, coverageEnd: coverage)
        }
        // Live speech is over: no volatile words are left to show.
        await liveText.close()
        // Cancelled during transcription: keep the audio, publish no partial transcript.
        if transcriptionCancelled || Task.isCancelled {
            try await finishCancelled(status: untranscribed)
        }
        // 4. The transcript, named by transcripts/current.json.
        var transcriptID: String?
        if !options.recordOnly {
            segments.sort { $0.start == $1.start ? ($0.track ?? "") < ($1.track ?? "") : $0.start < $1.start }
            let transcript = Transcript(source: archive.directory.path, locale: options.locale,
                                        backend: options.backend, segments: segments)
            try await archive.saveTranscript(transcript, writeLegacyExports: false)
            transcriptID = transcript.id
        }
        try await archive.recordEvent(kind: MeetingEventKind.captureStopped, details: [
            "transcriptionErrors": transcriptErrors.joined(separator: "; "), "reason": stopReason.rawValue,
        ])
        // Drain speech and save its transcript before optional OCR. OCR must not prolong live speech asset
        // ownership while the app is trying to resume dictation, or delay publication of the audio transcript.
        if options.screen != nil, !Task.isCancelled {
            reporter.message("Recognizing text in saved screen snapshots on this Mac…")
            do {
                let complete = try await MeetingScreenOCR.processBounded(session: archive.directory, sessionID: archive.id,
                    languages: options.languages.isEmpty ? [options.locale] : options.languages)
                if !complete { reporter.message("Remaining screen OCR is deferred; use Screen Text in Review to continue.") }
            } catch {
                // Optional visual evidence never fails audio/transcription, and raw OCR text is never logged.
                Self.log.error("Screen OCR did not complete; saved recording is unaffected")
            }
        }
        let finalStatus = options.recordOnly ? ArchiveStatus.audioOnly
            : (transcriptErrors.isEmpty ? ArchiveStatus.complete : ArchiveStatus.transcriptionIncomplete)
        if Task.isCancelled {
            try await archive.finish(status: finalStatus, keepingLock: true)
            archiveOpen = false
            await exitStatus(RecorderExit(archiveStatus: finalStatus, reason: stopReason, message: "Cancelled."))
            throw CancellationError()
        }

        // 5–6. The lease is taken while the writer lock is still held, so the session is never without a lock
        // between capture and post-processing.
        var lease: ProcessingLease?
        var leaseCancelled = false
        // A configured hook that cannot run is reported as a failed post-processing, never as nil: nil means no
        // hook was configured (`--no-postprocess`, `--record-only`), and callers map the two differently (§1.4).
        var postRecord: PostProcessingRecord?
        if dependencies.postProcess != nil {
            do {
                switch try await acquireLease() {
                case .acquired(let acquired): lease = acquired
                case .unavailable(let message):
                    let now = Date()
                    postRecord = PostProcessingRecord(sessionID: archive.id, state: .failed,
                        transcriptID: transcriptID, pid: getpid(), startedAt: now, updatedAt: now, message: message)
                }
            } catch { leaseCancelled = true }
        }
        defer { releaseLease(lease) }
        // With the lease, the writer lock goes now (the hook opens the archive for maintenance under the lease).
        // Without it (no hook, or the lease could not be taken), the writer lock is the session's only lock: it is
        // kept until status.json says exited, so liveness never reads a dead recorder in between.
        try await archive.finish(status: finalStatus, keepingLock: lease == nil)
        archiveOpen = false
        // Cancelled while the lease was being taken: the archive is finished; skip the hook, release the lease.
        if leaseCancelled || Task.isCancelled {
            Self.log.notice("Session \(self.archive.id, privacy: .public) cancelled before post-processing; archive finished as \(finalStatus, privacy: .public)")
            await exitStatus(RecorderExit(archiveStatus: finalStatus, reason: stopReason, message: "Cancelled."))
            releaseLease(lease)
            throw CancellationError()
        }
        // 7. Post-processing under the lease; its progress is mirrored into status.json in order.
        if let hook = dependencies.postProcess, let lease {
            await setPhase(.postprocessing)
            let mirror = ProgressMirror(status: status)
            postRecord = await hook(archive.directory, lease, progressHandler(mirror))
            await mirror.finish()
            Self.log.notice("Session \(self.archive.id, privacy: .public) post-processing ended: \(postRecord?.state.rawValue ?? "", privacy: .public)")
            // The hook never throws; a cancellation during it still ends the run with CancellationError.
            if Task.isCancelled {
                await exitStatus(RecorderExit(archiveStatus: finalStatus, reason: stopReason, message: "Cancelled.",
                                        postprocessing: postRecord?.state, postprocessingMessage: postRecord?.message))
                releaseLease(lease)
                throw CancellationError()
            }
        }
        // 8–9. status.json says exited, then the lease is released, so no one reads a `postprocessing` status without
        // a lock as a dead recorder; leftover requests are deleted.
        await exitStatus(RecorderExit(archiveStatus: finalStatus, reason: stopReason,
                                postprocessing: postRecord?.state, postprocessingMessage: postRecord?.message))
        releaseLease(lease)
        return RecordingOutcome(sessionID: archive.id, directory: archive.directory, archiveStatus: finalStatus,
                                stopReason: stopReason, transcriptID: transcriptID,
                                transcriptErrors: transcriptErrors, postProcessing: postRecord)
    }

    /// Epoch 0 ended before its first frame: nothing was recorded.
    private func failStart() async throws -> Never {
        for feed in live.values { await feed.cancel() }
        let journal = try? SessionArchive.readEvents(at: archive.directory)
        let message = journal?.events.last { $0.kind == MeetingEventKind.startFailed }?.details["error"]
            ?? "Audio capture stopped before any audio arrived."
        try? await archive.finish(status: ArchiveStatus.failed, keepingLock: true)
        archiveOpen = false
        await exitStatus(RecorderExit(archiveStatus: ArchiveStatus.failed, reason: .startFailed, message: message))
        Self.log.error("Session \(self.archive.id, privacy: .public): capture ended before any audio")
        throw HolosError.incomplete("Audio capture did not start: \(message)")
    }

    /// Cancels live speech, records the stop, finishes the archive with `status`, and rethrows the cancellation.
    private func finishCancelled(status archiveStatus: String) async throws -> Never {
        for feed in live.values { await feed.cancel() }
        try? await archive.recordEvent(kind: MeetingEventKind.captureStopped, details: ["cancelled": "true"])
        try? await archive.finish(status: archiveStatus, keepingLock: true)
        archiveOpen = false
        await exitStatus(RecorderExit(archiveStatus: archiveStatus, reason: machine.stopReason ?? .requested,
                                message: "Cancelled."))
        Self.log.notice("Session \(self.archive.id, privacy: .public) cancelled; archive finished as \(archiveStatus, privacy: .public)")
        throw CancellationError()
    }

    enum LeaseAttempt {
        case acquired(ProcessingLease)
        /// Post-processing cannot run; the message says why and what to do.
        case unavailable(String)
    }

    static let leaseBusyMessage = "Speaker labelling was skipped: the session is busy (recovery or another command "
        + "holds it). Run voiceislocal session diarize on this session later."

    static func leaseFailedMessage(_ error: any Error) -> String {
        "Speaker labelling was skipped: the session could not be locked for it (\(error.localizedDescription)). "
            + "Run voiceislocal session diarize on this session later."
    }

    /// Takes the processing lease (retrying for `tuning.leaseRetry`, 1 s) off the main actor. On failure,
    /// post-processing is skipped and the caller records it as failed. Throws only `CancellationError`.
    private func acquireLease() async throws -> LeaseAttempt {
        let directory = archive.directory
        let sessionID = archive.id
        let retry = dependencies.tuning.leaseRetry
        do {
            return .acquired(try await Task.detached {
                try SessionArchive.acquireProcessingLease(at: directory, retry: retry)
            }.value)
        } catch is CancellationError {
            throw CancellationError()
        } catch HolosError.unavailable {
            Self.log.error("Session \(sessionID, privacy: .public): processing lease held elsewhere; post-processing skipped")
            reporter.message("Another Voice is Local process is labelling this meeting.")
            return .unavailable(Self.leaseBusyMessage)
        } catch {
            let code = error as NSError
            Self.log.error("Session \(sessionID, privacy: .public): cannot take the processing lease (\(code.domain, privacy: .public) \(code.code, privacy: .public)): \(error.localizedDescription, privacy: .private); post-processing skipped")
            return .unavailable(Self.leaseFailedMessage(error))
        }
    }

    /// Mirrors progress into status.json and passes each new message to the reporter once, so repeated progress
    /// updates of one step (fractions) print one line.
    private func progressHandler(_ mirror: ProgressMirror) -> @Sendable (PostProcessingProgress) -> Void {
        let reporter = self.reporter
        let last = LockedValue<String?>(nil)
        return { progress in
            mirror.send(progress)
            let isNew = last.withLock { previous in
                guard previous != progress.message else { return false }
                previous = progress.message
                return true
            }
            if isNew { reporter.message(progress.message) }
        }
    }
}

/// Post-processing progress on its way into status.json: one queue read by one task, so updates land in order; a
/// burst is coalesced to its latest value.
///
/// Invariants:
/// 1. One task reads the queue: progress reaches `status.update` in the order it was sent, a burst coalesced to its
///    latest value, and a failed update is skipped.
/// 2. `finish()` closes the queue and returns once the task has handled everything queued before the close.
private final class ProgressMirror: Sendable {
    private let queue = WorkQueue<PostProcessingProgress>(capacity: .infinity) { _ in 0 }
    private let task: Task<Void, Never>

    init(status: StatusWriter) {
        let queue = self.queue
        task = Task {
            while let first = await queue.next() {
                var latest = first
                while !queue.isEmpty, let newer = await queue.next() { latest = newer }
                let progress = latest
                try? await status.update { status in
                    status.phase = .postprocessing
                    status.progress = progress
                }
            }
        }
    }

    func send(_ progress: PostProcessingProgress) { queue.push(progress) }

    /// Writes what is queued and stops.
    func finish() async {
        queue.close()
        await task.value
    }
}
