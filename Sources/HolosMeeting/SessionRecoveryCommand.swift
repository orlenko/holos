import Foundation
import HolosCore
import HolosStorage
import os

/// What `holos session recover` does (docs/meeting-design.md §5.6), as a library call: the CLI parses its arguments
/// and prints the outcome, so the one-lease chain is tested here.
///
/// The processing lease is taken once and kept for `SessionArchive.recover(at:lease:)`,
/// `TranscriptRebuilder.rebuild(lease:)`, and `MeetingPostProcessor.run(lease:)`, so no other process can start
/// labelling (or delete the meeting) in between.
public enum SessionRecoveryCommand {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    public struct Request: Sendable {
        public var session: URL
        /// Transcribe the audio live transcription missed (`--no-transcribe` turns it off).
        public var transcribe: Bool
        /// Label speakers and rewrite the exports afterwards (`--no-postprocess` turns it off).
        public var postProcess: Bool
        /// Rebuild the transcript even when it was already rebuilt, or the meeting was not interrupted.
        public var force: Bool
        /// Recognition vocabulary for the replay; nil reads vocabulary.json.
        public var vocabulary: [String]?

        public init(session: URL, transcribe: Bool = true, postProcess: Bool = true, force: Bool = false,
                    vocabulary: [String]? = nil) {
            self.session = session; self.transcribe = transcribe; self.postProcess = postProcess
            self.force = force; self.vocabulary = vocabulary
        }
    }

    /// A step of the chain that has finished; the lease is still held.
    public enum Step: String, Sendable, Equatable {
        case recovered, rebuilt, postProcessed
    }

    public struct Outcome: Sendable {
        /// Read before the rebuild, so its manifest has the status recovery left (for example `interrupted`); see
        /// `status` for the status at the end.
        public var recovery: RecoveryReport
        /// The manifest status once the whole chain ended (for example `recovered`); nil when it cannot be read.
        public var status: String?
        /// Nil when the transcript did not need rebuilding.
        public var rebuild: RebuildReport?
        /// Nil when post-processing did not run.
        public var postProcessing: PostProcessingRecord?
        /// For stdout: "Recovered 212 chunks (1:46:10). Transcript rebuilt from 1812 saved phrases; transcribed 0:31
        /// of uncovered audio. Speaker labels: 9 speakers."
        public var summary: String
        /// For stderr: audio that could not be recovered, skipped journal lines, speaker-labelling problems.
        public var warnings: [String]
        /// 0 done; 3 done, but speaker labelling was partial or failed; 1 some saved audio could not be recovered, or
        /// the rebuilt transcript is current but the rebuild could not be recorded.
        public var exitCode: Int32
    }

    /// Manifest statuses whose transcript is rebuilt without `force`: an interrupted recording, and one recovered
    /// before (which the rebuild's idempotence answers).
    static let rebuiltStatuses: Set<String> = [ArchiveStatus.interrupted, ArchiveStatus.recovered]
    /// Manifest statuses whose transcript is rebuilt without `force` only when the recorder saved none: a recorder
    /// that stopped with transcription unfinished saved a transcript that can hold more than the journal (text
    /// transcribed from saved audio at stop, phrases whose journal write failed), so it is kept.
    static let rebuiltWithoutTranscriptStatuses: Set<String> = [
        ArchiveStatus.incomplete, ArchiveStatus.transcriptionIncomplete,
    ]

    /// Whether recover rebuilds the transcript of a session with manifest `status` without `force`.
    ///
    /// `stoppedCapturing`: the manifest was `processing` when recovery marked it `interrupted` (the recorder had
    /// stopped capturing and was transcribing, or had saved the transcript and died before `finish`). Such a session
    /// is treated like `rebuiltWithoutTranscriptStatuses`: a transcript the stop path saved is kept.
    ///
    /// A saved transcript is kept only while it can be read (`SessionFiles.readableCurrentTranscriptID`): a pointer or
    /// revision that is missing, damaged, or holds another ID counts as none (a rebuild adds a revision and deletes
    /// none). One written by a newer Holos throws `unavailable`.
    static func rebuilds(status: String, stoppedCapturing: Bool = false, session: URL) throws -> Bool {
        let keepsSavedTranscript = rebuiltWithoutTranscriptStatuses.contains(status)
            || (status == ArchiveStatus.interrupted && stoppedCapturing)
        if !keepsSavedTranscript, rebuiltStatuses.contains(status) { return true }
        guard keepsSavedTranscript else { return false }
        return try SessionFiles.readableCurrentTranscriptID(session: session) == nil
    }

