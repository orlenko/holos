import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Everything the exports, the CLI, and the review window show about a session's speakers, loaded at once
/// (docs/meeting-design.md §2.4, §5.5 PR7b). Reads take no lock: every file is replaced atomically and the edit
/// journal only grows. Callers that must see a consistent state across a write (the editor, `SessionExports`) load
/// it under the speaker lock.
public struct SpeakerSessionSnapshot: Sendable {
    public let session: URL
    public let manifest: SessionManifest
    public let meeting: MeetingInfo            // meeting.json or MeetingInfo.inferred
    /// The head run's transcript when a run exists (§2.4); otherwise the current transcript.
    public let transcript: Transcript
    public let run: DiarizationRun?            // head run, nil when unusable
    public let journal: EditJournal
    public let recognition: RecognitionResult?
    public let projection: SpeakerProjection?
    public let gaps: [TimelineGap]
    public let markers: [TimelineMarker]
    /// A newer transcript exists than the one the run was built from.
    public let transcriptChanged: Bool
    /// Why the head run could not be used (damaged head or run, missing transcript, invalid span), if so: one
    /// sentence of what is wrong; `diagnostics` adds that the labels were left out and how to relabel.
    public let runProblem: String?
    public let audioDeleted: Bool
    /// meeting.json is damaged or belongs to another session, so `meeting` is `MeetingInfo.inferred`.
    public let meetingInfoDamaged: Bool
    /// The head run's recognition result is damaged and was left out (no voice matches or suggestions).
    public let recognitionUnreadable: Bool
    /// Event journal lines and events the gaps and markers skipped (`SessionTimelineReader`).
    public let skippedEvents: Int

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "speakers")

    /// Throws unavailable when the session has no transcript (`incomplete` when a head exists whose labels cannot be
    /// used and there is no current transcript to fall back to).
    ///
    /// Details:
    /// - The head run is used with the transcript it was built from (`run.transcriptID`), not necessarily the
    ///   current one; `transcriptChanged` says when they differ. A head run that cannot be read, whose transcript is
    ///   missing or unreadable, or with a turn span outside its transcript (`0 ≤ first < end ≤` the segment's
    ///   effective word count) is not used: `run` and `projection` are nil, `runProblem` says why, and the current
    ///   transcript is used.
    /// - A head or run written by a newer Holos is refused (`unavailable`), as are a newer meeting.json,
    ///   transcript, recognition result, or audio-deleted.json, and a file that cannot be read right now (I/O) is an
    ///   error, never a reason to drop the speakers. A damaged recognition result is ignored (it only adds voice
    ///   matches and suggestions). A damaged meeting.json, or one of another session, gives `MeetingInfo.inferred`.
    ///   A damaged audio-deleted.json, or one of another session, leaves `audioDeleted` false.
    /// - `transcriptChanged` is set only when the current revision can be read.
    /// - Every such fallback, and every journal line or event skipped, is recorded (`runProblem`,
    ///   `meetingInfoDamaged`, `recognitionUnreadable`, `journal`, `skippedEvents`) and reported by `diagnostics`.
    /// - With an incomplete edit journal (`EditJournal.isComplete` false) the recognition result is not read or
    ///   applied (`recognition` nil): no suggestion or automatic name is made on labels that may miss an edit.
    /// - `applyRecognition` false does the same for the whole meeting: the stored result is neither read nor
    ///   applied, so no suggestion or automatic name is shown or exported. Callers that read the people store pass
    ///   `rememberVoices` (`VoiceProfileService.recognitionAllowed`), which is the promise the People window makes
    ///   when the setting is turned off with the samples kept: "Kept samples are not used while Remember voices is
    ///   off." Nothing is deleted, so turning it back on brings the suggestions back. Names are unaffected: a
    ///   meeting's own names, and the people's current names in `profileNames`, are not governed by the setting.
    public static func load(session: URL, profileNames: [String: String] = [:],
                            applyRecognition: Bool = true) throws -> SpeakerSessionSnapshot {
        let manifest = try SessionArchive.readManifest(at: session)
        let meeting: MeetingInfo
        var meetingInfoDamaged = false
        do {
            meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        } catch let error where SessionFiles.isDamage(error) {
            log.error("Session \(manifest.id, privacy: .public): meeting.json unusable, inferred instead: \(error.localizedDescription, privacy: .private)")
            meeting = MeetingInfo.inferred(sessionID: manifest.id, source: manifest.source, createdAt: manifest.createdAt)
            meetingInfoDamaged = true
        }
        let currentID = try SessionArchive.currentTranscriptID(at: session)

        var run: DiarizationRun?
        var transcript: Transcript?
        var runProblem: String?
        do {
            if let head = try SessionSpeakerStore.readHead(session: session) {
                let headRun = try SessionSpeakerStore.readRun(id: head.runID, session: session)
                do {
                    let runTranscript = try SessionFiles.transcript(id: headRun.transcriptID, session: session)
                    if let problem = spanProblem(run: headRun, transcript: runTranscript) {
                        runProblem = problem
                    } else {
                        run = headRun
                        transcript = runTranscript
                    }
                } catch let error where SessionFiles.isDamage(error) {
                    runProblem = "The transcript the speaker labels were made from is missing or damaged."
                    log.error("Session \(manifest.id, privacy: .public): head run transcript unusable: \(error.localizedDescription, privacy: .private)")
                }
            }
        } catch let error where SessionFiles.isDamage(error) {
            runProblem = "The speaker labels are missing or damaged."
            log.error("Session \(manifest.id, privacy: .public): head run unusable: \(error.localizedDescription, privacy: .private)")
        }
        if transcript == nil {
            guard let currentID else {
                // Saved labels that cannot be used are damage, never a refusal (`unavailable` is kept for a file
                // from a newer Holos and for a meeting that was never transcribed).
                if let runProblem {
                    throw HolosError.incomplete("\(runProblem) This meeting has no other transcript to show.")
                }
                throw HolosError.unavailable("This meeting has no transcript yet. Transcribe it before labelling speakers.")
            }
            transcript = try SessionFiles.transcript(id: currentID, session: session)
        }
        guard let transcript else {
            throw HolosError.unavailable("This meeting has no transcript yet. Transcribe it before labelling speakers.")
        }

        let journal = try SessionSpeakerStore.readEdits(session: session)
        var recognition: RecognitionResult?
        var recognitionUnreadable = false
        if !journal.isComplete {
            // A torn or unreadable edit may be a link or a "Not Jim": no suggestion or automatic name is shown (or
            // exported) on labels that may miss it.
            log.error("Session \(manifest.id, privacy: .public): speaker edits cannot all be read; voice suggestions not applied")
        } else if !applyRecognition {
            log.info("Session \(manifest.id, privacy: .public): Remember voices is off; voice suggestions not applied")
        } else if let run {
            do {
                recognition = try SessionSpeakerStore.readRecognition(runID: run.id, session: session)
            } catch let error where SessionFiles.isDamage(error) {
                log.error("Session \(manifest.id, privacy: .public): recognition result ignored: \(error.localizedDescription, privacy: .private)")
                recognitionUnreadable = true
            }
        }
        // A newer current transcript counts only once it was read: a pointer to a damaged revision is not one.
        var transcriptChanged = false
        if let run, let currentID, currentID != run.transcriptID {
            do {
                _ = try SessionFiles.transcript(id: currentID, session: session)
                transcriptChanged = true
            } catch let error where SessionFiles.isDamage(error) {
                log.error("Session \(manifest.id, privacy: .public): current transcript unusable: \(error.localizedDescription, privacy: .private)")
            }
        }
        let projection = run.map {
            SpeakerProjection.make(run: $0, transcript: transcript, edits: journal.edits, recognition: recognition,
                                   profileNames: profileNames)
        }
        let timeline = try SessionTimelineReader.readTimeline(session: session)
        return SpeakerSessionSnapshot(
            session: session, manifest: manifest, meeting: meeting, transcript: transcript, run: run,
            journal: journal, recognition: recognition, projection: projection, gaps: timeline.gaps,
            markers: timeline.markers, transcriptChanged: transcriptChanged,
            runProblem: runProblem,
            audioDeleted: try SessionFiles.audioDeleted(session: session, sessionID: manifest.id),
            meetingInfoDamaged: meetingInfoDamaged, recognitionUnreadable: recognitionUnreadable,
            skippedEvents: timeline.skippedEvents)
    }

    public func exportDocument(timeZone: TimeZone = .current) -> ExportDocument {
        let metadata = ExportMetadata(
            sessionID: manifest.id, name: manifest.name, createdAt: manifest.createdAt,
            durationSeconds: manifest.chunks.map(\.end).max() ?? 0, source: manifest.source, locale: manifest.locale,
            backend: manifest.backend, timeZone: timeZone)
        return ExportDocument(metadata: metadata, transcript: transcript, run: run, projection: projection,
                              gaps: gaps, markers: markers)
    }

    /// Why `run` cannot be shown with `transcript`: a turn span that names a missing segment or words outside it.
    static func spanProblem(run: DiarizationRun, transcript: Transcript) -> String? {
        var wordCounts: [String: Int] = [:]
        for segment in transcript.segments where wordCounts[segment.id] == nil {
            wordCounts[segment.id] = WordTiming.effectiveWords(of: segment).count
        }
        for turn in run.turns {
            for span in turn.spans {
                guard let count = wordCounts[span.segmentID], span.first >= 0, span.first < span.end,
                      span.end <= count else {
                    return "Speaker labels do not match the transcript (turn \(turn.id))."
                }
            }
        }
        return nil
    }
}

