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
/// that lists what it removes, then updates the profile store, then cleans each affected session, then appends a
/// `done` line with the same ID; a crash anywhere leaves the tombstone for the next run to finish.
public struct ForgetRecord: Codable, Sendable, Equatable {
    public static let pending = "pending"
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
    }

    public var schemaVersion: Int
    public var id: String
    /// Nil on a `done` line.
    public var kind: Kind?
    public var profileID: String?
    public var sampleIDs: [String]?
    public var sessionIDs: [String]?
    public var state: String

    public init(schemaVersion: Int = ForgetRecord.currentSchemaVersion, id: String = UUID().uuidString, kind: Kind?,
                profileID: String? = nil, sampleIDs: [String]? = nil, sessionIDs: [String]? = nil,
                state: String = ForgetRecord.pending) {
        self.schemaVersion = schemaVersion; self.id = id; self.kind = kind; self.profileID = profileID
        self.sampleIDs = sampleIDs; self.sessionIDs = sessionIDs; self.state = state
    }

    /// The `done` line for the tombstone `id`.
    public static func done(_ id: String) -> ForgetRecord { ForgetRecord(id: id, kind: nil, state: done) }
}

/// The global people store (docs/meeting-design.md §2.2, §4.10): `profiles.json` (0600) in a private folder
/// (0700) that is excluded from Time Machine, `profiles.lock`, and `forget-journal.jsonl` (0600).
///
/// Reads take no lock (`profiles.json` is replaced atomically). Every write is a read-modify-write under
/// `profiles.lock` (`update`), polled every 20 ms for up to 2 s. The lock is not re-entrant: never call `update` or a
/// journal method from inside `update`. When a caller also needs a session's speaker lock, it takes that lock first
/// (§1.7 order: speakers → profiles).
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
    /// newer Holos is refused (`unavailable`); a damaged one throws `invalidInput` and is never overwritten.
    public func load() throws -> SpeakerProfileDatabase {
        guard let data = try AtomicFile.readIfPresent(databaseURL, maxBytes: Self.maxDatabaseBytes) else {
            return SpeakerProfileDatabase()
        }
        return try SchemaVersion.decode(SpeakerProfileDatabase.self, from: data,
                                        current: SpeakerProfileDatabase.currentSchemaVersion,
                                        name: Self.databaseName)
    }

    /// Takes `profiles.lock` (2 s), reads the database, lets `body` change it, validates the result (`validate`),
    /// and writes it atomically when it changed. Nothing is written when `body` or the validation throws.
    public func update<T>(_ body: (inout SpeakerProfileDatabase) throws -> T) throws -> T {
        try withLock {
            var database = try load()
            let before = database
            let result = try body(&database)
            guard database != before else { return result }
            try Self.validate(database)
            try AtomicFile.writeJSON(database, to: databaseURL)
            Self.log.info("Saved the people store: \(database.profiles.count, privacy: .public) people, \(database.sampleCount, privacy: .public) voice samples")
            return result
        }
    }

    /// The rules every saved database meets: schema version 1; profile and sample IDs are valid tokens and unique;
    /// names are not blank; at most one `isSelf` profile; at most one sample per session per profile; a profile
    /// with samples names its embedding model, and its samples share one non-empty dimension with finite values and
    /// finite, non-negative speech seconds. Throws `invalidInput` saying which rule failed.
    public static func validate(_ database: SpeakerProfileDatabase) throws {
        guard database.schemaVersion == SpeakerProfileDatabase.currentSchemaVersion else {
            throw HolosError.invalidInput("The people store has schema version \(database.schemaVersion); this Holos writes version \(SpeakerProfileDatabase.currentSchemaVersion).")
        }
        var profileIDs = Set<String>()
        var sampleIDs = Set<String>()
        var selfCount = 0
        for profile in database.profiles {
            guard SessionArchive.validToken(profile.id), profileIDs.insert(profile.id).inserted else {
                throw HolosError.invalidInput("The people store has an invalid or repeated person ID.")
            }
            guard !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HolosError.invalidInput("Every person needs a name.")
            }
            if profile.isSelf { selfCount += 1 }
            var sessions = Set<String>()
            var dimension: Int?
            for sample in profile.samples {
                guard SessionArchive.validToken(sample.id), sampleIDs.insert(sample.id).inserted else {
                    throw HolosError.invalidInput("The people store has an invalid or repeated voice sample ID.")
                }
                guard SessionArchive.validToken(sample.sessionID), sessions.insert(sample.sessionID).inserted else {
                    throw HolosError.invalidInput("A person can have only one voice sample per meeting.")
                }
                guard profile.embeddingModel != nil else {
                    throw HolosError.invalidInput("A person with voice samples needs their embedding model.")
                }
                let values = sample.embedding.values
                guard !values.isEmpty, values.allSatisfy(\.isFinite), dimension == nil || dimension == values.count,
                      sample.speechSeconds.isFinite, sample.speechSeconds >= 0 else {
                    throw HolosError.invalidInput("A voice sample is damaged.")
                }
                dimension = values.count
            }
        }
        guard selfCount <= 1 else {
            throw HolosError.invalidInput("Only one person can be marked as you.")
        }
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

    /// Under `profiles.lock`, rewrites the journal without its finished tombstones (removing it when nothing is
    /// left), so it does not grow without bound. A readable tombstone with its `done` line, a torn last line, and a
    /// damaged line (not a JSON object with a schema version) are dropped. A line this build cannot read because it
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
