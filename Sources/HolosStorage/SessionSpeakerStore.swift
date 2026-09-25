import Foundation
import Darwin
import os
import HolosCore

/// The speaker edit journal as read from `speakers/edits.jsonl`.
public struct EditJournal: Sendable, Equatable {
    public var edits: [SpeakerEdit]
    /// The file does not end with "\n"; the partial line was skipped.
    public var tornTail: Bool
    /// Complete lines skipped because they are corrupt or have a newer schemaVersion.
    public var unreadableLines: Int

    public init(edits: [SpeakerEdit] = [], tornTail: Bool = false, unreadableLines: Int = 0) {
        self.edits = edits; self.tornTail = tornTail; self.unreadableLines = unreadableLines
    }

    /// Every line was read: no torn tail and no unreadable line. A projection built from an incomplete journal may
    /// miss a link, a rejection, or a reassignment, so nothing learns a voice or uses recognition from it.
    public var isComplete: Bool { unreadableLines == 0 && !tornTail }
}

/// Speaker files inside a session folder (docs/meeting-design.md §2.1): immutable runs, the head pointer,
/// the edit journal, per-run voice data, and recognition results.
///
/// Reads are lock-free (files are replaced atomically; the journal only grows).
/// Writes must run inside `SessionArchive.withSpeakerLock(at:)`.
public enum SessionSpeakerStore {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "storage")
    private static let maxRunBytes = 256 << 20
    private static let maxJournalBytes = 256 << 20

    // MARK: - Runs

    /// Publishes an immutable run (`AtomicFile.create`); creates speakers/runs lazily (0700).
    /// Refuses an invalid ID, a run of another session, or a run that already exists.
    public static func writeRun(_ run: DiarizationRun, session: URL) throws {
        try requireToken(run.id, "run ID")
        try requireToken(run.transcriptID, "transcript ID")
        try requireWritableSchema(run.schemaVersion, SchemaVersion.diarizationRun, "The run")
        try requireSameSession(run.sessionID, session: session, what: "The run")
        try ensureSpeakerFolder(SessionPaths.runs(session), session: session)
        let data = try HolosJSON.encoder().encode(run)
        try AtomicFile.create(data, at: SessionPaths.run(run.id, in: session))
    }

    public static func readRun(id: String, session: URL) throws -> DiarizationRun {
        try requireToken(id, "run ID")
        let url = SessionPaths.run(id, in: session)
        guard let data = try AtomicFile.readIfPresent(url, maxBytes: maxRunBytes) else {
            throw HolosError.invalidInput("Speaker run \(id) does not exist in this session.")
        }
        let run = try SchemaVersion.decode(DiarizationRun.self, from: data, current: SchemaVersion.diarizationRun,
                                           name: "speakers/runs/\(id).json")
        guard run.id == id, SessionArchive.validToken(run.transcriptID) else {
            throw HolosError.invalidInput("speakers/runs/\(id).json does not describe run \(id).")
        }
        try requireSameSession(run.sessionID, session: session, what: "speakers/runs/\(id).json")
        return run
    }

    /// IDs of every run file, sorted.
    public static func runIDs(session: URL) throws -> [String] {
        try SessionLockFile.requireSessionFolder(session)
        guard let entries = try AtomicFile.listFolder(SessionPaths.runs(session)) else { return [] }
        return entries.compactMap { entry -> String? in
            guard entry.type == S_IFREG, entry.name.hasSuffix(".json") else { return nil }
            let id = String(entry.name.dropLast(5))
            return SessionArchive.validToken(id) ? id : nil
        }.sorted()
    }

    // MARK: - Head

    public static func readHead(session: URL) throws -> SpeakerHead? {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.head(session), maxBytes: 64 << 10) else {
            return nil
        }
        let head = try SchemaVersion.decode(SpeakerHead.self, from: data, current: SchemaVersion.speakerHead,
                                            name: "speakers/head.json")
        try requireToken(head.runID, "run ID in speakers/head.json")
        return head
    }

    /// Replaces speakers/head.json. Refuses a runID with no run file.
    public static func writeHead(_ head: SpeakerHead, session: URL) throws {
        try requireToken(head.runID, "run ID")
        try requireWritableSchema(head.schemaVersion, SchemaVersion.speakerHead, "The speaker head")
        try SessionLockFile.requireSessionFolder(session)
        guard try AtomicFile.entryType(at: SessionPaths.run(head.runID, in: session)) == S_IFREG else {
            throw HolosError.invalidInput("Speaker run \(head.runID) does not exist in this session.")
        }
        try ensureSpeakerFolder(SessionPaths.speakers(session), session: session)
        try AtomicFile.writeJSON(head, to: SessionPaths.head(session))
    }

    // MARK: - Edit journal

    /// Missing file → empty journal. A partial last line is skipped and reported as `tornTail`; complete lines
    /// that are corrupt or have a newer schemaVersion are skipped and counted.
    public static func readEdits(session: URL) throws -> EditJournal {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.edits(session), maxBytes: maxJournalBytes) else {
            return EditJournal()
        }
        let (lines, torn) = JournalLines.split(data)
        var edits: [SpeakerEdit] = []
        var unreadable = 0
        let decoder = HolosJSON.decoder()
        for line in lines {
            guard let version = SchemaVersion.probe(line),
                  SchemaVersion.readable(version, current: SchemaVersion.speakerEdit),
                  let edit = try? decoder.decode(SpeakerEdit.self, from: line),
                  SessionArchive.validToken(edit.id), SessionArchive.validToken(edit.baseRunID),
                  edit.batchID.map(SessionArchive.validToken) ?? true else {
                unreadable += 1
                continue
            }
            edits.append(edit)
        }
        return EditJournal(edits: edits, tornTail: torn, unreadableLines: unreadable)
    }

    /// Repairs a torn tail first (copies the file to speakers/edits.torn-<UUID>.jsonl, truncates to the last
    /// newline), then appends all lines in one write and fsyncs.
    public static func appendEdits(_ edits: [SpeakerEdit], session: URL) throws {
        for edit in edits {
            try requireToken(edit.id, "edit ID")
            try requireToken(edit.baseRunID, "run ID")
            if let batchID = edit.batchID { try requireToken(batchID, "batch ID") }
            try requireWritableSchema(edit.schemaVersion, SchemaVersion.speakerEdit, "The speaker edit")
            guard !edit.source.isEmpty else { throw HolosError.invalidInput("A speaker edit needs a source.") }
        }
        guard !edits.isEmpty else { return }
        try ensureSpeakerFolder(SessionPaths.speakers(session), session: session)
        let journal = SessionPaths.edits(session)
        try repairTornTail(journal, session: session)
        var lines = Data()
        for edit in edits { lines.append(try HolosJSON.line(edit)) }
        try AtomicFile.append(lines, to: journal)
    }

    // MARK: - Recognition

    public static func readRecognition(runID: String, session: URL) throws -> RecognitionResult? {
        try requireToken(runID, "run ID")
        let name = "speakers/recognition/\(runID).json"
        guard let data = try AtomicFile.readIfPresent(SessionPaths.recognition(runID, in: session),
                                                      maxBytes: maxRunBytes) else { return nil }
        let result = try SchemaVersion.decode(RecognitionResult.self, from: data,
                                              current: SchemaVersion.recognition, name: name)
        guard result.runID == runID else { throw HolosError.invalidInput("\(name) does not describe run \(runID).") }
        return result
    }

    /// Replaces the recognition result of `result.runID`.
    public static func writeRecognition(_ result: RecognitionResult, session: URL) throws {
        try requireToken(result.runID, "run ID")
        try requireWritableSchema(result.schemaVersion, SchemaVersion.recognition, "The recognition result")
        try ensureSpeakerFolder(SessionPaths.recognitionDirectory(session), session: session)
        try AtomicFile.writeJSON(result, to: SessionPaths.recognition(result.runID, in: session))
    }

    /// Removes speakers/recognition/ and everything in it (Forget All Voices, PR10). Nothing to remove is not an
    /// error; a symbolic link or file in place of speakers/ is refused (`invalidInput`). Caller holds the speaker lock.
    public static func deleteRecognition(session: URL) throws {
        try SessionLockFile.requireSessionFolder(session)
        guard try AtomicFile.removeTree(["speakers", "recognition"], in: session) else { return }
        log.info("Deleted session recognition results")
    }

    // MARK: - Generation

    /// The session's speaker generation (docs/meeting-design.md §4.10, PR10): the head run ID and the edit journal's
    /// byte length, as "<runID>:<bytes>"; nil without a head. The journal only grows under one head, so any edit or
    /// relabel changes it. Read it under the speaker lock to compare it with a later reading.
    public static func generation(session: URL) throws -> String? {
        guard let head = try readHead(session: session) else { return nil }
        var length: Int64 = 0
        if let (parent, name) = try AtomicFile.openParentIfPresent(of: SessionPaths.edits(session)) {
            defer { Darwin.close(parent) }
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG else {
                    throw HolosError.invalidInput("speakers/edits.jsonl is not a regular file.")
                }
                length = Int64(info.st_size)
            } else if errno != ENOENT {
                throw HolosError.io("Cannot inspect speakers/edits.jsonl: \(AtomicFile.errnoText()).")
            }
        }
        return "\(head.runID):\(length)"
    }

    // MARK: - Voice data (biometric; only while "Remember voices" is on)

    public static func readVoiceData(runID: String, session: URL) throws -> SessionVoiceData? {
        try requireToken(runID, "run ID")
        let name = "speakers/voice/\(runID).json"
        guard let data = try AtomicFile.readIfPresent(SessionPaths.voiceData(runID, in: session),
                                                      maxBytes: maxRunBytes) else { return nil }
        let voice = try SchemaVersion.decode(SessionVoiceData.self, from: data,
                                             current: SchemaVersion.voiceData, name: name)
        guard voice.runID == runID else { throw HolosError.invalidInput("\(name) does not describe run \(runID).") }
        try requireSameSession(voice.sessionID, session: session, what: name)
        return voice
    }

    /// Replaces; creates speakers/voice (0700) with isExcludedFromBackup = true.
    public static func writeVoiceData(_ data: SessionVoiceData, session: URL) throws {
        try requireToken(data.runID, "run ID")
        try requireWritableSchema(data.schemaVersion, SchemaVersion.voiceData, "The voice data")
        try requireSameSession(data.sessionID, session: session, what: "The voice data")
        try ensureSpeakerFolder(SessionPaths.voiceDirectory(session), session: session, excludeFromBackup: true)
        try AtomicFile.writeJSON(data, to: SessionPaths.voiceData(data.runID, in: session))
    }

    /// Removes speakers/voice/ and everything in it. Nothing to remove is not an error. Refuses
    /// (`invalidInput`) when speakers/ is a symbolic link or a file, so the delete never leaves the session.
    public static func deleteVoiceData(session: URL) throws {
        try SessionLockFile.requireSessionFolder(session)
        guard try AtomicFile.removeTree(["speakers", "voice"], in: session) else { return }
        log.info("Deleted session voice data")
    }

    // MARK: - Forgetting

    /// The run IDs of the `<runID>.json` files in speakers/voice/, sorted, and whether that folder holds anything
    /// else (a leftover temporary file, a link, a folder), which a forget cannot check for a person. ([], false)
    /// without the folder. A listing error is thrown.
    public static func voiceDataFiles(session: URL) throws -> (runIDs: [String], other: Bool) {
        try speakerFiles(in: SessionPaths.voiceDirectory(session), session: session)
    }

    /// Like `voiceDataFiles`, for speakers/recognition/.
    public static func recognitionFiles(session: URL) throws -> (runIDs: [String], other: Bool) {
        try speakerFiles(in: SessionPaths.recognitionDirectory(session), session: session)
    }

    /// For a forget in a session whose manifest cannot be read, so its speakers cannot be checked for a person:
    /// removes speakers/voice/ and, with `recognition`, speakers/recognition/. Holds the speaker lock when the folder
    /// has a `manifest.json` file; without one the lock cannot be taken, and no Holos process can take it to write
    /// speaker files there either. Returns whether anything was removed. Refuses (`invalidInput`) a symbolic link or
    /// file in place of the session folder or speakers/.
    public static func purgeVoiceFolders(session: URL, recognition: Bool) throws -> Bool {
        let purge = { () throws -> Bool in
            try SessionLockFile.requireSessionFolder(session)
            var removed = try AtomicFile.removeTree(["speakers", "voice"], in: session)
            if recognition { removed = try AtomicFile.removeTree(["speakers", "recognition"], in: session) || removed }
            return removed
        }
        guard try AtomicFile.entryType(at: SessionPaths.manifest(session)) == S_IFREG else { return try purge() }
        return try SessionArchive.withSpeakerLock(at: session, purge)
    }

    /// Removes the leftovers of an interrupted atomic write from a meeting's `speakers/recognition` folder:
    /// regular files named `.<token>.tmp`, which `AtomicFile` publishes through and unlinks itself, but which a
    /// kill between their fsync and their rename leaves behind. Nothing else clears that folder, so a caller that
    /// refuses to act while it holds an entry it does not know would otherwise wait for one for ever. The caller
    /// holds the meeting's speaker lock, so no recognition write is in flight and such a file belongs to nobody.
    /// Returns whether anything was removed.
    @discardableResult
    public static func purgeRecognitionLeftovers(session: URL) throws -> Bool {
        try SessionLockFile.requireSessionFolder(session)
        let folder = SessionPaths.recognitionDirectory(session)
        guard let entries = try AtomicFile.listFolder(folder) else { return false }
        var removed = false
        for entry in entries where entry.type == S_IFREG && isAtomicWriteLeftover(entry.name) {
            _ = try AtomicFile.removeTree(["speakers", "recognition", entry.name], in: session)
            removed = true
        }
        return removed
    }

    /// `.<token>.tmp`, the name `AtomicFile` gives the file it writes before renaming it into place.
    static func isAtomicWriteLeftover(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        return SessionArchive.validToken(String(name.dropFirst().dropLast(4)))
    }

    private static func speakerFiles(in folder: URL, session: URL) throws -> (runIDs: [String], other: Bool) {
        try SessionLockFile.requireSessionFolder(session)
        guard let entries = try AtomicFile.listFolder(folder) else { return ([], false) }
        var runIDs: [String] = []
        var other = false
        for entry in entries where entry.name != ".DS_Store" {
            let id = entry.name.hasSuffix(".json") ? String(entry.name.dropLast(5)) : ""
            if entry.type == S_IFREG, SessionArchive.validToken(id) {
                runIDs.append(id)
            } else {
                other = true
            }
        }
        return (runIDs.sorted(), other)
    }

    // MARK: - Private

    private static func requireToken(_ value: String, _ what: String) throws {
        guard SessionArchive.validToken(value) else {
            throw HolosError.invalidInput("Invalid \(what): use letters, digits, '-' or '_'.")
        }
    }

    private static func requireWritableSchema(_ version: Int, _ current: Int, _ what: String) throws {
        guard version == current else {
            throw HolosError.invalidInput("\(what) has schema version \(version); this Holos writes version \(current).")
        }
    }

    private static func requireSameSession(_ sessionID: String, session: URL, what: String) throws {
        let manifest = try SessionArchive.readManifest(at: session)
        guard sessionID == manifest.id else {
            throw HolosError.invalidInput("\(what) belongs to another session.")
        }
    }

    /// Creates `folder` (speakers/ or a folder under it) and speakers/ itself as 0700 in one `openat`/`mkdirat`
    /// chain from the session folder's descriptor, refusing a symbolic link or file at each level, even one
    /// swapped in during the call. Nothing is checked by path first. With `excludeFromBackup`, the backup exclusion
    /// is set on the descriptor that chain returned, so a link swapped in afterwards never redirects it.
    ///
    /// The paths are compared in `AtomicFile.canonicalComponents` form, which never looks at the file system:
    /// `standardizedFileURL` would drop a leading "/private" when the shorter path exists, which it does for the
    /// session but not yet for the folder, and a session and folder named one with "/private" and one without would
    /// not match at all.
    private static func ensureSpeakerFolder(_ folder: URL, session: URL, excludeFromBackup: Bool = false) throws {
        let sessionComponents = AtomicFile.canonicalComponents(session)
        let folderComponents = AtomicFile.canonicalComponents(folder)
        guard folderComponents.count > sessionComponents.count,
              Array(folderComponents.prefix(sessionComponents.count)) == sessionComponents else {
            throw HolosError.invalidInput("\(folder.lastPathComponent) is not a folder of this session.")
        }
        let sessionFD = try SessionLockFile.openSessionFolder(session)
        defer { Darwin.close(sessionFD) }
        guard let fd = try AtomicFile.openFolder(Array(folderComponents.dropFirst(sessionComponents.count)),
                                                 in: sessionFD, baseURL: session, create: true) else {
            throw HolosError.io("Cannot create folder \(folder.lastPathComponent).")
        }
        defer { Darwin.close(fd) }
        if excludeFromBackup {
            beforeBackupExclusion?(folder)
            try Self.excludeFromBackup(fd, name: folder.lastPathComponent)
        }
    }

    private static func repairTornTail(_ journal: URL, session: URL) throws {
        guard let data = try AtomicFile.readIfPresent(journal, maxBytes: maxJournalBytes),
              let last = data.last, last != 0x0A else { return }
        try AtomicFile.create(data, at: SessionPaths.tornEditsBackup(session))
        let keep = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        try AtomicFile.truncate(journal, to: Int64(keep))
        log.notice("Repaired a torn speaker edit journal; dropped \(data.count - keep, privacy: .public) bytes after a backup")
    }

    /// The extended attribute behind `URLResourceValues.isExcludedFromBackup`, and the value Foundation writes
    /// for it: a binary property list holding the string "com.apple.backupd".
    static let backupExclusionAttribute = "com.apple.metadata:com_apple_backup_excludeItem"
    static let backupExclusionValue: Data = {
        // Encoding a constant string cannot fail.
        (try? PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0))
            ?? Data()
    }()

    /// Marks the open folder `fd` (named `name`) as excluded from backups with `fsetxattr`, the same attribute
    /// and value `URLResourceValues.isExcludedFromBackup = true` writes, but on the descriptor, never by path.
    static func excludeFromBackup(_ fd: Int32, name: String) throws {
        let result = backupExclusionValue.withUnsafeBytes { bytes in
            fsetxattr(fd, backupExclusionAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else {
            throw HolosError.io("Cannot exclude \(name) from backups: \(AtomicFile.errnoText()).")
        }
    }

    /// Test hook: while set (a task-local value), called with the folder's URL after `ensureSpeakerFolder` has
    /// opened it and just before it sets the backup exclusion, so tests can swap the folder for a link.
    @TaskLocal static var beforeBackupExclusion: (@Sendable (URL) -> Void)? = nil
}

/// Splits an append-only journal into complete lines.
enum JournalLines {
    /// Complete "\n"-terminated lines (without the newline, each rebased to index 0), and whether a partial
    /// line follows the last newline.
    static func split(_ data: Data) -> (lines: [Data], tornTail: Bool) {
        guard !data.isEmpty else { return ([], false) }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        // The piece after the final newline is empty when the file ends with "\n", else a torn line.
        let tail = parts.removeLast()
        return (parts.map { Data($0) }, !tail.isEmpty)
    }
}
