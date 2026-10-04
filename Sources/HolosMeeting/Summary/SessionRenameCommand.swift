import Foundation
import HolosCore
import HolosStorage
import os

/// What the Meetings list's rename editor (and its Use Generated Title) asks `SessionRenameCommand` for. Pure.
public enum MeetingRenameRequest: Sendable, Equatable {
    /// The user's name, as typed.
    case user(String)
    /// The generated title again (`nameSource` `default`).
    case generated

    /// The name for `SessionRenameCommand.Request.name`: nil for the generated title.
    public var typedName: String? {
        if case .user(let name) = self { return name }
        return nil
    }

    /// What saving `typed` in the editor of `summary` asks for, or nil when it changes nothing the meeting shows: the
    /// title shown left exactly as it was (compared before any cleaning, so a name saved before names were cut, too
    /// long or with runs of spaces, is never rewritten by opening the editor, and a generated title or default name
    /// not edited never becomes the user's), the user's own name typed again, or an empty name for a meeting that
    /// already shows its generated title. An empty name (`MeetingNaming.cleanUserName` nil) means the generated title.
    public static func name(typed: String, summary: SessionSummary) -> MeetingRenameRequest? {
        if typed == summary.displayTitle { return nil }
        guard let name = MeetingNaming.cleanUserName(typed) else {
            return summary.nameSource.isUser ? .generated : nil
        }
        if summary.nameSource.isUser { return name == summary.name ? nil : .user(name) }
        return name == summary.displayTitle ? nil : .user(name)
    }
}

extension MeetingRenameRequest {
    /// The rename the meeting has now, asked for again (Update Transcript Files, after a rename whose files could not
    /// be rewritten): its name as it is (the command does not clean a name equal to the current one), or the generated
    /// title.
    public static func retry(_ summary: SessionSummary) -> MeetingRenameRequest {
        summary.nameSource.isUser ? .user(summary.name) : .generated
    }
}

/// One edit of a meeting's name in the Meetings list: the meeting as it was when the editor opened, so what is saved
/// is compared with the title the editor started from, not with one a refresh read meanwhile (a summary finished
/// while the field was open). Pure.
public struct MeetingRenameEdit: Sendable, Equatable {
    public let original: SessionSummary

    public init(_ summary: SessionSummary) { original = summary }

    public var sessionID: String { original.id }
    /// What the editor starts with: the title shown.
    public var text: String { original.displayTitle }

    /// What saving `typed` asks for (`MeetingRenameRequest.name`, against the meeting as it was when the edit began).
    public func request(typed: String) -> MeetingRenameRequest? {
        MeetingRenameRequest.name(typed: typed, summary: original)
    }
}

/// How the app runs a rename: as `voiceislocal session rename`, a child in its own session like the other
/// maintenance commands, so quitting the app never cuts it between its writes. The meeting is marked as having
/// transcript files that may show an old title (`PendingExports.afterRename`) before the command starts; the mark stays
/// unless the command's result says otherwise (`staysMarked`), so a quit before it ends leaves Update Transcript Files
/// offered after the next launch. Pure.
public enum MeetingRenameRun {
    /// The command's arguments: the session's path and the name after `--`, so a name starting with "-" is a name.
    public static func arguments(session: URL, request: MeetingRenameRequest) -> [String] {
        if let name = request.typedName { return ["session", "rename", "--json", "--", session.path, name] }
        return ["session", "rename", "--generated", "--json", "--", session.path]
    }

    /// Whether the meeting stays marked once the command ended: not after exit 0 (the files show the title), yes after
    /// exit 3 (they do not); after exit 1 nothing was changed, so as before the run (`wasMarked`); without a result
    /// (stopped, or it could not start) what it changed is not known, so yes.
    public static func staysMarked(outcome: SessionRenameCommand.Outcome?, wasMarked: Bool) -> Bool {
        guard let outcome else { return true }
        switch outcome.exitCode {
        case 0: return false
        case 1: return wasMarked
        default: return true
        }
    }
}

