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

/// The decisions about the list that do not touch the disk.
public enum ReadingLibrary {
    /// What the app does with the list it loaded at launch: the readings whose deletion a quit interrupted (to
    /// finish deleting), the list without them after `afterLaunch`, and the readings to continue. A list a newer
    /// build wrote (`writable` false) is shown exactly as loaded: nothing is deleted, changed, or continued.
    public static func launchPlan(_ loaded: ReadingLibraryStore.Loaded)
        -> (entries: [ReadingEntry], resume: [UUID], delete: [ReadingEntry]) {
        guard loaded.writable else { return (loaded.entries, [], []) }
        let delete = loaded.entries.filter { $0.deletePending == true }
        let (entries, resume) = afterLaunch(loaded.entries.filter { $0.deletePending != true })
        return (entries, resume, delete)
    }

    /// The list as the app finds it at launch (a reading marked for deletion is left as it is, for the caller to
    /// finish deleting): a reading that was waiting or being made when Voice is Local quit
    /// continues when the user chose Keep Rendering (`resumeOnLaunch`; it is returned in `resume`: the one that was
    /// being made first, then the waiting ones oldest first, as they were asked for), and is otherwise shown as
    /// stopped, with Resume. `resumeOnLaunch` is used once.
    public static func afterLaunch(_ entries: [ReadingEntry]) -> (entries: [ReadingEntry], resume: [UUID]) {
        var result = entries
        var first: [ReadingEntry] = [], rest: [ReadingEntry] = []
        for index in result.indices where result[index].isActive && result[index].deletePending != true {
            if result[index].resumeOnLaunch {
                if result[index].state == .rendering { first.append(result[index]) } else { rest.append(result[index]) }
                result[index].state = .queued
            } else {
                result[index].state = .stopped
                result[index].message = "Voice is Local quit while this reading was being made."
            }
            result[index].resumeOnLaunch = false
        }
        let order = { (lhs: ReadingEntry, rhs: ReadingEntry) in lhs.created < rhs.created }
        return (result, (first.sorted(by: order) + rest.sorted(by: order)).map(\.id))
    }

    /// A reading whose deletion could not remove its files, back in the list: unmarked, with the reason, and, when it
    /// was waiting or being made (its render has stopped by then), stopped and never continued at a launch.
    /// `aside`: where its file was left, when it was moved aside and could not be put back (see `DeleteResult`).
    public static func afterFailedDelete(_ entry: ReadingEntry, problem: String, aside: String? = nil) -> ReadingEntry {
        var entry = entry
        entry.deletePending = nil
        entry.message = problem
        entry.outputAside = aside
        entry.resumeOnLaunch = false
        if entry.isActive { entry.state = .stopped }
        return entry
    }

    /// The list as saved when Voice is Local quits with readings waiting or being made: `keep` (Keep Rendering)
    /// continues them at the next launch; otherwise (Stop) they are stopped, each with Resume.
    public static func forQuit(_ entries: [ReadingEntry], keep: Bool) -> [ReadingEntry] {
        entries.map { entry in
            guard entry.isActive else { return entry }
            var entry = entry
            if keep {
                entry.resumeOnLaunch = true
            } else {
                entry.state = .stopped
                entry.message = "Stopped when Voice is Local quit."
                entry.resumeOnLaunch = false
            }
            return entry
        }
    }

    /// A new file in `folder` named after the title (see `ReadingOutput.fileName`): "Title.m4a", else "Title 2.m4a",
    /// "Title 3.m4a", …, skipping names another reading of the list will write (`taken`) and names already on disk
    /// (`exists`). A name is taken when it names the same file as one in `taken` through any path: the folders are
    /// compared with their links resolved (an output folder reached through a link, as the list saves the resolved
    /// path), and names without case, as the Mac's volumes compare them. The folder and the name (in NFC, as
    /// `ReadingOutput.fileName` makes it) keep their spelling (see `RawFilePath`). When every numbered name is taken,
    /// "Title 1a2b3c4d.m4a", its stem shortened so that it fits the volume's 255-unit name limit too.
    public static func outputURL(in folder: URL, title: String?, fallback: String?, taken: Set<String>,
                                 exists: (URL) -> Bool) -> URL {
        let suffix = { (text: String) in " \(text).\(ReadingAudioFormat.fileExtension)" }
        func stem(room: Int) -> String {
            let name = ReadingOutput.fileName(title: title, fallback: fallback, limit: ReadingOutput.defaultNameLimit - room)
            return String(name.dropLast(ReadingAudioFormat.fileExtension.count + 1))
        }
        // Room for " 999" in the volume's 255-unit name limit.
        let numbered = stem(room: " 999".utf8.count)
        let takenKeys = Set(taken.map(outputKey))
        func free(_ candidate: URL) -> Bool { !takenKeys.contains(outputKey(candidate.path)) && !exists(candidate) }
        for number in 1...999 {
            let candidate = RawFilePath.appending(number == 1 ? numbered + "." + ReadingAudioFormat.fileExtension
                : numbered + suffix(String(number)), to: folder)
            if free(candidate) { return candidate }
        }
        // Room for " " and eight hex digits.
        let short = stem(room: suffix(String(repeating: "0", count: 8)).utf8.count - ReadingAudioFormat.fileExtension.count - 1)
        var candidate = RawFilePath.appending(short + suffix(String(UUID().uuidString.prefix(8))), to: folder)
        for _ in 0..<8 where !free(candidate) {
            candidate = RawFilePath.appending(short + suffix(String(UUID().uuidString.prefix(8))), to: folder)
        }
        return candidate
    }

