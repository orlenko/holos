import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// `voiceislocal session summarize` (docs/meeting-design.md §4.17): the title, summary, key points and action items of
/// a finished meeting's current transcript, made on this Mac and saved as summary.json, then the transcript files
/// rewritten with them.
///
/// The summary is made without holding the meeting (it reads saved revisions, which never change); only saving it takes
/// the processing lease, for milliseconds, after checking that the transcript it was made from is still current. A
/// meeting another command holds then is `busy`, and one whose transcript changed meanwhile `changed`: both are tried
/// again later. Nothing is written for any other outcome.
public enum SessionSummarizeCommand {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")

    public struct Request: Sendable {
        public var session: URL
        /// Make it again even when summary.json is of the current transcript.
        public var force: Bool
        /// The name for the unnamed channel speaker ("Me"): the user's full name.
        public var selfName: String
        public var profileNames: [String: String]
        public var applyRecognition: Bool
        /// People's names and "Remember voices" (with any forget still going through the meetings) as they are now:
        /// read again at the save, so a summary made while they changed is not saved. Nil keeps the request's.
        public var voiceInputsNow: (@Sendable () -> (names: [String: String], recognition: Bool))?

        public init(session: URL, force: Bool = false, selfName: String = "Me", profileNames: [String: String] = [:],
                    applyRecognition: Bool = true,
                    voiceInputsNow: (@Sendable () -> (names: [String: String], recognition: Bool))? = nil) {
            self.session = session; self.force = force; self.selfName = selfName; self.profileNames = profileNames
            self.applyRecognition = applyRecognition; self.voiceInputsNow = voiceInputsNow
        }
    }

    /// The summary model, or why it cannot be used ("turn on Apple Intelligence in System Settings").
    public enum ModelChoice: Sendable {
        case available(MeetingSummaryModel)
        case unavailable(String)
    }

    public struct Status: OpenStringCode {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// summary.json was written.
        public static let written = Status("written")
        /// summary.json was already of the current transcript; nothing was done.
        public static let current = Status("current")
        public static let noTranscript = Status("noTranscript")
        /// The model cannot be used (Apple Intelligence off, not supported, the language not supported).
        public static let unavailable = Status("unavailable")
        /// The meeting is recording, another command holds it, or the model is busy: try again later.
        public static let busy = Status("busy")
        /// The current transcript changed while the summary was made: try again.
        public static let changed = Status("changed")
        public static let failed = Status("failed")
        /// Stopped (Ctrl-C, or SIGTERM from the app when a meeting starts) before anything was written.
        public static let cancelled = Status("cancelled")

        /// Whether the app tries again later for the same transcript.
        public var retriesLater: Bool { self == .busy || self == .changed || self == .cancelled }
    }

    public struct Outcome: Sendable, Encodable {
        public var sessionID: String?
        public var status: Status
        /// The transcript the summary is (or would have been) of.
        public var transcriptID: String?
        public var summary: MeetingSummaryRecord?
        public var stats: MeetingSummaryStats?
        /// The transcript files were rewritten with the summary.
        public var exportsUpdated: Bool
        public var message: String
        /// 0 written or current; 3 written but the transcript files could not be rewritten; 1 otherwise.
        public var exitCode: Int32

        public init(sessionID: String?, status: Status, transcriptID: String? = nil,
                    summary: MeetingSummaryRecord? = nil, stats: MeetingSummaryStats? = nil,
                    exportsUpdated: Bool = false, message: String, exitCode: Int32) {
            self.sessionID = sessionID; self.status = status; self.transcriptID = transcriptID
            self.summary = summary; self.stats = stats; self.exportsUpdated = exportsUpdated
            self.message = message; self.exitCode = exitCode
        }
    }