    /// `error` from a step after the archive was recovered, saying so. A refusal (`unavailable`, such as a file
    /// written by a newer Holos) stays a refusal; anything else is `incomplete`.
    static func afterRecovery(_ what: String, _ error: any Error) -> HolosError {
        let message = "The archive was recovered and its audio is kept, but \(what): \(error.localizedDescription)"
        if case .unavailable? = error as? HolosError { return .unavailable(message) }
        return .incomplete(message)
    }

    /// Whether the manifest's `interrupted` status was set by a recovery that found it `processing`: the last
    /// `archiveRecovered` event that marked a stale status (`previousStatus` `recording` or `processing`) says
    /// `processing`. Recovery writes that event before it rewrites the status, and no later recovery marks it again.
    static func stoppedCapturing(_ events: [ArchiveEvent]) -> Bool {
        let stale: Set<String> = [ArchiveStatus.recording, ArchiveStatus.processing]
        let marked = events.last { event in
            event.kind == MeetingEventKind.archiveRecovered && event.details["previousStatus"].map(stale.contains) == true
        }
        return marked?.details["previousStatus"] == ArchiveStatus.processing
    }

    /// Recovers the archive, rebuilds its transcript, then labels its speakers, all under one lease; `step` is called
    /// after each step while the lease is still held, `progress` with short messages (never transcript text).
    ///
    /// Throws, and changes nothing more, when the lease is held elsewhere, recovery refuses (missing or damaged
    /// audio, an unreadable manifest, an active recorder), or the transcript cannot be rebuilt (the archive recovery
    /// is kept). A post-processing failure does not throw: it is reported in `warnings` with exit code 3. A file that
    /// the chain would read or replace and that a newer Holos wrote (the current transcript pointer or revision,
    /// vocabulary.json, postprocess.json, the speaker head or run) throws `unavailable` (schema rule 3, §1.6), with
    /// the archive recovery kept.
    public static func run(_ request: Request, diarizer: (any SpeakerDiarizer)?, makeSpeech: LiveSpeechFactory? = nil,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           progress: @escaping @Sendable (String) -> Void = { _ in },
                           step: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> Outcome {
        let session = request.session
        // Checked before the lease is taken too, so a recording that is about to hand its lease to post-processing
        // (§4.6) is not kept waiting while recovery finds out it is still running.
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording. Stop it before recovering it.")
        }
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }

        progress("Recovering the saved audio…")
        // Recovery rewrites `processing` to `interrupted`; the status before it decides whether a transcript saved
        // at stop is kept.
        let statusBefore = (try? SessionArchive.readManifest(at: session))?.status
        let recovery = try await SessionArchive.recover(at: session, lease: lease)
        step(.recovered)
        // A maintenance command marks a dead recorder's status exited (§4.1), with the recovered archive status.
        do { try RecorderChannel.markDeadRecorderExited(session: session) } catch {
            log.error("Session \(recovery.manifest?.id ?? "unknown", privacy: .public): cannot check the recorder status during recovery: \(error.localizedDescription, privacy: .private)")
        }
        var warnings: [String] = []
        for path in recovery.unindexedChunks { warnings.append("Unindexed audio: \(path)") }
        for path in recovery.unrecoveredChunks { warnings.append("Could not safely recover: \(path)") }
        if let skipped = journalNote(recovery.unreadableEventLines) { warnings.append(skipped) }
        var exitCode: Int32 = 0

