import CryptoKit
import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

public struct ExportWriteResult: Sendable, Equatable {
    public var written: [URL]
    /// Hand-edited exports moved to `exports/edited-<YYYYMMDD-HHMMSS>.<ext>` before regeneration.
    public var movedAside: [URL]
    /// What the snapshot the exports were written from skipped or could not use; nil when nothing was written.
    public var diagnostics: SpeakerSnapshotDiagnostics?
    /// The files carry the summary (summary.json's, current for this transcript and these names).
    public var includesSummary = false

    public init(written: [URL] = [], movedAside: [URL] = [], diagnostics: SpeakerSnapshotDiagnostics? = nil) {
        self.written = written; self.movedAside = movedAside; self.diagnostics = diagnostics
    }
}

/// One format rendered by `SessionExports.renderChecked`, with what its snapshot skipped or could not use.
public struct RenderedExport: Sendable, Equatable {
    public var data: Data
    public var diagnostics: SpeakerSnapshotDiagnostics

    public init(data: Data, diagnostics: SpeakerSnapshotDiagnostics) {
        self.data = data; self.diagnostics = diagnostics
    }
}

/// Writes a session's exports (`exports/transcript.{md,json,txt}`) from its speaker snapshot (docs/meeting-design.md
/// §4.11). `exports/` is a generated cache: each file is written 0400 and its SHA-256 recorded in
/// `exports/.generated.json`; a file that no longer matches (someone edited it) is moved aside, never overwritten.
public enum SessionExports {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    /// Mode of generated export files.
    static let generatedPermissions: mode_t = 0o400
    /// Mode of a hand-edited export moved aside.
    static let editedPermissions: mode_t = 0o600
    static let maxExportBytes = 256 << 20
    /// The formats in the order they are written.
    static let formats: [ExportFormat] = [.md, .json, .txt]

    /// Takes the speaker lock, loads the snapshot, writes exports/transcript.{md,json,txt}, releases the lock.
    @discardableResult
    public static func regenerate(session: URL, profileNames: [String: String] = [:],
                                  applyRecognition: Bool = true) throws -> ExportWriteResult {
        try SessionArchive.withSpeakerLock(at: session) {
            try regenerateLocked(session: session, profileNames: profileNames, applyRecognition: applyRecognition)
        }
    }

    /// `regenerate` with people's names, "Remember voices" (`VoiceProfileService.recognitionAllowed`) and the user's own
    /// name read from `store` while the speaker lock and then `profiles.lock` are held (the §1.7 order), so a forget or
    /// a rename of a person lands either before the files are written, and shows in them, or after, and rewrites them
    /// itself. Without a store: plain `regenerate`.
    @discardableResult
    public static func regenerate(session: URL, people store: SpeakerProfileStore?) throws -> ExportWriteResult {
        guard let store else { return try regenerate(session: session) }
        return try SessionArchive.withSpeakerLock(at: session) {
            try store.withLockedDatabase { database in
                try regenerateLocked(
                    session: session, profileNames: VoiceProfileService.profileNames(in: database),
                    applyRecognition: VoiceProfileService.recognitionAllowed(in: database, store: store),
                    selfName: database.profiles.first(where: \.isSelf)?.displayName ?? VoiceProfileService.selfName)
            }
        }
    }

