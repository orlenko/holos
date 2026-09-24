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
    /// Why the head run could not be used (missing transcript, invalid span), if so.
    public let runProblem: String?
    public let audioDeleted: Bool

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "speakers")

    /// Throws unavailable when the session has no transcript.
    ///
    /// Details:
    /// - The head run is used with the transcript it was built from (`run.transcriptID`), not necessarily the
    ///   current one; `transcriptChanged` says when they differ. A head run that cannot be read, whose transcript is
    ///   missing or unreadable, or with a turn span outside its transcript (`0 ≤ first < end ≤` the segment's
    ///   effective word count) is not used: `run` and `projection` are nil, `runProblem` says why, and the current
    ///   transcript is used.
    /// - A head or run written by a newer Holos is refused (`unavailable`), as are a newer meeting.json or
    ///   transcript, and a file that cannot be read right now (I/O) is an error, never a reason to drop the
    ///   speakers. An unreadable recognition result is ignored (it only adds suggestions). A damaged meeting.json,
    ///   or one of another session, gives `MeetingInfo.inferred`.
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
        do {
            meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        } catch let error where SessionFiles.isDamage(error) {
            // The exports and the review window do not depend on meeting.json; the post-processor reports it.
            log.error("Session \(manifest.id, privacy: .public): meeting.json unusable, inferred instead: \(error.localizedDescription, privacy: .private)")
            meeting = MeetingInfo.inferred(sessionID: manifest.id, source: manifest.source, createdAt: manifest.createdAt)
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
                    runProblem = "The transcript the speaker labels were made from is missing or damaged. Label speakers again."
                    log.error("Session \(manifest.id, privacy: .public): head run transcript unusable: \(error.localizedDescription, privacy: .private)")
                }
            }
        } catch let error where SessionFiles.isDamage(error) {
            runProblem = "The speaker labels are missing or damaged. Label speakers again."
            log.error("Session \(manifest.id, privacy: .public): head run unusable: \(error.localizedDescription, privacy: .private)")
        }
        if transcript == nil {
            guard let currentID else {
                throw HolosError.unavailable("This meeting has no transcript yet. Transcribe it before labelling speakers.")
            }
            transcript = try SessionFiles.transcript(id: currentID, session: session)
        }
        guard let transcript else {
            throw HolosError.unavailable("This meeting has no transcript yet. Transcribe it before labelling speakers.")
        }

        let journal = try SessionSpeakerStore.readEdits(session: session)
        var recognition: RecognitionResult?
        if !journal.isComplete {
            // A torn or unreadable edit may be a link or a "Not Jim": no suggestion or automatic name is shown (or
            // exported) on labels that may miss it.
            log.error("Session \(manifest.id, privacy: .public): speaker edits cannot all be read; voice suggestions not applied")
        } else if !applyRecognition {
            log.info("Session \(manifest.id, privacy: .public): Remember voices is off; voice suggestions not applied")
        } else if let run {
            do {
                recognition = try SessionSpeakerStore.readRecognition(runID: run.id, session: session)
            } catch {
                log.error("Session \(manifest.id, privacy: .public): recognition result ignored: \(error.localizedDescription, privacy: .private)")
            }
        }
        let projection = run.map {
            SpeakerProjection.make(run: $0, transcript: transcript, edits: journal.edits, recognition: recognition,
                                   profileNames: profileNames)
        }
        let timeline = try SessionTimelineReader.read(session: session)
        return SpeakerSessionSnapshot(
            session: session, manifest: manifest, meeting: meeting, transcript: transcript, run: run,
            journal: journal, recognition: recognition, projection: projection, gaps: timeline.gaps,
            markers: timeline.markers,
            transcriptChanged: run.map { run in currentID.map { $0 != run.transcriptID } ?? false } ?? false,
            runProblem: runProblem, audioDeleted: SessionFiles.audioDeleted(session: session))
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
                    return "Speaker labels do not match the transcript (turn \(turn.id)). Label speakers again."
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

    /// Refuses (`unavailable`) a file written by a newer Holos (schema rule 3, §1.6).
    static func checkVersion(_ data: Data, current: Int, name: String) throws {
        guard let version = (try? HolosJSON.decoder().decode(VersionProbe.self, from: data))?.schemaVersion else {
            return
        }
        if version > current {
            throw HolosError.unavailable("\(name) was written by a newer Holos; update Holos to read it.")
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
        try checkVersion(data, current: 1, name: name)
        let transcript: Transcript
        do {
            transcript = try HolosJSON.decoder().decode(Transcript.self, from: data)
        } catch {
            throw HolosError.invalidInput("\(name) is damaged or was not written by Holos.")
        }
        guard transcript.id == id else { throw HolosError.invalidInput("\(name) does not describe transcript \(id).") }
        return transcript
    }

    /// The current transcript, or nil when the session has none.
    static func currentTranscript(session: URL) throws -> Transcript? {
        guard let id = try SessionArchive.currentTranscriptID(at: session) else { return nil }
        return try transcript(id: id, session: session)
    }

    /// meeting.json, or `MeetingInfo.inferred` for archives from before it existed.
    static func meetingInfo(session: URL, manifest: SessionManifest) throws -> MeetingInfo {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.meetingInfo(session), maxBytes: 1 << 20) else {
            return MeetingInfo.inferred(sessionID: manifest.id, source: manifest.source, createdAt: manifest.createdAt)
        }
        try checkVersion(data, current: 1, name: "meeting.json")
        let info: MeetingInfo
        do {
            info = try HolosJSON.decoder().decode(MeetingInfo.self, from: data)
        } catch {
            throw HolosError.invalidInput("meeting.json is damaged or was not written by Holos.")
        }
        guard info.sessionID == manifest.id else {
            throw HolosError.invalidInput("meeting.json belongs to another session.")
        }
        return info
    }

    /// Whether Delete Audio removed this session's audio (`audio-deleted.json` is a regular file).
    static func audioDeleted(session: URL) -> Bool {
        ((try? AtomicFile.readIfPresent(SessionPaths.audioDeleted(session), maxBytes: 1 << 20)) ?? nil) != nil
    }
}
