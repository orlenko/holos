import Darwin
import Foundation
import HolosCore
import os

/// Contents of `audio-deleted.json` (docs/meeting-design.md §2.1, §4.13): written by Delete Audio, so the chunks the
/// manifest still lists are known to be absent on purpose.
public struct AudioDeletedRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var deletedAt: Date
    /// Chunks the manifest listed when the audio was deleted.
    public var chunkCount: Int
    /// Seconds of audio deleted: the longest track's total chunk duration.
    public var seconds: Double

    public init(schemaVersion: Int = 1, deletedAt: Date = Date(), chunkCount: Int, seconds: Double) {
        self.schemaVersion = schemaVersion; self.deletedAt = deletedAt
        self.chunkCount = chunkCount; self.seconds = seconds
    }
}

extension SessionManifest {
    /// Seconds of audio saved: the longest track's `audioSeconds`.
    public var savedSeconds: Double {
        Set(chunks.map(\.track)).map { audioSeconds(track: $0) }.max() ?? 0
    }

    /// Seconds of `track`'s audio at or after session time `from`: the union of its chunks' intervals, so time that
    /// overlapping chunks (an older archive) both hold counts once, as `TrackReplayer` feeds it once. Chunks without
    /// finite times, or that end before they start, count as nothing.
    public func audioSeconds(track: String, from: Double = -.infinity) -> Double {
        let intervals = chunks
            .filter { $0.track == track && $0.start.isFinite && $0.end.isFinite }
            .map { (start: max($0.start, from), end: $0.end) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var total = 0.0
        var reached = -Double.infinity
        for interval in intervals where interval.end > reached {
            total += interval.end - max(interval.start, reached)
            reached = interval.end
        }
        return total
    }
}

/// Delete Audio and Delete Meeting (docs/meeting-design.md §4.13). Both run under the caller's processing lease and
/// hold the session's writer lock from the start to the end, so they refuse while a recorder holds it and no
/// recorder can reopen the session (`SessionArchive.open(at:)`, which does not consult the lease) while they run.
/// Locks are taken in the order processing → writer → speakers.
///
/// Every delete inside the session folder goes through `AtomicFile.removeTree`, which opens each folder on the way
/// with O_NOFOLLOW: a symbolic link in place of `audio/`, `derived/`, or `speakers/` is refused (or, as the last
/// component, removed itself), never followed out of the session.
public enum SessionDeletion {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "storage")

