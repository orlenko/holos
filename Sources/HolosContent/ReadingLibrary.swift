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

    public var outputURL: URL? { output.map { URL(fileURLWithPath: $0) } }
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
    /// wrote is shown (entries this build cannot read are left out) but never rewritten.
    public func load() -> Loaded {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return Loaded(entries: [], notice: nil, writable: true)
        }
        let data: Data
        do {
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

    /// The document saved for `id`, or nil when there is none (or it cannot be read).
    public func document(for id: UUID) -> ReadableDocument? {
        guard let data = try? Data(contentsOf: documentURL(id)) else { return nil }
        return try? JSONDecoder.reading.decode(ReadableDocument.self, from: data)
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
    /// the Mac's volumes compare them) and names already on disk (`exists`).
    public static func outputURL(in folder: URL, title: String?, fallback: String?, taken: Set<String>,
                                 exists: (URL) -> Bool) -> URL {
        // Room for " 999" in the volume's 255-unit name limit.
        let name = ReadingOutput.fileName(title: title, fallback: fallback, limit: ReadingOutput.defaultNameLimit - 4)
        let stem = String(name.dropLast(ReadingAudioFormat.fileExtension.count + 1))
        let takenKeys = Set(taken.map(Self.key))
        for number in 1...999 {
            let candidate = folder.appendingPathComponent(number == 1 ? name
                : "\(stem) \(number).\(ReadingAudioFormat.fileExtension)")
            if !takenKeys.contains(key(candidate.path)) && !exists(candidate) { return candidate }
        }
        return folder.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8)).\(ReadingAudioFormat.fileExtension)")
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

    /// What the file at a reading's output path is to that reading.
    public enum OutputOwnership: Sendable, Equatable {
        /// The finished file it published (its checksum matches the entry's or the cache manifest's).
        case finished
        /// A copy into the destination that a crash cut off, named by the cache manifest's `publishing` identity.
        case partial(ReadingFileIdentity)
    }

    /// Whether the file at `output` is this reading's: the finished file (`sha256`, else the checksum the render
    /// cache's manifest saved for that output), or its own partly copied file (the manifest's `publishing`
    /// identity). Nil for anything else (a file put there since, or nothing there): Delete leaves it alone.
    public static func ownership(of output: URL, sha256: String?, cache: URL?) -> OutputOwnership? {
        guard (try? ReadingOutput.exists(output)) == true else { return nil }
        var manifest: ReadingManifest?
        if let cache {
            let url = cache.appendingPathComponent(ReadingManifest.fileName)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
            if size <= ReadingManifest.maximumBytes, let data = try? Data(contentsOf: url),
               let saved = try? JSONDecoder().decode(ReadingManifest.self, from: data),
               saved.kind == ReadingManifest.readingKind,
               URL(fileURLWithPath: saved.output).standardizedFileURL.path == output.standardizedFileURL.path {
                manifest = saved
            }
        }
        let checksums = [sha256, manifest?.outputSHA256].compactMap { $0 }
        if !checksums.isEmpty, let actual = try? fileSHA256(output), checksums.contains(actual) { return .finished }
        if let claimed = manifest?.publishing, ExclusivePublisher.FileIdentity.of(output) == claimed {
            return .partial(claimed)
        }
        return nil
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
