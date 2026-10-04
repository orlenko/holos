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
        public var voiceInputsNow: (@Sendable () -> VoiceInputs)?
        /// The people store the save reads again, holding its lock (after the speaker lock: speakers → profiles,
        /// docs/meeting-design.md §1.7) until the summary and the transcript files are written, so no rename of a
        /// person lands between the check and the files. Nil: `voiceInputsNow`, else the request's own inputs.
        public var profileStore: SpeakerProfileStore?

        public init(session: URL, force: Bool = false, selfName: String = VoiceProfileService.ownName(),
                    profileNames: [String: String] = [:],
                    applyRecognition: Bool = true,
                    voiceInputsNow: (@Sendable () -> VoiceInputs)? = nil, profileStore: SpeakerProfileStore? = nil) {
            self.profileStore = profileStore
            self.session = session; self.force = force; self.selfName = selfName; self.profileNames = profileNames
            self.applyRecognition = applyRecognition; self.voiceInputsNow = voiceInputsNow
        }
    }

    /// People's names, "Remember voices" (with any forget still going through the meetings) and the user's own name,
    /// read together from the people store: what decides the names the prompt gives.
    public struct VoiceInputs: Sendable, Equatable {
        public var names: [String: String]
        public var recognition: Bool
        public var selfName: String

        public init(names: [String: String], recognition: Bool, selfName: String) {
            self.names = names; self.recognition = recognition; self.selfName = selfName
        }

        /// The people store as it is now: the names and the user's own name from one read of it, and "Remember
        /// voices" with the forgets it waits for. A store that cannot be read (one a newer build wrote, a damaged one)
        /// throws: a summary is not made with names it could not read.
        public static func read(store: SpeakerProfileStore = SpeakerProfileStore()) throws -> VoiceInputs {
            from(try store.load(), store: store)
        }

        /// The inputs from a database already read, with no second read of it.
        static func from(_ database: SpeakerProfileDatabase, store: SpeakerProfileStore) -> VoiceInputs {
            VoiceInputs(
                names: VoiceProfileService.profileNames(in: database),
                recognition: VoiceProfileService.recognitionAllowed(in: database, store: store),
                selfName: database.profiles.first(where: \.isSelf)?.displayName ?? VoiceProfileService.selfName)
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
        /// The session's manifest or transcript could not be read (a volume or file briefly unavailable): try again
        /// later.
        public static let unreadable = Status("unreadable")
        public static let failed = Status("failed")
        /// Stopped (Ctrl-C, or SIGTERM from the app when a meeting starts) before anything was written.
        public static let cancelled = Status("cancelled")

        /// Whether the app tries again later for the same transcript.
        public var retriesLater: Bool {
            self == .busy || self == .changed || self == .unreadable || self == .cancelled
        }
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
            // Unreadable for now (a volume going away, a file being replaced): tried again later, as a transcript.
            return Outcome(sessionID: nil, status: .unreadable, message: error.localizedDescription, exitCode: 1)
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
            return outcome(.unreadable, error.localizedDescription)
        }
        // Only a finished meeting, by the predicate the app's schedule uses (`MeetingSummarySchedule.isFinished`): a
        // recorder that died left a transcript of part of the meeting (interrupted, still processing), which recovery
        // finishes first; an incomplete, failed or damaged archive is not summarized either.
        let state = SessionCatalog.state(manifestStatus: manifest.status,
                                         liveness: RecorderChannel.liveness(session: session))
        guard MeetingSummarySchedule.isFinished(state) else {
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
            return readFailure(error, outcome: { outcome($0, $1) })
        }
        guard let transcriptID else {
            return outcome(.noTranscript, "This meeting has no transcript to summarize.")
        }
        // What to summarize: the transcript the exports show, with speaker names. Its key is noted, so a summary made
        // while anything in the prompt changed (a rename in Terminal, a person renamed) is not saved.
        let input: MeetingSummaryInput
        let key: MeetingSummaryKey
        do {
            let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: request.profileNames,
                                                           applyRecognition: request.applyRecognition)
            let document = try SessionExports.exportDocument(snapshot)
            guard document.transcript.id == transcriptID else {
                return outcome(.changed, "The transcript changed while it was read; try again.",
                               transcriptID: transcriptID)
            }
            input = MeetingSummarySource.input(document: document, selfName: request.selfName)
            key = MeetingSummaryKey(document, selfName: request.selfName)
        } catch {
            return readFailure(error, outcome: { outcome($0, $1, transcriptID: transcriptID) })
        }
        // Current (the transcript and the speakers' names it was made with): kept, unless its transcript files were
        // not rewritten with it, which is done now, checked again at the save like any summary.
        if !request.force, let existing, key.isCurrent(existing) {
            if existing.exportsPending == true {
                return await save(existing, request: request, transcriptID: transcriptID, key: key,
                                  message: "Rewrote the transcript files with the summary.") {
                    outcome($0, $1, transcriptID: $2, code: $3)
                }
            }
            var done = outcome(.current, "The summary is up to date.", transcriptID: transcriptID, code: 0)
            done.summary = existing
            return done
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
            parts: made.stats.parts, skippedParts: made.stats.skippedParts, namesDigest: key.namesDigest)

        // A cancellation that came while the model answered writes nothing.
        if Task.isCancelled {
            return outcome(.cancelled, "Summarizing was cancelled; nothing was written.",
                           transcriptID: transcriptID)
        }
        var result = await save(record, request: request, transcriptID: transcriptID, key: key,
                                message: "Summarized the meeting.") { outcome($0, $1, transcriptID: $2, code: $3) }
        result.stats = made.stats
        log.notice("Session \(id, privacy: .public): summary \(result.status.rawValue, privacy: .public) in \(made.stats.calls, privacy: .public) calls")
        return result
    }

    /// A file that could not be read before the model: refused (`unavailable`: summary.json, the transcript or the
    /// speaker labels written by a newer Voice is Local, as every versioned session file reports it), a failure with
    /// that reason, not tried again; anything else (an I/O error, a file being replaced), tried again later.
    private static func readFailure(_ error: any Error, outcome: (Status, String) -> Outcome) -> Outcome {
        if case .unavailable(let message)? = error as? HolosError { return outcome(.failed, message) }
        return outcome(.unreadable, "Cannot read the transcript: \(error.localizedDescription)")
    }

    /// Saves `record` under the processing lease, only while `transcriptID` is still current, then rewrites the
    /// transcript files with it. The record is written with `exportsPending` first and again without it once the
    /// files are rewritten, so a failure there leaves it set and the next run rewrites them (without asking the model).
    private static func save(_ record: MeetingSummaryRecord, request: Request, transcriptID: String,
                             key: MeetingSummaryKey? = nil, message: String,
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
                // Only a lock not taken (the speaker lock, then the people store's) is `busy`: everything thrown
                // with the locks held comes wrapped (`UnderLocks`), and fails the run with its own message (a people
                // store a newer build wrote is not tried again every minute).
                do {
                    return try SessionArchive.withSpeakerLock(at: session) { () throws -> Outcome in
                        try publishLocked(record, request: request, transcriptID: transcriptID, key: key,
                                          message: message, outcome: outcome)
                    }
                } catch let error as UnderLocks {
                    throw error.error
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
                                      key: MeetingSummaryKey?, message: String,
                                      outcome: (Status, String, String?, Int32) -> Outcome) throws -> Outcome {
        // The key again, from the labels as they are now and the people store read now (names, Remember voices, the
        // user's own name, in one read): anything that would change the prompt changed meanwhile, so the summary
        // names people as they were and is made again. With the store, its lock is held from that read until the
        // files are written (taken after the speaker lock, which the caller holds: speakers → profiles).
        if let key, let store = request.profileStore {
            return try store.withLockedRead { read in
                try UnderLocks.wrapping {
                    try publishChecked(record, request: request, transcriptID: transcriptID, key: key,
                                       fresh: VoiceInputs.from(try read.get(), store: store), message: message,
                                       outcome: outcome)
                }
            }
        }
        return try UnderLocks.wrapping {
            let fresh = request.voiceInputsNow?() ?? VoiceInputs(names: request.profileNames,
                                                                recognition: request.applyRecognition,
                                                                selfName: request.selfName)
            return try publishChecked(record, request: request, transcriptID: transcriptID, key: key, fresh: fresh,
                                      message: message, outcome: outcome)
        }
    }

    /// An error thrown while the save's locks were held, so not one of a lock not taken.
    private struct UnderLocks: Error {
        let error: any Error

        static func wrapping<T>(_ body: () throws -> T) throws -> T {
            do { return try body() } catch let error as UnderLocks { throw error } catch { throw UnderLocks(error: error) }
        }
    }

    /// The check of the key against `fresh` and the writes, under the speaker lock (and the profile lock when the
    /// request names the store).
    private static func publishChecked(_ record: MeetingSummaryRecord, request: Request, transcriptID: String,
                                       key: MeetingSummaryKey?, fresh: VoiceInputs, message: String,
                                       outcome: (Status, String, String?, Int32) -> Outcome) throws -> Outcome {
        let session = request.session
        if let key {
            let now = MeetingSummaryKey.load(session: session, profileNames: fresh.names,
                                             applyRecognition: fresh.recognition, selfName: fresh.selfName)
            guard now == key else {
                return outcome(.changed, "The speaker labels or people's names changed while the meeting was "
                    + "summarized; try again.", transcriptID, 1)
            }
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
            // With the names, Remember voices and the user's own name just checked, read under the locks: the files
            // name people as the summary does, even when the request's (from before the model ran) are out of date,
            // and their summary key is the record's, so the files written carry the summary.
            try SessionExports.regenerateLocked(session: session, profileNames: fresh.names,
                                                applyRecognition: fresh.recognition, selfName: fresh.selfName)
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

    /// The speaker labels as files: the head, the edit journal and the recognition results (automatic names, written
    /// after the head), each by size and modification time. Any change to them (a relabel, a rename, a merge, a
    /// recognition run) changes it.
    static func speakerRevision(_ session: URL) -> String {
        MeetingPeopleCache.fileStamp(SessionPaths.head(session)) + "|"
            + MeetingPeopleCache.fileStamp(SessionPaths.edits(session)) + "|"
            + MeetingPeopleCache.recognitionStamp(session)
    }
}