    /// `~/Library/Logs/Holos`, where the app writes each recorder child's output (`recorder-<SESSION-UUID>.log`).
    public static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Holos", isDirectory: true)
    }

    /// Moves `url` to the Trash with `FileManager.trashItem`.
    public static func systemTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// §4.13. Requires the lease and no writer.
    ///
    /// Removes the session's audio for good: `speakers/voice/` (under the speaker lock), then writes
    /// `audio-deleted.json`, then removes `derived/` and `audio/`. The manifest, event journal, transcripts, speaker
    /// runs, edits, recognition results, and exports stay. The marker is written before any audio goes, so a failure
    /// part-way never leaves chunks missing without it; calling again finishes the job and keeps the first marker.
    ///
    /// Throws `HolosError.invalidInput` when the lease is released or belongs to another session, or the manifest
    /// cannot be read, and `HolosError.unavailable` while a recorder holds the writer lock (for more than 1 s) or
    /// another process holds the speaker lock for more than 2 s.
    public static func deleteAudio(session: URL, lease: ProcessingLease) throws {
        // The lease stays locked, even across a concurrent `release()`, until the deletion ends.
        try lease.beginUse(for: session)
        defer { lease.endUse() }
        let writer = try holdWriterLock(session, action: "deleting its audio")
        defer { SessionLockFile.unlockAndClose(writer) }
        let manifest = try SessionArchive.readManifest(at: session)

        // Voice data is only for evaluation sessions; it goes first and is never left behind by a later failure.
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.deleteVoiceData(session: session)
        }
        let marker = SessionPaths.audioDeleted(session)
        if try AtomicFile.entryType(at: marker) != S_IFREG {
            try AtomicFile.writeJSON(AudioDeletedRecord(chunkCount: manifest.chunks.count,
                                                        seconds: manifest.savedSeconds), to: marker)
        }
        try AtomicFile.removeTree(["derived"], in: session)
        try AtomicFile.removeTree(["audio"], in: session)
        log.notice("Session \(manifest.id, privacy: .public): deleted the audio of \(manifest.chunks.count, privacy: .public) chunks")
    }

    /// §4.13. `trash` defaults to FileManager.trashItem; `logDirectory` to ~/Library/Logs/Holos (tests inject both).
    ///
    /// Removes `speakers/voice/` first, so no voice data waits in the Trash, then hands the session folder to
    /// `trash`, then deletes `<logDirectory>/recorder-<SESSION-UUID>.log`. The speaker lock is held from the voice
    /// data through `trash`, so a speaker edit or export regeneration (which take only that lock) either finishes
    /// before the folder moves or is refused until it has. The session ID comes from the manifest, or from the folder
    /// name when the manifest cannot be read, so a damaged session can be deleted too. A log that cannot be deleted
    /// is logged, not thrown: the meeting is already in the Trash by then.
    ///
    /// Throws, with the folder left in place, when the lease is released or belongs to another session, while a
    /// recorder holds the writer lock, when the speaker lock stays busy, or when `trash` fails.
    public static func moveToTrash(session: URL, lease: ProcessingLease,
                                   logDirectory: URL = SessionDeletion.defaultLogDirectory,
                                   trash: (URL) throws -> Void = SessionDeletion.systemTrash) throws {
        try lease.beginUse(for: session)
        defer { lease.endUse() }
        let writer = try holdWriterLock(session, action: "deleting it")
        defer { SessionLockFile.unlockAndClose(writer) }
        let sessionID = self.sessionID(of: session)
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.deleteVoiceData(session: session)
            try trash(session)
        }
        log.notice("Session \(sessionID ?? "unknown", privacy: .public): moved to the Trash")
        if let sessionID { removeRecorderLog(sessionID: sessionID, in: logDirectory) }
    }

    /// Whether `session` is a folder with no `manifest.json` file, which cannot take a processing lease: a crash
    /// between `SessionArchive.create`'s mkdir and its manifest write leaves one. The catalog lists it as damaged;
    /// `moveToTrashWithoutManifest` deletes it.
    public static func lacksManifest(session: URL) throws -> Bool {
        let folder = try SessionLockFile.openSessionFolder(session)
        defer { Darwin.close(folder) }
        return try !hasManifest(inFolder: folder)
    }

    /// Delete Meeting for a `.holos` folder with no `manifest.json` file (`lacksManifest`), which
    /// `acquireProcessingLease` refuses. Takes `.processing.lock` and then `.writer.lock` itself (each retried for up
    /// to 1 s, the order maintenance uses), so no Holos command or recorder works in the folder meanwhile; checks
    /// again that it has no manifest, takes `.speakers.lock` (up to 2 s) and holds it through `trash`, removes
    /// `speakers/voice/`, hands the folder to `trash`, and deletes the recorder log of the `<UUID>` the folder is
    /// named after.
    ///
    /// Throws `HolosError.invalidInput` for a folder not named `<something>.holos` or one that has a manifest (delete
    /// it with `moveToTrash(session:lease:)`), and `HolosError.unavailable` when any of the locks stays held.
    public static func moveToTrashWithoutManifest(session: URL,
                                                  logDirectory: URL = SessionDeletion.defaultLogDirectory,
                                                  trash: (URL) throws -> Void = SessionDeletion.systemTrash) throws {
        guard session.standardizedFileURL.pathExtension == "holos" else {
            throw HolosError.invalidInput("\(session.lastPathComponent) is not a .holos folder.")
        }
        let folder = try SessionLockFile.openSessionFolder(session)
        defer { Darwin.close(folder) }
        guard let processing = try SessionLockFile.acquire(SessionLockFile.processing, inFolder: folder,
                                                           timeout: .seconds(1)) else {
            throw HolosError.unavailable("Another Holos process is processing this session.")
        }
        defer { SessionLockFile.unlockAndClose(processing) }
        guard let writer = try SessionLockFile.acquire(SessionLockFile.writer, inFolder: folder,
                                                       timeout: .seconds(1)) else {
            throw HolosError.unavailable("This meeting is still recording. Stop it before deleting it.")
        }
        defer { SessionLockFile.unlockAndClose(writer) }
        guard try !hasManifest(inFolder: folder) else {
            throw HolosError.invalidInput("\(session.lastPathComponent) has a manifest; delete it as a session.")
        }
        let sessionID = self.sessionID(of: session)
        // Held through `trash`, as in `moveToTrash`, so a holder of the speaker lock never works in a folder that
        // is being moved.
        guard let speakers = try SessionLockFile.acquire(SessionLockFile.speakers, inFolder: folder,
                                                         timeout: .seconds(2)) else {
            throw HolosError.unavailable("Speaker labels are being saved by another Holos window or command; try again.")
        }
        defer { SessionLockFile.unlockAndClose(speakers) }
        try SessionSpeakerStore.deleteVoiceData(session: session)
        try trash(session)
        log.notice("Session \(sessionID ?? "unknown", privacy: .public): folder without a manifest moved to the Trash")
        if let sessionID { removeRecorderLog(sessionID: sessionID, in: logDirectory) }
    }

    // MARK: - Private

    /// Whether the open session folder holds a regular `manifest.json` (what `acquireProcessingLease` requires).
    private static func hasManifest(inFolder folder: Int32) throws -> Bool {
        var info = stat()
        guard fstatat(folder, "manifest.json", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw HolosError.io("Cannot inspect manifest.json: \(AtomicFile.errnoText(code)).")
        }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Takes the session's writer lock, retried for up to 1 s (as `SessionArchive.open(at:)` does, so a concurrent
    /// `isActive` probe cannot make it fail), and returns the locked descriptor for the caller to unlock when the
    /// deletion ends. Holding it, not probing it, keeps a recorder from reopening the session meanwhile.
    private static func holdWriterLock(_ session: URL, action: String) throws -> Int32 {
        guard let fd = try SessionLockFile.acquire(SessionLockFile.writer, in: session, timeout: .seconds(1)) else {
            throw HolosError.unavailable("This meeting is still recording. Stop it before \(action).")
        }
        return fd
    }

    /// The manifest's session ID, else the folder's `<UUID>` when it names one; nil otherwise.
    private static func sessionID(of session: URL) -> String? {
        if let manifest = try? SessionArchive.readManifest(at: session) { return manifest.id }
        let name = session.standardizedFileURL.lastPathComponent
        guard name.hasSuffix(".holos"), let uuid = UUID(uuidString: String(name.dropLast(6))) else { return nil }
        return uuid.uuidString
    }

    /// Deletes `recorder-<sessionID>.log` from `directory` without following a symbolic link; nothing when either is
    /// missing.
    private static func removeRecorderLog(sessionID: String, in directory: URL) {
        guard SessionArchive.validToken(sessionID) else { return }
        do {
            guard try AtomicFile.entryType(at: directory) == S_IFDIR else { return }
            if try AtomicFile.removeTree(["recorder-\(sessionID).log"], in: directory) {
                log.info("Session \(sessionID, privacy: .public): deleted the recorder log")
            }
        } catch {
            log.error("Session \(sessionID, privacy: .public): cannot delete the recorder log: \(error.localizedDescription, privacy: .private)")
        }
    }
}
