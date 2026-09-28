import Darwin
import Foundation
import HolosCore

extension HolosPaths {
    /// `<supportRoot>/History`: the dictation history (docs/design.md "Dictation history"). Tests point
    /// `supportRoot` at a temporary folder (`HOLOS_SUPPORT_DIR`).
    public static var dictationHistory: URL {
        supportRoot.appendingPathComponent("History", isDirectory: true)
    }
}

/// The dictation history on disk: `dictations.jsonl` (0600, one `DictationRecord` per line, oldest first) in a
/// private folder (0700). New dictations are appended; deleting one, clearing, and the retention sweep rewrite the
/// file atomically (`AtomicFile.write`), and the sweep also drops lines that cannot be read. Every write holds
/// `dictations.lock` (flock), so the app and `voiceislocal history clear` never interleave. Reads take no lock: a
/// line that is still being appended reads as damaged and is skipped. Nothing here logs the text.
public struct DictationHistoryStore: Sendable {
    static let fileName = "dictations.jsonl"
    static let lockName = "dictations.lock"
    private static let maxBytes = 128 << 20

    public let directory: URL

    public init(directory: URL = HolosPaths.dictationHistory) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    /// What `load` read.
    public struct Contents: Sendable, Equatable {
        /// Oldest first (the order they were recorded).
        public var records: [DictationRecord]
        /// Lines that could not be read (damaged, or written by a newer Voice is Local).
        public var skippedLines: Int
    }

    /// The records, oldest first; a missing file (or folder) is an empty history.
    public func load() throws -> Contents {
        guard let data = try AtomicFile.readIfPresent(fileURL, maxBytes: Self.maxBytes) else {
            return Contents(records: [], skippedLines: 0)
        }
        let decoder = HolosJSON.decoder()
        var records: [DictationRecord] = []
        var skipped = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(DictationRecord.self, from: Data(line)),
                  record.schemaVersion <= DictationRecord.currentSchemaVersion else {
                skipped += 1
                continue
            }
            records.append(record)
        }
        return Contents(records: records, skippedLines: skipped)
    }

    /// Appends one record (creating the folder and file privately when missing).
    public func append(_ record: DictationRecord) throws {
        let line = try HolosJSON.line(record)
        try withLock {
            try AtomicFile.append(line, to: fileURL, permissions: 0o600)
        }
    }

    /// Removes the record `id`; returns whether it was there.
    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try withLock {
            let contents = try load()
            let kept = contents.records.filter { $0.id != id }
            guard kept.count != contents.records.count else { return false }
            try rewrite(kept)
            return true
        }
    }

    /// Removes every record; returns how many there were.
    @discardableResult
    public func clear() throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try withLock {
            let count = (try? load().records.count) ?? 0
            try rewrite([])
            return count
        }
    }

    /// Removes records dated before `cutoff` and any unreadable lines; returns how many records were removed.
    @discardableResult
    public func sweep(before cutoff: Date) throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        return try withLock {
            let contents = try load()
            let kept = contents.records.filter { $0.date >= cutoff }
            let removed = contents.records.count - kept.count
            if removed > 0 || contents.skippedLines > 0 { try rewrite(kept) }
            return removed
        }
    }

    /// The retention sweep for a setting: nothing for Off and Forever (`HistoryRetention.cutoff`).
    @discardableResult
    public func sweep(_ retention: HistoryRetention, now: Date = Date()) throws -> Int {
        guard let cutoff = retention.cutoff(now: now) else { return 0 }
        return try sweep(before: cutoff)
    }

    // MARK: - Helpers

    private func rewrite(_ records: [DictationRecord]) throws {
        var data = Data()
        for record in records { data.append(try HolosJSON.line(record)) }
        try AtomicFile.write(data, to: fileURL, permissions: 0o600)
    }

    /// Runs `body` holding `dictations.lock` (an exclusive flock; the folder is created privately first).
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try AtomicFile.ensurePrivateDirectory(directory)
        let path = directory.appendingPathComponent(Self.lockName, isDirectory: false).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw HolosError.io("Cannot open the history lock: \(String(cString: strerror(errno))).")
        }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw HolosError.io("Cannot lock the history: \(String(cString: strerror(errno))).")
            }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