/// `voiceislocal session rename` and the Meetings list's Rename… (docs/meeting-design.md §4.17): gives a finished
/// meeting the user's name (`MeetingNameSource.user`, which no generated title replaces), or gives it back its
/// generated title (`default`, the name Voice is Local made up). The name is the manifest's; where it came from is
/// meeting.json's `nameSource`. Then the transcript files are rewritten, so the Markdown heading follows, without the
/// model.
///
/// Refused while the meeting records or saves, while another command holds it (the processing lease), and while a
/// final transcript or a summary of it is being made (the deep transcription lock names it).
public enum SessionRenameCommand {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    public struct Request: Sendable {
        public var session: URL
        /// The name the user typed; nil, or empty once cleaned (`MeetingNaming.cleanUserName`): the generated title.
        public var name: String?
        /// People's names, Remember voices and the user's own name, for the transcript files (read when they are
        /// rewritten). One that throws leaves the files as they were (exit 3).
        public var voiceInputs: @Sendable () throws -> SessionSummarizeCommand.VoiceInputs
        /// The deep transcription lock (§4.16), which a final transcript or a summary holds.
        public var jobLock: URL
        /// For the default name a recording gets back ("Meeting 2026-10-03 14:00").
        public var timeZone: TimeZone
        /// Tests: runs just before the lease is taken (another command changing the meeting meanwhile).
        var beforeLease: (@Sendable () async -> Void)?
        /// Tests: runs just after the lease is taken (the folder moved or replaced then).
        var afterLease: (@Sendable () async -> Void)?
        /// Tests: writes meeting.json's `nameSource` in place of `writeNameSource` (a write that fails).
        var nameSourceWriter: (@Sendable (MeetingNameSource, URL, MeetingInfo) throws -> Void)?

        public init(session: URL, name: String?,
                    voiceInputs: @escaping @Sendable () throws -> SessionSummarizeCommand.VoiceInputs = {
                        try SessionSummarizeCommand.VoiceInputs.read()
                    },
                    jobLock: URL = DeepTranscriptionLock.url, timeZone: TimeZone = .current) {
            self.session = session; self.name = name; self.voiceInputs = voiceInputs; self.jobLock = jobLock
            self.timeZone = timeZone
        }
    }

    public struct Status: OpenStringCode {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The name (or the generated title) was saved.
        public static let renamed = Status("renamed")
        /// It already had that name from that source: only the transcript files were rewritten (so a rename whose
        /// files could not be rewritten is finished by asking for it again).
        public static let unchanged = Status("unchanged")
        /// Recording, saving, or held by another command or a final transcript or summary of it: try again later.
        public static let busy = Status("busy")
        /// The transcript (or the record of the transcript files) cannot be read now: nothing was written; try again
        /// later.
        public static let unreadable = Status("unreadable")
        /// Not a meeting that can be renamed (not finished, damaged, meeting.json or the transcript damaged or from a
        /// newer build), the transcript files could not be prepared, or a write failed. Nothing was written, except
        /// when the write itself failed.
        public static let failed = Status("failed")
    }

    /// What the command prints with `--json`, which the app reads back (`MeetingRenameRun`).
    public struct Outcome: Sendable, Codable, Equatable {
        public var sessionID: String?
        public var status: Status
        /// The manifest's name now.
        public var name: String?
        /// Where it came from now: `user`, or `default` for the generated title.
        public var nameSource: MeetingNameSource?
        /// What the Meetings list shows now (`MeetingNaming.displayTitle`).
        public var title: String?
        /// The transcript files were rewritten with the new title.
        public var exportsUpdated: Bool
        public var message: String
        /// 0 renamed or unchanged; 3 renamed (or unchanged) but the transcript files could not be rewritten, or partly
        /// renamed (the previous name could not be put back after a failed write); 1 otherwise, with nothing changed.
        public var exitCode: Int32

        public init(sessionID: String?, status: Status, name: String? = nil, nameSource: MeetingNameSource? = nil,
                    title: String? = nil, exportsUpdated: Bool = false, message: String, exitCode: Int32) {
            self.sessionID = sessionID; self.status = status; self.name = name; self.nameSource = nameSource
            self.title = title; self.exportsUpdated = exportsUpdated; self.message = message
            self.exitCode = exitCode
        }
    }