/// The snapshot holds transcript text and names. Printing, `dump`, and test-failure output show only IDs, counts, and
/// flags (docs/meeting-design.md §1.5, §1.9).
extension SpeakerSessionSnapshot: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SpeakerSessionSnapshot(sessionID: \(manifest.id), transcriptID: \(transcript.id), "
            + "runID: \(run?.id ?? "nil"), edits: \(journal.edits.count), gaps: \(gaps.count), "
            + "markers: \(markers.count), transcriptChanged: \(transcriptChanged), "
            + "runProblem: \(runProblem != nil), audioDeleted: \(audioDeleted))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "sessionID": manifest.id,
            "transcriptID": transcript.id,
            "runID": run?.id as Any,
            "edits": journal.edits.count,
            "projection": projection.map { String(describing: $0) } as Any,
            "gaps": gaps.count,
            "markers": markers.count,
            "transcriptChanged": transcriptChanged,
            "audioDeleted": audioDeleted,
        ], displayStyle: .struct)
    }
}

/// Session files the post-processing code reads besides the speaker store (docs/meeting-design.md §2.1).
enum SessionFiles {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")
    static let maxTranscriptBytes = 256 << 20

    private struct VersionProbe: Decodable { var schemaVersion: Int? }

    /// Whether `error` means a file is missing or damaged (so the data it held cannot be used), rather than that it
    /// could not be read now (I/O, permissions, cancellation) or was written by a newer Holos: those are thrown on.
    static func isDamage(_ error: any Error) -> Bool {
        switch error as? HolosError {
        case .invalidInput?, .incomplete?: true
        default: false
        }
    }

