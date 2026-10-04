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
    /// user's own name typed again, the title shown left as it was (a generated title or default name not edited,
    /// which stays the generated one rather than becoming the user's), or an empty name for a meeting that already
    /// shows its generated title. An empty name (`MeetingNaming.cleanUserName` nil) means the generated title.
    public static func name(typed: String, summary: SessionSummary) -> MeetingRenameRequest? {
        guard let name = MeetingNaming.cleanUserName(typed) else {
            return summary.nameSource.isUser ? .generated : nil
        }
        if summary.nameSource.isUser { return name == summary.name ? nil : .user(name) }
        return name == summary.displayTitle ? nil : .user(name)
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
        /// It already had that name from that source; nothing was written.
        public static let unchanged = Status("unchanged")
        /// Recording, saving, or held by another command or a final transcript or summary of it: try again later.
        public static let busy = Status("busy")
        /// Not a meeting that can be renamed (interrupted, damaged, meeting.json unreadable), or a write failed.
        public static let failed = Status("failed")
    }

    public struct Outcome: Sendable, Encodable, Equatable {
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
        /// 0 renamed or unchanged; 3 renamed but the transcript files could not be rewritten; 1 otherwise.
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
        let manifest: SessionManifest
        do {
            manifest = try SessionArchive.readManifest(at: session)
        } catch {
            return Outcome(sessionID: nil, status: .failed,
                           message: "Cannot read this meeting: \(error.localizedDescription)", exitCode: 1)
        }
        let id = manifest.id
        func refused(_ status: Status, _ message: String) -> Outcome {
            Outcome(sessionID: id, status: status, message: message, exitCode: 1)
        }
        if let busy = busyReason(session: session, id: id, jobLock: request.jobLock) { return refused(.busy, busy) }
        guard manifest.status != ArchiveStatus.recording else {
            return refused(.failed, "This meeting was interrupted before it was saved; recover it first "
                + "(voiceislocal session recover \(id)).")
        }
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
        let generated = MeetingSummaryStore.readIfUsable(session: session, sessionID: id)?.title
        func done(_ status: Status, _ message: String, exports: Bool = false, code: Int32 = 0) -> Outcome {
            Outcome(sessionID: id, status: status, name: target.name, nameSource: target.source,
                    title: MeetingNaming.displayTitle(name: target.name, source: target.source,
                                                      generatedTitle: generated),
                    exportsUpdated: exports, message: message, exitCode: code)
        }
        if target.name == manifest.name, target.source == currentSource, meeting.nameSource == target.source {
            return done(.unchanged, target.source.isUser ? "The meeting already has this name."
                : "The meeting already shows its generated title.")
        }

        let lease: ProcessingLease
        do {
            lease = try SessionArchive.acquireProcessingLease(at: session)
        } catch {
            return refused(.busy, "Another Voice is Local command is working on this meeting; try again when it "
                + "finishes.")
        }
        defer { lease.release() }
        let hasTranscript = (try? SessionFiles.readableCurrentTranscriptID(session: session)) != nil
        let inputs = Result { try request.voiceInputs() }
        // Transcript files written before any was generated here (the recorder's, without speakers) are known by the
        // name they were written with: rewritten under the old name first, so the rename does not take them for files
        // the user edited and move them aside.
        if hasTranscript, case .success(let voice) = inputs,
           case .success(nil) = Result(catching: {
               try AtomicFile.readIfPresent(SessionPaths.generatedExports(session), maxBytes: 1 << 20)
           }) {
            _ = try? regenerate(session: session, voice: voice)
        }
        do {
            let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
            do {
                // Written in the order that leaves, after a crash between the two, what was there before (a rename
                // not made yet) or what was asked (the generated title shown): never the default name as the user's.
                if target.source.isUser {
                    try await archive.setName(target.name)
                    try writeNameSource(target.source, session: session, meeting: meeting)
                } else {
                    try writeNameSource(target.source, session: session, meeting: meeting)
                    try await archive.setName(target.name)
                }
                do {
                    try await archive.recordEvent(kind: MeetingEventKind.renamed,
                                                  details: ["nameSource": target.source.rawValue])
                } catch {
                    log.error("Session \(id, privacy: .public): rename not journaled: \(error.localizedDescription, privacy: .private)")
                }
            } catch {
                await archive.releaseLock()
                throw error
            }
            await archive.releaseLock()
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

    /// The name and source a rename asks for: the user's name cleaned, else the generated title with the name Voice
    /// is Local made up (`MeetingNaming.defaultName`).
    static func target(_ typed: String?, manifest: SessionManifest, meeting: MeetingInfo, timeZone: TimeZone)
        -> (name: String, source: MeetingNameSource) {
        if let typed, let name = MeetingNaming.cleanUserName(typed) { return (name, .user) }
        return (MeetingNaming.defaultName(current: manifest.name, createdAt: manifest.createdAt, origin: meeting.origin,
                                          importedFileName: meeting.importedFileName, timeZone: timeZone), .default)
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