        let status = recovery.manifest?.status ?? ""
        let stoppedCapturing = status == ArchiveStatus.interrupted
            && (statusBefore == ArchiveStatus.processing || Self.stoppedCapturing(recovery.events))
        let chunks = recovery.manifest?.chunks.count ?? 0
        var parts = ["Recovered \(chunks) \(chunks == 1 ? "chunk" : "chunks") "
            + "(\(clock(recovery.manifest?.savedSeconds ?? 0)))."]
        var rebuild: RebuildReport?
        var record: PostProcessingRecord?
        let rebuildsTranscript: Bool
        do {
            rebuildsTranscript = try request.force
                || rebuilds(status: status, stoppedCapturing: stoppedCapturing, session: session)
        } catch {
            throw afterRecovery("its transcript cannot be read", error)
        }
        if rebuildsTranscript {
            progress("Rebuilding the transcript…")
            do {
                rebuild = try await TranscriptRebuilder.rebuild(
                    session: session, lease: lease, force: request.force, transcribe: request.transcribe,
                    vocabulary: request.vocabulary, makeSpeech: makeSpeech,
                    progress: { fraction in
                        guard fraction > 0, fraction < 1 else { return }
                        progress("Transcribing audio live transcription missed (\(Int(fraction * 100))%)…")
                    })
            } catch let error where !(error is CancellationError) {
                throw afterRecovery("the transcript could not be rebuilt", error)
            }
            step(.rebuilt)
        } else if stoppedCapturing {
            parts.append("Nothing to rebuild: the recorder was interrupted after it stopped capturing and keeps the "
                + "transcript saved when it stopped. Use --force to rebuild its transcript from the saved phrases "
                + "anyway.")
        } else if rebuiltWithoutTranscriptStatuses.contains(status) {
            parts.append("Nothing to rebuild: the meeting is \(status) and keeps the transcript saved when it "
                + "stopped. Use --force to rebuild its transcript from the saved phrases anyway.")
        } else {
            parts.append("Nothing to rebuild: the meeting is \(status.isEmpty ? "unknown" : status). "
                + "Use --force to rebuild its transcript anyway.")
        }
        if let rebuild {
            parts.append(rebuildSentence(rebuild))
            if let problem = rebuild.recordingError {
                warnings.append("The transcript was rebuilt, but recording the rebuild failed: \(problem) "
                    + "Run holos session recover again once this is fixed.")
            }
        }
        // The transcript to label: the rebuilt one, or the one a recorder interrupted before `finish` saved (its
        // post-processing never ran). Labels already made for the same transcript are kept.
        // A kept transcript counts only while it can be read; `rebuilds` already refused one from a newer Holos.
        var kept: String?
        if rebuild == nil, stoppedCapturing {
            do { kept = try SessionFiles.readableCurrentTranscriptID(session: session) } catch {
                throw afterRecovery("its transcript cannot be read", error)
            }
        }
        if request.postProcess, let transcriptID = rebuild?.transcriptID ?? kept {
            let unchanged = rebuild?.reused ?? true
            // Read after a new rebuild too: a postprocess.json or speaker head written by a newer Holos is refused
            // (thrown, `unavailable`), never treated as absent and replaced by post-processing.
            var labels: PostProcessingRecord?
            var unreadable: (any Error)?
            do {
                labels = try currentLabels(session, transcriptID: transcriptID, canLabel: diarizer != nil)
            } catch {
                if case .unavailable? = error as? HolosError {
                    throw afterRecovery("its speaker labels were not updated", error)
                }
                unreadable = error
            }
            if let unreadable {
                warnings.append("Speaker labels were not updated: \(unreadable.localizedDescription)")
                exitCode = 3
            } else if unchanged, let current = labels {
                // A success without labels repeats why (the setup hint) instead of calling them up to date.
                parts.append(current.runID == nil ? (current.message ?? "No speaker labels.")
                    : "Speaker labels are up to date.")
            } else {
                do {
                    let processor = MeetingPostProcessor(diarizer: diarizer, options: PostProcessingOptions(),
                                                         freeSpace: freeSpace)
                    let result = try await processor.run(session: session, lease: lease) { progress($0.message) }
                    record = result
                    step(.postProcessed)
                    if let sentence = speakerSentence(result, session: session) { parts.append(sentence) }
                    if result.state == .partial || result.state == .failed {
                        warnings.append(result.message ?? "Speaker labelling \(result.state.rawValue).")
                        exitCode = 3
                    }
                } catch let error where !(error is CancellationError) {
                    if case .unavailable? = error as? HolosError {
                        throw afterRecovery("its speaker labels were not updated", error)
                    }
                    warnings.append("Speaker labels were not updated: \(error.localizedDescription)")
                    exitCode = 3
                }
            }
        }
        if recovery.needsAttention {
            warnings.append("Some saved audio still needs attention; see holos session inspect.")
            exitCode = 1
        }
        if rebuild?.recordingError != nil { exitCode = 1 }
        let finalStatus = (try? SessionArchive.readManifest(at: session))?.status
        return Outcome(recovery: recovery, status: finalStatus, rebuild: rebuild, postProcessing: record,
                       summary: parts.joined(separator: " "), warnings: warnings, exitCode: exitCode)
    }

    /// "N unreadable journal lines were skipped." when N > 0.
    public static func journalNote(_ unreadableLines: Int) -> String? {
        guard unreadableLines > 0 else { return nil }
        return unreadableLines == 1 ? "1 unreadable journal line was skipped."
            : "\(unreadableLines) unreadable journal lines were skipped."
    }

    /// h:mm:ss.
    static func clock(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, min(seconds, 1e9)).rounded()) : 0
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// m:ss below an hour, h:mm:ss from one hour.
    static func duration(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, min(seconds, 1e9)).rounded()) : 0
        return total < 3600 ? String(format: "%d:%02d", total / 60, total % 60) : clock(seconds)
    }

    private static func rebuildSentence(_ report: RebuildReport) -> String {
        let phrases = "\(report.journalSegments) saved \(report.journalSegments == 1 ? "phrase" : "phrases")"
        if report.reused { return "The transcript was already rebuilt from \(phrases)." }
        let replayed = report.replayedSeconds.values.reduce(0, +)
        guard replayed > 0 else { return "Transcript rebuilt from \(phrases)." }
        return "Transcript rebuilt from \(phrases); transcribed \(duration(replayed)) of uncovered audio."
    }

    /// "Speaker labels: 9 speakers." when the record names a run; else the record's message, if any.
    private static func speakerSentence(_ record: PostProcessingRecord, session: URL) -> String? {
        if let runID = record.runID, let run = try? SessionSpeakerStore.readRun(id: runID, session: session) {
            let count = run.speakers.count
            return "Speaker labels: \(count) \(count == 1 ? "speaker" : "speakers")."
        }
        return record.state == .partial || record.state == .failed ? nil : record.message
    }

    /// The last post-processing record when it succeeded for `transcriptID`, so a rebuild that changed nothing does
    /// not diarize the meeting again (and recover run twice changes nothing). A record that names a run counts only
    /// while the saved labels are usable for `transcriptID`: `speakers/head.json` is readable and its run is readable,
    /// was built from that transcript, and its spans fit it (`SpeakerAnalysis.HeadState.usableRunID`); a missing,
    /// damaged, or other transcript's head is replaced by post-processing instead of being called up to date. A
    /// success without labels (speaker models were not installed) counts only while nothing can label (`canLabel`
    /// false). Anything else (no record, a run that was interrupted or failed, labels possible now) gives nil:
    /// post-processing runs again.
    ///
    /// A damaged postprocess.json, head, run, or transcript gives nil (post-processing replaces it). One written by a
    /// newer Holos throws `unavailable` (schema rule 3, §1.6), and a file that cannot be read now throws too.
    static func currentLabels(_ session: URL, transcriptID: String, canLabel: Bool) throws -> PostProcessingRecord? {
        let found: PostProcessingRecord?
        do {
            found = try SessionFiles.postProcessingRecord(session: session)
        } catch let error where SessionFiles.isDamage(error) {
            log.error("postprocess.json is unusable and will be replaced: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        guard let record = found, record.state == .succeeded, record.transcriptID == transcriptID else { return nil }
        guard record.runID != nil else { return canLabel ? nil : record }
        do {
            let transcript = try SessionFiles.transcript(id: transcriptID, session: session)
            guard let head = try SpeakerAnalysis.headState(session: session, transcript: transcript),
                  head.usableRunID != nil else { return nil }
        } catch let error where SessionFiles.isDamage(error) {
            return nil
        }
        return record
    }
}