    /// Decodes a versioned session file (schema rules, §1.6): the version is checked before the whole file is
    /// decoded, so one written by a newer Holos is refused (`unavailable`) even when it uses values this build does
    /// not know; a version below 1, or data that does not decode, is damage (`invalidInput`).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, current: Int, name: String) throws -> T {
        if let version = (try? HolosJSON.decoder().decode(VersionProbe.self, from: data))?.schemaVersion {
            if version > current {
                throw HolosError.unavailable("\(name) was written by a newer Holos; update Holos to read it.")
            }
            if version < 1 {
                throw HolosError.invalidInput("\(name) has an unsupported schema version \(version).")
            }
        }
        do {
            return try HolosJSON.decoder().decode(type, from: data)
        } catch {
            throw HolosError.invalidInput("\(name) is damaged or was not written by Holos.")
        }
    }

    /// `error` with `prefix` before its message, keeping its `HolosError` kind.
    static func prefixed(_ error: any Error, _ prefix: String) -> any Error {
        let message = prefix + error.localizedDescription
        switch error as? HolosError {
        case .invalidInput?: return HolosError.invalidInput(message)
        case .unavailable?: return HolosError.unavailable(message)
        case .permissionDenied?: return HolosError.permissionDenied(message)
        case .incomplete?: return HolosError.incomplete(message)
        case .io?: return HolosError.io(message)
        case nil: return error
        }
    }

    /// A transcript revision; its ID must match the file name.
    static func transcript(id: String, session: URL) throws -> Transcript {
        guard SessionArchive.validToken(id) else { throw HolosError.invalidInput("Invalid transcript ID.") }
        let name = "transcripts/\(id).json"
        guard let data = try AtomicFile.readIfPresent(SessionPaths.transcript(id, in: session),
                                                      maxBytes: maxTranscriptBytes) else {
            throw HolosError.incomplete("\(name) is missing.")
        }
        let transcript = try decode(Transcript.self, from: data, current: 1, name: name)
        guard transcript.id == id else { throw HolosError.invalidInput("\(name) does not describe transcript \(id).") }
        return transcript
    }

    /// The current transcript, or nil when the session has none.
    static func currentTranscript(session: URL) throws -> Transcript? {
        guard let id = try SessionArchive.currentTranscriptID(at: session) else { return nil }
        return try transcript(id: id, session: session)
    }

    /// The current transcript's ID once that revision was read and names itself (`transcript(id:session:)`), not only
    /// found on disk. Nil when the session has none, or when the pointer or the revision it names is missing, damaged,
    /// or holds another ID (`isDamage`): there is no readable current transcript. A pointer or revision written by a
    /// newer Holos (`unavailable`), or one that cannot be read now, throws.
    static func readableCurrentTranscriptID(session: URL) throws -> String? {
        do {
            return try currentTranscript(session: session)?.id
        } catch let error where isDamage(error) {
            log.error("The current transcript is unusable: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// postprocess.json; nil when it does not exist. One written by a newer Holos is refused (`unavailable`); a
    /// damaged one, or one that belongs to another session than the manifest's (read when `manifest` is nil), is
    /// `invalidInput`, so a record copied or restored into the wrong session is never trusted.
    static func postProcessingRecord(session: URL, manifest: SessionManifest? = nil) throws -> PostProcessingRecord? {
        let name = "postprocess.json"
        guard let data = try AtomicFile.readIfPresent(SessionPaths.postprocess(session), maxBytes: 1 << 20) else {
            return nil
        }
        let record = try decode(PostProcessingRecord.self, from: data, current: 1, name: name)
        let sessionID = try manifest?.id ?? SessionArchive.readManifest(at: session).id
        guard record.sessionID == sessionID else {
            throw HolosError.invalidInput("\(name) belongs to another session.")
        }
        return record
    }

    /// meeting.json, or `MeetingInfo.inferred` for archives from before it existed.
    static func meetingInfo(session: URL, manifest: SessionManifest) throws -> MeetingInfo {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.meetingInfo(session), maxBytes: 1 << 20) else {
            return MeetingInfo.inferred(sessionID: manifest.id, source: manifest.source, createdAt: manifest.createdAt)
        }
        let info = try decode(MeetingInfo.self, from: data, current: 1, name: "meeting.json")
        guard info.sessionID == manifest.id else {
            throw HolosError.invalidInput("meeting.json belongs to another session.")
        }
        return info
    }

    /// Whether Delete Audio removed this session's audio: `audio-deleted.json` is a readable record of this session
    /// (`AudioDeletedRecord.isDeleted`). A missing, damaged, or other session's marker is false; one written by a
    /// newer Holos throws `unavailable`, and one that cannot be read now throws its error.
    static func audioDeleted(session: URL, sessionID: String?) throws -> Bool {
        try AudioDeletedRecord.isDeleted(session: session, sessionID: sessionID)
    }
}