    public static func run(_ request: Request) async -> Outcome {
        let session = request.session
        let id: String
        do {
            id = try SessionArchive.readManifest(at: session).id
        } catch {
            return Outcome(sessionID: nil, status: .failed,
                           message: "Cannot read this meeting: \(error.localizedDescription)", exitCode: 1)
        }
        func refused(_ status: Status, _ message: String) -> Outcome {
            Outcome(sessionID: id, status: status, message: message, exitCode: 1)
        }
        if let busy = busyReason(session: session, id: id, jobLock: request.jobLock) { return refused(.busy, busy) }
        if let manifest = try? SessionArchive.readManifest(at: session),
           let unfinished = unfinishedReason(manifest: manifest, liveness: RecorderChannel.liveness(session: session)) {
            return unfinished
        }

        // Everything the rename decides from is read under the lease, so another rename (or any command) that ends
        // while this one waits for it is seen.
        await request.beforeLease?()
        let lease: ProcessingLease
        do {
            lease = try SessionArchive.acquireProcessingLease(at: session)
        } catch {
            return refused(.busy, "Another Voice is Local command is working on this meeting; try again when it "
                + "finishes.")
        }
        defer { lease.release() }
        await request.afterLease?()
        // All of it runs under the lease's use, which checks that the folder at the path is the one the lease locks
        // (device and inode, as every processing command does): a folder moved or replaced meanwhile is left alone.
        do {
            return try await lease.withUse(for: session) {
                await renameHeld(request, id: id, lease: lease)
            }
        } catch {
            return refused(.busy, "This meeting's folder was moved or replaced while it was being renamed; nothing "
                + "was changed. Try again.")
        }
    }

