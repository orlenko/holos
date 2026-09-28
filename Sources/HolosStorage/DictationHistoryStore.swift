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
/// file atomically (`AtomicFile.write`), and every sweep (any retention, Forever too) drops lines that cannot be
/// read. Every write holds `dictations.lock` (flock), so the app and `voiceislocal history clear` never interleave.
/// Reads take no lock and stream the file a line at a time, so a Forever history of any size stays readable: a line
/// that is still being appended reads as damaged and is skipped, and so is one longer than `maxLineBytes`, without
/// being held in memory. A line of a later schema version (written by a newer Voice is Local) is not shown but is
/// kept byte for byte by every rewrite, so opening the history with an older build never loses it. Nothing here logs
/// the text.
public struct DictationHistoryStore: Sendable {
    static let fileName = "dictations.jsonl"
    static let lockName = "dictations.lock"

    public let directory: URL
    /// A line longer than this is skipped as damaged; a dictation's line is far shorter.
    var maxLineBytes = 8 << 20
    /// How much a read takes from the file at a time.
    var readChunkBytes = 256 << 10

    public init(directory: URL = HolosPaths.dictationHistory) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    /// What `load` read.
    public struct Contents: Sendable, Equatable {
        /// Oldest first (the order they were recorded).
        public var records: [DictationRecord]
        /// Lines that could not be read (damaged, torn, or too long); a sweep drops them.
        public var skippedLines: Int
        /// Lines written by a newer Voice is Local (a later schema version): not shown, and kept by every rewrite
        /// except Clear History and the retention sweep of their date, so opening an older build never loses them.
        public var newerLines: Int
        /// Every readable line in file order, for rewrites.
        var entries: [Entry]

        public init(records: [DictationRecord], skippedLines: Int, newerLines: Int = 0) {
            self.records = records
            self.skippedLines = skippedLines
            self.newerLines = newerLines
            entries = records.map(Entry.record)
        }

        init(entries: [Entry], skippedLines: Int) {
            self.entries = entries
            self.skippedLines = skippedLines
            records = entries.compactMap { if case .record(let record) = $0 { record } else { nil } }
            newerLines = entries.count - records.count
        }
    }

    /// A readable line.
    enum Entry: Sendable, Equatable {
        case record(DictationRecord)
        /// A line of a later schema version, kept byte for byte; `date` when it could be read, for the sweep.
        case newer(Data, date: Date?)
    }

    /// The part of a line an older build can still read: its schema version and date.
    private struct LineProbe: Decodable {
        var schemaVersion: Int
    }

    private struct DateProbe: Decodable {
        var date: Date
    }

    /// The records, oldest first; a missing file (or folder) is an empty history.
    public func load() throws -> Contents {
        guard let handle = try AtomicFile.openForReading(fileURL) else {
            return Contents(records: [], skippedLines: 0)
        }
        defer { try? handle.close() }
        let decoder = HolosJSON.decoder()
        var entries: [Entry] = []
        var skipped = 0
        var line = Data()
        var oversized = false
        func take(_ piece: Data.SubSequence) {
            guard !oversized else { return }
            if line.count + piece.count > maxLineBytes {
                oversized = true
                line = Data()
            } else {
                line.append(contentsOf: piece)
            }
        }
        func endLine() {
            defer {
                line.removeAll(keepingCapacity: true)
                oversized = false
            }
            if oversized {
                skipped += 1
                return
            }
            guard !line.isEmpty else { return }
            if let probe = try? decoder.decode(LineProbe.self, from: line),
               probe.schemaVersion > DictationRecord.currentSchemaVersion {
                entries.append(.newer(line, date: (try? decoder.decode(DateProbe.self, from: line))?.date))
                return
            }
            guard let record = try? decoder.decode(DictationRecord.self, from: line) else {
                skipped += 1
                return
            }
            entries.append(.record(record))
        }
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: max(1, readChunkBytes)) ?? Data()
            } catch {
                throw HolosError.io("Cannot read the history: \(error.localizedDescription)")
            }
            if chunk.isEmpty { break }
            var start = chunk.startIndex
            while start < chunk.endIndex {
                guard let newline = chunk[start...].firstIndex(of: 0x0A) else {
                    take(chunk[start...])
                    break
                }
                take(chunk[start..<newline])
                endLine()
                start = chunk.index(after: newline)
            }
        }
        endLine()  // a last line without its newline: complete, or still being appended (then skipped)
        return Contents(entries: entries, skippedLines: skipped)
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
            let kept = contents.entries.filter { if case .record(let record) = $0 { record.id != id } else { true } }
            guard kept.count != contents.entries.count else { return false }
            try rewrite(kept)
            return true
        }
    }

    /// Removes every line, a newer build's too (Clear History deletes all the text kept); returns how many
    /// dictations there were.
    @discardableResult
    public func clear() throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try withLock {
            let count = (try? load()).map { $0.records.count + $0.newerLines } ?? 0
            try rewrite([])
            return count
        }
    }

    /// Removes records dated before `cutoff` (a newer build's lines too, when their date can be read) and any
    /// unreadable lines; returns how many were removed. Lines of a newer build are otherwise kept as they are.
    @discardableResult
    public func sweep(before cutoff: Date) throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        return try withLock {
            let contents = try load()
            let kept = contents.entries.filter { entry in
                switch entry {
                case .record(let record): record.date >= cutoff
                case .newer(_, let date): date.map { $0 >= cutoff } ?? true
                }
            }
            let removed = contents.entries.count - kept.count
            if removed > 0 || contents.skippedLines > 0 { try rewrite(kept) }
            return removed
        }
    }

    /// The retention sweep for a setting (`HistoryRetention.cutoff`). Off and Forever keep every record, but the file
    /// is still compacted: lines that cannot be read are dropped.
    @discardableResult
    public func sweep(_ retention: HistoryRetention, now: Date = Date()) throws -> Int {
        try sweep(before: retention.cutoff(now: now) ?? .distantPast)
    }

    // MARK: - Helpers

    private func rewrite(_ entries: [Entry]) throws {
        var data = Data()
        for entry in entries {
            switch entry {
            case .record(let record):
                data.append(try HolosJSON.line(record))
            case .newer(let line, _):
                data.append(line)
                data.append(0x0A)
            }
        }
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
