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
        public var recovery: RecoveryReport
        /// Nil when the transcript did not need rebuilding.
        public var rebuild: RebuildReport?
        /// Nil when post-processing did not run.
        public var postProcessing: PostProcessingRecord?
        /// For stdout: "Recovered 212 chunks (1:46:10). Transcript rebuilt from 1812 saved phrases; transcribed 0:31
        /// of uncovered audio. Speaker labels: 9 speakers."
        public var summary: String
        /// For stderr: audio that could not be recovered, skipped journal lines, speaker-labelling problems.
        public var warnings: [String]
        /// 0 done; 3 done, but speaker labelling was partial or failed; 1 some saved audio could not be recovered.
        public var exitCode: Int32
    }

    /// Manifest statuses whose transcript is rebuilt without `force`: an interrupted recording (and one recovered
    /// before, which the rebuild's idempotence answers), and recordings whose transcription did not finish.
    static let rebuiltStatuses: Set<String> = [
        ArchiveStatus.interrupted, ArchiveStatus.recovered, ArchiveStatus.incomplete,
        ArchiveStatus.transcriptionIncomplete,
    ]

    /// Recovers the archive, rebuilds its transcript, then labels its speakers, all under one lease; `step` is called
    /// after each step while the lease is still held, `progress` with short messages (never transcript text).
    ///
    /// Throws, and changes nothing more, when the lease is held elsewhere, recovery refuses (missing or damaged
    /// audio, an unreadable manifest, an active recorder), or the transcript cannot be rebuilt (the archive recovery
    /// is kept). A post-processing failure does not throw: it is reported in `warnings` with exit code 3.
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
        let recovery = try await SessionArchive.recover(at: session, lease: lease)
        step(.recovered)
        // A maintenance command marks a dead recorder's status exited (§4.1), with the recovered archive status.
        do { try RecorderChannel.markDeadRecorderExited(session: session) } catch {
            log.error("Session \(TranscriptRebuilder.manifestID(session), privacy: .public): cannot check the recorder status during recovery: \(error.localizedDescription, privacy: .private)")
        }
        var warnings: [String] = []
        for path in recovery.unindexedChunks { warnings.append("Unindexed audio: \(path)") }
        for path in recovery.unrecoveredChunks { warnings.append("Could not safely recover: \(path)") }
        if let skipped = journalNote(recovery.unreadableEventLines) { warnings.append(skipped) }
        var exitCode: Int32 = 0

        let status = recovery.manifest?.status ?? ""
        let chunks = recovery.manifest?.chunks.count ?? 0
        var parts = ["Recovered \(chunks) \(chunks == 1 ? "chunk" : "chunks") "
            + "(\(clock(recovery.manifest?.savedSeconds ?? 0)))."]
        var rebuild: RebuildReport?
        var record: PostProcessingRecord?
        if request.force || rebuiltStatuses.contains(status) {
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
                throw HolosError.incomplete("The archive was recovered and its audio is kept, but the transcript "
                    + "could not be rebuilt: \(error.localizedDescription)")
            }
            step(.rebuilt)
        } else {
            parts.append("Nothing to rebuild: the meeting is \(status.isEmpty ? "unknown" : status). "
                + "Use --force to rebuild its transcript anyway.")
        }
        if let rebuild {
            parts.append(rebuildSentence(rebuild))
            if request.postProcess {
                if rebuild.reused, labelsAreCurrent(session, transcriptID: rebuild.transcriptID) {
                    parts.append("Speaker labels are up to date.")
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
                        warnings.append("Speaker labels were not updated: \(error.localizedDescription)")
                        exitCode = 3
                    }
                }
            }
        }
        if recovery.needsAttention {
            warnings.append("Some saved audio still needs attention; see holos session inspect.")
            exitCode = 1
        }
        return Outcome(recovery: recovery, rebuild: rebuild, postProcessing: record,
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

    /// Whether the last post-processing labelled `transcriptID` and succeeded, so a rebuild that changed nothing does
    /// not diarize the meeting again. Anything else (no record, a run that was interrupted or failed, no labels yet)
    /// runs post-processing again.
    private static func labelsAreCurrent(_ session: URL, transcriptID: String) -> Bool {
        guard let record = try? AtomicFile.readJSON(PostProcessingRecord.self, from: SessionPaths.postprocess(session),
                                                    maxBytes: 1 << 20) else { return false }
        return record.state == .succeeded && record.transcriptID == transcriptID && record.runID != nil
    }
}
