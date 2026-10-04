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
    ///
    /// Update Transcript Files runs `retry` of the meeting as it is now: the command writes no name and rewrites the
    /// files for the title shown and the saved labels.
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
/// maintenance commands, so quitting the app never cuts it between its writes. Nothing about it is remembered: whether
/// the transcript files are out of date afterwards is read from the files (`SessionExports.filesState`). Pure.
public enum MeetingRenameRun {
    /// The command's arguments: the session's path and the name after `--`, so a name starting with "-" is a name.
    /// `expectedID`: the meeting the app means (`--expect-id`): the command refuses a folder that holds another.
    public static func arguments(session: URL, request: MeetingRenameRequest, expectedID: String) -> [String] {
        if let name = request.typedName {
            return ["session", "rename", "--json", "--expect-id", expectedID, "--", session.path, name]
        }
        return ["session", "rename", "--generated", "--json", "--expect-id", expectedID, "--", session.path]
    }

    /// The menu item that repairs a meeting whose files are out of date or whose switch to the generated title is
    /// unfinished: Update Transcript Files, or Finish Rename for a meeting without a transcript (no files to update).
    public static func repairTitle(_ summary: SessionSummary) -> String {
        summary.transcriptID == nil ? "Finish Rename" : "Update Transcript Files"
    }