    /// The rename once the lease is held and in use for the session's folder.
    private static func renameHeld(_ request: Request, id: String, lease: ProcessingLease) async -> Outcome {
        let session = request.session
        func refused(_ status: Status, _ message: String) -> Outcome {
            Outcome(sessionID: id, status: status, message: message, exitCode: 1)
        }
        let manifest: SessionManifest
        do {
            manifest = try SessionArchive.readManifest(at: session)
        } catch {
            return refused(.failed, "Cannot read this meeting: \(error.localizedDescription)")
        }
        // The meeting the rename was asked for, not another one put in its place before the lease was taken.
        guard manifest.id == id else {
            return refused(.busy, "This meeting's folder was moved or replaced while it was being renamed; nothing "
                + "was changed. Try again.")
        }
        if let unfinished = unfinishedReason(manifest: manifest, liveness: .dead) { return unfinished }
        let meeting: MeetingInfo
        do {
            meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        } catch {
            return refused(.failed, "Cannot read meeting.json, which records where the name came from: "
                + error.localizedDescription)
        }
        let target = Self.target(request.name, manifest: manifest, meeting: meeting, timeZone: request.timeZone)
        let currentSource = MeetingNaming.source(
            stored: meeting.nameSource, name: manifest.name,
            importedFileName: meeting.origin == .imported ? meeting.importedFileName : nil)
        // The generated title the meeting can show: one of a summary of the current transcript (`MeetingNaming.title`,
        // the rule the list and the transcript files' heading follow), read with the transcript below.
        var generated: String?
        func done(_ status: Status, _ message: String, exports: Bool = false, code: Int32 = 0) -> Outcome {
            Outcome(sessionID: id, status: status, name: target.name, nameSource: target.source,
                    title: MeetingNaming.displayTitle(name: target.name, source: target.source,
                                                      generatedTitle: generated),
                    exportsUpdated: exports, message: message, exitCode: code)
        }
        // Already so: nothing to write, but the transcript files are still rewritten below, so a rename whose files
        // could not be rewritten (exit 3) is finished by asking for it again.
        // The source compared as read (stored, else inferred from the name), so nothing is written when the name stays:
        // a source a newer build wrote, or none (a meeting from before it was recorded), is kept as it is.
        let unchanged = target.name == manifest.name && target.source == currentSource

        // The transcript files must follow the name, so a transcript that is there but cannot be read refuses the
        // rename rather than leaving them with the old title.
        let transcriptID: String?
        do {
            transcriptID = try SessionFiles.currentTranscript(session: session)?.id
        } catch {
            return transcriptRefusal(error, id: id)
        }
        let hasTranscript = transcriptID != nil
        // Transcript files the rename must rewrite: with no transcript to write them from, they would keep the old
        // title, so the rename is refused; and none can be written over a record a newer build wrote.
        if !hasTranscript, hasExportFiles(session) {
            return refused(.failed, "This meeting's transcript is missing but its transcript files exist, so they "
                + "cannot follow a new name; recover it first (voiceislocal session recover \(id)).")
        }
        if SessionExports.recordIsFromNewerVersion(session: session) {
            return refused(.failed, "This meeting's transcript files were written by a newer version of Voice is "
                + "Local, so they cannot follow a new name; update Voice is Local to rename it.")
        }
        generated = MeetingSummaryStore.current(MeetingSummaryStore.readIfUsable(session: session, sessionID: id),
                                                transcriptID: transcriptID)?.title
        let inputs = Result { try request.voiceInputs() }
        if unchanged {
            let message = target.source.isUser ? "The meeting already has this name."
                : "The meeting already shows its generated title."
            guard hasTranscript else { return done(.unchanged, message) }
            // Rewriting files that already show the title writes the same bytes.
            do {
                try regenerate(session: session, voice: inputs.get())
                return done(.unchanged, message, exports: true)
            } catch {
                return done(.unchanged, message + " The transcript files were not rewritten: "
                    + error.localizedDescription, code: 3)
            }
        }
        // Transcript files without a usable record of what was generated (none: the recorder's, written without
        // speakers; or a damaged one) are known only by the name they were written with: rewritten under the old name
        // first, so the rename does not take them for files the user edited and move them aside. When that cannot be
        // done, nothing is changed.
        if hasTranscript {
            let usable: Bool
            do {
                usable = try SessionExports.hasUsableRecord(session: session)
            } catch {
                if case .unavailable? = error as? HolosError {
                    return refused(.failed, "This meeting's transcript files were written by a newer version of Voice "
                        + "is Local, so they cannot follow a new name; update Voice is Local to rename it.")
                }
                return refused(.unreadable, "Cannot read the record of this meeting's transcript files, so its name "
                    + "was not changed; try again later: \(error.localizedDescription)")
            }
            if !usable, hasExportFiles(session) {
                do {
                    try regenerate(session: session, voice: inputs.get())
                } catch {
                    return refused(.failed, "Cannot prepare this meeting's transcript files for the new name, so its "
                        + "name was not changed: \(error.localizedDescription)")
                }
            }
        }
        do {
            try await writeName(target, manifest: manifest, meeting: meeting, session: session, lease: lease,
                                nameSourceWriter: request.nameSourceWriter ?? {
                                    try writeNameSource($0, session: $1, meeting: $2)
                                })
        } catch let partial as PartialRename {
            // The new name may be in the manifest without its source, and the files were not rewritten: exit 3, so
            // the app keeps the meeting marked (Update Transcript Files).
            return Outcome(sessionID: id, status: .failed, message: partial.message, exitCode: 3)
        } catch {
            return refused(.failed, "Cannot rename the meeting: \(error.localizedDescription)")
        }
        log.notice("Session \(id, privacy: .public): renamed (\(target.source.rawValue, privacy: .public))")
        let message = target.source.isUser ? "Renamed the meeting."
            : generated == nil ? "The meeting shows its default name until Apple Intelligence writes its title."
            : "The meeting shows its generated title again."
        guard hasTranscript else { return done(.renamed, message) }
        do {
            try regenerate(session: session, voice: inputs.get())
            return done(.renamed, message, exports: true)
        } catch {
            return done(.renamed, message + " The transcript files were not rewritten: \(error.localizedDescription)",
                        code: 3)
        }
    }