    /// `model(language)` gives the model for a meeting mostly in `language`; `callTimeout` bounds each call.
    public static func run(_ request: Request, callTimeout: Duration = .seconds(90),
                           model: @Sendable (_ language: String) -> ModelChoice) async -> Outcome {
        let session = request.session
        let manifest: SessionManifest
        do {
            manifest = try SessionArchive.readManifest(at: session)
        } catch {
            return Outcome(sessionID: nil, status: .failed, message: error.localizedDescription, exitCode: 1)
        }
        let id = manifest.id
        func outcome(_ status: Status, _ message: String, transcriptID: String? = nil, code: Int32 = 1) -> Outcome {
            Outcome(sessionID: id, status: status, transcriptID: transcriptID, message: message, exitCode: code)
        }
        do {
            if try SessionArchive.isActive(at: session) {
                return outcome(.busy, "This meeting is still recording; it is summarized once it is saved.")
            }
        } catch {
            return outcome(.failed, error.localizedDescription)
        }
        // As `session deep-transcribe` refuses it: a recorder that died left a transcript of part of the meeting,
        // which recovery finishes first.
        if [ArchiveStatus.recording, ArchiveStatus.interrupted, ArchiveStatus.processing].contains(manifest.status) {
            return outcome(.failed, "This session was not finished properly; run voiceislocal session recover "
                + "\(id) first, so all of its saved audio is transcribed.")
        }
        let transcriptID: String?
        let existing: MeetingSummaryRecord?
        do {
            transcriptID = try SessionFiles.readableCurrentTranscriptID(session: session)
            do {
                existing = try MeetingSummaryStore.read(session: session, sessionID: id)
            } catch let error where SessionFiles.isDamage(error) {
                log.error("Session \(id, privacy: .public): replacing an unusable summary.json")
                existing = nil
            }
        } catch {
            return outcome(.failed, error.localizedDescription)
        }
        guard let transcriptID else {
            return outcome(.noTranscript, "This meeting has no transcript to summarize.")
        }
        // Who the summary names depends on the speaker labels and people's names as well as the transcript: their
        // stamp now, compared with the one the summary was made with.
        let stampNow = MeetingSummarySchedule.speakerStamp(
            session: session,
            voice: MeetingSummarySchedule.voiceStamp(names: request.profileNames,
                                                     recognition: request.applyRecognition))
        let transcriptCurrent = !MeetingSummaryStore.needsSummary(record: existing, transcriptID: transcriptID,
                                                                  force: request.force)
        if transcriptCurrent, let existing {
            // Up to date, unless the transcript files were not rewritten with it: that is done now.
            if existing.exportsPending == true {
                return await save(existing, request: request, transcriptID: transcriptID,
                                  message: "Rewrote the transcript files with the summary.") {
                    outcome($0, $1, transcriptID: $2, code: $3)
                }
            }
            if existing.speakerStamp == stampNow {
                var done = outcome(.current, "The summary is up to date.", transcriptID: transcriptID, code: 0)
                done.summary = existing
                return done
            }
            // The labels or names changed since: whether the summary's names did is known once they are read.
        }

        // What to summarize: the transcript the exports show, with speaker names. The speaker labels it was read with
        // are noted, so a summary made while they changed (a rename in Terminal) is not saved with the old names.
        let speakers = speakerRevision(session)
        let input: MeetingSummaryInput
        do {
            let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: request.profileNames,
                                                           applyRecognition: request.applyRecognition)
            let document = try SessionExports.exportDocument(snapshot)
            guard document.transcript.id == transcriptID else {
                return outcome(.changed, "The transcript changed while it was read; try again.",
                               transcriptID: transcriptID)
            }
            input = MeetingSummarySource.input(document: document, selfName: request.selfName)
        } catch {
            return outcome(.failed, "Cannot read the transcript: \(error.localizedDescription)",
                           transcriptID: transcriptID)
        }
        let digest = MeetingSummarySource.speakersDigest(input)
        if transcriptCurrent, var existing {
            // The labels changed but not the names the summary was made with (a relabel that kept them): it stays,
            // noted with the new stamp. Otherwise it is made again with the names as they are now.
            if existing.speakersDigest == digest {
                existing.speakerStamp = stampNow
                return await save(existing, request: request, transcriptID: transcriptID, speakers: speakers,
                                  message: "The summary is up to date.") { outcome($0, $1, transcriptID: $2, code: $3) }
            }
        }
        let summaryModel: MeetingSummaryModel
        switch model(input.language) {
        case .available(let found): summaryModel = found
        case .unavailable(let why):
            return outcome(.unavailable, "Meetings are not summarized: \(why).", transcriptID: transcriptID)
        }

        let made: (draft: MeetingSummaryDraft, stats: MeetingSummaryStats)
        do {
            made = try await MeetingSummarizer(model: summaryModel, callTimeout: callTimeout).summarize(input)
        } catch let failure as MeetingSummarizer.Failure {
            switch failure {
            case .emptyTranscript:
                return outcome(.noTranscript, "This meeting's transcript has no words to summarize.",
                               transcriptID: transcriptID)
            case .busy:
                return outcome(.busy, "Apple Intelligence is busy; try again later.", transcriptID: transcriptID)
            case .timedOut:
                return outcome(.failed, "Apple Intelligence did not answer in time.", transcriptID: transcriptID)
            case .tooManyFailures(let message), .unusableAnswer(let message):
                return outcome(.failed, message, transcriptID: transcriptID)
            }
        } catch {
            if error is CancellationError {
                return outcome(.cancelled, "Summarizing was cancelled; nothing was written.",
                               transcriptID: transcriptID)
            }
            return outcome(.failed, error.localizedDescription, transcriptID: transcriptID)
        }
        let record = MeetingSummaryRecord(
            sessionID: id, transcriptID: transcriptID, title: made.draft.title, summary: made.draft.summary,
            points: made.draft.points, actions: made.draft.actions, model: summaryModel.name, language: input.language,
            parts: made.stats.parts, skippedParts: made.stats.skippedParts, speakerStamp: stampNow,
            speakersDigest: digest)

