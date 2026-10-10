import Foundation
import HolosCore
import HolosSynthesis

/// One reading in the app's Reading list (docs/design.md "Reading section"): where it comes from, the voice and
/// speed it is made with, where its file goes, and how far it got. Kept in `ReadingLibraryStore`'s index so the list
/// survives a relaunch.
public struct ReadingEntry: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// Waiting for the reading before it to finish.
        case queued
        /// Loading its source or rendering.
        case rendering
        /// The file is made.
        case done
        /// It stopped on an error (`message`); Try Again resumes it.
        case failed
        /// The user stopped it, or Voice is Local quit while it was made; Resume continues it.
        case stopped
    }

    public let id: UUID
    public let created: Date
    public var source: ReadingSource
    /// The document's title once it is loaded; until then the source's label.
    public var title: String
    /// The voice asked for; nil for the best installed voice for the text's language.
    public var requestedVoice: String?
    /// The voice the reading is made with, fixed when it starts so a resume uses the same one.
    public var voiceIdentifier: String?
    /// The voice's name as the list shows it ("Ava (Premium)").
    public var voiceName: String?
    /// 0.8…1.4 (see `ReadingSpeed`).
    public var speed: Double
    /// The finished `.m4a`'s path, chosen when the reading first starts.
    public var output: String?
    /// The folder its file goes to, as Settings › Reading named it when the reading was added (a change of the
    /// setting is for readings added later); nil for one an earlier build added (the setting when it starts).
    public var folder: String?
    /// Whether `folder` was the default folder (made when missing; a folder chosen in Settings never is).
    public var folderIsDefault: Bool?
    /// The render cache (`Readings/Output-<hash>` in Application Support), once known.
    public var cache: String?
    public var state: State
    /// Why it failed or stopped.
    public var message: String?
    /// The part being rendered, or where it stopped, counted from 1, and how many parts there are.
    public var part: Int?
    public var parts: Int?
    public var duration: Double?
    public var chapters: Int?
    /// Voice is Local quit while this reading was made or waiting and the user chose Keep Rendering: the next launch
    /// continues it.
    public var resumeOnLaunch: Bool
    /// Delete was chosen: the entry is saved marked before its files are removed, so a quit or a crash in between
    /// finishes the deletion at the next launch instead of bringing the reading back. Nil when not.
    public var deletePending: Bool?
    /// The finished file's SHA-256, so Delete moves to the Trash only that file, never one put at its path since.
    public var outputSHA256: String?
    /// The finished file's identity (volume, inode, creation time), so Play, Share…, and Show in Finder use only that
    /// file: one put at its path since shows as missing.
    public var outputIdentity: ReadingFileIdentity?
    /// Where a Delete that failed left the file it moved aside from `output` to check it (it could not be put back:
    /// see `ExclusivePublisher.removeVerified`), so the next Delete checks and removes that file too. Nil when none.
    public var outputAside: String?

    public init(id: UUID = UUID(), created: Date = Date(), source: ReadingSource, requestedVoice: String?,
                speed: Double) {
        self.id = id
        self.created = created
        self.source = source
        self.title = source.label
        self.requestedVoice = requestedVoice
        self.speed = speed
        self.state = .queued
        self.resumeOnLaunch = false
    }

    /// Whether the reading is waiting or being made.
    public var isActive: Bool { state == .queued || state == .rendering }

    /// The output, its path spelled as saved (see `ReadingOutput.fileURL(keepingSpelling:)`).
    public var outputURL: URL? { output.map { ReadingOutput.fileURL(keepingSpelling: $0) } }
}

/// What the index file holds.
struct ReadingIndex: Codable {
    static let kind = "voiceislocal.reading-library"
    static let currentSchemaVersion = 1

    var kind: String
    var schemaVersion: Int
    var entries: [ReadingEntry]
}

/// The Reading list's index: `<support>/ReadingLibrary/library.json` (0600), plus a snapshot of each unfinished
/// reading's loaded document (`Documents/<id>.json`) so a resume reads exactly the same text without loading the web
/// page again. Render caches stay where the pipeline keeps them (`<support>/Readings`); the finished files go to the
/// output folder (Settings › Reading).
public final class ReadingLibraryStore: @unchecked Sendable {
    public struct Loaded: Sendable, Equatable {
        public var entries: [ReadingEntry]
        /// Something the list should say about the index (it was unreadable and set aside, or made by a newer build).
        public var notice: String?
        /// False when the index was written by a newer Voice is Local: it is shown but never rewritten.
        public var writable: Bool
        /// The folder that holds the index cannot be reached (its drive or share is not connected): the list is not
        /// known to be empty, so it is never written; `load` again once the folder is back.
        public var unavailable: Bool = false

