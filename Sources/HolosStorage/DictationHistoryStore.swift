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
///
/// Each dictation's audio, when kept (docs/design.md "Dictation audio and Run Again"), is `audio/<id>.m4a` (0600) in a
/// private folder next to the file. It is written as `audio/<id>.partial.m4a` while the user speaks and renamed to its
/// name, holding the lock, just before its record is appended, so under the lock every finished audio file has its
/// record. It goes with its record: Delete, Clear History, and the retention sweep remove it (set aside first and put
/// back when the rewrite fails), and every sweep also removes audio no record links (its record is gone, or an older
/// build rewrote the line without the link) and partial files left by a dictation that never finished.
public struct DictationHistoryStore: Sendable {
    static let fileName = "dictations.jsonl"
    static let lockName = "dictations.lock"
    static let audioFolderName = "audio"
    static let partialAudioSuffix = ".partial.m4a"
    /// A partial audio file older than this belongs to no dictation in progress (a dictation lasts two minutes at
    /// most, and its end at most a few more).
    public static let partialAudioLifetime: TimeInterval = 3_600

    public let directory: URL
    /// A line longer than this is skipped as damaged; a dictation's line is far shorter.
    var maxLineBytes = 8 << 20
    /// How much a read takes from the file at a time.
    var readChunkBytes = 256 << 10

    public init(directory: URL = HolosPaths.dictationHistory) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    /// `<directory>/audio`: the dictations' audio.
    public var audioDirectory: URL { directory.appendingPathComponent(Self.audioFolderName, isDirectory: true) }

    /// Where the audio of dictation `id` is kept once it is finished.
    public func audioURL(for id: UUID) -> URL {
        audioDirectory.appendingPathComponent(DictationRecord.Audio.fileName(for: id), isDirectory: false)
    }

    /// Where the audio of dictation `id` is written while the user speaks.
    public func partialAudioURL(for id: UUID) -> URL {
        audioDirectory.appendingPathComponent(id.uuidString + Self.partialAudioSuffix, isDirectory: false)
    }

    /// Creates the history and audio folders privately (0700), for a writer about to write a partial audio file.
    public func prepareAudioFolder() throws {
        try AtomicFile.ensurePrivateDirectory(audioDirectory)
    }

    /// The audio of a dictation that has ended, written to `partialAudioURL(for:)`, and how long it is.
    public struct FinishedAudio: Sendable, Equatable {
        public var partial: URL
        public var seconds: Double

        public init(partial: URL, seconds: Double) {
            self.partial = partial
            self.seconds = seconds
        }
    }

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
        /// A line of a later schema version, kept byte for byte; `date` when it could be read, for the sweep, and
        /// `id` when it could be read, so its audio is not taken for audio without a record.
        case newer(Data, date: Date?, id: UUID?)