    /// One key for every path that names the same output: its folder's links resolved (`ReadingPathIdentity`), then
    /// case and Unicode normalization folded (the conservative rule: two names that may be one file count as one).
    static func outputKey(_ path: String) -> String {
        ReadingPathIdentity.key(path: path, .lock).precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
    }

    /// Whether `path` is a render cache the pipeline made in `readingsRoot` for a reading with an explicit output
    /// (`Output-` and 16 lowercase hex digits, directly inside it): the only kind of folder Delete removes, whatever
    /// the index says.
    public static func isRenderCache(_ path: String, in readingsRoot: URL) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == readingsRoot.standardizedFileURL.path else { return false }
        let name = url.lastPathComponent
        let prefix = "Output-"
        guard name.hasPrefix(prefix) else { return false }
        let digest = name.dropFirst(prefix.count)
        return digest.count == 16 && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    /// A reading's file was not found, but the folder that holds it cannot be reached: it may come back.
    public struct OutputUnreachable: LocalizedError, Equatable {
        public let file: String
        /// "the drive or share “Backup” is not connected".
        public let reason: String

        public var errorDescription: String? {
            "\(file) is unavailable: \(reason). Connect it, then try again."
        }
    }

    /// What the file at a reading's output path is to that reading.
    public enum OutputOwnership: Sendable, Equatable {
        /// The finished file it published (its checksum matches the entry's or the cache manifest's).
        case finished
        /// A copy into the destination that a crash cut off, named by the cache manifest's `publishing` identity.
        case partial(ReadingFileIdentity)
    }

    /// Whether the file at `output` is this reading's: the finished file (`sha256`, else the checksum the render
    /// cache's manifest saved for that output), or its own partly copied file (the manifest's `publishing`
    /// identity). Nil for anything else (a file put there since, or nothing there): Delete leaves it alone. Throws
    /// when that cannot be told (the file or the manifest cannot be read), so nothing that identifies it is removed;
    /// `OutputUnreachable` when nothing is found but the folder that holds it cannot be reached (its drive or share
    /// is not connected), and something of the reading's may be there.
    public static func ownership(of output: URL, sha256: String?, cache: URL?, made: Bool = false) throws
        -> OutputOwnership? {
        guard try ReadingOutput.exists(output) else {
            // Not found is "gone" only where the folder can be looked into: a drive that is not connected brings the
            // file back when it is, and the reading must still be there to delete it then. Unless nothing of the
            // reading's can be there (no finished file, no copy begun); a manifest that cannot be read may name one.
            if let reason = ReadingOutput.unreachableReason(for: output) {
                let evidence = try? ownershipEvidence(of: output, sha256: sha256, cache: cache, made: made)
                if evidence.map({ !$0.checksums.isEmpty || $0.publishing != nil }) ?? true {
                    throw OutputUnreachable(file: output.lastPathComponent, reason: reason)
                }
            }
            return nil
        }
        let evidence = try ownershipEvidence(of: output, sha256: sha256, cache: cache, made: made)
        if !evidence.checksums.isEmpty, evidence.checksums.contains(try fileSHA256(output)) { return .finished }
        // A lookup that fails (not "nothing there") throws: it says nothing about which file is there.
        if let claimed = evidence.publishing, try evidence.isPartial(output) { return .partial(claimed) }
        return nil
    }

    /// What identifies the reading's files (see `ownershipEvidence`).
    struct Evidence: Equatable {
        /// The checksums of its finished file.
        var checksums: [String]
        /// The identity of a copy into the output a crash cut off.
        var publishing: ReadingFileIdentity?
        /// The finished file's size, when known: a copy cut off is smaller.
        var finishedSize: Int64?

