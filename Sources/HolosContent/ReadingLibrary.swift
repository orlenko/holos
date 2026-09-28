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
    }

    public let folder: URL
    public var indexURL: URL { folder.appendingPathComponent("library.json") }
    var documentsFolder: URL { folder.appendingPathComponent("Documents", isDirectory: true) }
    /// Larger index files are not read.
    static let maximumBytes = 32 << 20

    public init(folder: URL) {
        self.folder = folder
    }

    /// `<support>/ReadingLibrary`.
    public static func standard(support: URL = HolosPaths.supportRoot) -> ReadingLibraryStore {
        ReadingLibraryStore(folder: support.appendingPathComponent("ReadingLibrary", isDirectory: true))
    }

    /// The saved entries. A missing index is an empty list; one that cannot be read is renamed aside
    /// (`library.json.unreadable-<date>`), so it is kept, and the list starts empty with a notice; one a newer build
    /// wrote is shown (entries this build cannot read are left out) but never rewritten. Only "no such file" is a
    /// missing index: one that cannot be looked up (an I/O error, a permission) is kept and never written over.
    public func load() -> Loaded {
        let data: Data
        do {
            guard try ReadingOutput.exists(indexURL) else { return Loaded(entries: [], notice: nil, writable: true) }
            let handle = try FileHandle(forReadingFrom: indexURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        } catch {
            // Not rewritten: what it keeps may still be readable later (a permission fixed, a disk remounted).
            return Loaded(entries: [], notice: "The Reading list could not be read (\(error.localizedDescription)); "
                            + "readings made now are not kept in it after Voice is Local quits.", writable: false)
        }
        struct Marker: Decodable { let kind: String?; let schemaVersion: Int? }
        if data.count <= Self.maximumBytes, let marker = try? JSONDecoder.reading.decode(Marker.self, from: data),
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
        do {
            try FileManager.default.moveItem(at: indexURL, to: aside)
        } catch {
            return Loaded(entries: [], notice: "The Reading list could not be read and could not be set aside "
                            + "(\(error.localizedDescription)); readings made now are not kept in it after Voice is "
                            + "Local quits.", writable: false)
        }
        return Loaded(entries: [], notice: "The Reading list could not be read; it was kept as \(aside.lastPathComponent) "
                        + "and a new list was started. The audio files are still in their folder.", writable: true)
    }

    /// Writes `entries` atomically, readable by this user only.
    public func save(_ entries: [ReadingEntry]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder.reading
        let data = try encoder.encode(ReadingIndex(kind: ReadingIndex.kind,
                                                   schemaVersion: ReadingIndex.currentSchemaVersion, entries: entries))
        try Self.write(data, to: indexURL)
    }

    /// Keeps `document`, the text reading `id` reads, until the reading is finished or deleted.
    public func saveDocument(_ document: ReadableDocument, for id: UUID) throws {
        try FileManager.default.createDirectory(at: documentsFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.write(try JSONEncoder.reading.encode(document), to: documentURL(id))
    }

    /// The document saved for `id`, or nil when none was saved. One that is there but cannot be read or decoded is
    /// an error, never nil: a resume must not load its source again and read different text.
    public func document(for id: UUID) throws -> ReadableDocument? {
        let url = documentURL(id)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder.reading.decode(ReadableDocument.self, from: data)
    }

    /// Whether a text is saved for `id`.
    public func hasDocument(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: documentURL(id).path)
    }

    /// Removes the text saved for `id`; one that is not there is not an error.
    public func removeDocument(for id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: documentURL(id))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    func documentURL(_ id: UUID) -> URL {
        documentsFolder.appendingPathComponent("\(id.uuidString).json")
    }

    private static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HolosError.io("Could not save \(url.lastPathComponent) in \(url.deletingLastPathComponent().path).")
        }
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw HolosError.io("Could not save \(url.lastPathComponent): \(reason)")
        }
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
    /// "Title 3.m4a", …, skipping names another reading of the list will write (`taken`, compared without case, as
    /// the Mac's volumes compare them) and names already on disk (`exists`). The folder and the name (in NFC, as
    /// `ReadingOutput.fileName` makes it) keep their spelling (see `RawFilePath`).
    public static func outputURL(in folder: URL, title: String?, fallback: String?, taken: Set<String>,
                                 exists: (URL) -> Bool) -> URL {
        // Room for " 999" in the volume's 255-unit name limit.
        let name = ReadingOutput.fileName(title: title, fallback: fallback, limit: ReadingOutput.defaultNameLimit - 4)
        let stem = String(name.dropLast(ReadingAudioFormat.fileExtension.count + 1))
        let takenKeys = Set(taken.map(Self.key))
        for number in 1...999 {
            let candidate = RawFilePath.appending(number == 1 ? name
                : "\(stem) \(number).\(ReadingAudioFormat.fileExtension)", to: folder)
            if !takenKeys.contains(key(candidate.path)) && !exists(candidate) { return candidate }
        }
        return RawFilePath.appending("\(stem) \(UUID().uuidString.prefix(8)).\(ReadingAudioFormat.fileExtension)",
                                     to: folder)
    }

    private static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
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
    public static func ownership(of output: URL, sha256: String?, cache: URL?) throws -> OutputOwnership? {
        guard try ReadingOutput.exists(output) else {
            // Not found is "gone" only where the folder can be looked into: a drive that is not connected brings the
            // file back when it is, and the reading must still be there to delete it then. Unless nothing of the
            // reading's can be there (no finished file, no copy begun); a manifest that cannot be read may name one.
            if let reason = ReadingOutput.unreachableReason(for: output) {
                let evidence = try? ownershipEvidence(of: output, sha256: sha256, cache: cache)
                if evidence.map({ !$0.checksums.isEmpty || $0.publishing != nil }) ?? true {
                    throw OutputUnreachable(file: output.lastPathComponent, reason: reason)
                }
            }
            return nil
        }
        let evidence = try ownershipEvidence(of: output, sha256: sha256, cache: cache)
        if !evidence.checksums.isEmpty, evidence.checksums.contains(try fileSHA256(output)) { return .finished }
        // A lookup that fails (not "nothing there") throws: it says nothing about which file is there.
        if let claimed = evidence.publishing, try ExclusivePublisher.FileIdentity.lookup(output) == claimed {
            return .partial(claimed)
        }
        return nil
    }

    /// What identifies the reading's file at `output`: the checksums of its finished file (`sha256`, and the one
    /// the cache's manifest saved for that output) and the identity of a copy a crash cut off.
    static func ownershipEvidence(of output: URL, sha256: String?, cache: URL?) throws
        -> (checksums: [String], publishing: ReadingFileIdentity?) {
        var manifest: ReadingManifest?
        if let cache {
            let url = cache.appendingPathComponent(ReadingManifest.fileName)
            if try ReadingOutput.exists(url) {  // only "no such file" is no manifest
                // A manifest that is there but cannot be read, is too large, or is not a reading's may hold the
                // only identity of a partly copied file: that is an error, never "not the reading's".
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
                guard size <= ReadingManifest.maximumBytes else {
                    throw HolosError.io("The reading's manifest \(url.path) is larger than \(ReadingManifest.maximumBytes) bytes.")
                }
                let saved = try JSONDecoder().decode(ReadingManifest.self, from: try Data(contentsOf: url))
                guard saved.kind == ReadingManifest.readingKind else {
                    throw HolosError.io("\(url.path) is not a Voice is Local reading's manifest.")
                }
                // One made for another output says nothing about this file.
                if sameFile(saved.output, output) { manifest = saved }
            }
        }
        return ([sha256, manifest?.outputSHA256].compactMap { $0 }, manifest?.publishing)
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

    /// The file at `output` opened for reading when the object opened is the one `identity` names (checked on the
    /// open descriptor, not the path): an action that reads through it (Play, Share…) uses that very file, whatever
    /// is put at the path at any moment. Nil when it is not there, not a regular file, or another file.
    public static func openVerified(_ output: URL, identity: ReadingFileIdentity) -> FileHandle? {
        let descriptor = open(RawFilePath.system(output), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              ExclusivePublisher.FileIdentity(metadata) == identity else {
            close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
    static func removePartial(_ output: URL, identity: ReadingFileIdentity, token: String? = nil) -> RemovalReport {
        report(ExclusivePublisher.removeIfIdentical(output, to: identity, token: token),
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

    /// Where a Delete of `entry` may have left its file aside: the places `asideToken` names beside its output, and
    /// `outputAside`.
    static func asideCandidates(of entry: ReadingEntry) -> [URL] {
        guard let output = entry.outputURL else { return [] }
        let folder = output.deletingLastPathComponent()
        var candidates = [false, true].map { partial in
            RawFilePath.appending(output.lastPathComponent,
                                  to: RawFilePath.appending(asideToken(entry.id, partial: partial), to: folder))
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
            let evidence: (checksums: [String], publishing: ReadingFileIdentity?)
            do {
                owned = try ownership(of: output, sha256: entry.outputSHA256, cache: cache)
                evidence = try ownershipEvidence(of: output, sha256: entry.outputSHA256, cache: cache)
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
                    report = removePartial(output, identity: identity, token: asideToken(entry.id, partial: true))
                case nil:
                    let present = (try? ReadingOutput.exists(output)) == true
                    if present, entry.state != .done, !evidence.checksums.isEmpty {
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
            do {
                if try ReadingOutput.exists(URL(fileURLWithPath: cache, isDirectory: true)) {
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

    /// A file an earlier Delete may have moved aside and left at `url`: moved to the Trash when it is the finished
    /// file, removed when it is the partly written copy. One that is neither (changed since, or another file that
    /// Delete moved aside and could not put back) is left there and is a problem, so the entry keeps pointing at it
    /// until the user deals with it. It is in a place only a Delete of this reading uses, so nothing else takes its
    /// place between the check and the removal. The private folder it was in goes once empty.
    static func removeAside(_ url: URL, evidence: (checksums: [String], publishing: ReadingFileIdentity?),
                            trash: (URL) throws -> Void) -> RemovalReport {
        do {
            if try ReadingOutput.exists(url) {
                if !evidence.checksums.isEmpty, evidence.checksums.contains(try fileSHA256(url)) {
                    try trash(url)
                } else if let claimed = evidence.publishing, try ExclusivePublisher.FileIdentity.lookup(url) == claimed {
                    try ExclusivePublisher.removeFile(url)
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