        // A cancellation that came while the model answered writes nothing.
        if Task.isCancelled {
            return outcome(.cancelled, "Summarizing was cancelled; nothing was written.",
                           transcriptID: transcriptID)
        }
        var result = await save(record, request: request, transcriptID: transcriptID, speakers: speakers,
                                message: "Summarized the meeting.") { outcome($0, $1, transcriptID: $2, code: $3) }
        result.stats = made.stats
        log.notice("Session \(id, privacy: .public): summary \(result.status.rawValue, privacy: .public) in \(made.stats.calls, privacy: .public) calls")
        return result
    }

    /// Saves `record` under the processing lease, only while `transcriptID` is still current, then rewrites the
    /// transcript files with it. The record is written with `exportsPending` first and again without it once the
    /// files are rewritten, so a failure there leaves it set and the next run rewrites them (without asking the model).
    private static func save(_ record: MeetingSummaryRecord, request: Request, transcriptID: String,
                             speakers: String? = nil, message: String,
                             outcome: (Status, String, String?, Int32) -> Outcome) async -> Outcome {
        let session = request.session
        let lease: ProcessingLease
        do {
            lease = try SessionArchive.acquireProcessingLease(at: session)
        } catch {
            return outcome(.busy, "Another Voice is Local command is working on this meeting; try again.",
                           transcriptID, 1)
        }
        defer { lease.release() }
        do {
            return try await lease.withUse(for: session) { () async throws -> Outcome in
                guard try SessionFiles.readableCurrentTranscriptID(session: session) == transcriptID else {
                    return outcome(.changed, "The transcript changed while it was summarized; try again.",
                                   transcriptID, 1)
                }
                // The speaker lock is held from the check of the labels to the last export written, so no speaker
                // edit (which takes only that lock) lands between them: the summary and the files name the same
                // people.
                do {
                    return try SessionArchive.withSpeakerLock(at: session) { () throws -> Outcome in
                        try publishLocked(record, request: request, transcriptID: transcriptID, speakers: speakers,
                                          message: message, outcome: outcome)
                    }
                } catch let error as HolosError {
                    guard case .unavailable = error else { throw error }
                    return outcome(.busy, error.localizedDescription, transcriptID, 1)
                }
            }
        } catch {
            return outcome(.failed, "Cannot save the summary: \(error.localizedDescription)", transcriptID, 1)
        }
    }

    /// The checks and writes of `save` under the speaker lock (the caller holds it and the processing lease).
    private static func publishLocked(_ record: MeetingSummaryRecord, request: Request, transcriptID: String,
                                      speakers: String?, message: String,
                                      outcome: (Status, String, String?, Int32) -> Outcome) throws -> Outcome {
        let session = request.session
        // Speaker labels changed meanwhile: the summary names people as they were, so it is made again. So do people's
        // names and "Remember voices" (turned off, or a forget going through the meetings), which decide the names it
        // was given.
        if let speakers, speakerRevision(session) != speakers {
            return outcome(.changed, "The speaker labels changed while the meeting was summarized; try again.",
                           transcriptID, 1)
        }
        if speakers != nil, let now = request.voiceInputsNow?(),
           now.names != request.profileNames || now.recognition != request.applyRecognition {
            return outcome(.changed, "People's names or Remember voices changed while the meeting was summarized; "
                + "try again.", transcriptID, 1)
        }
        // The last point where a cancellation stops it: from here summary.json (atomic writes) and the transcript
        // files are written together.
        if Task.isCancelled {
            return outcome(.cancelled, "Summarizing was cancelled; nothing was written.", transcriptID, 1)
        }
        var pending = record
        pending.exportsPending = true
        try MeetingSummaryStore.write(pending, session: session)
        var written = outcome(.written, message, transcriptID, 0)
        written.summary = pending
        do {
            try SessionExports.regenerateLocked(session: session, profileNames: request.profileNames,
                                                applyRecognition: request.applyRecognition)
            var done = record
            done.exportsPending = nil
            try MeetingSummaryStore.write(done, session: session)
            written.summary = done
            written.exportsUpdated = true
        } catch {
            written.message += " The transcript files were not rewritten: \(error.localizedDescription)"
            written.exitCode = 3
        }
        return written
    }

    /// The speaker labels as files: the head and the edit journal, each by size and modification time. Any change to
    /// either (a relabel, a rename, a merge) changes it.
    static func speakerRevision(_ session: URL) -> String {
        MeetingPeopleCache.fileStamp(SessionPaths.head(session)) + "|"
            + MeetingPeopleCache.fileStamp(SessionPaths.edits(session))
    }
}