        public init(entries: [ReadingEntry], notice: String?, writable: Bool, unavailable: Bool = false) {
            self.entries = entries
            self.notice = notice
            self.writable = writable
            self.unavailable = unavailable
        }
    }

    public let folder: URL
    public var indexURL: URL { folder.appendingPathComponent("library.json") }
    var documentsFolder: URL { folder.appendingPathComponent("Documents", isDirectory: true) }
    /// The largest index a save that adds readings writes. The largest read is twice that (`readLimit`), so a list at
    /// this size can still be changed (a Delete marks its reading first, which makes the index larger).
    let maximumBytes: Int
    static let defaultMaximumBytes = 32 << 20
    /// The largest index read, and so the largest written (a larger one would be set aside at the next launch).
    var readLimit: Int { maximumBytes * 2 }
    /// The index file this store last read or wrote: its identity (nil when there was none); unset before the
    /// first. A save finds that file there, or refuses: an index put there since (another disk mounted at the
    /// support folder's path, another copy of the app) is never written over with this list.
    private var expected: ReadingFileIdentity??
    private let lock = NSLock()

    public convenience init(folder: URL) {
        self.init(folder: folder, maximumBytes: Self.defaultMaximumBytes)
    }

    init(folder: URL, maximumBytes: Int) {
        self.folder = folder
        self.maximumBytes = maximumBytes
    }

    /// `<support>/ReadingLibrary`.
    public static func standard(support: URL = HolosPaths.supportRoot) -> ReadingLibraryStore {
        ReadingLibraryStore(folder: support.appendingPathComponent("ReadingLibrary", isDirectory: true))
    }

    /// The saved entries. A missing index is an empty list; one that cannot be read is renamed aside
    /// (`library.json.unreadable-<date>`), so it is kept, and the list starts empty with a notice; one a newer build
    /// wrote is shown (entries this build cannot read are left out) but never rewritten. Only "no such file" is a
    /// missing index: one that cannot be looked up (an I/O error, a permission) is kept and never written over. Nor is
    /// one not found in a folder that cannot be reached (a support folder on a drive or share that is not connected,
    /// see `ReadingOutput.unreachableReason`): the list is `unavailable`, shown empty and never written, until a
    /// `load` finds the folder back.
    public func load() -> Loaded {
        lock.lock()
        defer { lock.unlock() }
        let data: Data
        do {
            guard try ReadingOutput.exists(indexURL) else {
                if let reason = ReadingOutput.unreachableReason(for: indexURL) {
                    return Loaded(entries: [], notice: "The Reading list is unavailable: \(reason). Connect it; the "
                                    + "list shows again when Voice is Local finds it.", writable: false,
                                  unavailable: true)
                }
                expected = .some(nil)
                return Loaded(entries: [], notice: nil, writable: true)
            }
            // Not blocked by a special file put in its place (see `openRegularFile`).
            let handle = try openRegularFile(indexURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: readLimit + 1) ?? Data()
            expected = .some(ExclusivePublisher.FileIdentity.of(descriptor: handle.fileDescriptor))
        } catch {
            // Not rewritten: what it keeps may still be readable later (a permission fixed, a disk remounted), so it
            // is read again then (`unavailable`).
            return Loaded(entries: [], notice: "The Reading list could not be read (\(error.localizedDescription)); "
                            + "it is read again when you come back to this window.", writable: false,
                          unavailable: true)
        }
        struct Marker: Decodable { let kind: String?; let schemaVersion: Int? }
        if data.count <= readLimit, let marker = try? JSONDecoder.reading.decode(Marker.self, from: data),
           marker.kind == ReadingIndex.kind, let version = marker.schemaVersion {
            if version > ReadingIndex.currentSchemaVersion {
                return Loaded(entries: Self.lenientEntries(data),
                              notice: "The Reading list was saved by a newer Voice is Local; it is shown but not changed here.",
                              writable: false)
            }
            if let index = try? JSONDecoder.reading.decode(ReadingIndex.self, from: data) {
                return Loaded(entries: index.entries, notice: nil, writable: true)
            }
        }
        let aside = folder.appendingPathComponent("library.json.unreadable-\(Self.stamp())")
        // Set aside only while it is the file read, under the index's lock: another copy of the app may have saved a
        // good list there since, which must not be set aside for what this one read before.
        struct Replaced: Error {}
        let read = expected ?? nil
        do {
            try withIndexLock {
                guard let read, try ExclusivePublisher.FileIdentity.lookup(indexURL) == read else { throw Replaced() }
                try FileManager.default.moveItem(at: indexURL, to: aside)
            }
        } catch is Replaced {
            expected = nil
            return Loaded(entries: [], notice: "The Reading list changed while it was read; it is read again when you "
                            + "come back to this window.", writable: false, unavailable: true)
        } catch {
            expected = nil
            return Loaded(entries: [], notice: "The Reading list could not be read and could not be set aside "
                            + "(\(error.localizedDescription)); readings made now are not kept in it after Voice is "
                            + "Local quits.", writable: false)
        }
        expected = .some(nil)
        return Loaded(entries: [], notice: "The Reading list could not be read; it was kept as \(aside.lastPathComponent) "
                        + "and a new list was started. The audio files are still in their folder.", writable: true)
    }