        var id: UUID? {
            switch self {
            case .record(let record): record.id
            case .newer(_, _, let id): id
            }
        }
    }

    /// The part of a line an older build can still read: its schema version and date.
    private struct LineProbe: Decodable {
        var schemaVersion: Int
    }

    private struct DateProbe: Decodable {
        var date: Date
    }

    private struct IDProbe: Decodable {
        var id: UUID
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
                entries.append(.newer(line, date: (try? decoder.decode(DateProbe.self, from: line))?.date,
                                      id: (try? decoder.decode(IDProbe.self, from: line))?.id))
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
        _ = try append(record, audio: nil)
    }

    /// Appends one record with its audio, when there is some: the partial file becomes `audioURL(for:)` and the record
    /// links it. Audio that cannot be moved there is deleted and the record is appended without it; audio whose record
    /// cannot be appended is deleted too. Returns the record as appended.
    public func append(_ record: DictationRecord, audio: FinishedAudio?) throws -> DictationRecord {
        var record = record
        record.audio = nil
        return try withLock {
            var moved: URL?
            if let audio {
                if audio.partial.standardizedFileURL.path == partialAudioURL(for: record.id).standardizedFileURL.path,
                   audio.seconds > 0,
                   rename(audio.partial.path, audioURL(for: record.id).path) == 0 {
                    moved = audioURL(for: record.id)
                    record.audio = DictationRecord.Audio(file: DictationRecord.Audio.fileName(for: record.id),
                                                         seconds: audio.seconds)
                } else {
                    try? Self.removeAudioFile(audio.partial)
                }
            }
            do {
                try AtomicFile.append(try HolosJSON.line(record), to: fileURL, permissions: 0o600)
            } catch {
                if let moved { try? Self.removeAudioFile(moved) }
                throw error
            }
            return record
        }
    }

    /// Replaces the record with `record`'s ID (Update History), keeping the audio link the file has (Update History
    /// never changes the audio); returns false when it is no longer there.
    @discardableResult
    public func update(_ record: DictationRecord) throws -> Bool {
        try withLock {
            let contents = try load()
            guard contents.records.contains(where: { $0.id == record.id }) else { return false }
            try rewrite(contents.entries.map { entry in
                guard case .record(let old) = entry, old.id == record.id else { return entry }
                var updated = record
                updated.audio = old.audio
                return .record(updated)
            })
            return true
        }
    }

    /// Removes the record `id` and its audio; returns whether the record was there. The audio is moved aside first
    /// and deleted once the file no longer has the record, so a failure leaves both.
    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try withLock {
            let contents = try load()
            let kept = contents.entries.filter { if case .record(let record) = $0 { record.id != id } else { true } }
            let staged = try stageRemoval(of: [audioURL(for: id)])
            if kept.count != contents.entries.count {
                do {
                    try rewrite(kept)
                } catch {
                    rollBack(staged)
                    throw error
                }
            }
            commit(staged)
            return kept.count != contents.entries.count
        }
    }

    /// Removes every line, a newer build's too (Clear History deletes all the text kept), and all the audio but that
    /// of a dictation still in progress; returns how many dictations there were. A failure leaves text and audio.
    @discardableResult
    public func clear(now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try withLock {
            let count = (try? load()).map { $0.records.count + $0.newerLines } ?? 0
            try replaceRemovingAudio(keeping: [], partialsBefore: now.addingTimeInterval(-Self.partialAudioLifetime)) {
                try rewrite([])
            }
            return count
        }
    }

    /// Removes records dated before `cutoff` (a newer build's lines too, when their date can be read) with their
    /// audio, and any unreadable lines; returns how many were removed. Lines of a newer build are otherwise kept as
    /// they are, with their audio. Audio no kept record links (its record is gone, or an older build rewrote the line
    /// without the link), and partial audio written before `partialsBefore` (a dictation that never finished), are
    /// removed too. A failure leaves text and audio.
    @discardableResult
    public func sweep(before cutoff: Date, partialsBefore: Date? = nil) throws -> Int {
        let partialsBefore = partialsBefore ?? Date().addingTimeInterval(-Self.partialAudioLifetime)
        guard FileManager.default.fileExists(atPath: fileURL.path)
                || FileManager.default.fileExists(atPath: audioDirectory.path) else { return 0 }
        return try withLock {
            let contents = try load()
            let kept = contents.entries.filter { entry in
                switch entry {
                case .record(let record): record.date >= cutoff
                case .newer(_, let date, _): date.map { $0 >= cutoff } ?? true
                }
            }
            let removed = contents.entries.count - kept.count
            try replaceRemovingAudio(keeping: Self.audioKept(by: kept), partialsBefore: partialsBefore) {
                if removed > 0 || contents.skippedLines > 0 { try rewrite(kept) }
            }
            return removed
        }
    }

    /// The retention sweep for a setting (`HistoryRetention.cutoff`). Off and Forever keep every record, but the file
    /// is still compacted: lines that cannot be read are dropped.
    @discardableResult
    public func sweep(_ retention: HistoryRetention, now: Date = Date()) throws -> Int {
        try sweep(before: retention.cutoff(now: now) ?? .distantPast)
    }

    /// Deletes every dictation's audio (Settings, when keeping it is turned off) and the records' links to it, but
    /// not a dictation still in progress; its audio is dropped when it ends (the setting is off). Returns how many
    /// records had audio. A failure leaves links and audio.
    @discardableResult
    public func removeAllAudio(now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try withLock {
            let contents = try load()
            let linked = contents.records.count { $0.audio != nil }
            try replaceRemovingAudio(keeping: [], partialsBefore: now.addingTimeInterval(-Self.partialAudioLifetime)) {
                guard linked > 0 else { return }
                try rewrite(contents.entries.map { entry in
                    guard case .record(var record) = entry, record.audio != nil else { return entry }
                    record.audio = nil
                    return .record(record)
                })
            }
            return linked
        }
    }

    /// Bytes the audio folder takes (finished, partial, and set-aside files).
    public func audioBytes() -> Int64 {
        audioFiles().reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Audio helpers

    /// A regular file in the audio folder named for a dictation, its size and date.
    struct AudioFile {
        enum Kind: Equatable {
            /// `<id>.m4a`.
            case finished
            /// `<id>.partial.m4a`: being written while the user speaks.
            case partial
            /// `<id>.m4a.removing`: set aside for a removal a failure could still roll back.
            case removing
        }

        var url: URL
        var id: UUID
        var kind: Kind
        var bytes: Int64
        var modified: Date
    }

    /// The audio folder's files named for a dictation; nothing else in it is touched.
    func audioFiles() -> [AudioFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: audioDirectory.path) else { return [] }
        return names.compactMap { name in
            let kinds: [(String, AudioFile.Kind)] = [(Self.partialAudioSuffix, .partial),
                                                     (Self.removingAudioSuffix, .removing), (".m4a", .finished)]
            guard let (suffix, kind) = kinds.first(where: { name.hasSuffix($0.0) }) else { return nil }
            let stem = String(name.dropLast(suffix.count))
            guard let id = UUID(uuidString: stem), stem == id.uuidString else { return nil }
            let url = audioDirectory.appendingPathComponent(name, isDirectory: false)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                                + Double(info.st_mtimespec.tv_nsec) / 1e9)
            return AudioFile(url: url, id: id, kind: kind, bytes: Int64(info.st_size), modified: modified)
        }
    }

    static let removingAudioSuffix = ".m4a.removing"

    /// The dictations whose audio `entries` keep: records that link it, and a newer build's lines (their audio is
    /// theirs to judge).
    static func audioKept(by entries: [Entry]) -> Set<UUID> {
        Set(entries.compactMap { entry in
            switch entry {
            case .record(let record): record.audio == nil ? nil : record.id
            case .newer(_, _, let id): id
            }
        })
    }

    /// Runs `write` (a rewrite of the file) with the finished audio of dictations not in `keeping` set aside, then
    /// deletes it; when `write` fails, puts it back and rethrows, so a failed rewrite never loses audio its record
    /// still links. Audio a crash left set aside is put back when `keeping` links it (and nothing replaced it),
    /// else deleted; partial audio written before `partialsBefore` is deleted.
    private func replaceRemovingAudio(keeping: Set<UUID>, partialsBefore: Date, _ write: () throws -> Void) throws {
        let files = audioFiles()
        let finished = Set(files.filter { $0.kind == .finished }.map(\.id))
        for file in files where file.kind == .removing {
            if keeping.contains(file.id), !finished.contains(file.id),
               rename(file.url.path, audioURL(for: file.id).path) == 0 {
                continue
            }
            try? Self.removeAudioFile(file.url)
        }
        let staged = try stageRemoval(of: files.filter { $0.kind == .finished && !keeping.contains($0.id) }.map(\.url))
        do {
            try write()
        } catch {
            rollBack(staged)
            throw error
        }
        commit(staged)
        for file in files where file.kind == .partial && file.modified < partialsBefore {
            try? Self.removeAudioFile(file.url)
        }
    }

    /// Moves each file (`<id>.m4a`) aside to `<id>.m4a.removing`; a missing one is skipped. When one cannot be moved,
    /// those already moved are put back and the error is thrown. Returns the files moved, as they are now named.
    private func stageRemoval(of urls: [URL]) throws -> [URL] {
        var staged: [URL] = []
        for url in urls {
            let aside = URL(fileURLWithPath: url.path + ".removing", isDirectory: false)
            if rename(url.path, aside.path) == 0 {
                staged.append(aside)
            } else if errno != ENOENT {
                let reason = String(cString: strerror(errno))
                rollBack(staged)
                throw HolosError.io("Cannot delete a dictation's audio: \(reason).")
            }
        }
        return staged
    }

    /// Puts files set aside back under their names.
    private func rollBack(_ staged: [URL]) {
        for aside in staged {
            _ = rename(aside.path, String(aside.path.dropLast(".removing".count)))
        }
    }

    /// Deletes files set aside; one that cannot be deleted stays set aside, and the next sweep deletes it (its record
    /// no longer links it).
    private func commit(_ staged: [URL]) {
        for aside in staged { try? Self.removeAudioFile(aside) }
    }

    /// Unlinks an audio file in the private audio folder; one that is already gone is fine.
    public static func removeAudioFile(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw HolosError.io("Cannot delete a dictation's audio: \(String(cString: strerror(errno))).")
        }
    }

    // MARK: - Helpers

    private func rewrite(_ entries: [Entry]) throws {
        var data = Data()
        for entry in entries {
            switch entry {
            case .record(let record):
                data.append(try HolosJSON.line(record))
            case .newer(let line, _, _):
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

/// A dictation's audio being written while the user speaks (HolosAudio's `DictationAudioWriter`), to
/// `DictationHistoryStore.partialAudioURL(for:)`.
public protocol DictationAudioRecording: AnyObject, Sendable {
    /// Stops taking audio, finishes the file, and returns it; blocks until it is written. Nil when there is no usable
    /// audio (nothing was heard, or the file could not be written); the partial file is then deleted.
    func finish() -> DictationHistoryStore.FinishedAudio?
    /// Stops taking audio and deletes the partial file (the dictation is not kept).
    func discard()
}