    /// The name's source could not be written and the previous name could not be put back: the meeting may be partly
    /// renamed.
    struct PartialRename: Error {
        let message: String
    }

    /// Writes the name, then its source, under the writer lock (the caller holds the lease). The manifest's name goes
    /// first; when meeting.json's `nameSource` then cannot be written, the manifest gets its previous name back, so a
    /// failure leaves the meeting as it was (and a crash between the two leaves a state a retry repairs: the name and
    /// source differ from what is asked, so they are written again). A `renamed` event is journaled.
    static func writeName(_ target: (name: String, source: MeetingNameSource), manifest: SessionManifest,
                          meeting: MeetingInfo, session: URL, lease: ProcessingLease,
                          nameSourceWriter: (MeetingNameSource, URL, MeetingInfo) throws -> Void) async throws {
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        do {
            try await archive.setName(target.name)
            do {
                try nameSourceWriter(target.source, session, meeting)
            } catch {
                do {
                    try await archive.setName(manifest.name)
                } catch let restore {
                    log.error("Session \(manifest.id, privacy: .public): the previous name could not be put back: \(restore.localizedDescription, privacy: .private)")
                    throw PartialRename(message: "Cannot rename the meeting: \(error.localizedDescription) Its "
                        + "previous name could not be put back either (\(restore.localizedDescription)), so the new name "
                        + "may be saved without the rest, and its transcript files may still show the old title; "
                        + "rename it again.")
                }
                throw error
            }
            do {
                try await archive.recordEvent(kind: MeetingEventKind.renamed,
                                              details: ["nameSource": target.source.rawValue])
            } catch {
                log.error("Session \(manifest.id, privacy: .public): rename not journaled: \(error.localizedDescription, privacy: .private)")
            }
        } catch {
            await archive.releaseLock()
            throw error
        }
        await archive.releaseLock()
    }

    /// The name and source a rename asks for: the user's name cleaned, else the generated title with the name Voice
    /// is Local made up (`MeetingNaming.defaultName`).
    static func target(_ typed: String?, manifest: SessionManifest, meeting: MeetingInfo, timeZone: TimeZone)
        -> (name: String, source: MeetingNameSource) {
        let current = MeetingNaming.source(
            stored: meeting.nameSource, name: manifest.name,
            importedFileName: meeting.origin == .imported ? meeting.importedFileName : nil)
        // The user's name asked for again exactly (Update Transcript Files): kept as it is, even one given before
        // names were cut.
        // The user's name asked for again (exactly, or as it cleans to): the name and its source stay as they are,
        // also a source a newer build wrote (the user's to this build).
        if let typed, current.isUser,
           typed == manifest.name || MeetingNaming.cleanUserName(typed) == manifest.name {
            return (manifest.name, current)
        }
        if let typed, let name = MeetingNaming.cleanUserName(typed) { return (name, .user) }
        return (MeetingNaming.defaultName(current: manifest.name, currentSource: current,
                                          createdAt: manifest.createdAt, origin: meeting.origin,
                                          importedFileName: meeting.importedFileName, timeZone: timeZone), .default)
    }

    /// A meeting that is not finished by the predicate summaries and final transcripts use
    /// (`MeetingSummarySchedule.isFinished`, with the state the catalog gives it): still being saved, interrupted
    /// (also after capture stopped, a `processing` manifest whose recorder is gone), incomplete, failed or damaged.
    /// Nil for a finished one.
    ///
    /// `liveness` is the recorder's as read before the lease is taken; under the rename's own lease it is `dead`
    /// (no recorder can hold the lease then, so a `recording` or `processing` manifest is an interrupted one).
    static func unfinishedReason(manifest: SessionManifest, liveness: RecorderLiveness) -> Outcome? {
        let state = SessionCatalog.state(manifestStatus: manifest.status, liveness: liveness)
        guard !MeetingSummarySchedule.isFinished(state) else { return nil }
        let id = manifest.id
        switch state {
        case .recording, .processing:
            return Outcome(sessionID: id, status: .busy,
                           message: "This meeting is still being saved; rename it once it is saved.", exitCode: 1)
        case .interrupted:
            return Outcome(sessionID: id, status: .failed,
                           message: "This meeting was interrupted before it was saved; recover it first "
                               + "(voiceislocal session recover \(id)).", exitCode: 1)
        default:
            return Outcome(sessionID: id, status: .failed,
                           message: "This meeting was not finished properly; run voiceislocal session recover \(id) "
                               + "first.", exitCode: 1)
        }
    }