    /// Writes `entries` atomically, readable by this user only. Refused when the folder cannot be reached (its drive
    /// or share is not connected: nothing is written in its place); when the index there is not the one this store
    /// last read or wrote (see `expected`); and when the index would be larger than `load` reads (it would be set
    /// aside at the next launch), or, for a save that adds readings (`growing`), than `maximumBytes`, which leaves room
    /// to delete them. The index there is then kept as it was.
    public func save(_ entries: [ReadingEntry], growing: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        if let reason = ReadingOutput.unreachableReason(for: indexURL) {
            throw HolosError.unavailable("The Reading list's folder is unavailable: \(reason).")
        }
        let encoder = JSONEncoder.reading
        let data = try encoder.encode(ReadingIndex(kind: ReadingIndex.kind,
                                                   schemaVersion: ReadingIndex.currentSchemaVersion, entries: entries))
        let limit = growing ? maximumBytes : readLimit
        guard data.count <= limit else {
            throw HolosError.io("The Reading list is too large to save (\(data.count) bytes; at most \(limit)). "
                + "Delete some readings.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // The check and the replacement under one lock across processes: another copy of the app saving this index
        // between them would otherwise have its list replaced unseen.
        try withIndexLock {
            if case .some(let known) = expected {
                let found = try ExclusivePublisher.FileIdentity.lookup(indexURL)
                guard found == known else {
                    throw HolosError.unavailable("The Reading list at \(indexURL.path) is not the one Voice is Local "
                        + "read (another disk may be connected at that place, or another copy of Voice is Local "
                        + "changed it); it is not written over. Quit and open Voice is Local again to read it.")
                }
            }
            // The file written is the one renamed into place (a rename keeps its identity), known before it is.
            do {
                expected = .some(try Self.write(data, to: indexURL))
            } catch let placed as PlacedButNotFlushed {
                // The index there is this store's own now (its list, not flushed): the next save writes over it, so
                // the list the app goes on with (a failed addition taken back, a Delete mark cleared) replaces it.
                expected = .some(placed.identity)
                throw placed
            }
        }
    }

    /// Serializes `withIndexLock`'s callers in this process.
    private static let processLock = NSLock()

    /// Takes the place of `flock(descriptor, LOCK_EX)` on the index's lock (tests: a volume without `flock`).
    @TaskLocal static var lockCall: (@Sendable (Int32) -> Int32)? = nil

    /// Runs `body` holding the index's lock (`flock` on `.library.lock` in the folder, which must exist): a save of
    /// this index, or of a saved text, by another process waits. On a volume without `flock` (some network shares),
    /// the lock is a reservation file made exclusively instead (`.library.reservation`, see
    /// `ReadingOutputReservation`: one whose process ended is taken over): while another process holds it, this
    /// fails rather than run unlocked.
    func withIndexLock<T>(_ body: () throws -> T) throws -> T {
        // Callers in this process one at a time first (a save of the index and a saved text's, say): the lock across
        // processes then only ever meets another process, and its reservation (without `flock`) is never this
        // process's own.
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let path = folder.appendingPathComponent(".library.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw HolosError.io("Could not lock the Reading list (\(path)): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        let lock = { Self.lockCall?(descriptor) ?? flock(descriptor, LOCK_EX) }
        var locked = lock() == 0
        while !locked && errno == EINTR { locked = lock() == 0 }
        if locked {
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }
        guard errno == ENOTSUP || errno == EOPNOTSUPP else {
            throw HolosError.io("Could not lock the Reading list (\(path)): \(String(cString: strerror(errno)))")
        }
        let reservation: ReadingOutputReservation
        do {
            reservation = try ReadingOutputReservation.acquire(
                path: folder.appendingPathComponent(".library.reservation").path, output: indexURL)
        } catch {
            throw HolosError.unavailable("The Reading list is being saved by another copy of Voice is Local, so it "
                + "was not saved now: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        return try withExtendedLifetime(reservation) { try body() }
    }

    /// Keeps `document`, the text reading `id` reads, until the reading is finished or deleted. Never over a text
    /// saved for it already (one `document(for:)` could not see, its folder out of reach for a moment): that one is
    /// what the reading reads, and this save fails.
    public func saveDocument(_ document: ReadableDocument, for id: UUID) throws {
        if let reason = ReadingOutput.unreachableReason(for: documentURL(id)) {
            throw HolosError.unavailable("The folder of the saved texts is unavailable: \(reason).")
        }
        try FileManager.default.createDirectory(at: documentsFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder.reading.encode(document)
        // Under the index's lock: a launch of another copy of the app sweeping temporaries leaves this one's.
        try withIndexLock { try Self.write(data, to: documentURL(id), exclusive: true) }
    }

    /// The document saved for `id`, or nil when none was saved. One that is there but cannot be read or decoded is
    /// an error, never nil: a resume must not load its source again and read different text.
    public func document(for id: UUID) throws -> ReadableDocument? {
        let url = documentURL(id)
        let data: Data
        do {
            // Not blocked by a special file put in its place (see `openRegularFile`).
            let handle = try openRegularFile(url)
            defer { try? handle.close() }
            data = try handle.readToEnd() ?? Data()
        } catch let error as ReadingFileError where error.code == ENOENT {
            // Not found is "none saved" only where its folder can be looked into (a support folder on a drive that is
            // not connected would have the reading load its source again, and read other text).
            if let reason = ReadingOutput.unreachableReason(for: url) {
                throw HolosError.unavailable("The text saved for this reading is unavailable: \(reason).")
            }
            return nil
        }
        return try JSONDecoder.reading.decode(ReadableDocument.self, from: data)
    }

    /// Whether a text is saved for `id`.
    public func hasDocument(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: documentURL(id).path)
    }

    /// Removes the text saved for `id`, and any copy of it a save that a quit or a crash cut off left (see
    /// `write`); one that is not there is not an error.
    public func removeDocument(for id: UUID) throws {
        // No saved-texts folder: nothing saved, nor being saved (a save makes the folder first; a folder made
        // after this look-up holds a text saved after this removal was asked). Only where it can be reached.
        if let reason = ReadingOutput.unreachableReason(for: documentURL(id)) {
            throw HolosError.unavailable("The folder of the saved texts is unavailable: \(reason).")
        }
        guard try ReadingOutput.exists(documentsFolder) else { return }
        // The text and its temporaries under the index's lock, which a save holds from its temporary to its
        // publication: a save by another process is either done (and its text removed here) or not begun.
        try withIndexLock {
            do {
                try FileManager.default.removeItem(at: documentURL(id))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
            }
            try removeTemporaries(in: documentsFolder) { $0 == documentURL(id).lastPathComponent }
        }
    }

    func documentURL(_ id: UUID) -> URL {
        documentsFolder.appendingPathComponent("\(id.uuidString).json")
    }

    /// Removes what saves that a quit or a crash cut off left (the index's and the saved texts' temporaries, see
    /// `write`). For the launch, before anything is saved: a save under way would lose its temporary.
    public func sweepTemporaries() {
        // Under the index's lock: another process's save under way (of the index or of a saved text) keeps its
        // temporary.
        guard (try? ReadingOutput.exists(folder)) == true else { return }
        _ = try? withIndexLock {
            try? removeTemporaries(in: folder) { $0 == indexURL.lastPathComponent }
            try? removeTemporaries(in: documentsFolder) { name in
                name.hasSuffix(".json") && UUID(uuidString: String(name.dropLast(5))) != nil
            }
        }
    }

    /// Removes the temporaries `write` makes in `folder` for the files whose names `target` accepts:
    /// `.<name>.<UUID>.tmp`, regular files owned by this user. A folder that is not there has none.
    func removeTemporaries(in folder: URL, target: (String) -> Bool) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
        for name in names {
            guard let file = Self.temporaryTarget(name), target(file) else { continue }
            let path = folder.appendingPathComponent(name).path
            var metadata = stat()
            guard lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == getuid() else { continue }
            guard unlink(path) == 0 || errno == ENOENT else {
                throw HolosError.io("Could not remove \(path): \(String(cString: strerror(errno)))")
            }
        }
    }

    /// The file a temporary named `.<name>.<UUID>.tmp` (see `write`) was for, or nil for any other name.
    static func temporaryTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return nil }
        let middle = name.dropFirst().dropLast(4)
        guard let dot = middle.lastIndex(of: "."), UUID(uuidString: String(middle[middle.index(after: dot)...])) != nil
        else { return nil }
        let target = middle[..<dot]
        return target.isEmpty ? nil : String(target)
    }

    /// Writes `data` to a new temporary beside `url` (0600), then renames it over `url`; returns the identity of the
    /// file written, read from it before the rename. A temporary that is not renamed is removed.
    /// `exclusive`: never over a file already at `url` (an exclusive rename, else a hard link where the volume has no
    /// exclusive rename); the save fails instead.
    @discardableResult
    private static func write(_ data: Data, to url: URL, exclusive: Bool = false) throws -> ReadingFileIdentity {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let failure = { (reason: String) in
            HolosError.io("Could not save \(url.lastPathComponent) in \(url.deletingLastPathComponent().path): \(reason)")
        }
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw failure(String(cString: strerror(errno))) }
        let written = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let identity: ReadingFileIdentity
        do {
            try written.write(contentsOf: data)
            // On the disk before it takes the place of the file there: a save that reports success is what a crash
            // or a drive pulled out leaves (the files removed after it rely on it).
            if fsync(descriptor) != 0, errno != ENOTSUP, errno != EINVAL {
                throw failure(String(cString: strerror(errno)))
            }
            guard let known = ExclusivePublisher.FileIdentity.of(descriptor: descriptor) else {
                throw failure(String(cString: strerror(errno)))
            }
            identity = known
            try written.close()
        } catch {
            // A copy cut off (a full disk) is not left.
            try? written.close()
            _ = unlink(temporary.path)
            throw error
        }
        if exclusive {
            // Never over a file there: an exclusive rename, else (a volume without one, or without hard links) an
            // exclusive copy (see `ExclusivePublisher.publish`), whose file is then the one saved.
            var saved = identity
            do {
                try ExclusivePublisher.publish(temporary, to: url, existing: "Already saved",
                                               isCancelled: { false }) { saved = $0 }
            } catch {
                _ = unlink(temporary.path)
                throw HolosError.io("Could not save \(url.lastPathComponent): \(error.localizedDescription)")
            }
            try syncFolder(of: url, placed: saved)
            return saved
        }
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = unlink(temporary.path)
            throw HolosError.io("Could not save \(url.lastPathComponent): \(reason)")
        }
        try syncFolder(of: url, placed: identity)
        return identity
    }

