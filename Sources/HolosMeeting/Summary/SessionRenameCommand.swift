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

    /// The action that retries transcript-file publication for the saved name.
    public static func repairTitle(_ summary: SessionSummary) -> String { "Update Transcript Files" }

    /// A metadata failure reports no rename; a committed title with export/durability trouble reports a warning.
    public static func alert(for outcome: SessionRenameCommand.Outcome?, shown: String, failure: String?,
                             repair: String = "Update Transcript Files") -> (title: String, text: String)? {
        guard let outcome else {
            return ("Voice is Local could not rename “\(shown)”.",
                    failure ?? "The rename command stopped before it said how it ended.")
        }
        switch outcome.exitCode {
        case 0: return nil
        case 3:
            return (outcome.renamed ? "“\(shown)” was renamed, with a warning."
                        : "The transcript files for “\(shown)” could not be updated.",
                    outcome.message + "\n\nChoose \(repair) from the meeting’s Advanced menu to try again.")
        default:
            return ("Voice is Local could not rename “\(shown)”.", outcome.message)
        }
    }
}

/// `voiceislocal session rename` and the Meetings list's Rename… (docs/meeting/titles-summaries.md §4.17).
/// The canonical name and source commit together in meeting.json under the short speaker lock, independently of
/// recording and processing. Available transcript files follow under that lock. Their failure cannot undo the name.
/// The manifest retains an optional compatibility copy, updated only when its processing and writer locks are free.
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
        /// Compatibility input; naming does not acquire or wait for the background-job lock.
        public var jobLock: URL
        /// For the default name a recording gets back ("Meeting 2026-10-03 14:00").
        public var timeZone: TimeZone
        /// The meeting the caller means (`--expect-id`): a folder whose manifest names another is refused before
        /// anything is written.
        public var expectedID: String?
        /// Tests: runs just before the naming lock is taken (another command changing the meeting meanwhile).
        var beforeLease: (@Sendable () async -> Void)?
        /// Tests: runs just after the naming lock is taken (the folder moved or replaced then).
        var afterLease: (@Sendable () async -> Void)?
        /// Tests: runs before "write", "regenerate", "manifest", or "event", before the folder is checked again.
        var beforeStep: (@Sendable (String) async -> Void)?
        /// Tests: the optional manifest copy is written, then an error as if its folder could not be synced.
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
        /// Metadata initialization has not finished, or another short naming/publication operation holds the lock.
        public static let busy = Status("busy")
        /// A temporary read failure. Retained for decoding older command outcomes.
        public static let unreadable = Status("unreadable")
        /// Naming metadata cannot be read or saved, or the intended folder was replaced before committing.
        public static let failed = Status("failed")
    }

    /// What the command prints with `--json`, which the app reads back (`MeetingRenameRun`).
    public struct Outcome: Sendable, Codable, Equatable {
        public var sessionID: String?
        public var status: Status
        /// The canonical name now.
        public var name: String?
        /// Where it came from now: `user`, or `default` for the generated title.
        public var nameSource: MeetingNameSource?
        /// What the Meetings list shows now (`MeetingNaming.displayTitle`).
        public var title: String?
        /// The transcript files were rewritten with the new title.
        public var exportsUpdated: Bool
        /// The canonical name or source changed; export and compatibility-copy updates do not affect this value.
        public var renamed: Bool
        public var message: String
        /// 0 saved or unchanged; 3 saved with an export/durability warning; 1 metadata could not be committed.
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
        var sessionID = request.expectedID
        do {
            let identity = try SessionFolderIdentity(at: session)
            let id = try SessionArchive.readManifest(at: session).id
            sessionID = id
            try identity.verify(for: session)
            if let expected = request.expectedID, expected.caseInsensitiveCompare(id) != .orderedSame {
                return Outcome(sessionID: id, status: .failed,
                               message: "This folder holds another meeting; nothing was changed.", exitCode: 1)
            }
            await request.beforeLease?()
            let result = try await SessionArchive.withVerifiedSpeakerLockAsync(at: session, matching: identity) {
                await request.afterLease?()
                try identity.verify(for: session)
                try Task.checkCancellation()
                return try await renameLocked(request, id: id, identity: identity)
            }
            if result.exitCode == 0 || result.renamed {
                await mirrorName(request, identity: identity, id: id)
            }
            return result
        } catch let error as SessionArchive.SpeakerLockBusy {
            return Outcome(sessionID: sessionID, status: .busy,
                           message: error.localizedDescription, exitCode: 1)
        } catch {
            return Outcome(sessionID: sessionID, status: .failed,
                           message: "The meeting was not renamed: \(error.localizedDescription)", exitCode: 1)
        }
    }

    /// Caller holds the speaker lock. Naming commits independently of transcripts and the processing lease.
    private static func renameLocked(_ request: Request, id: String, identity: SessionFolderIdentity) async throws -> Outcome {
        let session = request.session
        let manifest = try SessionArchive.readManifest(at: session)
        guard manifest.id == id else { throw HolosError.invalidInput("This folder holds another meeting.") }
        // A recorder creates its full settings after the manifest. Do not replace that initialization with inferred settings.
        if manifest.status == ArchiveStatus.recording,
           try AtomicFile.readIfPresent(SessionPaths.meetingInfo(session), maxBytes: 1 << 20) == nil,
           try SessionArchive.isActive(at: session) {
            return Outcome(sessionID: id, status: .busy, message: "The meeting is starting; try again in a moment.", exitCode: 1)
        }
        let meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        let name = MeetingNaming.name(manifestName: manifest.name, meeting: meeting)
        let target = target(request.name, name: name, manifest: manifest, meeting: meeting, timeZone: request.timeZone)
        let source = MeetingNaming.source(stored: meeting.nameSource, name: name,
                                         importedFileName: meeting.origin == .imported ? meeting.importedFileName : nil)
        let changed = target.name != name || target.source != source
        var outcome = Outcome(sessionID: id, status: changed ? .renamed : .unchanged,
                              name: target.name, nameSource: target.source, title: target.name,
                              renamed: changed, message: changed ? "Renamed the meeting." : "The meeting already has this name.",
                              exitCode: 0)
        if changed {
            await request.beforeStep?("write")
            try identity.verify(for: session)
            try Task.checkCancellation()
            do {
                if let writer = request.namingWriter {
                    try writer(target.name, target.source, session, meeting)
                } else {
                    try SessionNamingStore.writeLocked(name: target.name, source: target.source, session: session,
                                                       meeting: meeting, identity: identity)
                }
            } catch {
                try identity.verify(for: session)
                let stored = try? SessionFiles.meetingInfo(session: session, manifest: manifest)
                guard stored?.name == target.name, stored?.nameSource == target.source else { throw error }
                outcome.message += " The name was saved, but its durability could not be confirmed: \(error.localizedDescription)"
                outcome.exitCode = 3
                return outcome
            }
        }
        return await refreshExportsLocked(request, outcome: outcome, identity: identity)
    }

    /// Caller holds the speaker lock. An export problem cannot undo or refuse the authoritative name.
    private static func refreshExportsLocked(_ request: Request, outcome: Outcome,
                                            identity: SessionFolderIdentity) async -> Outcome {
        var result = outcome
        do {
            let transcript = try SessionFiles.currentTranscript(session: request.session)
            guard let transcript else {
                if SessionExports.hasTranscriptFiles(session: request.session) {
                    throw HolosError.incomplete("The transcript is unavailable; its files can be updated after recovery.")
                }
                return result
            }
            guard let id = result.sessionID, let name = result.name, let source = result.nameSource else { return result }
            let summary: MeetingSummaryRecord?
            do { summary = try MeetingSummaryStore.read(session: request.session, sessionID: id) }
            catch let error where SessionFiles.isDamage(error) { summary = nil }
            result.title = MeetingNaming.displayTitle(name: name, source: source,
                generatedTitle: MeetingSummaryStore.current(summary, transcriptID: transcript.id)?.title)
            await request.beforeStep?("regenerate")
            try identity.verify(for: request.session)
            try Task.checkCancellation()
            try regenerateLocked(request, identity: identity, summary: summary)
            result.exportsUpdated = true
        } catch {
            result.exitCode = 3
            result.message += " Its transcript files could not be updated: \(error.localizedDescription) Choose Update Transcript Files to try again."
        }
        return result
    }

    /// Optional compatibility copy, after metadata/export locks have been released. Normal contention is harmless.
    private static func mirrorName(_ request: Request, identity: SessionFolderIdentity, id: String) async {
        guard !Task.isCancelled, (try? SessionArchive.isActive(at: request.session)) == false else { return }
        let lease: ProcessingLease
        do { lease = try SessionArchive.acquireProcessingLease(at: request.session, retry: .zero) }
        catch { return }
        defer { lease.release() }
        do {
            try await SessionArchive.withMaintenanceArchive(at: request.session, lease: lease) { archive in
                try await SessionArchive.withVerifiedSpeakerLockAsync(at: request.session, matching: identity) {
                    await request.beforeStep?("manifest")
                    try identity.verify(for: request.session)
                    let manifest = try SessionArchive.readManifest(at: request.session)
                    guard manifest.id == id else { throw HolosError.invalidInput("This folder holds another meeting.") }
                    let meeting = try SessionFiles.meetingInfo(session: request.session, manifest: manifest)
                    let name = MeetingNaming.name(manifestName: manifest.name, meeting: meeting)
                    if manifest.name != name { try await archive.setName(name) }
                    if request.failAfterNameWrite { throw HolosError.io("The compatibility copy could not be synced.") }
                    await request.beforeStep?("event")
                    try identity.verify(for: request.session)
                    try await archive.recordEvent(kind: "renamed", details: ["nameSource": meeting.nameSource?.rawValue ?? "user"])
                }
            }
        } catch {
            log.error("The optional meeting-name copy was not updated: \(error.localizedDescription, privacy: .private)")
        }
    }

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

    /// Caller holds the speaker lock. Kept as the shared naming write for injected failure tests.
    static func writeNaming(name: String, source: MeetingNameSource, session: URL, meeting: MeetingInfo) throws {
        try SessionNamingStore.writeLocked(name: name, source: source, session: session, meeting: meeting,
                                           identity: SessionFolderIdentity(at: session))
    }

    /// Caller holds the speaker lock; people's names are read under the profile lock for the export snapshot.
    private static func regenerateLocked(_ request: Request, identity: SessionFolderIdentity,
                                         summary: MeetingSummaryRecord?) throws {
        var checks = 0
        func check() throws {
            checks += 1
            try request.exportCheck?(checks)
            try identity.verify(for: request.session)
        }
        func write(_ voice: SessionSummarizeCommand.VoiceInputs) throws {
            let result = try SessionExports.regenerateLocked(session: request.session, profileNames: voice.names,
                applyRecognition: voice.recognition, selfName: voice.selfName, summaryRecord: .some(summary), check: check)
            if result.includesSummary, var record = summary, record.exportsPending == true {
                record.exportsPending = nil
                try check()
                try MeetingSummaryStore.write(record, session: request.session)
            }
        }
        if let read = request.voiceInputs { try write(read()); return }
        let store = request.profileStore
        try store.withLockedRead { result in
            try write(SessionSummarizeCommand.VoiceInputs.from(try result.get(), store: store))
        }
    }
}