    /// What the app says when a rename of the meeting titled `shown` ended (nil: nothing, it worked): exit 3 with the
    /// name changed says the files still show the old title (Update Transcript Files); exit 3 without it (the files
    /// rewritten under the old name, then the rename failed) and any other failure say it was not renamed.
    ///
    /// `repair`: what the meeting's menu offers to finish it (`repairTitle`: Finish Rename without a transcript).
    public static func alert(for outcome: SessionRenameCommand.Outcome?, shown: String, failure: String?,
                             repair: String = "Update Transcript Files") -> (title: String, text: String)? {
        guard let outcome else {
            return ("Voice is Local could not rename “\(shown)”.",
                    failure ?? "The rename command stopped before it said how it ended.")
        }
        switch outcome.exitCode {
        case 0: return nil
        case 3 where outcome.renamed:
            return (repair == "Finish Rename" ? "“\(shown)” was renamed, but the rename did not finish."
                        : "“\(shown)” was renamed, but its transcript files still show the old title.",
                    outcome.message + "\n\nRight-click the meeting and choose \(repair) to try again.")
        default:
            return ("Voice is Local could not rename “\(shown)”.", outcome.message)
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
        /// People's names, Remember voices and the user's own name for the transcript files: read from `profileStore`
        /// under its lock, inside the speaker lock (speakers → profiles), when each file rewrite runs, as `session
        /// summarize` reads them at its save; or, when set (tests), from this closure at the same moment. A read that
        /// fails leaves the files as they were.
        public var voiceInputs: (@Sendable () throws -> SessionSummarizeCommand.VoiceInputs)?
        public var profileStore: SpeakerProfileStore
        /// The deep transcription lock (§4.16), which a final transcript or a summary holds.
        public var jobLock: URL
        /// For the default name a recording gets back ("Meeting 2026-10-03 14:00").
        public var timeZone: TimeZone
        /// The meeting the caller means (`--expect-id`): a folder whose manifest names another is refused before
        /// anything is written.
        public var expectedID: String?
        /// Tests: runs just before the lease is taken (another command changing the meeting meanwhile).
        var beforeLease: (@Sendable () async -> Void)?
        /// Tests: runs just after the lease is taken (the folder moved or replaced then).
        var afterLease: (@Sendable () async -> Void)?
        /// Tests: runs before each step that writes ("prepare", "write", "commit", "manifest", "event", "regenerate"),
        /// just before the folder is checked again.
        var beforeStep: (@Sendable (String) async -> Void)?
        /// Tests: the manifest's copy of the name is written, then an error as if its folder could not be synced.
        var failAfterNameWrite = false
        /// Tests: runs before each write of a rewrite of the files (its 1-based count within that rewrite); throwing
        /// stops the rewrite there.
        var exportCheck: (@Sendable (Int) throws -> Void)?
        /// Tests: writes meeting.json's name and `nameSource` in place of `writeNaming` (a write that fails).
        var namingWriter: (@Sendable (String, MeetingNameSource, URL, MeetingInfo) throws -> Void)?

        public init(session: URL, name: String?,
                    voiceInputs: (@Sendable () throws -> SessionSummarizeCommand.VoiceInputs)? = nil,
                    profileStore: SpeakerProfileStore = SpeakerProfileStore(),
                    jobLock: URL = DeepTranscriptionLock.url, timeZone: TimeZone = .current) {
            self.session = session; self.name = name; self.voiceInputs = voiceInputs; self.profileStore = profileStore
            self.jobLock = jobLock; self.timeZone = timeZone
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
        /// The name (or its source) was changed, wholly or partly; false when nothing of the name changed (refused,
        /// unchanged, or undone after a failure, also when the files were rewritten under the old name first).
        public var renamed: Bool
        public var message: String
        /// 0 renamed or unchanged; 3 renamed (or unchanged) but the transcript files could not be rewritten, or partly
        /// renamed (the previous name could not be put back after a failed write); 1 otherwise, with nothing changed.
        public var exitCode: Int32

        public init(sessionID: String?, status: Status, name: String? = nil, nameSource: MeetingNameSource? = nil,
                    title: String? = nil, exportsUpdated: Bool = false, renamed: Bool = false, message: String,
                    exitCode: Int32) {
            self.sessionID = sessionID; self.status = status; self.name = name; self.nameSource = nameSource
            self.title = title; self.exportsUpdated = exportsUpdated; self.renamed = renamed; self.message = message
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
        if let expected = request.expectedID, expected.caseInsensitiveCompare(id) != .orderedSame {
            return refused(.failed, "This folder now holds another meeting (\(id)), not \(expected); nothing was "
                + "changed.")
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
        // The meeting's name: meeting.json's after a rename, else the manifest's (`MeetingNaming.name`).
        let name = MeetingNaming.name(manifestName: manifest.name, meeting: meeting)
        let target = Self.target(request.name, name: name, manifest: manifest, meeting: meeting,
                                 timeZone: request.timeZone)
        let currentSource = MeetingNaming.source(
            stored: meeting.nameSource, name: name,
            importedFileName: meeting.origin == .imported ? meeting.importedFileName : nil)
        // The generated title the meeting can show: one of a summary of the current transcript (`MeetingNaming.title`,
        // the rule the list and the transcript files' heading follow), read with the transcript below.
        var generated: String?
        func done(_ status: Status, _ message: String, exports: Bool = false, code: Int32 = 0) -> Outcome {
            Outcome(sessionID: id, status: status, name: target.name, nameSource: target.source,
                    title: MeetingNaming.displayTitle(name: target.name, source: target.source,
                                                      generatedTitle: generated),
                    exportsUpdated: exports, renamed: status == .renamed, message: message, exitCode: code)
        }
        // Already so: nothing to write, but the transcript files are still rewritten below, so a rename whose files
        // could not be rewritten (exit 3) is finished by asking for it again.
        // The source compared as read (stored, else inferred from the name), so nothing is written when the name stays:
        // a source a newer build wrote, or none (a meeting from before it was recorded), is kept as it is.
        let unchanged = target.name == name && target.source == currentSource

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
        // Without a transcript and transcript files the rename does not touch them, so their record does not matter.
        if hasTranscript || hasExportFiles(session), SessionExports.recordIsFromNewerVersion(session: session) {
            return refused(.failed, "This meeting's transcript files were written by a newer version of Voice is "
                + "Local, so they cannot follow a new name; update Voice is Local to rename it.")
        }
        // A summary.json a newer build wrote cannot be carried into the rewritten files (they would lose it, and the
        // generated title): refused, as other newer files are. A damaged one counts as none.
        let summaryRecord: MeetingSummaryRecord?
        do {
            summaryRecord = try MeetingSummaryStore.read(session: session, sessionID: id)
        } catch let error where SessionFiles.isDamage(error) {
            summaryRecord = nil
        } catch {
            if case .unavailable? = error as? HolosError {
                return refused(.failed, "This meeting's summary was written by a newer version of Voice is Local, so "
                    + "its transcript files cannot follow a new name; update Voice is Local to rename it.")
            }
            // Not readable now (permissions, not a regular file, an I/O error): the files would lose it.
            return refused(.unreadable, "Cannot read this meeting's summary now, so its name was not changed; try "
                + "again later: \(error.localizedDescription)")
        }
        generated = MeetingSummaryStore.current(summaryRecord, transcriptID: transcriptID)?.title
        // Before each step that writes, the folder at the path is checked again to be the one the lease locks (the
        // device and inode check of the lease's use): a folder moved or replaced meanwhile gets nothing written.
        func checkpoint(_ step: String) async throws {
            await request.beforeStep?(step)
            try await lease.withUse(for: session) {}
        }
        let moved = "This meeting's folder was moved or replaced while it was being renamed"
        // What repairs what a rename leaves unfinished: Update Transcript Files, or Finish Rename without a transcript.
        let repair = hasTranscript ? "Update Transcript Files" : "Finish Rename"
        if unchanged {
            let message = target.source.isUser ? "The meeting already has this name."
                : "The meeting already shows its generated title."
            // The manifest's copy of the name, when a rename committed it to meeting.json without updating the copy.
            if manifest.name != target.name {
                do {
                    try await checkpoint("manifest")
                } catch {
                    return refused(.busy, moved + "; nothing was changed. Try again.")
                }
                do {
                    let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
                    do {
                        try await archive.setName(target.name)
                    } catch {
                        await archive.releaseLock()
                        throw error
                    }
                    await archive.releaseLock()
                } catch {
                    return done(.unchanged, message + " The manifest's copy of its name could not be written: "
                        + error.localizedDescription + " Choose \(repair) to try again.", code: 3)
                }
            }
            guard hasTranscript else { return done(.unchanged, message) }
            // Rewriting files that already show the title writes the same bytes.
            do {
                try await checkpoint("regenerate")
            } catch {
                return refused(.busy, moved + "; nothing was changed. Try again.")
            }
            do {
                try regenerate(session: session, request: request, lease: lease, summary: summaryRecord)
                return done(.unchanged, message, exports: true)
            } catch {
                return done(.unchanged, message + " The transcript files were not rewritten: "
                    + error.localizedDescription, code: 3)
            }
        }
        var prepared = false
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
                    try await checkpoint("prepare")
                } catch {
                    return refused(.busy, moved + "; nothing was changed. Try again.")
                }
                let writes = WriteCount()
                do {
                    try regenerate(session: session, request: request, lease: lease, summary: summaryRecord, writes: writes)
                } catch {
                    // Stopped after its first write: the files changed (and may be left mid-write).
                    guard writes.made == 0 else {
                        return Outcome(sessionID: id, status: .failed, message: "Cannot prepare this meeting's "
                            + "transcript files for the new name: \(error.localizedDescription) Its name was not "
                            + "changed, but its transcript files were partly rewritten under the old name; choose "
                            + "\(repair), or rename it again.", exitCode: 3)
                    }
                    return refused(.failed, "Cannot prepare this meeting's transcript files for the new name, so its "
                        + "name was not changed: \(error.localizedDescription)")
                }
                prepared = true
            }
        }
        // A rename that fails once the files were rewritten under the old name changed them: exit 3, saying so.
        func failed(_ status: Status, _ message: String) -> Outcome {
            guard prepared else { return refused(status, message) }
            return Outcome(sessionID: id, status: status, message: message + " Its transcript files were rewritten "
                + "under the old name first (any edited by hand were moved aside as edited copies in exports).",
                exitCode: 3)
        }
        do {
            try await checkpoint("write")
        } catch {
            return failed(.busy, moved + "; its name was not changed. Try again.")
        }
        // The commit: meeting.json's name and `nameSource`, in one atomic write. From then on the meeting has the new
        // name; what follows (the manifest's copy, the event, the files) only catches up, and when it does not, the
        // files read as out of date and Update Transcript Files (Finish Rename) does it.
        let archive: SessionArchive
        do {
            archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        } catch {
            return failed(.failed, "Cannot rename the meeting: \(error.localizedDescription)")
        }
        // The folder is checked again right before the commit: opening the archive took time.
        do {
            try await checkpoint("commit")
        } catch {
            await archive.releaseLock()
            return failed(.busy, moved + "; its name was not changed. Try again.")
        }
        var unfinished: [String] = []
        do {
            try (request.namingWriter ?? { try writeNaming(name: $0, source: $1, session: $2, meeting: $3) })(
                target.name, target.source, session, meeting)
        } catch {
            // A write that failed after its file was in place (its folder not synced) is committed all the same.
            let written = try? SessionFiles.meetingInfo(session: session, manifest: manifest)
            guard written?.name == target.name, written?.nameSource == target.source else {
                await archive.releaseLock()
                return failed(.failed, "Cannot rename the meeting: \(error.localizedDescription)")
            }
            unfinished.append("The name is saved, but saving it could not be confirmed (\(error.localizedDescription)).")
        }
        func partial(_ message: String) -> Outcome {
            done(.renamed, message + " Choose \(repair) to finish it.", code: 3)
        }
        // The manifest's copy of the name; a failure leaves the copy stale, not the rename undone.
        do {
            try await checkpoint("manifest")
        } catch {
            await archive.releaseLock()
            return partial("The meeting was renamed, but its folder was moved or replaced, so the rest was not "
                + "written.")
        }
        do {
            try await archive.setName(target.name)
            if request.failAfterNameWrite { throw HolosError.io("Cannot sync the session folder.") }
        } catch {
            unfinished.append("The manifest's copy of the name could not be written (\(error.localizedDescription)).")
        }
        // The folder is checked once more before the journal is written: a replaced one gets no event.
        do {
            try await checkpoint("event")
        } catch {
            await archive.releaseLock()
            return partial("The meeting was renamed, but its folder was moved or replaced, so the rest was not "
                + "written.")
        }
        do {
            try await archive.recordEvent(kind: MeetingEventKind.renamed, details: ["nameSource": target.source.rawValue])
        } catch {
            log.error("Session \(id, privacy: .public): rename not journaled: \(error.localizedDescription, privacy: .private)")
        }
        await archive.releaseLock()
        log.notice("Session \(id, privacy: .public): renamed (\(target.source.rawValue, privacy: .public))")
        let message = target.source.isUser ? "Renamed the meeting."
            : generated == nil ? "The meeting shows its default name until Apple Intelligence writes its title."
            : "The meeting shows its generated title again."
        let notes = unfinished.isEmpty ? "" : " " + unfinished.joined(separator: " ")
        guard hasTranscript else {
            return unfinished.isEmpty ? done(.renamed, message) : partial("The name is saved." + notes)
        }
        do {
            try await checkpoint("regenerate")
        } catch {
            return partial(message + notes + " " + moved + ", so its transcript files were not rewritten.")
        }
        do {
            try regenerate(session: session, request: request, lease: lease, summary: summaryRecord)
            return unfinished.isEmpty ? done(.renamed, message, exports: true)
                : done(.renamed, message + notes + " Choose \(repair) to finish it.", exports: true, code: 3)
        } catch {
            return partial(message + notes + " The transcript files were not rewritten: "
                + error.localizedDescription + ".")
        }
    }

    /// How many writes a rewrite made before it stopped (each file moved aside, the pending record, each file).
    final class WriteCount {
        var made = 0
    }

    /// The name and source a rename asks for: the user's name cleaned, else the generated title with the name Voice
    /// is Local made up (`MeetingNaming.defaultName`).
    static func target(_ typed: String?, name currentName: String, manifest: SessionManifest, meeting: MeetingInfo,
                       timeZone: TimeZone) -> (name: String, source: MeetingNameSource) {
        let current = MeetingNaming.source(
            stored: meeting.nameSource, name: currentName,
            importedFileName: meeting.origin == .imported ? meeting.importedFileName : nil)
        // The user's name asked for again exactly (Update Transcript Files): kept as it is, even one given before
        // names were cut.
        // The user's name asked for again (exactly, or as it cleans to): the name and its source stay as they are,
        // also a source a newer build wrote (the user's to this build).
        if let typed, current.isUser,
           typed == currentName || MeetingNaming.cleanUserName(typed) == currentName {
            return (currentName, current)
        }
        if let typed, let name = MeetingNaming.cleanUserName(typed) { return (name, .user) }
        return (MeetingNaming.defaultName(current: currentName, currentSource: current,
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

    /// The rename's commit: sets `name` and `nameSource` in meeting.json in one atomic write (0600), keeping every other
    /// field as it is, also fields a newer build added; a meeting from before meeting.json existed gets one with its
    /// inferred settings.
    static func writeNaming(name: String, source: MeetingNameSource, session: URL, meeting: MeetingInfo) throws {
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
        object["name"] = name
        object["nameSource"] = source.rawValue
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        try AtomicFile.write(data, to: url)
    }

    /// Rewrites the transcript files under the speaker lock, with people's names, Remember voices and the user's own
    /// name read then: from the people store under its lock (taken after the speaker lock, speakers → profiles) and
    /// held until the files are written, as `session summarize` does at its save, so a change to the people (Remember
    /// voices turned off, a rename) never lands between the read and the files; a summary that is current stays in
    /// them (its key is computed with the same names).
    ///
    /// Each write it makes is preceded by `lease.verify`: the folder must still be the one the lease locks.
    ///
    /// `writes`, when given, counts the writes the rewrite made before it stopped.
    ///
    /// `summary` is the summary.json read and checked at the start of the rename, written as it is (not read again,
    /// so one that turns unreadable meanwhile is not left out).
    private static func regenerate(session: URL, request: Request, lease: ProcessingLease,
                                   summary: MeetingSummaryRecord?, writes: WriteCount? = nil) throws {
        var checks = 0
        func check() throws {
            checks += 1
            do {
                try request.exportCheck?(checks)
                try lease.verify(for: session)
            } catch {
                // This check stopped it: the writes before it were made.
                writes?.made = checks - 1
                throw error
            }
            // Each check is before a write, counted as made from here: a publication can land and then fail (its
            // folder not synced), so a write that fails may have changed the files.
            writes?.made = checks
        }
        func write(_ voice: SessionSummarizeCommand.VoiceInputs) throws {
            let result = try SessionExports.regenerateLocked(session: session, profileNames: voice.names,
                                                             applyRecognition: voice.recognition,
                                                             selfName: voice.selfName, summaryRecord: .some(summary),
                                                             check: check)
            // The summary's own debt: its files left to write (`exportsPending`, a summary run whose rewrite failed)
            // are written now, so the record says so through the summary store's one writer, still under the speaker
            // lock, rather than leaving the summary schedule to start a run that rewrites them again.
            if result.includesSummary, var record = summary, record.exportsPending == true {
                record.exportsPending = nil
                do {
                    try check()
                    try MeetingSummaryStore.write(record, session: session)
                } catch {
                    log.error("Session \(record.sessionID, privacy: .public): summary.json's pending files not cleared: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        try SessionArchive.withSpeakerLock(at: session) {
            if let read = request.voiceInputs {
                try write(read())
                return
            }
            let store = request.profileStore
            try store.withLockedRead { result in
                try write(SessionSummarizeCommand.VoiceInputs.from(try result.get(), store: store))
            }
        }
    }
}
