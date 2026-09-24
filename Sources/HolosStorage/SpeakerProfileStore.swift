import Darwin
import Foundation
import HolosCore
import os

extension HolosPaths {
    /// `<supportRoot>/Speakers`: the people store (docs/meeting-design.md §2.2). Tests point `supportRoot` at a
    /// temporary folder (`HOLOS_SUPPORT_DIR`).
    public static var speakerProfiles: URL {
        supportRoot.appendingPathComponent("Speakers", isDirectory: true)
    }
}

/// One line of `forget-journal.jsonl` (docs/meeting-design.md §4.10). A forget first appends a `pending` tombstone
/// that lists what it removes, then updates the profile store, then appends a `stored` line for the same ID, then
/// cleans each affected session, then appends a `done` line; a crash anywhere leaves the tombstone for the next run
/// to finish.
///
/// The `stored` line is what tells a resumed forget which phase it is in. Without it the store write still has to
/// happen: it turns "Remember voices" off when the tombstone asked for that, and it sweeps every sample the scope
/// covers at that write, not only the IDs listed before the tombstone was written. With it, only the listed samples
/// are removed, so a forget that keeps failing on a meeting cannot undo the user turning remembering back on, or
/// take a sample learned since. The `stored` line also carries the person the store write found the forgotten
/// sample under (`profileID`), which a merge may have changed since the tombstone was written.
public struct ForgetRecord: Codable, Sendable, Equatable {
    public static let pending = "pending"
    public static let stored = "stored"
    public static let done = "done"
    public static let currentSchemaVersion = 1

    /// What is forgotten.
    public enum Kind: String, Codable, Sendable {
        /// One sample (`sampleIDs`) of one person (`profileID`).
        case sample
        /// A person and all their samples.
        case profile
        /// The samples learned from the meetings in `sessionIDs`.
        case session
        /// Every sample and every session's voice data; names stay.
        case all
        /// Not a forget: `profileID` was merged into `targetProfileID`, and the meetings that still name the person
        /// merged away are to name the one they were merged into. It rides in this journal because it needs the
        /// same thing a forget does: a record of unfinished work across the meetings, finished at the next launch.
        case merge
    }

    public var schemaVersion: Int
    public var id: String
    /// Nil on a `stored` or `done` line.
    public var kind: Kind?
    /// The person to clean the meetings of; on a `stored` line, the one the store write actually found.
    public var profileID: String?
    public var sampleIDs: [String]?
    public var sessionIDs: [String]?
    /// The store write of this tombstone's first run also turns "Remember voices" off. Absent (nil) in tombstones
    /// written by an earlier Holos, which is read as false, as those forgets did not ask for it either.
    public var turnRememberOff: Bool?
    /// `.merge` only: the person `profileID` was merged into.
    public var targetProfileID: String?
    public var state: String

    public init(schemaVersion: Int = ForgetRecord.currentSchemaVersion, id: String = UUID().uuidString, kind: Kind?,
                profileID: String? = nil, sampleIDs: [String]? = nil, sessionIDs: [String]? = nil,
                turnRememberOff: Bool? = nil, targetProfileID: String? = nil,
                state: String = ForgetRecord.pending) {
        self.schemaVersion = schemaVersion; self.id = id; self.kind = kind; self.profileID = profileID
        self.sampleIDs = sampleIDs; self.sessionIDs = sessionIDs; self.turnRememberOff = turnRememberOff
        self.targetProfileID = targetProfileID; self.state = state
    }

    /// The `stored` line for the tombstone `id`: its store write is done, and `profileID` is the person the
    /// meetings are to be cleaned of (for a `.sample` forget, the one the sample was found under).
    public static func stored(_ id: String, profileID: String? = nil) -> ForgetRecord {
        ForgetRecord(id: id, kind: nil, profileID: profileID, state: stored)
    }

    /// The `done` line for the tombstone `id`.
    public static func done(_ id: String) -> ForgetRecord { ForgetRecord(id: id, kind: nil, state: done) }
}