    /// Caller holds the speaker lock.
    ///
    /// Every format is rendered before anything is written, so a render failure changes nothing. Then, per file:
    /// an existing file that differs from what will be written, and matches neither the digest recorded for it in
    /// `.generated.json` nor the digest a regeneration recorded just before writing it (a crash in between; files
    /// accepted that way are folded into the recorded digests, so repeated interruptions keep them), is
    /// copied to `exports/edited-<YYYYMMDD-HHMMSS>.<ext>` (0600, local time; `-2`, `-3`, … when taken) and listed
    /// in `movedAside`. Without a usable record (no `.generated.json`, or a damaged one, which records nothing), the
    /// speaker-less exports `SessionArchive.saveTranscript` writes for the current transcript count as generated; any
    /// other existing file that differs is moved aside. A `.generated.json` from a newer Holos is refused
    /// (`unavailable`).
    ///
    /// `selfName` names the unnamed channel speaker in the summary's key (nil: `VoiceProfileService.ownName()`): the
    /// summary command passes the one it checked, so the files it marks written carry its summary.
    ///
    /// `check` runs before each write (the exports folder, the pending record, each file, the final record), so a
    /// caller holding the processing lease can check the folder is still the one it locks (`ProcessingLease.verify`)
    /// and stop when not.
    @discardableResult
    ///
    /// `summaryRecord`: summary.json as the caller read and checked it (nil inside: none), used instead of reading it
    /// again; nil: read here (`readIfUsable`).
    public static func regenerateLocked(session: URL, profileNames: [String: String] = [:],
                                        applyRecognition: Bool = true, selfName: String? = nil,
                                        summaryRecord: MeetingSummaryRecord?? = nil,
                                        check: () throws -> Void = {}) throws -> ExportWriteResult {
        let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: profileNames,
                                                       applyRecognition: applyRecognition)
        let document = try exportDocument(snapshot, selfName: selfName, summaryRecord: summaryRecord)
        let rendered = try renderAll(document)
        var result = try write(rendered, session: session, snapshot: snapshot, check: check)
        result.includesSummary = document.summary != nil
        log.info("Session \(snapshot.manifest.id, privacy: .public): wrote \(result.written.count, privacy: .public) exports; moved \(result.movedAside.count, privacy: .public) edited exports aside")
        return result
    }

    /// One format, not written anywhere.
    public static func render(_ format: ExportFormat, session: URL, profileNames: [String: String] = [:],
                              applyRecognition: Bool = true) throws -> Data {
        try renderChecked(format, session: session, profileNames: profileNames,
                          applyRecognition: applyRecognition).data
    }

    /// `render`, with the diagnostics of the snapshot it was rendered from (to report after the export).
    public static func renderChecked(_ format: ExportFormat, session: URL, profileNames: [String: String] = [:],
                                     applyRecognition: Bool = true) throws -> RenderedExport {
        let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: profileNames,
                                                       applyRecognition: applyRecognition)
        return RenderedExport(data: try TranscriptExporter.render(exportDocument(snapshot), format: format),
                              diagnostics: snapshot.diagnostics)
    }

    /// The document the exports are written from: the snapshot's, except when the transcript changed after speakers
    /// were labelled (`transcriptChanged`). The head run's labels then name words of the earlier transcript, so the
    /// exports show the current transcript without speakers until speakers are labelled again; a newer transcript
    /// never disappears from them.
    static func exportDocument(_ snapshot: SpeakerSessionSnapshot, withSummary: Bool = true,
                               selfName: String? = nil, summaryRecord: MeetingSummaryRecord?? = nil) throws
        -> ExportDocument {
        var document = snapshot.exportDocument()
        // The meeting's name (meeting.json's after a rename, else the manifest's), in every file.
        document.metadata.name = meetingName(snapshot)
        if snapshot.transcriptChanged, let current = try SessionFiles.currentTranscript(session: snapshot.session) {
            document.transcript = current
            document.run = nil
            document.projection = nil
        }
        if withSummary {
            let selfName = selfName ?? VoiceProfileService.ownName()
            let record = summaryRecord ?? MeetingSummaryStore.readIfUsable(session: snapshot.session,
                                                                          sessionID: snapshot.manifest.id)
            document.summary = exportSummary(snapshot, key: MeetingSummaryKey(document, selfName: selfName),
                                             record: record)
            // The heading follows the rule the Meetings list does (`MeetingNaming.title`): the title of a summary of
            // this transcript heads the files also while its text is left out (made with other speaker names).
            document.heading = MeetingNaming.title(
                name: document.metadata.name, source: nameSource(snapshot), summary: record,
                transcriptID: document.transcript.id)
        }
        return document
    }

    /// Where the meeting's name came from; a damaged meeting.json leaves it unknown: the user's, so no generated title
    /// replaces it.
    static func nameSource(_ snapshot: SpeakerSessionSnapshot) -> MeetingNameSource {
        snapshot.meetingInfoDamaged ? .user : MeetingNaming.source(
            stored: snapshot.meeting.nameSource, name: meetingName(snapshot),
            importedFileName: snapshot.meeting.origin == .imported ? snapshot.meeting.importedFileName : nil)
    }

    /// The meeting's name (`MeetingNaming.name`): meeting.json's, else (none, or meeting.json damaged) the manifest's.
    static func meetingName(_ snapshot: SpeakerSessionSnapshot) -> String {
        MeetingNaming.name(manifestName: snapshot.manifest.name,
                           meeting: snapshot.meetingInfoDamaged ? nil : snapshot.meeting)
    }

    /// summary.json for the exports (docs/meeting-design.md §4.17), when one can be read and is current (`key`: made
    /// from this transcript with these speakers' names); otherwise the exports leave it out, so corrected speaker
    /// labels never sit beside a summary made with the old ones. Its title heads the Markdown export unless the user
    /// named the meeting.
    static func exportSummary(_ snapshot: SpeakerSessionSnapshot, key: MeetingSummaryKey,
                              record: MeetingSummaryRecord?) -> ExportSummary? {
        guard let record, key.isCurrent(record) else { return nil }
        let source = nameSource(snapshot)
        return ExportSummary(transcriptID: record.transcriptID, title: record.title, summary: record.summary,
                             points: record.points, actions: record.actions,
                             model: MeetingSummaryModel.displayName(record.model), titleIsHeading: !source.isUser)
    }

    /// Every format, in the order they are written.
    static func renderAll(_ document: ExportDocument) throws -> [(format: ExportFormat, data: Data)] {
        try formats.map { ($0, try TranscriptExporter.render(document, format: $0)) }
    }

    // MARK: - Private

    /// Contents of `exports/.generated.json`.
    struct GeneratedRecord: Codable, Equatable {
        var schemaVersion: Int
        /// File name → SHA-256 (lowercase hex) of the bytes last written.
        var files: [String: String]
        /// Set while a regeneration writes: file name → SHA-256 of the bytes it is writing, so a file it wrote before
        /// a crash still counts as generated.
        var pending: [String: String]?
        /// The acoustic echo mask the labels were shown with when the files were written
        /// (`EchoMaskStore.identity`; nil: none, as in records written before it existed).
        var echoMask: String?

        init(schemaVersion: Int = 1, files: [String: String], pending: [String: String]? = nil,
             echoMask: String? = nil) {
            self.schemaVersion = schemaVersion; self.files = files; self.pending = pending; self.echoMask = echoMask
        }

        func isGenerated(_ name: String, digest: String) -> Bool {
            files[name] == digest || pending?[name] == digest
        }

        /// Every entry names a transcript file this build writes and holds a SHA-256 as `write` records it (64
        /// lowercase hex digits). A record that decodes but breaks this is damaged.
        ///
        /// It covers every format too: `write` records them all, in `files` once written, in `pending` while it writes.
        /// An empty or partial record would leave existing files unknown, so it counts as damaged.
        var isValid: Bool {
            let names = Set(SessionExports.formats.map(SessionExports.fileName))
            // A write in progress has recorded every format in `pending`; a finished one, in `files`.
            if let pending {
                guard names.isSubset(of: Set(pending.keys)) else { return false }
            } else {
                guard names.isSubset(of: Set(files.keys)) else { return false }
            }
            return [files, pending ?? [:]].allSatisfy { entries in
                entries.allSatisfy { name, digest in
                    names.contains(name) && digest.utf8.count == 64
                        && digest.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
                }
            }
        }
    }

    private static func write(_ rendered: [(format: ExportFormat, data: Data)], session: URL,
                              snapshot: SpeakerSessionSnapshot, check: () throws -> Void = {}) throws
        -> ExportWriteResult {
        var result = ExportWriteResult(movedAside: try beginWrite(rendered, session: session, snapshot: snapshot,
                                                                  check: check),
                                       diagnostics: snapshot.diagnostics)
        for entry in rendered {
            try check()
            let url = SessionPaths.export(entry.format.rawValue, in: session)
            try AtomicFile.write(entry.data, to: url, permissions: generatedPermissions)
            result.written.append(url)
        }
        try check()
        // The mask the files were rendered with (the snapshot's), so one saved since makes them out of date.
        try AtomicFile.writeJSON(GeneratedRecord(files: digestsByName(rendered), echoMask: snapshot.echoMaskIdentity),
                                 to: SessionPaths.generatedExports(session))
        return result
    }

    private static func digestsByName(_ rendered: [(format: ExportFormat, data: Data)]) -> [String: String] {
        var digests: [String: String] = [:]
        for entry in rendered { digests[fileName(entry.format)] = sha256(entry.data) }
        return digests
    }

    /// The part of a write before the export files are replaced: moves hand-edited files aside and records the
    /// digests about to be written as `pending`. Returns the files moved aside. (Tests call it alone to stand for
    /// a regeneration interrupted before it replaced any file.)
    ///
    /// `check` runs before each write it makes (the exports folder, each file moved aside, the pending record).
    static func beginWrite(_ rendered: [(format: ExportFormat, data: Data)], session: URL,
                           snapshot: SpeakerSessionSnapshot, check: () throws -> Void = {}) throws -> [URL] {
        // Making sure of the exports folder can create it: checked first like every other write.
        try check()
        try AtomicFile.ensurePrivateDirectory(SessionPaths.exports(session))
        let read = try readRecordChecked(session: session)
        let record = read.record
        let digests = digestsByName(rendered)

        var movedAside: [URL] = []
        var legacy: [String: Data]?
        var legacyLoaded = false
        // Every file on disk accepted as generated is recorded under `files` before the new `pending` replaces the
        // old one, so a file an earlier interrupted regeneration wrote still counts after another interruption.
        var files = record?.files ?? [:]
        for entry in rendered {
            let name = fileName(entry.format)
            let url = SessionPaths.export(entry.format.rawValue, in: session)
            guard let existing = try AtomicFile.readIfPresent(url, maxBytes: maxExportBytes) else { continue }
            let digest = sha256(existing)
            if digest == digests[name] {
                files[name] = digest
                continue
            }
            if let record, record.isGenerated(name, digest: digest) {
                files[name] = digest
                continue
            }
            // Without a usable record (none, or a damaged one), the speaker-less files the recording wrote are still
            // known by what they hold.
            if record == nil || read.damaged {
                if !legacyLoaded {
                    legacy = legacyExports(session: session, snapshot: snapshot)
                    legacyLoaded = true
                }
                if let legacyData = legacy?[entry.format.rawValue], legacyData == existing {
                    files[name] = digest
                    continue
                }
            }
            try check()
            movedAside.append(try moveAside(existing, format: entry.format, session: session))
        }
        try check()
        try AtomicFile.writeJSON(GeneratedRecord(files: files, pending: digests), to: SessionPaths.generatedExports(session))
        return movedAside
    }

    static func fileName(_ format: ExportFormat) -> String { "transcript.\(format.rawValue)" }

    /// Why the record of the transcript files (exports/.generated.json) cannot be used for a rewrite, or nil: written
    /// by a newer Voice is Local, or not readable now (permissions, not a regular file, an I/O error). A missing or
    /// damaged one is nil: a rewrite recovers from those.
    public static func recordProblem(session: URL) -> String? {
        do {
            _ = try readRecordChecked(session: session)
            return nil
        } catch {
            if case .unavailable? = error as? HolosError {
                return "exports/.generated.json was written by a newer version of Voice is Local."
            }
            return "exports/.generated.json cannot be read: \(error.localizedDescription)"
        }
    }

    /// Whether `exports/.generated.json` was written by a newer Voice is Local: the transcript files cannot be
    /// rewritten until it is updated, so nothing tries again meanwhile.
    public static func recordIsFromNewerVersion(session: URL) -> Bool {
        do {
            _ = try readRecord(session: session)
            return false
        } catch {
            if case .unavailable? = error as? HolosError { return true }
            return false
        }
    }

    /// The identity of the acoustic echo mask the labels show now (`EchoMaskStore.identity`); nil without one.
    static func echoMaskIdentity(session: URL) -> String? {
        guard let manifest = try? SessionArchive.readManifest(at: session) else { return nil }
        return EchoMaskStore.identity(session: session, manifest: manifest)
    }

    /// Whether the transcript files were written with the acoustic echo mask the labels show now (§5.11). False when
    /// they were written with another (or with one that is gone) and when their record cannot be read; true without
    /// transcript files (nothing to bring up to date). For passes that only need to rewrite the files for the mask
    /// (Recover); the full check is `filesState`.
    public static func echoMaskIsCurrent(session: URL) -> Bool {
        guard hasTranscriptFiles(session: session) else { return true }
        guard let read = try? readRecordChecked(session: session), let record = read.record, !read.damaged else {
            return false
        }
        return record.echoMask == echoMaskIdentity(session: session)
    }

    /// Whether a meeting's transcript files are what a finished rewrite left for the title it shows (§4.17).
    public enum FilesState: Sendable, Equatable {
        /// No transcript file and no transcript: nothing to bring up to date.
        case none
        /// Every file is the one the record says was written last (no rewrite left halfway), and transcript.md is
        /// headed by the meeting's title.
        case current
        /// Out of date: no file although there is a transcript, the record is missing, damaged, from a newer build or
        /// left mid-write (`pending`), a file is missing or not the one it records, or the heading is another title.
        case stale
    }

    /// The state of the transcript files, derived from the files themselves each time (whoever wrote them: a rename,
    /// Review, a summary, a command in Terminal), for a meeting titled `title` (`MeetingNaming.title`). Nothing is
    /// remembered between calls; `TranscriptFilesCache` saves reading unchanged files again.
    ///
    /// transcript.json must be of the current transcript (`transcriptID`): files left from an earlier one (a new one
    /// saved, the rewrite not done) are out of date. `name`, when given, is the manifest's name, which transcript.json
    /// records (`session.name`): a rename that changed only the name, not the title shown, is out of date until the
    /// files are rewritten too.
    public static func filesState(session: URL, title: String, name: String? = nil) -> FilesState {
        // No file: nothing to bring up to date only without a transcript; a meeting with one has its files written
        // (one missing them, a rewrite that failed before its first file, is out of date).
        guard hasTranscriptFiles(session: session) else {
            return (try? SessionArchive.currentTranscriptID(at: session)) != nil ? .stale : .none
        }
        guard let read = try? readRecordChecked(session: session), let record = read.record, !read.damaged,
              record.pending == nil else { return .stale }
        // Written with the acoustic echo mask the labels show now (§5.11): one saved, replaced or dropped since makes
        // them out of date.
        guard record.echoMask == echoMaskIdentity(session: session) else { return .stale }
        var markdown: Data?
        for format in formats {
            guard let data = try? AtomicFile.readIfPresent(SessionPaths.export(format.rawValue, in: session),
                                                           maxBytes: maxExportBytes),
                  record.files[fileName(format)] == sha256(data) else { return .stale }
            if format == .md { markdown = data }
            if format == .json {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                // Of the current transcript (a new one saved by a final transcript or a recovery that stopped before
                // the rewrite leaves files of the earlier one).
                guard let transcriptID = try? SessionArchive.currentTranscriptID(at: session),
                      object?["transcriptID"] as? String == transcriptID else { return .stale }
                if let name {
                    guard (object?["session"] as? [String: Any])?["name"] as? String == name else { return .stale }
                }
            }
        }
        guard let markdown else { return .stale }
        let firstLine = String(decoding: markdown.prefix { $0 != 0x0A }, as: UTF8.self)
        return firstLine == TranscriptExporter.markdownHeading(title) ? .current : .stale
    }

    /// Whether the transcript files are exactly what a rewrite with the saved speaker labels (and these people's
    /// names, Remember voices and own name) would write now: the check that a Review's failed rewrite
    /// (`PendingExports`) was made up for by another writer since. Renders every format; false when anything cannot
    /// be read.
    public static func filesMatchLabels(session: URL, profileNames: [String: String], applyRecognition: Bool,
                                        selfName: String) -> Bool {
        do {
            let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: profileNames,
                                                           applyRecognition: applyRecognition)
            for entry in try renderAll(exportDocument(snapshot, selfName: selfName)) {
                guard let existing = try AtomicFile.readIfPresent(SessionPaths.export(entry.format.rawValue,
                                                                                      in: session),
                                                                  maxBytes: maxExportBytes),
                      existing == entry.data else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    /// Whether any transcript file this build writes (Markdown, JSON, text) is in the session's exports.
    public static func hasTranscriptFiles(session: URL) -> Bool {
        formats.contains { FileManager.default.fileExists(atPath: SessionPaths.export($0.rawValue, in: session).path) }
    }

    /// Whether exports/.generated.json is there and can be read as a record of what was generated: false when it is
    /// missing or damaged (a regeneration then knows existing files only by what they hold). One a newer Voice is
    /// Local wrote throws `unavailable`; one that cannot be read now throws its error.
    static func hasUsableRecord(session: URL) throws -> Bool {
        let read = try readRecordChecked(session: session)
        return read.record != nil && !read.damaged
    }

    /// nil when no export was ever generated here; an empty record when the file is damaged.
    private static func readRecord(session: URL) throws -> GeneratedRecord? {
        try readRecordChecked(session: session).record
    }

    /// `readRecord`, and whether the file was damaged (the record is then empty).
    private static func readRecordChecked(session: URL) throws -> (record: GeneratedRecord?, damaged: Bool) {
        let name = "exports/.generated.json"
        guard let data = try AtomicFile.readIfPresent(SessionPaths.generatedExports(session), maxBytes: 1 << 20) else {
            return (nil, false)
        }
        do {
            let record = try SessionFiles.decode(GeneratedRecord.self, from: data, current: 1, name: name)
            guard record.isValid else { throw HolosError.invalidInput("\(name) holds an entry this build cannot use.") }
            return (record, false)
        } catch let error where SessionFiles.isDamage(error) {
            log.error("\(name, privacy: .public) is damaged; every edited export will be moved aside")
            return (GeneratedRecord(files: [:]), true)
        }
    }

    /// The speaker-less exports `saveTranscript` wrote for the current transcript, or nil when it cannot be read.
    private static func legacyExports(session: URL, snapshot: SpeakerSessionSnapshot) -> [String: Data]? {
        do {
            let currentID = try SessionArchive.currentTranscriptID(at: session)
            let transcript = currentID == snapshot.transcript.id
                ? snapshot.transcript : try SessionFiles.currentTranscript(session: session)
            return transcript.map { SessionArchive.legacyExports(for: $0, name: snapshot.manifest.name) }
        } catch {
            log.error("Cannot read the current transcript to recognize older exports: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Copies `contents` to a new `exports/edited-<YYYYMMDD-HHMMSS>.<ext>` and returns its URL. The caller then
    /// replaces the original, so the edit is kept whether or not a crash comes in between.
    private static func moveAside(_ contents: Data, format: ExportFormat, session: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        for attempt in 1...1_000 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let url = SessionPaths.exports(session)
                .appendingPathComponent("edited-\(stamp)\(suffix).\(format.rawValue)", isDirectory: false)
            guard try AtomicFile.openForReading(url) == nil else { continue }
            try AtomicFile.create(contents, at: url, permissions: editedPermissions)
            return url
        }
        throw HolosError.io("Cannot find a free name to keep the edited transcript.\(format.rawValue).")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