        /// Whether the file at `url` is the copy a crash cut off: the file `publishing` names, and smaller than the
        /// finished file when its size is known (one as large is the finished copy, edited in place since: it is
        /// never removed as a partial one). A look-up that fails throws.
        func isPartial(_ url: URL) throws -> Bool {
            guard let publishing, let found = try ReadingLibrary.FileVersion.of(url), found.identity == publishing
            else { return false }
            return finishedSize.map { found.size < $0 } ?? true
        }
    }

    /// What identifies the reading's file at `output`: the checksums of its finished file (`sha256`, and the one
    /// the cache's manifest saved for that output) and the identity of a copy a crash cut off. For a made reading
    /// (`made`) there is no such copy: the copy was finished, so the file with that identity is its finished file,
    /// edited in place when its checksum no longer matches, never a partial one to remove.
    static func ownershipEvidence(of output: URL, sha256: String?, cache: URL?, made: Bool = false) throws
        -> Evidence {
        var manifest: ReadingManifest?
        if let cache {
            let url = cache.appendingPathComponent(ReadingManifest.fileName)
            if try ReadingOutput.exists(url) {  // only "no such file" is no manifest
                // A manifest that is there but cannot be read, is too large, or is not a reading's may hold the
                // only identity of a partly copied file: that is an error, never "not the reading's".
                // Opened without waiting, and read only up to its limit (see `readSmallFile`).
                let saved = try JSONDecoder().decode(
                    ReadingManifest.self, from: try readSmallFile(url, maximumBytes: ReadingManifest.maximumBytes))
                guard saved.kind == ReadingManifest.readingKind else {
                    throw HolosError.io("\(url.path) is not a Voice is Local reading's manifest.")
                }
                // One made for another output says nothing about this file.
                if sameFile(saved.output, output) { manifest = saved }
            }
        }
        return Evidence(checksums: [sha256, manifest?.outputSHA256].compactMap { $0 },
                        publishing: made ? nil : manifest?.publishing, finishedSize: manifest?.outputSize)
    }

    /// The identity of the file at `output` when it is the finished file whose checksum is `sha256`, and the file read
    /// is the file named (the same identity before and after); nil otherwise or when it cannot be read. For a made
    /// reading whose identity could not be recorded when it was made. Reads the whole file: not on the main actor.
    public static func verifiedIdentity(of output: URL, sha256: String) -> ReadingFileIdentity? {
        guard let before = try? ExclusivePublisher.FileIdentity.lookup(output),
              (try? fileSHA256(output)) == sha256,
              (try? ExclusivePublisher.FileIdentity.lookup(output)) == before else { return nil }
        return before
    }

    /// What a made reading's file is now, as its row shows it (see `fileStatus`).
    public enum FileStatus: Sendable, Equatable {
        /// Its file is there, the one it made (by identity); `size` in bytes.
        case available(size: Int64?)
        /// A regular file is at its path, but its identity is not the one recorded (or none was): it may still be the
        /// reading's file (a share mounted again gets a new device number; see `ExclusivePublisher.FileIdentity`),
        /// which only its checksum tells (`revalidate`). `found` is the file there, as it was then.
        case changed(found: FileVersion)
        /// Nothing (or no regular file) is at its path: it was moved or deleted.
        case missing
        /// The folder that holds it cannot be reached (its drive or share is not connected, or it answers with an
        /// error): the file may come back.
        case unavailable(String)
    }

    /// A file as it was at one moment: which file (its identity), and its size and last change, so a checksum read
    /// while it was being written (a file copied back into place) is known for what it is.
    public struct FileVersion: Sendable, Equatable {
        public let identity: ReadingFileIdentity
        public let size: Int64
        public let modifiedSeconds: Int64
        public let modifiedNanoseconds: Int64