/// The global people store (docs/meeting-design.md §2.2, §4.10): `profiles.json` (0600) in a private folder
/// (0700) that is excluded from Time Machine, `profiles.lock`, and `forget-journal.jsonl` (0600).
///
/// Reads take no lock (`profiles.json` is replaced atomically). Every write is a read-modify-write under
/// `profiles.lock` (`update`), polled every 20 ms for up to 2 s; a read whose result is written elsewhere
/// (recognition results, forget clean-up) holds it through that write (`withLockedDatabase`). The lock is not
/// re-entrant: never call `update`, `withLockedDatabase`, or a journal method from inside either. When a caller also
/// needs a session's speaker lock, it takes that lock first (§1.7 order: speakers → profiles), and nothing takes a
/// speaker lock while holding `profiles.lock`.
public struct SpeakerProfileStore: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "storage")
    static let databaseName = "profiles.json"
    static let lockName = "profiles.lock"
    static let journalName = "forget-journal.jsonl"
    private static let maxDatabaseBytes = 64 << 20
    private static let maxJournalBytes = 64 << 20

    public let directory: URL

    public init(directory: URL = HolosPaths.speakerProfiles) {
        self.directory = directory
    }

    /// `profiles.json`.
    public var databaseURL: URL { directory.appendingPathComponent(Self.databaseName, isDirectory: false) }
    /// `forget-journal.jsonl`.
    public var forgetJournalURL: URL { directory.appendingPathComponent(Self.journalName, isDirectory: false) }

    // MARK: - Database

    /// The database; a missing file (or folder) gives an empty one with "Remember voices" off. A file written by a
    /// newer Holos is refused (`unavailable`); a damaged one (not JSON, or JSON that breaks a `validate` rule, such as
    /// a repeated ID) throws `invalidInput` and is never overwritten.
    public func load() throws -> SpeakerProfileDatabase {
        guard let data = try AtomicFile.readIfPresent(databaseURL, maxBytes: Self.maxDatabaseBytes) else {
            return SpeakerProfileDatabase()
        }
        let database = try SchemaVersion.decode(SpeakerProfileDatabase.self, from: data,
                                                current: SpeakerProfileDatabase.currentSchemaVersion,
                                                name: Self.databaseName)
        do {
            try Self.validate(database)
        } catch {
            Self.log.error("The people store is damaged and was not used")
            throw error
        }
        return database
    }

    /// Takes `profiles.lock` (2 s), reads the database (`load`, so a damaged one is refused even when `body` changes
    /// nothing), lets `body` change it, validates the result (`validate`), and writes it atomically when it changed.
    /// Nothing is written when the read, `body`, or the validation throws.
    ///
    /// When `body` changed the voice-sample population (a sample learned, refreshed, merged, or forgotten, or a
    /// model changed), the calibration is cleared in this same write
    /// (`SpeakerProfileDatabase.resetCalibrationIfSamplesChanged`): thresholds measured on other samples no longer
    /// keep their false-accept budget.
    public func update<T>(_ body: (inout SpeakerProfileDatabase) throws -> T) throws -> T {
        try withLock {
            var database = try load()
            let before = database
            let result = try body(&database)
            if database.resetCalibrationIfSamplesChanged(since: before) {
                Self.log.notice("The voice samples changed, so the recognition calibration was reset")
            }
            guard database != before else { return result }
            try Self.validate(database)
            try AtomicFile.writeJSON(database, to: databaseURL)
            Self.log.info("Saved the people store: \(database.profiles.count, privacy: .public) people, \(database.sampleCount, privacy: .public) voice samples")
            return result
        }
    }

    /// Takes `profiles.lock` (2 s), reads the database (`load`), and runs `body` with it while the lock is held;
    /// writes nothing to the store. For a caller that writes something else (a recognition result) from the people as
    /// they are: no store change can land between its read and its write, so a change is either seen or made after
    /// the write. A caller that also holds a session's speaker lock took that first (§1.7 order: speakers →
    /// profiles). `body` must not call `update`, `withLockedDatabase`, or a journal method (the lock is not
    /// re-entrant).
    public func withLockedDatabase<T>(_ body: (SpeakerProfileDatabase) throws -> T) throws -> T {
        try withLock { try body(try load()) }
    }

    /// The rules every saved database meets: schema version 1; calibrated thresholds pass
    /// `RecognitionThresholds.problem` (finite, in range, `likely ≤ possible`, a margin of 0 … 2, a non-negative
    /// minimum sample length), and a calibrated model comes only with thresholds and names its model; profile and
    /// sample IDs are valid tokens and unique; names are not blank; at most one `isSelf` profile; at most one sample
    /// per session per profile; a profile with samples names its embedding model, and its samples have a non-empty
    /// vector of finite values, finite, non-negative speech seconds, and a non-negative count of dropped turns. Every
    /// sample of one embedding model has the same dimension, across people as well as within one: two people whose
    /// samples name one model but hold vectors of different sizes cannot be compared (`VectorMath.cosineDistance`
    /// answers 2 for them, which would silently exclude the pair instead of reporting the damage).
    /// Throws `invalidInput` saying which rule failed.
    public static func validate(_ database: SpeakerProfileDatabase) throws {
        guard database.schemaVersion == SpeakerProfileDatabase.currentSchemaVersion else {
            throw HolosError.invalidInput("The people store has schema version \(database.schemaVersion); this Holos writes version \(SpeakerProfileDatabase.currentSchemaVersion).")
        }
        if let thresholds = database.calibratedThresholds, let problem = thresholds.problem {
            throw HolosError.invalidInput("The people store's calibrated thresholds are damaged: \(problem).")
        }
        if let model = database.calibratedModel {
            guard database.calibratedThresholds != nil, Self.validModel(model) else {
                throw HolosError.invalidInput("The people store's calibration is damaged.")
            }
        }
        var profileIDs = Set<String>()
        var sampleIDs = Set<String>()
        var selfCount = 0
        /// The vector size every sample of one embedding model has, from the first one seen.
        var dimensions: [EmbeddingModelID: Int] = [:]
        for profile in database.profiles {
            guard SessionArchive.validToken(profile.id), profileIDs.insert(profile.id).inserted else {
                throw HolosError.invalidInput("The people store has an invalid or repeated person ID.")
            }
            guard !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HolosError.invalidInput("Every person needs a name.")
            }
            if profile.isSelf { selfCount += 1 }
            var sessions = Set<String>()
            for sample in profile.samples {
                guard SessionArchive.validToken(sample.id), sampleIDs.insert(sample.id).inserted else {
                    throw HolosError.invalidInput("The people store has an invalid or repeated voice sample ID.")
                }
                guard SessionArchive.validToken(sample.sessionID), sessions.insert(sample.sessionID).inserted else {
                    throw HolosError.invalidInput("A person can have only one voice sample per meeting.")
                }
                guard let model = profile.embeddingModel, Self.validModel(model) else {
                    throw HolosError.invalidInput("A person with voice samples needs their embedding model.")
                }
                let values = sample.embedding.values
                guard !values.isEmpty, values.allSatisfy(\.isFinite),
                      sample.speechSeconds.isFinite, sample.speechSeconds >= 0, sample.droppedOutlierTurns >= 0 else {
                    throw HolosError.invalidInput("A voice sample is damaged.")
                }
                guard dimensions[model, default: values.count] == values.count else {
                    throw HolosError.invalidInput("Voice samples of one speaker model have different sizes.")
                }
                dimensions[model] = values.count
            }
        }
        guard selfCount <= 1 else {
            throw HolosError.invalidInput("Only one person can be marked as you.")
        }
    }

    /// An embedding model names its ID and revision.
    private static func validModel(_ model: EmbeddingModelID) -> Bool {
        !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Forget journal

    /// Appends one line to `forget-journal.jsonl` (0600) under `profiles.lock` and fsyncs it. After a torn last line
    /// the new line starts on a line of its own, so the torn part stays a separate damaged line.
    public func appendForgetRecord(_ record: ForgetRecord) throws {
        guard SessionArchive.validToken(record.id) else { throw HolosError.invalidInput("Invalid forget record ID.") }
        try withLock {
            var line = try HolosJSON.line(record)
            if let existing = try AtomicFile.readIfPresent(forgetJournalURL, maxBytes: Self.maxJournalBytes),
               let last = existing.last, last != 0x0A {
                line.insert(0x0A, at: line.startIndex)
            }
            try AtomicFile.append(line, to: forgetJournalURL)
        }
    }

    /// Every readable line, in file order. A torn last line, a damaged line, or one from a newer Holos is skipped
    /// (the next append starts a new line after a torn part; `compactForgetJournal` drops it).
    public func forgetRecords() throws -> [ForgetRecord] {
        guard let data = try AtomicFile.readIfPresent(forgetJournalURL, maxBytes: Self.maxJournalBytes) else {
            return []
        }
        let (lines, torn) = JournalLines.split(data)
        if torn { Self.log.notice("The forget journal ends with a partial line; it was skipped") }
        let decoder = HolosJSON.decoder()
        var records: [ForgetRecord] = []
        for line in lines {
            guard let version = SchemaVersion.probe(line),
                  SchemaVersion.readable(version, current: ForgetRecord.currentSchemaVersion),
                  let record = try? decoder.decode(ForgetRecord.self, from: line) else { continue }
            records.append(record)
        }
        return records
    }

    /// Tombstones without a `done` line, in file order.
    public func pendingForgets() throws -> [ForgetRecord] {
        let records = try forgetRecords()
        let finished = Set(records.filter { $0.state == ForgetRecord.done }.map(\.id))
        var seen = Set<String>()
        return records.filter {
            $0.state == ForgetRecord.pending && $0.kind != nil && !finished.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    /// The `stored` line of the tombstone `id`, when its store write is already done; nil while that phase is still
    /// owed (including for a tombstone written by an earlier Holos, which journalled no such line: its store write
    /// is then made again, which removes at most a little more than it did).
    public func storedForget(_ id: String) throws -> ForgetRecord? {
        try forgetRecords().first { $0.id == id && $0.state == ForgetRecord.stored }
    }

    /// Under `profiles.lock`, rewrites the journal without its finished tombstones (removing it when nothing is
    /// left), so it does not grow without bound. A readable tombstone with its `done` line, its `stored` line, a
    /// `stored` line whose tombstone is gone, a torn last line, and a damaged line (not a JSON object with a schema
    /// version) are dropped. A line this build cannot read because it
    /// comes from a newer Holos (a newer schema version, or a kind this build does not know) is kept byte for byte,
    /// and so is a `done` line that finishes none of the readable tombstones (it may finish one of those lines), so a
    /// newer Holos's pending forget is never destroyed (§1.6 rule 5).
    public func compactForgetJournal() throws {
        try withLock {
            guard let data = try AtomicFile.readIfPresent(forgetJournalURL, maxBytes: Self.maxJournalBytes) else {
                return
            }
            let decoder = HolosJSON.decoder()
            // Damaged lines (not a JSON object with a usable schemaVersion, such as a torn line) are dropped.
            let lines = JournalLines.split(data).lines.filter { line in
                guard let version = SchemaVersion.probe(line) else { return false }
                return version >= 1
            }
            let readable = lines.map { line -> ForgetRecord? in
                guard let version = SchemaVersion.probe(line),
                      SchemaVersion.readable(version, current: ForgetRecord.currentSchemaVersion) else { return nil }
                return try? decoder.decode(ForgetRecord.self, from: line)
            }
            let pendingIDs = Set(readable.compactMap { $0 }.filter { $0.state == ForgetRecord.pending && $0.kind != nil }
                .map(\.id))
            let finished = Set(readable.compactMap { $0 }.filter { $0.state == ForgetRecord.done }.map(\.id))
            let unreadable = readable.contains { $0 == nil }
            var kept = Data()
            var seen = Set<String>()
            for (line, record) in zip(lines, readable) {
                let keep: Bool
                if let record {
                    if record.state == ForgetRecord.done {
                        keep = unreadable && !pendingIDs.contains(record.id) && seen.insert("done:" + record.id).inserted
                    } else if record.state == ForgetRecord.pending, record.kind != nil {
                        keep = !finished.contains(record.id) && seen.insert(record.id).inserted
                    } else if record.state == ForgetRecord.stored {
                        // Kept only while its tombstone is: it says that tombstone's store write is done.
                        keep = pendingIDs.contains(record.id) && !finished.contains(record.id)
                            && seen.insert("stored:" + record.id).inserted
                    } else {
                        keep = true
                    }
                } else {
                    keep = true
                }
                guard keep else { continue }
                kept.append(line)
                kept.append(0x0A)
            }
            if kept.isEmpty {
                try removeJournal()
            } else if kept != data {
                try AtomicFile.write(kept, to: forgetJournalURL)
            }
        }
    }

    // MARK: - Leftovers

    /// Removes the leftovers of an interrupted atomic write from the store's private folder: regular files named
    /// `.<token>.tmp`, which `AtomicFile` publishes through and unlinks itself, but which a kill or a power loss
    /// between their fsync and their rename leaves behind holding a whole copy of the database, voiceprints and
    /// all. Nothing else in this folder is ever removed (`profiles.json`, `profiles.lock`, the forget journal, and
    /// anything a newer Holos writes stay). Run under `profiles.lock`, so no write of this store is in flight: a
    /// `.tmp` file seen here belongs to no live write. A file that cannot be removed is thrown, so the forget that
    /// called this stays pending. Returns how many were removed.
    @discardableResult
    public func purgeTemporaryFiles() throws -> Int {
        try withLock {
            let folder = try openDirectory()
            defer { Darwin.close(folder) }
            guard let entries = try AtomicFile.listFolder(directory) else { return 0 }
            var removed = 0
            for entry in entries where entry.type == S_IFREG && Self.isTemporaryName(entry.name) {
                guard unlinkat(folder, entry.name, 0) == 0 || errno == ENOENT else {
                    throw HolosError.io("Cannot remove a leftover temporary file in the people folder: "
                                        + "\(AtomicFile.errnoText()).")
                }
                removed += 1
            }
            guard removed > 0 else { return 0 }
            try AtomicFile.syncFolder(folder, directory)
            Self.log.notice("Removed \(removed, privacy: .public) leftover temporary files from the people folder")
            return removed
        }
    }

    /// `.<token>.tmp`, the name `AtomicFile.publish` gives the file it writes before renaming it into place.
    static func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        return SessionArchive.validToken(String(name.dropFirst().dropLast(4)))
    }

    // MARK: - Private

    /// Runs `body` holding `profiles.lock` in the store's private folder (made 0700, excluded from backups).
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let folder = try openDirectory()
        defer { Darwin.close(folder) }
        guard let lock = try SessionLockFile.acquire(Self.lockName, inFolder: folder, timeout: .seconds(2)) else {
            throw HolosError.unavailable("People are being saved by another Holos window or command; try again.")
        }
        defer { SessionLockFile.unlockAndClose(lock) }
        return try body()
    }

    /// Opens (creating it and missing parents as 0700) the store's folder without following a symbolic link in its
    /// place, sets it to 0700, and excludes it from backups, both on the descriptor. The caller closes it.
    private func openDirectory() throws -> Int32 {
        guard let fd = try AtomicFile.openFolder(directory, create: true) else {
            throw HolosError.io("Cannot create the people folder \(directory.lastPathComponent).")
        }
        do {
            guard fchmod(fd, 0o700) == 0 else {
                throw HolosError.io("Cannot make the people folder private: \(AtomicFile.errnoText()).")
            }
            try SessionSpeakerStore.excludeFromBackup(fd, name: directory.lastPathComponent)
        } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// Removes the journal file (a regular file only), then fsyncs the folder.
    private func removeJournal() throws {
        let (parent, name) = try AtomicFile.openParent(of: forgetJournalURL)
        defer { Darwin.close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("\(Self.journalName) is not a regular file.")
        }
        guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else {
            throw HolosError.io("Cannot remove \(Self.journalName): \(AtomicFile.errnoText()).")
        }
        try AtomicFile.syncFolder(parent, directory)
    }
}