    /// The current transcript is there but cannot be read: one a newer Voice is Local wrote, or a damaged one, refuses
    /// the rename for good (until it is updated or recovered); anything else (an I/O error, a file being replaced) is
    /// tried again later. Nothing is written either way.
    static func transcriptRefusal(_ error: any Error, id: String) -> Outcome {
        if case .unavailable? = error as? HolosError {
            return Outcome(sessionID: id, status: .failed,
                           message: "This meeting's transcript was written by a newer version of Voice is Local, so its "
                               + "transcript files cannot follow a new name; update Voice is Local to rename it. "
                               + error.localizedDescription, exitCode: 1)
        }
        if SessionFiles.isDamage(error) {
            return Outcome(sessionID: id, status: .failed,
                           message: "This meeting's transcript is damaged, so its transcript files cannot follow a new "
                               + "name; run voiceislocal session recover \(id) first. " + error.localizedDescription,
                           exitCode: 1)
        }
        return Outcome(sessionID: id, status: .unreadable,
                       message: "Cannot read this meeting's transcript now, so its name was not changed; try again "
                           + "later: " + error.localizedDescription, exitCode: 1)
    }

    /// Any of the transcript files `SessionExports` writes (Markdown, JSON, text) is there.
    static func hasExportFiles(_ session: URL) -> Bool {
        SessionExports.hasTranscriptFiles(session: session)
    }

    /// Why the meeting cannot be renamed now, or nil: it records or saves, or a final transcript or a summary of it is
    /// being made.
    static func busyReason(session: URL, id: String, jobLock: URL) -> String? {
        switch RecorderChannel.liveness(session: session) {
        case .capturing: return "This meeting is being recorded; rename it once it is saved."
        case .processing: return "This meeting is being saved; rename it once it is saved."
        case .maintenance, .exited, .dead: break
        }
        if case .held(let holder) = DeepTranscriptionLock.state(at: jobLock) {
            guard let holder else { return DeepTranscriptionLock.busyMessage }
            if holder.sessionID.caseInsensitiveCompare(id) == .orderedSame {
                return holder.isSummary
                    ? "A summary of this meeting is being written; rename it when that is done."
                    : "A final transcript of this meeting is being made; rename it when that is done."
            }
        }
        return nil
    }

    /// Sets `nameSource` in meeting.json (0600, atomic), keeping every other field as it is, also fields a newer
    /// build added; a meeting from before meeting.json existed gets one with its inferred settings.
    static func writeNameSource(_ source: MeetingNameSource, session: URL, meeting: MeetingInfo) throws {
        let url = SessionPaths.meetingInfo(session)
        var object: [String: Any]
        if let data = try AtomicFile.readIfPresent(url, maxBytes: 1 << 20) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HolosError.invalidInput("meeting.json is not a JSON object.")
            }
            object = parsed
        } else {
            let data = try HolosJSON.encoder().encode(meeting)
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        object["nameSource"] = source.rawValue
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        try AtomicFile.write(data, to: url)
    }

    /// Rewrites the transcript files under the speaker lock, with `voice`'s names, so a summary that is current stays
    /// in them (its key is computed with the same names).
    private static func regenerate(session: URL, voice: SessionSummarizeCommand.VoiceInputs) throws {
        try SessionArchive.withSpeakerLock(at: session) {
            _ = try SessionExports.regenerateLocked(session: session, profileNames: voice.names,
                                                    applyRecognition: voice.recognition, selfName: voice.selfName)
        }
    }
}