        /// The regular file at `url` now (a link is not followed); nil when nothing is there or it is not a regular
        /// file. Any other failure throws.
        static func of(_ url: URL) throws -> FileVersion? {
            guard let identity = try ExclusivePublisher.FileIdentity.lookup(url) else { return nil }
            var metadata = stat()
            guard lstat(RawFilePath.system(url), &metadata) == 0 else {
                let error = errno
                if error == ENOENT { return nil }
                throw HolosError.io("Could not check \(url.path): \(String(cString: strerror(error)))")
            }
            return FileVersion(identity: identity, size: Int64(metadata.st_size),
                               modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
                               modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec))
        }
    }

    /// The status of a made reading's file, from its metadata alone (the file is not read). Not on the main actor: a
    /// look-up on a share whose server stopped answering waits for its timeout.
    public static func fileStatus(of entry: ReadingEntry) -> FileStatus {
        guard let output = entry.outputURL else { return .missing }
        let found: FileVersion?
        do {
            found = try FileVersion.of(output)
        } catch {
            return .unavailable("\((output.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) "
                + "cannot be reached (\(error.localizedDescription))")
        }
        guard let found else { return ReadingOutput.unreachableReason(for: output).map { .unavailable($0) } ?? .missing }
        guard let made = entry.outputIdentity, made == found.identity else { return .changed(found: found) }
        return .available(size: found.size)
    }

    /// What reading a changed file's checksum found (see `revalidate`).
    public enum Revalidation: Sendable, Equatable {
        /// It is the reading's file: the identity to record.
        case same(ReadingFileIdentity)
        /// Another file (its checksum is not the reading's).
        case different
        /// It could not be told (the file could not be read, or it changed during the check): try again later.
        case unknown
    }

    /// Whether the file whose status is `.changed(found)` is the made reading's: `.same` with its identity when its
    /// checksum is the reading's. Either answer holds only when the file is still `found` (the same file, size, and
    /// last change) after the check: one written meanwhile is `.unknown`. Reads the whole file: not on the main
    /// actor; a cancelled task stops between chunks (`.unknown`).
    public static func revalidate(_ entry: ReadingEntry, found: FileVersion) -> Revalidation {
        guard let output = entry.outputURL, let sha256 = entry.outputSHA256 else { return .different }
        let checksum: String
        do {
            checksum = try fileSHA256(output)
        } catch {
            return .unknown
        }
        guard (try? FileVersion.of(output)) == found else { return .unknown }
        return checksum == sha256 ? .same(found.identity) : .different
    }

    /// The folder new readings' files go to, checked (see `location`): the default one is made when missing; one
    /// chosen in Settings that is missing (its disk is not connected) is not, so nothing is written on the startup
    /// disk in its place. `shown` is how the folder is named in the message.
    public static func outputFolder(_ folder: URL, isDefault: Bool, shown: String) throws -> URL {
        if isDefault {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            // `stat` on the path as spelled (`FileManager` would decompose it).
            var metadata = stat()
            guard stat(RawFilePath.system(folder), &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw HolosError.unavailable("The folder \(shown) chosen in Settings › Reading is not available. "
                    + "Connect its disk, or choose another folder there, then Try Again.")
            }
        }
        return folder
    }

    /// Where a reading's file and render cache go when it starts: the file chosen when it first started (`chosen`),
    /// unless something else took that name since (no render cache of this reading, but a file there) or its cache is
    /// another reading's (`otherCaches`); else a new name (see `outputURL`) in `folder()`, never one another reading
    /// of the list writes (`taken`) nor one whose cache is another reading's (the same text, voice, and settings
    /// reach the same cache through the same file: two entries would share, and delete, one another's file).
    /// Checks and creates what `ReadingOutput.locate` does: not on the main actor.
    public static func location(chosen: URL?, folder: () throws -> URL, title: String?, fallback: String?,
                                name: String, identity: String, readingsRoot: URL, taken: [String],
                                otherCaches: [String]) throws -> ReadingLocation {
        let claimedCaches = Set(otherCaches.map(cacheKey))
        func claimed(_ location: ReadingLocation) -> Bool { claimedCaches.contains(cacheKey(location.workDirectory.path)) }
        if let chosen {
            let found = try ReadingOutput.locate(output: chosen.path, name: name, identity: identity,
                                                 readingsRoot: readingsRoot, resume: true)
            if !claimed(found), try ReadingOutput.exists(found.workDirectory) || !ReadingOutput.exists(found.output) {
                return found
            }
        }
        let folder = try folder()
        var taken = Set(taken)
        for _ in 0..<8 {
            let url = outputURL(in: folder, title: title, fallback: fallback, taken: taken) { url in
                (try? ReadingOutput.exists(url)) ?? true
            }
            let location = try ReadingOutput.locate(output: url.path, name: name, identity: identity,
                                                    readingsRoot: readingsRoot, resume: false)
            if !claimed(location) { return location }
            taken.insert(url.path)
        }
        throw HolosError.unavailable("No free name was found for the reading's file in \(folder.path).")
    }

    private static func cacheKey(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// The file at `output` opened for reading when the object opened is the one `identity` names (checked on the
    /// open descriptor, not the path): an action that reads through it (Play, Share…) uses that very file, whatever
    /// is put at the path at any moment. Nil when it is not there, not a regular file, or another file. Opened without
    /// waiting (see `openRegularFile`): a FIFO or a device put at the path is refused at once. Not on the main actor:
    /// an open on a share whose server stopped answering waits for its timeout.
    public static func openVerified(_ output: URL, identity: ReadingFileIdentity) -> FileHandle? {
        guard let handle = try? openRegularFile(output, followLinks: false),
              ExclusivePublisher.FileIdentity.of(descriptor: handle.fileDescriptor) == identity else { return nil }
        return handle
    }

    /// This process's folder for Share… copies inside `base`: `<process ID>-<start time>`, so another copy of the app
    /// running meanwhile never removes the copies it hands to a service.
    public static func sharingFolder(in base: URL) -> URL {
        let pid = getpid()
        return base.appendingPathComponent("\(pid)-\(ReadingOutputReservation.processStart(pid) ?? 0)", isDirectory: true)
    }

    /// Removes the Share… copies of processes that have ended (their services are done with them by now), and those
    /// an earlier build left directly in `base`. Not on the main actor.
    public static func sweepSharingFolders(in base: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        for name in names {
            let parts = name.split(separator: "-", maxSplits: 1)
            if parts.count == 2, let pid = Int32(parts[0]), let start = Int64(parts[1]),
               ReadingOutputReservation.processStart(pid) == start { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    /// A copy of the open file `file`, named `name`, in a new folder inside `folder`: a clone (instant, no space)
    /// where the volume can, else its bytes. What Share… hands to the services, which read it later.
    public static func copyForSharing(_ file: FileHandle, name: String, into folder: URL) throws -> URL {
        let holder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let copy = RawFilePath.appending(name, to: holder)
        if fclonefileat(file.fileDescriptor, AT_FDCWD, RawFilePath.system(copy), 0) == 0 { return copy }
        do {
            let output = open(RawFilePath.system(copy), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw HolosError.io("Could not copy \(name): \(String(cString: strerror(errno)))") }
            let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
            try file.seek(toOffset: 0)
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
            try writer.close()
            return copy
        } catch {
            // A copy cut off (a full disk) is not left taking space until the next launch.
            try? FileManager.default.removeItem(at: holder)
            throw error
        }
    }

    /// Whether `path` (a manifest's output) names the file `output` names: spelled the same, or, through links in
    /// its folder or another spelling the volume takes for the same name, the same file (`ReadingPathIdentity`,
    /// by exact identity: two names the volume may tell apart are two files).
    static func sameFile(_ path: String, _ output: URL) -> Bool {
        // Compared as bytes: Foundation's paths and Swift's `==` take NFC and NFD spellings for one, which a volume
        // that keeps them apart holds as two files.
        if path.utf8.elementsEqual(output.path.utf8) { return true }
        return ReadingPathIdentity.key(path: path, .exact).utf8.elementsEqual(ReadingPathIdentity.key(output, .exact).utf8)
    }

    /// What a removal of one of the reading's files left to tell: the problem (nil when the file is gone), and where a
    /// file it moved aside to check stayed because it could not be put back.
    struct RemovalReport: Equatable {
        var problem: String?
        var keptAt: String?
    }

    /// Moves the reading's finished file at `output` to the Trash only once it is the very file that was checked:
    /// it is first moved into a private folder beside it (same volume, same name), where nothing else can take its
    /// place, then checked against `checksums`, then given to `trash`. A file that no longer matches, or that `trash`
    /// refuses, goes back to `output` (never over something put there meanwhile). `token` names the private folder
    /// (see `asideToken`).
    static func trashVerified(_ output: URL, checksums: [String], token: String? = nil,
                              trash: (URL) throws -> Void) -> RemovalReport {
        let name = output.lastPathComponent
        // A file that cannot be read is a failure (it goes back), never "not the reading's".
        let removal = ExclusivePublisher.removeVerified(output, token: token, matches: { staged in
            checksums.contains(try fileSHA256(staged))
        }, dispose: trash)
        return report(removal, name: name, action: "moved to the Trash", reportChanged: true)
    }

    /// Removes the copy into `output` that a crash cut off, only while it is that very file (`identity`), through
    /// the same move-aside-then-check step as the finished file. No problem when it is gone: one replaced by another
    /// file since is gone too (the other file is left alone). `token` names the place aside (see `asideToken`).
    /// `dispose` takes the file (default: removed; a Delete moves it to the Trash, so a file that only looked like a
    /// cut-off copy, the finished one shortened in place, can still be had back).
    static func removePartial(_ output: URL, identity: ReadingFileIdentity, token: String? = nil,
                              dispose: (URL) throws -> Void = ExclusivePublisher.removeFile) -> RemovalReport {
        report(ExclusivePublisher.removeIfIdentical(output, to: identity, token: token, dispose: dispose),
               name: "The partly written \(output.lastPathComponent)", action: "removed", reportChanged: false)
    }

    /// What to tell about a removal of the reading's file `name`. One that no longer matches (a file put there
    /// since) is left alone; it is a problem when `reportChanged` (the Trash: the user expects the file gone) or when
    /// it could not be put back.
    private static func report(_ removal: ExclusivePublisher.Removal, name: String, action: String,
                               reportChanged: Bool) -> RemovalReport {
        func kept(_ path: String?) -> String { path.map { " It is kept at \($0)." } ?? "" }
        switch removal {
        case .removed, .absent:
            return RemovalReport()
        case .notMatching(let keptAt):
            guard reportChanged || keptAt != nil else { return RemovalReport() }
            return RemovalReport(problem: "\(name) changed before it could be \(action), so it was left in place."
                                    + kept(keptAt), keptAt: keptAt)
        case .failed(let reason, let keptAt):
            return RemovalReport(problem: "\(name) could not be \(action): \(reason)"
                                    + (reason.hasSuffix(".") ? "" : ".") + kept(keptAt), keptAt: keptAt)
        }
    }

    /// The private folder beside its file that a reading's Delete moves the file into (under its own name):
    /// `.holos-delete-<entry ID>` for the finished file, that plus ".partial" for the partly written copy. Derived
    /// from the entry, so a Delete that a quit or a crash cut off after the move finds the file there next time.
    static func asideToken(_ id: UUID, partial: Bool) -> String {
        ExclusivePublisher.removalPrefix + id.uuidString + (partial ? ".partial" : "")
    }

    /// Where a Delete of `entry` may have left its file aside: the places `asideToken` names beside its output, the
    /// one its render moves a partly written file into to remove it (`ReadingTemporaries.publicationAside`), and
    /// `outputAside`.
    static func asideCandidates(of entry: ReadingEntry) -> [URL] {
        guard let output = entry.outputURL else { return [] }
        let folder = output.deletingLastPathComponent()
        var candidates = [false, true].map { partial in
            RawFilePath.appending(output.lastPathComponent,
                                  to: RawFilePath.appending(asideToken(entry.id, partial: partial), to: folder))
        }
        if let cache = entry.cache {
            candidates.append(ReadingTemporaries.publicationAside(
                output: output, key: ReadingTemporaries.key(for: URL(fileURLWithPath: cache, isDirectory: true))))
        }
        if let recorded = entry.outputAside,
           !candidates.contains(where: { $0.path.utf8.elementsEqual(recorded.utf8) }) {
            candidates.append(ReadingOutput.fileURL(keepingSpelling: recorded))
        }
        return candidates
    }

    /// What `deleteFiles` did: nil `problem` when every file is gone; otherwise the problems, and `aside`, where a
    /// file of the reading (or one that could not be told) stays after it was moved aside and could not be put back,
    /// for the entry to keep (`ReadingEntry.outputAside`) so the next Delete deals with it.
    public struct DeleteResult: Sendable, Equatable {
        public var problem: String?
        public var aside: String?
        /// With no problem: something to tell although the reading is deleted (its file had changed since it was
        /// made, so it was left in place).
        public var note: String?

        public init(problem: String? = nil, aside: String? = nil, note: String? = nil) {
            self.problem = problem
            self.aside = aside
            self.note = note
        }
    }

    /// Removes a deleted reading's files. Only the reading's own output is touched (see `ownership`): its finished
    /// file goes to `trash`, a copy a crash cut off is removed, and anything else at that path is left alone; the
    /// same, first, for a file an earlier Delete left aside (`asideCandidates`). While such a file is still there the
    /// render cache stays, since its manifest is what identifies the file next time. The cache is removed only when
    /// it is one the pipeline made directly in `readingsRoot` (`isRenderCache`); then the saved text is removed. A
    /// cache or text that cannot be looked up (not "not there") is a problem, so the entry stays for another try.
    ///
    /// All of it happens holding the cache's render lock (`ReadingDirectoryLock`), so a render of the same cache in
    /// another process (`voiceislocal read --resume`) never has its cache removed under it, nor publishes a file
    /// after it was checked for: while one runs, nothing is removed and the entry stays.
    public static func deleteFiles(of entry: ReadingEntry, readingsRoot: URL?, store: ReadingLibraryStore,
                                   trash: (URL) throws -> Void) -> DeleteResult {
        let keep = { (problem: String) in DeleteResult(problem: problem, aside: entry.outputAside) }
        var lock: ReadingDirectoryLock?
        if let cache = entry.cache, let readingsRoot, isRenderCache(cache, in: readingsRoot) {
            let directory = URL(fileURLWithPath: cache, isDirectory: true)
            do {
                // No Readings folder, no cache and no render to wait for.
                if try ReadingOutput.exists(directory.deletingLastPathComponent()) {
                    lock = try ReadingDirectoryLock.acquire(for: directory)
                }
            } catch let error as HolosError {
                if case .unavailable = error {
                    return keep("It is being made by another process (voiceislocal read); stop that first, then "
                        + "Delete again.")
                }
                return keep("Its rendered parts in \(cache) could not be checked: \(error.localizedDescription) "
                    + "Try Delete again.")
            } catch {
                return keep("Its rendered parts in \(cache) could not be checked: \(error.localizedDescription) "
                    + "Try Delete again.")
            }
        }
        return withExtendedLifetime(lock) {
            deleteFilesLocked(of: entry, readingsRoot: readingsRoot, store: store, trash: trash)
        }
    }

    private static func deleteFilesLocked(of entry: ReadingEntry, readingsRoot: URL?, store: ReadingLibraryStore,
                                          trash: (URL) throws -> Void) -> DeleteResult {
        var problems: [String] = []
        var aside: String?
        var note: String?
        if let output = entry.outputURL {
            let cache = entry.cache.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let owned: OutputOwnership?
            let evidence: Evidence
            do {
                let made = entry.state == .done
                owned = try ownership(of: output, sha256: entry.outputSHA256, cache: cache, made: made)
                evidence = try ownershipEvidence(of: output, sha256: entry.outputSHA256, cache: cache, made: made)
            } catch let unreachable as OutputUnreachable {
                // Kept whole (row, cache, text) until the file can be looked for again.
                return DeleteResult(problem: "\(unreachable.file) is unavailable: \(unreachable.reason). "
                                        + "Connect it, then Delete again.", aside: entry.outputAside)
            } catch {
                return DeleteResult(problem: "\(output.lastPathComponent) could not be checked: "
                                        + "\(error.localizedDescription) Try Delete again.", aside: entry.outputAside)
            }
            for candidate in asideCandidates(of: entry) where aside == nil {
                let report = removeAside(candidate, evidence: evidence, trash: trash)
                if let problem = report.problem {
                    problems.append(problem)
                    aside = report.keptAt ?? candidate.path
                }
            }
            if aside == nil {
                // Only ever the entry's own place aside, which the next Delete looks in (a quit or a crash may come
                // before anything records where the file went); something still there (that could not be removed)
                // stops the Delete rather than send the file somewhere no later Delete would find it.
                func blocked(partial: Bool) -> String? {
                    let token = asideToken(entry.id, partial: partial)
                    let place = RawFilePath.appending(token, to: output.deletingLastPathComponent())
                    guard (try? ReadingOutput.exists(place)) != false else { return nil }
                    return "\(output.lastPathComponent) was not moved: \(place.path), left by an earlier Delete, is in "
                        + "the way. Remove it in Finder, then Delete again."
                }
                let report: RemovalReport
                switch owned {
                case .finished? where blocked(partial: false) != nil:
                    report = RemovalReport(problem: blocked(partial: false))
                case .partial? where blocked(partial: true) != nil:
                    report = RemovalReport(problem: blocked(partial: true))
                case .finished?:
                    report = trashVerified(output, checksums: evidence.checksums,
                                           token: asideToken(entry.id, partial: false), trash: trash)
                case .partial(let identity)?:
                    report = removePartial(output, identity: identity, token: asideToken(entry.id, partial: true),
                                           dispose: trash)
                case nil:
                    // A look-up that fails (not "nothing there") tells nothing: the reading stays for another try.
                    let present: Bool
                    do {
                        present = try ReadingOutput.exists(output)
                    } catch {
                        return DeleteResult(problem: "\(output.lastPathComponent) could not be checked: "
                                                + "\(error.localizedDescription) Try Delete again.", aside: entry.outputAside)
                    }
                    // Or a copy it began is named (as large as the finished file: it cannot be told from that
                    // file edited since).
                    if present, entry.state != .done, !evidence.checksums.isEmpty || evidence.publishing != nil {
                        // An unfinished reading whose manifest holds the finished file's checksum was being saved
                        // when it stopped: the file there may be the one it began (created before its identity was
                        // saved). It cannot be told, so the reading stays until the user decides.
                        report = RemovalReport(problem: "A file is at \(output.path), where this reading was being "
                            + "saved when it stopped, and it cannot be told whether it is this reading's. Remove it in "
                            + "Finder if it is, then Delete again.")
                    } else {
                        report = RemovalReport()
                        // A made reading's file that is there but no longer matches (edited in place, or replaced)
                        // is left alone, and said so: Delete promised to move it to the Trash.
                        if present, entry.state == .done {
                            note = "\(output.lastPathComponent) changed since it was made, so it was left in place at "
                                + "\((output.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)."
                        }
                    }
                }
                if let problem = report.problem {
                    problems.append(problem)
                    aside = report.keptAt
                }
            }
        }
        if problems.isEmpty, let cache = entry.cache, let readingsRoot, isRenderCache(cache, in: readingsRoot) {
            // The joined files a render a quit or a crash cut off left beside the output (hidden, named after this
            // cache, whose lock is held: no run of it is under way). The cache (whose key names them) stays until
            // they are gone, or while the folder that holds them cannot be reached.
            if let output = entry.outputURL {
                let directory = URL(fileURLWithPath: cache, isDirectory: true)
                if let reason = ReadingOutput.unreachableReason(for: output) {
                    // Only a render that got to joining leaves something there: every part rendered.
                    if mayHaveJoined(cache: directory) {
                        problems.append("\(output.deletingLastPathComponent().lastPathComponent) is unavailable: "
                            + "\(reason), and what its render left there cannot be removed. Connect it, then Delete "
                            + "again.")
                    }
                } else if let problem = ReadingTemporaries.sweepJoins(outputFolder: output.deletingLastPathComponent(),
                                                                      key: ReadingTemporaries.key(for: directory),
                                                                      currentRun: UUID()) {
                    problems.append(problem)
                }
            }
        }
        if problems.isEmpty, let cache = entry.cache, let readingsRoot, isRenderCache(cache, in: readingsRoot) {
            do {
                let directory = URL(fileURLWithPath: cache, isDirectory: true)
                // Not found is "gone" only where its folder can be reached (the support drive may have gone away
                // since the Delete began).
                if let reason = ReadingOutput.unreachableReason(for: directory) {
                    throw HolosError.unavailable("its folder is unavailable: \(reason).")
                }
                if try ReadingOutput.exists(directory) {
                    try FileManager.default.removeItem(atPath: cache)
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Gone meanwhile.
            } catch {
                problems.append("Its rendered parts in \(cache) could not be removed: \(error.localizedDescription)")
            }
        }
        if problems.isEmpty {
            do {
                try store.removeDocument(for: entry.id)
            } catch {
                problems.append("Its saved text could not be removed: \(error.localizedDescription)")
            }
        }
        return problems.isEmpty ? DeleteResult(note: note)
            : DeleteResult(problem: problems.joined(separator: " ") + " Try Delete again.", aside: aside)
    }

    /// Whether a render of the cache may have got to joining its parts (and left a joined file beside the output):
    /// its manifest says every part is rendered, or it cannot be read. A cache that is not there made nothing.
    static func mayHaveJoined(cache: URL) -> Bool {
        let url = cache.appendingPathComponent(ReadingManifest.fileName)
        guard (try? ReadingOutput.exists(cache)) != false else { return false }
        guard let data = try? readSmallFile(url, maximumBytes: ReadingManifest.maximumBytes),
              let manifest = try? JSONDecoder().decode(ReadingManifest.self, from: data) else { return true }
        return manifest.parts.allSatisfy { $0.status == "complete" }
    }

    /// A file an earlier Delete may have moved aside and left at `url`: moved to the Trash when it is the finished
    /// file, removed when it is the partly written copy. One that is neither (changed since, or another file that
    /// Delete moved aside and could not put back) is left there and is a problem, so the entry keeps pointing at it
    /// until the user deals with it. It is in a place only a Delete of this reading uses, so nothing else takes its
    /// place between the check and the removal. The private folder it was in goes once empty.
    static func removeAside(_ url: URL, evidence: Evidence,
                            trash: (URL) throws -> Void) -> RemovalReport {
        do {
            if try ReadingOutput.exists(url) {
                if !evidence.checksums.isEmpty, evidence.checksums.contains(try fileSHA256(url)) {
                    try trash(url)
                } else if try evidence.isPartial(url) {
                    // To the Trash too: it may be the finished file shortened in place (see `removePartial`).
                    try trash(url)
                } else {
                    return RemovalReport(problem: "An earlier Delete left \(url.lastPathComponent) at \(url.path), and "
                                            + "it is not this reading's file as it was made. Move it back or remove it "
                                            + "in Finder, then Delete again.", keptAt: url.path)
                }
            }
        } catch {
            return RemovalReport(problem: "\(url.lastPathComponent), left at \(url.path) by an earlier Delete, could "
                                    + "not be removed: \(error.localizedDescription)", keptAt: url.path)
        }
        let folder = url.deletingLastPathComponent()
        if folder.lastPathComponent.hasPrefix(ExclusivePublisher.removalPrefix) {
            _ = rmdir(RawFilePath.system(folder))
        }
        return RemovalReport()
    }

    /// "25 min", "1 h 5 min", "40 s".
    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = (total + 30) / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "3:07" or "1:02:03", for the player's position.
    public static func clockText(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
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