    /// Flushes the folder holding `url` (its new name). Only a volume that cannot flush a folder is let off; any
    /// other failure (an I/O error) fails the save, which then does not count: nothing is removed on its word.
    /// The failure is `PlacedButNotFlushed`, naming the file now at `url` (`placed`).
    private static func syncFolder(of url: URL, placed: ReadingFileIdentity) throws {
        let path = url.deletingLastPathComponent().path
        let failed = { PlacedButNotFlushed(identity: placed, message: "Could not save \(url.lastPathComponent): \(path): "
                                               + String(cString: strerror(errno))) }
        let folder = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard folder >= 0 else { throw failed() }
        defer { close(folder) }
        let synced = (folderSync?(folder) ?? fsync(folder)) == 0
        guard synced || errno == ENOTSUP || errno == EINVAL || errno == EOPNOTSUPP else { throw failed() }
    }

    /// Takes the place of `fsync` on a saved file's folder (tests: a flush that fails).
    @TaskLocal static var folderSync: (@Sendable (Int32) -> Int32)? = nil

    /// A save put its file in place, but its folder could not be flushed: the save failed (it may not last), and the
    /// file at its place is `identity`, this store's own, which the next save may write over.
    struct PlacedButNotFlushed: LocalizedError {
        let identity: ReadingFileIdentity
        let message: String
        var errorDescription: String? { message }
    }

    /// The entries of a newer build's index that this build can read.
    private static func lenientEntries(_ data: Data) -> [ReadingEntry] {
        struct Lenient: Decodable {
            struct Maybe: Decodable {
                let entry: ReadingEntry?
                init(from decoder: any Decoder) throws { entry = try? ReadingEntry(from: decoder) }
            }
            let entries: [Maybe]
        }
        return ((try? JSONDecoder.reading.decode(Lenient.self, from: data))?.entries ?? []).compactMap(\.entry)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// The Reading list's decisions and the work on a reading's files, as static functions in extensions: launch and
/// quit (`+LaunchPolicy`), where a reading's file and cache go (`+Location`), whether the file at its output is its
/// own (`+Ownership`), what a made reading's file is now (`+FileStatus`), Share… copies (`+Sharing`), Delete
/// (`+Deletion`), and the cache of a reading begun before (`+Saved`).
public enum ReadingLibrary {
}

extension JSONEncoder {
    static var reading: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var reading: JSONDecoder { JSONDecoder() }
}
