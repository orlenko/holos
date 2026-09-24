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
        try requireWritableSchema(run.schemaVersion, "The run")
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
        let run = try AtomicFile.decode(DiarizationRun.self, from: data, name: "speakers/runs/\(id).json")
        try SchemaVersion.check(run.schemaVersion, file: "speakers/runs/\(id).json")
        guard run.id == id, SessionArchive.validToken(run.transcriptID) else {
            throw HolosError.invalidInput("speakers/runs/\(id).json does not describe run \(id).")
        }
        return run
    }

    /// IDs of every run file, sorted.
    public static func runIDs(session: URL) throws -> [String] {
        try SessionLockFile.requireSessionFolder(session)
        let folder = SessionPaths.runs(session)
        guard try folderExists(folder) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return names.compactMap { name -> String? in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard SessionArchive.validToken(id), isRegularFile(folder.appendingPathComponent(name)) else { return nil }
            return id
        }.sorted()
    }

    // MARK: - Head

    public static func readHead(session: URL) throws -> SpeakerHead? {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.head(session), maxBytes: 64 << 10) else {
            return nil
        }
        let head = try AtomicFile.decode(SpeakerHead.self, from: data, name: "speakers/head.json")
        try SchemaVersion.check(head.schemaVersion, file: "speakers/head.json")
        try requireToken(head.runID, "run ID in speakers/head.json")
        return head
    }

    /// Replaces speakers/head.json. Refuses a runID with no run file.
    public static func writeHead(_ head: SpeakerHead, session: URL) throws {
        try requireToken(head.runID, "run ID")
        try requireWritableSchema(head.schemaVersion, "The speaker head")
        try SessionLockFile.requireSessionFolder(session)
        guard isRegularFile(SessionPaths.run(head.runID, in: session)) else {
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
            guard let probe = try? decoder.decode(SchemaProbe.self, from: line),
                  probe.schemaVersion == SchemaVersion.current,
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
            try requireWritableSchema(edit.schemaVersion, "The speaker edit")
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
        let result = try AtomicFile.decode(RecognitionResult.self, from: data, name: name)
        try SchemaVersion.check(result.schemaVersion, file: name)
        guard result.runID == runID else { throw HolosError.invalidInput("\(name) does not describe run \(runID).") }
        return result
    }

    /// Replaces the recognition result of `result.runID`.
    public static func writeRecognition(_ result: RecognitionResult, session: URL) throws {
        try requireToken(result.runID, "run ID")
        try requireWritableSchema(result.schemaVersion, "The recognition result")
        try ensureSpeakerFolder(SessionPaths.recognitionDirectory(session), session: session)
        try AtomicFile.writeJSON(result, to: SessionPaths.recognition(result.runID, in: session))
    }

    // MARK: - Voice data (biometric; only while "Remember voices" is on)

    public static func readVoiceData(runID: String, session: URL) throws -> SessionVoiceData? {
        try requireToken(runID, "run ID")
        let name = "speakers/voice/\(runID).json"
        guard let data = try AtomicFile.readIfPresent(SessionPaths.voiceData(runID, in: session),
                                                      maxBytes: maxRunBytes) else { return nil }
        let voice = try AtomicFile.decode(SessionVoiceData.self, from: data, name: name)
        try SchemaVersion.check(voice.schemaVersion, file: name)
        guard voice.runID == runID else { throw HolosError.invalidInput("\(name) does not describe run \(runID).") }
        return voice
    }

    /// Replaces; creates speakers/voice (0700) with isExcludedFromBackup = true.
    public static func writeVoiceData(_ data: SessionVoiceData, session: URL) throws {
        try requireToken(data.runID, "run ID")
        try requireWritableSchema(data.schemaVersion, "The voice data")
        try requireSameSession(data.sessionID, session: session, what: "The voice data")
        let folder = SessionPaths.voiceDirectory(session)
        try ensureSpeakerFolder(folder, session: session)
        try excludeFromBackup(folder)
        try AtomicFile.writeJSON(data, to: SessionPaths.voiceData(data.runID, in: session))
    }

    /// Removes speakers/voice/ and everything in it. Nothing to remove is not an error.
    public static func deleteVoiceData(session: URL) throws {
        try SessionLockFile.requireSessionFolder(session)
        let folder = SessionPaths.voiceDirectory(session)
        var info = stat()
        guard lstat(folder.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw HolosError.io("Cannot inspect speakers/voice: \(AtomicFile.errnoText()).")
        }
        do {
            // Removes a symlink itself, never its target.
            try FileManager.default.removeItem(at: folder)
        } catch {
            throw HolosError.io("Cannot delete voice data: \(error.localizedDescription)")
        }
        try AtomicFile.syncDirectory(SessionPaths.speakers(session))
        log.info("Deleted session voice data")
    }

    // MARK: - Private

    private struct SchemaProbe: Decodable {
        var schemaVersion: Int
    }

    private static func requireToken(_ value: String, _ what: String) throws {
        guard SessionArchive.validToken(value) else {
            throw HolosError.invalidInput("Invalid \(what): use letters, digits, '-' or '_'.")
        }
    }

    private static func requireWritableSchema(_ version: Int, _ what: String) throws {
        guard version == SchemaVersion.current else {
            throw HolosError.invalidInput("\(what) has schema version \(version); this Holos writes version \(SchemaVersion.current).")
        }
    }

    private static func requireSameSession(_ sessionID: String, session: URL, what: String) throws {
        let manifest = try SessionArchive.readManifest(at: session)
        guard sessionID == manifest.id else {
            throw HolosError.invalidInput("\(what) belongs to another session.")
        }
    }

    /// Creates `folder` (a folder under speakers/) and speakers/ itself as 0700, refusing symlinks at each level.
    private static func ensureSpeakerFolder(_ folder: URL, session: URL) throws {
        try SessionLockFile.requireSessionFolder(session)
        let speakers = SessionPaths.speakers(session)
        try AtomicFile.ensurePrivateDirectory(speakers)
        if folder.standardizedFileURL.path != speakers.standardizedFileURL.path {
            try AtomicFile.ensurePrivateDirectory(folder)
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

    private static func excludeFromBackup(_ folder: URL) throws {
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            throw HolosError.io("Cannot exclude voice data from backups: \(error.localizedDescription)")
        }
    }

    private static func folderExists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw HolosError.io("Cannot inspect \(url.lastPathComponent): \(AtomicFile.errnoText()).")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw HolosError.invalidInput("\(url.lastPathComponent) must be a folder, not a file or a symbolic link.")
        }
        return true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
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
