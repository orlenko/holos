import CryptoKit
import Darwin
import Foundation
import HolosCore
import HolosSynthesis

public struct ReadingPart: Codable, Sendable, Equatable {
    public let index: Int
    public let sourceUTF16Offset: Int
    public let sourceUTF16Length: Int
    public let textSHA256: String
    public let relativeAudioPath: String
    /// Starts a chapter with this title.
    public let chapter: String?
    /// Starts a section, so a longer pause comes before it.
    public let startsSection: Bool
    public var status: String
    public var audioSHA256: String?
    public var duration: Double?
}

/// The fixed encoding settings a reading's file is made with. Saved in the manifest so a reading
/// started by another version with different settings is not resumed into a mixed file.
public struct ReadingFormatSettings: Codable, Sendable, Equatable {
    public let fileExtension: String
    public let sampleRate: Double
    public let bitRate: Int
    public let channels: Int
    public let partGap: Double
    public let chapterGap: Double

    public static let current = ReadingFormatSettings(
        fileExtension: ReadingAudioFormat.fileExtension, sampleRate: ReadingAudioFormat.sampleRate,
        bitRate: ReadingAudioFormat.bitRate, channels: ReadingAudioFormat.channels,
        partGap: ReadingAudioFormat.partGap, chapterGap: ReadingAudioFormat.chapterGap)
}

public struct ReadingManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3
    /// Marks a manifest this app wrote, so an unrelated `manifest.json` is never taken for one.
    public static let readingKind = "voiceislocal.reading"
    public static let fileName = "manifest.json"

    public let kind: String
    public let schemaVersion: Int
    public let sourceSHA256: String
    /// Everything besides the text and the part plan that ends up in the finished file.
    public let voiceIdentifier: String
    public let rate: Float?
    public let title: String?
    public let author: String?
    public let language: String?
    public let comment: String
    public let format: ReadingFormatSettings
    /// Absolute path of the finished `.m4a`.
    public let output: String
    /// Checksum of the finished file, saved before it is published so a reading interrupted
    /// right after publishing is recognized as done.
    public var outputSHA256: String?
    public var duration: Double?
    public var chapters: [AudioBookChapter]
    public var status: String
    /// The render cache. Part files are deleted once the finished file is published.
    public var parts: [ReadingPart]
    /// The file this reading created at `output` while copying the finished file into it (on
    /// volumes that cannot rename exclusively), saved before any byte is written: a copy cut off
    /// by a crash is recognized on `--resume` as this reading's own partial output.
    public var publishing: ReadingFileIdentity? = nil

    /// Manifests are small (under 1 KB per part); a larger `manifest.json` is not read.
    static let maximumBytes = 64 << 20

    /// Whether `url` is a manifest this app wrote (any schema version): it names
    /// `readingKind`. Anything else, including unreadable JSON, is not.
    public static func isReading(_ url: URL) -> Bool {
        struct Marker: Decodable { let kind: String?; let schemaVersion: Int? }
        guard let data = try? readSmallFile(url, maximumBytes: maximumBytes),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return false }
        return marker.kind == readingKind && marker.schemaVersion != nil
    }

    /// Whether this saved reading was made from the same settings: every value that ends up
    /// in the finished file, besides the text and the part plan (which includes chapter titles).
    /// The output compares by exact identity (see `ReadingPathIdentity.Rule.exact`): another
    /// spelling resumes this reading only when it names the same file.
    func sameSettings(voiceIdentifier: String, rate: Float?, metadata: AudioBookMetadata, output: URL,
                      volume: ReadingPathIdentity.VolumeQuery = ReadingPathIdentity.volumeRules) -> Bool {
        self.voiceIdentifier == voiceIdentifier && self.rate == rate
            && title == metadata.title && author == metadata.author && language == metadata.language
            && comment == metadata.comment && format == .current
            // Compared byte for byte: Swift's `==` takes NFC and NFD spellings for one string.
            && (self.output.utf8.elementsEqual(output.path.utf8)
                || ReadingPathIdentity.key(path: self.output, .exact, volume: volume).utf8
                    .elementsEqual(ReadingPathIdentity.key(output, .exact, volume: volume).utf8))
    }
}

public struct ReadingResult: Sendable, Equatable {
    public let output: URL
    public let manifest: ReadingManifest
}

@MainActor public protocol ReadingAudioRenderer {
    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio
    /// Fails unless the renderer can speak with the voice `identifier`. Checked before a reading
    /// creates anything.
    func checkVoice(_ identifier: String) throws
}

extension ReadingAudioRenderer {
    /// A renderer that cannot tell which voices it has accepts every one here; `render` fails
    /// for one it lacks.
    public func checkVoice(_ identifier: String) throws {}
}

extension NativeSpeechRenderer: ReadingAudioRenderer {}

@MainActor public protocol ReadingAudioJoiner {
    func join(parts: [AudioBookPart], metadata: AudioBookMetadata, to output: URL) async throws -> AudioBookSummary
}

public struct AudioBookJoiner: ReadingAudioJoiner {
    public init() {}
    public func join(parts: [AudioBookPart], metadata: AudioBookMetadata,
                     to output: URL) async throws -> AudioBookSummary {
        try await AudioBookWriter.write(parts: parts, metadata: metadata, to: output)
    }
}

/// Renders a script part by part into a cache of PCM files (so an interrupted reading resumes
/// where it stopped), then joins the parts into one AAC `.m4a` with chapters.
@MainActor public final class ReadingPipeline {
    static let partExtension = "caf"
    /// The longest part rendered at once, in UTF-16 units.
    nonisolated public static let defaultMaxPartUTF16Units = 3_000

    private let renderer: any ReadingAudioRenderer
    private let joiner: any ReadingAudioJoiner
    private let exclusiveRename: ReadingPublisher.ExclusiveRename
    /// Called after each step of creating a new reading's cache; tests fail one to check that
    /// nothing is left behind.
    private let initializationFault: (ReadingCache.Step) throws -> Void

    public init(renderer: any ReadingAudioRenderer = NativeSpeechRenderer(),
                joiner: any ReadingAudioJoiner = AudioBookJoiner()) {
        self.renderer = renderer
        self.joiner = joiner
        self.exclusiveRename = ReadingPublisher.systemExclusiveRename
        self.initializationFault = { _ in }
    }

    init(renderer: any ReadingAudioRenderer, joiner: any ReadingAudioJoiner,
         exclusiveRename: @escaping ReadingPublisher.ExclusiveRename = ReadingPublisher.systemExclusiveRename,
         initializationFault: @escaping (ReadingCache.Step) throws -> Void = { _ in }) {
        self.renderer = renderer
        self.joiner = joiner
        self.exclusiveRename = exclusiveRename
        self.initializationFault = initializationFault
    }

    /// The cache key for a reading with an explicit output: the text and every setting that
    /// ends up in the finished file, so a change to any of them starts a new reading.
    public static func identity(script: ReadingScript, voiceIdentifier: String, rate: Float?,
                                metadata: AudioBookMetadata) -> String {
        let format = ReadingFormatSettings.current
        return [
            ReadingManifest.readingKind, String(ReadingManifest.currentSchemaVersion), voiceIdentifier,
            rate.map { "\($0)" } ?? "", metadata.title ?? "", metadata.author ?? "", metadata.language ?? "",
            metadata.comment, format.fileExtension, "\(format.sampleRate)", "\(format.bitRate)",
            "\(format.channels)", "\(format.partGap)", "\(format.chapterGap)",
            script.segments.map { ($0.chapter ?? "") + "\u{2}" + $0.text }.joined(separator: "\u{3}"),
        ].joined(separator: "\u{1}")
    }

    public func render(script: ReadingScript, voiceIdentifier: String, rate: Float? = nil,
                       metadata: AudioBookMetadata, location: ReadingLocation,
                       resume: Bool = false,
                       maxPartUTF16Units: Int = defaultMaxPartUTF16Units) async throws -> ReadingResult {
        let directory = location.workDirectory
        let output = location.output
        // Every setting is checked before anything (lock, cache, source, manifest) is created, so
        // a bad one never leaves a cache behind that cannot be resumed.
        try validate(script: script, voiceIdentifier: voiceIdentifier, rate: rate, metadata: metadata,
                     location: location, resume: resume)
        let text = script.text
        let writerLock = try ReadingDirectoryLock.acquire(for: directory)
        let outputLock = try ReadingDirectoryLock.acquire(output: output, beside: directory)
        defer { withExtendedLifetime((writerLock, outputLock)) {} }
        // Caches that runs killed while creating them left behind (see `ReadingCache.create`).
        ReadingCache.sweep(beside: directory)
        let planned = script.parts(maxUTF16Units: maxPartUTF16Units)
        let sourceHash = sha256(Data(text.utf8))
        let sourceURL = directory.appendingPathComponent("source.txt")
        let manifestURL = directory.appendingPathComponent(ReadingManifest.fileName)
        let expected = planned.map { part in
            ReadingPart(index: part.index, sourceUTF16Offset: part.offset, sourceUTF16Length: part.length,
                        textSHA256: sha256(Data(part.text.utf8)),
                        relativeAudioPath: Self.partPath(part.index),
                        chapter: part.chapter, startsSection: part.startsSegment, status: "pending")
        }
        var manifest: ReadingManifest

        if resume {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw HolosError.invalidInput("No reading exists to resume at \(directory.path).")
            }
            guard ReadingManifest.isReading(manifestURL) else {
                throw HolosError.invalidInput("No Voice is Local reading to resume at \(directory.path).")
            }
            guard let saved = try? JSONDecoder().decode(
                      ReadingManifest.self, from: readSmallFile(manifestURL, maximumBytes: ReadingManifest.maximumBytes)),
                  saved.schemaVersion == ReadingManifest.currentSchemaVersion else {
                throw HolosError.invalidInput("The reading at \(directory.path) was made by another version and cannot be resumed.")
            }
            manifest = saved
            guard manifest.sourceSHA256 == sourceHash,
                  manifest.sameSettings(voiceIdentifier: voiceIdentifier, rate: rate, metadata: metadata, output: output),
                  (try? fileSHA256(sourceURL)) == sourceHash else {
                throw HolosError.invalidInput("Reading source, voice, rate, title, author, language, or output differs from the saved reading.")
            }
            guard manifest.parts.count == expected.count,
                  zip(manifest.parts, expected).allSatisfy({ Self.samePlan($0, $1) }) else {
                throw HolosError.invalidInput("Reading part boundaries differ from the saved reading.")
            }
        } else {
            // A cache an earlier version left half made, with no manifest, goes, and the
            // locations are checked as for a new reading (`validate` skipped them while it was there).
            if ReadingCache.removeAbandoned(directory) {
                try Self.checkLocation(directory: directory, output: output, resume: false)
            }
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw HolosError.invalidInput("A reading already exists at \(directory.path). Use --resume to continue it.")
            }
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw HolosError.invalidInput("Reading output already exists: \(output.path)")
            }
            manifest = ReadingManifest(kind: ReadingManifest.readingKind,
                                       schemaVersion: ReadingManifest.currentSchemaVersion,
                                       sourceSHA256: sourceHash, voiceIdentifier: voiceIdentifier, rate: rate,
                                       title: metadata.title, author: metadata.author, language: metadata.language,
                                       comment: metadata.comment, format: .current, output: output.path,
                                       outputSHA256: nil, duration: nil, chapters: [],
                                       status: "incomplete", parts: expected)
            try ReadingCache.create(directory, source: Data(text.utf8), manifest: manifest,
                                    fault: initializationFault)
        }

        // This run's name for the joined file. Temporaries an interrupted earlier run left behind
        // (killed before its cleanup ran) are removed now: the lock means no other run of this
        // reading is active, and only names this reading's runs create are touched.
        let run = UUID()
        let key = ReadingTemporaries.key(for: directory)
        ReadingTemporaries.sweep(workDirectory: directory, outputFolder: output.deletingLastPathComponent(),
                                 key: key, currentRun: run)

        // Finished before (possibly interrupted right after publishing): nothing to do.
        if let published = manifest.outputSHA256,
           (try? fileSHA256(output)) == published {
            if manifest.status != "complete" || manifest.publishing != nil {
                manifest.status = "complete"
                manifest.publishing = nil
                try save(manifest, to: manifestURL)
            }
            removeParts(in: directory)
            return ReadingResult(output: output, manifest: manifest)
        }
        // A copy into the destination that a crash cut off is this reading's own file: it goes,
        // and the reading is joined and published again. Anything else there is kept.
        if let claimed = manifest.publishing {
            ReadingPublisher.removeIfIdentical(output, to: claimed)
            manifest.publishing = nil
            try save(manifest, to: manifestURL)
        }
        var existing = stat()
        guard lstat(output.path, &existing) != 0 else {
            throw HolosError.invalidInput("Reading output already exists and is not this reading: \(output.path)")
        }
        manifest.status = "incomplete"
        manifest.outputSHA256 = nil
        manifest.duration = nil
        manifest.chapters = []
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("parts"),
                                                withIntermediateDirectories: true)

        // Only parts whose files still match their checksums are reused.
        for index in manifest.parts.indices {
            let part = manifest.parts[index]
            let audio = directory.appendingPathComponent(part.relativeAudioPath)
            let valid = part.status == "complete" && part.audioSHA256 != nil &&
                (try? fileSHA256(audio)) == part.audioSHA256
            if !valid {
                manifest.parts[index].status = "pending"
                manifest.parts[index].audioSHA256 = nil
                manifest.parts[index].duration = nil
            }
        }
        try save(manifest, to: manifestURL)

        for part in planned {
            try Task.checkCancellation()
            if manifest.parts[part.index].status == "complete" { continue }
            let audio = directory.appendingPathComponent(manifest.parts[part.index].relativeAudioPath)
            if FileManager.default.fileExists(atPath: audio.path) {
                let quarantined = audio.deletingLastPathComponent()
                    .appendingPathComponent(".invalid-\(UUID().uuidString)-\(audio.lastPathComponent)")
                try FileManager.default.moveItem(at: audio, to: quarantined)
            }
            do {
                let result = try await renderer.render(text: part.text, voiceIdentifier: voiceIdentifier,
                                                       rate: rate, to: audio)
                guard result.url.standardizedFileURL == audio.standardizedFileURL else {
                    throw HolosError.io("Speech renderer returned an unexpected part path.")
                }
                manifest.parts[part.index].status = "complete"
                manifest.parts[part.index].audioSHA256 = try fileSHA256(result.url)
                manifest.parts[part.index].duration = result.duration
                try save(manifest, to: manifestURL)
            } catch {
                manifest.status = "incomplete"
                try? save(manifest, to: manifestURL)
                throw HolosError.incomplete("Reading stopped at part \(part.index + 1) of \(planned.count): \(error.localizedDescription)")
            }
        }

        try Task.checkCancellation()
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(ReadingTemporaries.joinName(key: key, run: run))
        // Runs on every exit, cancellation (Ctrl-C in `voiceislocal read`) included.
        defer { _ = unlink(temporary.path) }
        let audioParts = manifest.parts.map { part in
            AudioBookPart(url: directory.appendingPathComponent(part.relativeAudioPath),
                          silenceBefore: part.index == 0 ? 0
                              : part.startsSection ? ReadingAudioFormat.chapterGap : ReadingAudioFormat.partGap,
                          chapter: part.chapter)
        }
        let summary: AudioBookSummary
        do {
            summary = try await joiner.join(parts: audioParts, metadata: metadata, to: temporary)
        } catch {
            try? save(manifest, to: manifestURL)
            throw HolosError.incomplete("Reading parts are rendered, but joining them failed: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        manifest.outputSHA256 = try fileSHA256(temporary)
        manifest.duration = summary.duration
        manifest.chapters = summary.chapters
        try save(manifest, to: manifestURL)
        try Task.checkCancellation()
        do {
            try ReadingPublisher.publish(temporary, to: output, exclusiveRename: exclusiveRename) { claimed in
                manifest.publishing = claimed
                try save(manifest, to: manifestURL)
            }
        } catch {
            manifest.outputSHA256 = nil
            manifest.publishing = nil
            try? save(manifest, to: manifestURL)
            throw error
        }
        manifest.publishing = nil
        manifest.status = "complete"
        try save(manifest, to: manifestURL)
        removeParts(in: directory)
        return ReadingResult(output: output, manifest: manifest)
    }

    /// Fails unless every setting of a reading is usable, creating nothing: the text is not
    /// empty; the rate is nil or a finite rate `AVSpeechUtterance` takes (see `SpeechRate`); the
    /// renderer has the voice; a title has readable text (see `AudioBookMetadata.usableTitle`);
    /// the locations are file URLs, the output a `.m4a`; and both folders can take their files
    /// (see `checkLocation`).
    func validate(script: ReadingScript, voiceIdentifier: String, rate: Float?, metadata: AudioBookMetadata,
                  location: ReadingLocation, resume: Bool) throws {
        let directory = location.workDirectory
        let output = location.output
        guard directory.isFileURL, output.isFileURL else {
            throw HolosError.invalidInput("Reading locations must be file URLs.")
        }
        guard output.pathExtension.lowercased() == ReadingAudioFormat.fileExtension else {
            throw HolosError.invalidInput("Reading output must be a .\(ReadingAudioFormat.fileExtension) file: \(output.path)")
        }
        guard !script.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HolosError.invalidInput("Reading source is empty.")
        }
        try SpeechRate.validate(rate)
        try renderer.checkVoice(voiceIdentifier)
        if let title = metadata.title, AudioBookMetadata.usableTitle(title) == nil {
            throw HolosError.invalidInput("Reading title has no readable text.")
        }
        try Self.checkLocation(directory: directory, output: output, resume: resume)
    }

    /// Checks both folders before anything is rendered, so a destination that cannot take the
    /// finished file fails now rather than after hours of rendering: the cache's parent folder
    /// (where the cache and its lock are created) and the output's (see
    /// `ReadingOutput.checkDestination`). An output inside a cache that does not exist yet
    /// (a reading without `--output`) is checked through the cache's parent.
    static func checkLocation(directory: URL, output: URL, resume: Bool) throws {
        let cacheExists = FileManager.default.fileExists(atPath: directory.path)
        // A new reading over an existing cache, or a resume without one, fails next with a
        // clearer message ("use --resume", "no reading to resume").
        if cacheExists != resume { return }
        if !cacheExists {
            try ReadingOutput.checkFolder(directory.deletingLastPathComponent(), role: "Reading cache folder")
        }
        let folder = output.deletingLastPathComponent()
        if !cacheExists && folder.standardizedFileURL.path == directory.standardizedFileURL.path {
            guard ReadingOutput.fits(output.lastPathComponent,
                                     limit: ReadingOutput.nameLimit(in: directory.deletingLastPathComponent())) else {
                throw HolosError.invalidInput("Output file name is too long for its volume: \(output.lastPathComponent)")
            }
            try ReadingOutput.checkPathLength(output)
        } else {
            try ReadingOutput.checkDestination(output, allowExisting: resume)
        }
    }

    static func partPath(_ index: Int) -> String {
        String(format: "parts/part%04d.%@", index + 1, partExtension)
    }

    private static func samePlan(_ saved: ReadingPart, _ planned: ReadingPart) -> Bool {
        saved.index == planned.index && saved.sourceUTF16Offset == planned.sourceUTF16Offset &&
            saved.sourceUTF16Length == planned.sourceUTF16Length && saved.textSHA256 == planned.textSHA256 &&
            saved.relativeAudioPath == planned.relativeAudioPath && saved.chapter == planned.chapter &&
            saved.startsSection == planned.startsSection
    }

    /// The cache is several times larger than the finished file; it is not kept once that exists.
    private func removeParts(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("parts"))
    }
}

/// Moves a finished reading into place without ever replacing a file that is already there,
/// and without needing hard links (exFAT and many network volumes have none).
enum ReadingPublisher {
    /// Renames the first path to the second, failing with EEXIST when the second exists.
    typealias ExclusiveRename = @Sendable (String, String) -> Int32

    static let systemExclusiveRename: ExclusiveRename = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }

    /// `source` must be in the destination's directory (the finished file is written there), so
    /// the move never crosses volumes. Volumes that cannot rename exclusively get the destination
    /// created exclusively and the finished bytes copied into that open file (never a rename over
    /// the pathname, which would replace whatever is there by then); `claimed` gets the new
    /// file's identity before any byte is written, so a copy a crash cuts off can be recognized
    /// later. On failure only that file is removed, and only while it is still the one at
    /// `destination`. `source` is removed once published.
    static func publish(_ source: URL, to destination: URL,
                        exclusiveRename: ExclusiveRename = systemExclusiveRename,
                        claimed: (ReadingFileIdentity) throws -> Void = { _ in }) throws {
        if exclusiveRename(source.path, destination.path) == 0 { return }
        let error = errno
        guard error == ENOTSUP || error == EINVAL || error == ENOSYS else {
            throw failure(destination, error)
        }
        try copyExclusively(source, to: destination, claimed: claimed)
        _ = unlink(source.path)
    }

    private static func copyExclusively(_ source: URL, to destination: URL,
                                        claimed: (ReadingFileIdentity) throws -> Void) throws {
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw failure(source, errno) }
        defer { close(input) }
        let output = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o666)
        guard output >= 0 else { throw failure(destination, errno) }
        var metadata = stat()
        guard fstat(output, &metadata) == 0 else {
            // Without its identity, this empty file cannot be told apart from one put in its
            // place, so it is left alone.
            let error = errno
            close(output)
            throw failure(destination, error)
        }
        let identity = ReadingFileIdentity(metadata)
        var isOpen = true
        do {
            try claimed(identity)
            try copy(from: input, to: output, destination: destination)
            if fsync(output) != 0, errno != ENOTSUP, errno != EINVAL { throw failure(destination, errno) }
            isOpen = false
            if close(output) != 0 { throw failure(destination, errno) }
            guard ReadingFileIdentity.of(destination) == identity else {
                throw HolosError.io("\(destination.path) was replaced while the reading was saved to it; the other file is kept.")
            }
        } catch {
            if isOpen { close(output) }
            removeIfIdentical(destination, to: identity)
            throw error
        }
    }

    private static func copy(from input: Int32, to output: Int32, destination: URL) throws {
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            // A cancelled render (Ctrl-C) stops here, and the partial copy is removed.
            try Task.checkCancellation()
            let count = read(input, buffer, size)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure(destination, errno)
            }
            var offset = 0
            while offset < count {
                let written = write(output, buffer + offset, count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure(destination, errno)
                }
                offset += written
            }
        }
    }

    /// Removes `url` when it is still the file `identity` describes; anything else is kept.
    static func removeIfIdentical(_ url: URL, to identity: ReadingFileIdentity) {
        guard ReadingFileIdentity.of(url) == identity else { return }
        _ = unlink(url.path)
    }

    private static func failure(_ destination: URL, _ error: Int32) -> HolosError {
        if error == EEXIST {
            return .invalidInput("Reading output already exists and is not this reading: \(destination.path)")
        }
        return .io("Could not save \(destination.path): \(String(cString: strerror(error)))")
    }
}

/// A persistent sibling lock serializes new renders and resumes across processes.
/// The lock file is intentionally kept so another process cannot lock a replacement inode.
final class ReadingDirectoryLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// A hash of the directory's filesystem identity (see `ReadingPathIdentity`).
    static func key(for directory: URL) -> String {
        sha256(Data(ReadingPathIdentity.key(directory).utf8))
    }

    static func acquire(for directory: URL) throws -> ReadingDirectoryLock {
        try acquire(name: ".holos-reading-\(key(for: directory)).lock", beside: directory,
                    busy: "Reading directory is already being rendered: \(directory.path)")
    }

    /// A lock on the finished file's path, kept beside the cache's lock. Readings of different
    /// text or settings for one explicit output have different caches (see
    /// `ReadingOutput.locate`), so this is what stops a second one before it renders anything.
    /// It is keyed by the file's filesystem identity (see `ReadingPathIdentity`), so "Book.m4a"
    /// and "book.m4a" on a case-insensitive volume, or one name in NFC and NFD, share it.
    static func acquire(output: URL, beside directory: URL) throws -> ReadingDirectoryLock {
        try acquire(name: ".holos-output-\(sha256(Data(ReadingPathIdentity.key(output).utf8))).lock",
                    beside: directory, busy: "Another reading is already being made for \(output.path).")
    }

    /// The folder a cache's locks are kept in: the cache's parent, links resolved.
    static func folder(beside directory: URL) -> URL {
        directory.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// The lock of the cache whose `key` is given, in `folder`, when no run holds it; else nil.
    static func acquireIfIdle(key: String, in folder: URL) -> ReadingDirectoryLock? {
        try? acquire(name: ".holos-reading-\(key).lock", in: folder, busy: "")
    }

    private static func acquire(name: String, beside directory: URL, busy: String) throws -> ReadingDirectoryLock {
        try acquire(name: name, in: folder(beside: directory), busy: busy)
    }

    private static func acquire(name: String, in parent: URL, busy: String) throws -> ReadingDirectoryLock {
        let path = parent.appendingPathComponent(name).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw HolosError.io("Could not open reading lock: \(String(cString: strerror(errno)))")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(descriptor)
            throw HolosError.io("Reading lock is not a regular file owned by this user.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw HolosError.unavailable(busy)
            }
            throw HolosError.io("Could not acquire reading lock: \(String(cString: strerror(error)))")
        }
        return ReadingDirectoryLock(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// One string for every spelling of one filesystem location, so the locks and cache keys that
/// name a file follow the filesystem's own rules rather than the path's spelling:
/// - the parent folder is its real path (`realpath(3)`: links resolved, "..", and on macOS each
///   component's on-disk case);
/// - the last component (which may not exist yet) is put in Unicode canonical composition and
///   case-folded as `Rule` and the volume's `NameRules` say.
enum ReadingPathIdentity {
    /// How a name's case and Unicode normalization count.
    enum Rule {
        /// For locks: case is folded unless the volume is known to tell names apart by case, and
        /// NFC and NFD spellings are always one, so every spelling that may name one file shares
        /// the lock. On a volume whose rules cannot be told, "Book.m4a" and "book.m4a" (or one
        /// name in NFC and NFD) share a lock, which only serializes them.
        case lock
        /// For render caches and `--resume`: case is folded only when the volume is known to
        /// ignore it, and a name is composed only when the volume is known to treat NFC and NFD
        /// spellings as one (APFS, HFS+), so two spellings share a cache only when they name
        /// one file.
        case exact
    }

    /// How the volume holding a folder compares names; nil where that cannot be told.
    struct NameRules: Equatable {
        /// Whether "Book" and "book" are two names.
        var caseSensitive: Bool?
        /// Whether a name's NFC and NFD spellings name one file.
        var equatesNormalization: Bool?
    }

    typealias VolumeQuery = (String) -> NameRules

    /// A file URL's path is already in one normalization: Foundation gives its file system
    /// representation, decomposed (an NFC "Café.m4a" becomes NFD), and that is the name every
    /// file this app creates at the URL gets. Both spellings of a URL therefore name one file on
    /// any volume, and share every key.
    static func key(_ url: URL, _ rule: Rule = .lock, volume: VolumeQuery = volumeRules) -> String {
        key(path: url.standardizedFileURL.path, rule, volume: volume)
    }

    /// The identity of `path`, spelled as given.
    static func key(path: String, _ rule: Rule = .lock, volume: VolumeQuery = volumeRules) -> String {
        // An existing path resolves whole, so a link in the last component is followed too.
        let resolved = realPath(path) ?? path
        let name = (resolved as NSString).lastPathComponent
        let parentPath = (resolved as NSString).deletingLastPathComponent
        let parent = realPath(parentPath)
            ?? URL(fileURLWithPath: parentPath).standardizedFileURL.resolvingSymlinksInPath().path
        let rules = volume(parent)
        let (keepsCase, composes) = switch rule {
        case .lock: (rules.caseSensitive == true, true)
        case .exact: (rules.caseSensitive != false, rules.equatesNormalization == true)
        }
        let folded = normalizedName(name, caseSensitive: keepsCase, composed: composes)
        return parent == "/" ? "/" + folded : parent + "/" + folded
    }

    /// `name` as the volume compares names: composed when `composed`, and case-folded unless
    /// `caseSensitive`. A name not composed keeps its spelling as given.
    static func normalizedName(_ name: String, caseSensitive: Bool, composed: Bool = true) -> String {
        let spelled = composed ? name.precomposedStringWithCanonicalMapping : name
        guard !caseSensitive else { return spelled }
        let folded = spelled.folding(options: [.caseInsensitive], locale: nil)
        return composed ? folded.precomposedStringWithCanonicalMapping : folded
    }

    /// Whether the volume holding `folder` tells names apart by case; false when unknown.
    static func caseSensitive(_ folder: String) -> Bool {
        volumeCaseSensitivity(folder) ?? false
    }

    /// How the volume holding `folder` compares names, as far as it can be told.
    static func volumeRules(_ folder: String) -> NameRules {
        NameRules(caseSensitive: volumeCaseSensitivity(folder),
                  equatesNormalization: volumeEquatesNormalization(folder))
    }

    /// Whether the volume holding `folder` tells names apart by case, as the volume reports it;
    /// nil when that cannot be told.
    static func volumeCaseSensitivity(_ folder: String) -> Bool? {
        let values = try? URL(fileURLWithPath: folder, isDirectory: true)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames
    }

    /// Whether the volume holding `folder` treats a name's NFC and NFD spellings as one file:
    /// true for APFS and HFS+ (by their format, `statfs`'s `f_fstypename`); nil for any other
    /// or when it cannot be told (a network share may keep the bytes as given).
    static func volumeEquatesNormalization(_ folder: String) -> Bool? {
        guard let type = fileSystemType(folder) else { return nil }
        return normalizationInsensitiveTypes.contains(type) ? true : nil
    }

    static let normalizationInsensitiveTypes: Set<String> = ["apfs", "hfs"]

    /// The format name of the volume holding `path` ("apfs", "hfs", "smbfs", "exfat"), or nil.
    static func fileSystemType(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }.lowercased()
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Which file a path named at one moment: its volume, inode, and creation time. A file removed
/// and another created at the same path (even reusing the inode number) compare unequal.
public struct ReadingFileIdentity: Codable, Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64

    init(_ metadata: stat) {
        device = Int64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        birthSeconds = Int64(metadata.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(metadata.st_birthtimespec.tv_nsec)
    }

    /// The regular file at `url` (a link is not followed), or nil.
    static func of(_ url: URL) -> ReadingFileIdentity? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else { return nil }
        return ReadingFileIdentity(metadata)
    }
}

/// The names of the temporary files a reading creates, and the removal of ones an interrupted run
/// left behind. Each name carries a marker only this reading's runs use, so a sweep never touches
/// another reading's (or anyone else's) files:
/// - beside the output: `.holos-join-<reading key>-<run UUID>.m4a`, the joined file before it is
///   published. The key is a hash of the cache directory, whose lock serializes runs, so one
///   with another run's UUID is left over from an earlier run;
/// - in the cache: `.holos-manifest-<UUID>.tmp`, a manifest being saved;
/// - in the cache's `parts`: `.holos-<UUID>.<ext>` from the speech renderer and
///   `.invalid-<UUID>-<part>`, a part that failed its checksum.
enum ReadingTemporaries {
    static let joinPrefix = ".holos-join-"
    static let manifestPrefix = ".holos-manifest-"
    static let manifestSuffix = ".tmp"
    static let rendererPrefix = ".holos-"
    static let invalidPrefix = ".invalid-"

    static func key(for directory: URL) -> String { String(ReadingDirectoryLock.key(for: directory).prefix(16)) }

    static func joinName(key: String, run: UUID) -> String {
        "\(joinPrefix)\(key)-\(run.uuidString).\(ReadingAudioFormat.fileExtension)"
    }

    static func manifestName() -> String { "\(manifestPrefix)\(UUID().uuidString)\(manifestSuffix)" }

    /// Removes this reading's temporaries from earlier runs: regular files owned by this user whose
    /// names match exactly, except the current run's.
    static func sweep(workDirectory: URL, outputFolder: URL, key: String, currentRun: UUID) {
        let joinStart = "\(joinPrefix)\(key)-"
        let joinEnd = "." + ReadingAudioFormat.fileExtension
        remove(in: outputFolder) { name in
            guard let run = uuid(between: joinStart, and: joinEnd, in: name) else { return false }
            return run != currentRun
        }
        remove(in: workDirectory) { name in
            uuid(between: manifestPrefix, and: manifestSuffix, in: name) != nil
        }
        remove(in: workDirectory.appendingPathComponent("parts")) { name in
            if name.hasPrefix(invalidPrefix) {
                let rest = name.dropFirst(invalidPrefix.count)
                guard rest.count > 37, UUID(uuidString: String(rest.prefix(36))) != nil else { return false }
                return rest.dropFirst(36).first == "-"
            }
            guard name.hasPrefix(rendererPrefix), let dot = name.lastIndex(of: ".") else { return false }
            let stem = name[name.index(name.startIndex, offsetBy: rendererPrefix.count)..<dot]
            let ext = name[name.index(after: dot)...]
            return UUID(uuidString: String(stem)) != nil && !ext.isEmpty
                && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    static func uuid(between prefix: String, and suffix: String, in name: String) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    private static func remove(in folder: URL, where matches: (String) -> Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where matches(name) {
            let path = folder.appendingPathComponent(name).path
            var metadata = stat()
            guard lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == getuid() else { continue }
            _ = unlink(path)
        }
    }
}

/// Creating a new reading's cache as one step: it is made under a temporary name beside its
/// place (`.holos-init-<lock key>-<UUID>`), filled (`parts`, `source.txt`, the first manifest), and
/// only then renamed into place. A cache is therefore never at its place without a manifest, and
/// a failure removes everything the run created, so the reading can simply be started again.
enum ReadingCache {
    /// The steps of `create`, after each of which a test may fail it.
    enum Step: CaseIterable { case directory, parts, source, manifest }

    static let stagingPrefix = ".holos-init-"

    /// `directory`'s contents, made beside it and renamed into place. Fails, leaving nothing,
    /// when anything is in the way.
    static func create(_ directory: URL, source: Data, manifest: ReadingManifest,
                       fault: (Step) throws -> Void = { _ in }) throws {
        let folder = ReadingDirectoryLock.folder(beside: directory)
        let staging = folder.appendingPathComponent(
            "\(stagingPrefix)\(ReadingDirectoryLock.key(for: directory))-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try fault(.directory)
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("parts"),
                                                    withIntermediateDirectories: false)
            try fault(.parts)
            try source.write(to: staging.appendingPathComponent("source.txt"), options: [.withoutOverwriting])
            try fault(.source)
            try save(manifest, to: staging.appendingPathComponent(ReadingManifest.fileName))
            try fault(.manifest)
            try commit(staging, to: folder.appendingPathComponent(directory.lastPathComponent))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Renames the filled cache into place, never over anything there: exclusively where the
    /// volume can, else with rename(2), which replaces only an empty folder.
    private static func commit(_ staging: URL, to directory: URL) throws {
        if ReadingPublisher.systemExclusiveRename(staging.path, directory.path) == 0 { return }
        var error = errno
        if error == ENOTSUP || error == EINVAL || error == ENOSYS {
            if rename(staging.path, directory.path) == 0 { return }
            error = errno
        }
        if error == EEXIST || error == ENOTEMPTY || error == ENOTDIR || error == EISDIR {
            throw HolosError.invalidInput("A reading already exists at \(directory.path). Use --resume to continue it.")
        }
        throw HolosError.io("Could not create the reading cache \(directory.path): \(String(cString: strerror(error)))")
    }

    /// Removes the caches that runs killed in the middle of `create` left beside `directory`:
    /// this reading's (whose lock the caller holds), and any other reading's whose lock no run
    /// holds. Only folders owned by this user and named as `create` names them are touched.
    static func sweep(beside directory: URL) {
        let folder = ReadingDirectoryLock.folder(beside: directory)
        let own = ReadingDirectoryLock.key(for: directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            guard let key = stagingKey(name) else { continue }
            let staging = folder.appendingPathComponent(name, isDirectory: true)
            var metadata = stat()
            guard lstat(staging.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid() else { continue }
            if key == own {
                try? FileManager.default.removeItem(at: staging)
            } else if let lock = ReadingDirectoryLock.acquireIfIdle(key: key, in: folder) {
                withExtendedLifetime(lock) { try? FileManager.default.removeItem(at: staging) }
            }
        }
    }

    /// The lock key in a name `create` gives, or nil for any other name.
    static func stagingKey(_ name: String) -> String? {
        guard name.hasPrefix(stagingPrefix) else { return nil }
        let rest = name.dropFirst(stagingPrefix.count)
        guard rest.count == 64 + 1 + 36 else { return nil }
        let key = rest.prefix(64)
        guard key.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }), rest.dropFirst(64).first == "-",
              UUID(uuidString: String(rest.suffix(36))) != nil else { return nil }
        return String(key)
    }

    /// Removes a cache that an earlier version (which created it in place) left half made: a
    /// folder owned by this user, named as caches are (`Output-<16 hex digits>` or a UUID), with
    /// no manifest and nothing in it but what that creation writes (an empty `parts`,
    /// `source.txt`, a manifest being saved). Returns whether it was removed; anything else is kept.
    static func removeAbandoned(_ directory: URL) -> Bool {
        guard isCacheName(directory.lastPathComponent) else { return false }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        var files: [String] = []
        var parts: String?
        for name in names {
            let path = directory.appendingPathComponent(name).path
            var entry = stat()
            guard lstat(path, &entry) == 0, entry.st_uid == getuid() else { return false }
            let type = entry.st_mode & S_IFMT
            if name == "parts", type == S_IFDIR,
               (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true {
                parts = path
            } else if type == S_IFREG, name == "source.txt"
                        || ReadingTemporaries.uuid(between: ReadingTemporaries.manifestPrefix,
                                                   and: ReadingTemporaries.manifestSuffix, in: name) != nil {
                files.append(path)
            } else {
                return false
            }
        }
        for path in files { _ = unlink(path) }
        if let parts { _ = rmdir(parts) }
        return rmdir(directory.path) == 0
    }

    /// `Output-<16 lowercase hex digits>` (a reading with `--output`) or a UUID (one without).
    static func isCacheName(_ name: String) -> Bool {
        if UUID(uuidString: name) != nil { return true }
        let prefix = "Output-"
        guard name.hasPrefix(prefix) else { return false }
        let digest = name.dropFirst(prefix.count)
        return digest.count == 16 && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }
}

private func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
}

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

/// SHA-256 of a file read in 1 MiB chunks, so a book-length file never sits in memory at once.
func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let done = try autoreleasepool { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return true }
            hasher.update(data: chunk)
            return false
        }
        if done { break }
    }
    return hex(hasher.finalize())
}

/// The contents of a file expected to be small; a larger one is an error, not read whole.
private func readSmallFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else {
        throw HolosError.invalidInput("\(url.path) is larger than \(maximumBytes) bytes.")
    }
    return data
}

private func save(_ manifest: ReadingManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try atomicWrite(encoder.encode(manifest), to: url)
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(ReadingTemporaries.manifestName())
    try data.write(to: temporary, options: [.withoutOverwriting])
    if rename(temporary.path, url.path) != 0 {
        let message = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: temporary)
        throw HolosError.io("Could not save reading metadata: \(message)")
    }
}

public enum SemanticChunker {
    public struct Chunk: Sendable, Equatable {
        public let index: Int
        public let offset: Int
        public let length: Int
        public let text: String
    }

    public static func chunks(_ text: String, maxUTF16Units: Int = 3_000) -> [Chunk] {
        precondition(maxUTF16Units > 0)
        let characters = Array(text)
        var positions = [Int](repeating: 0, count: characters.count + 1)
        for index in characters.indices { positions[index + 1] = positions[index] + characters[index].utf16.count }
        var result: [Chunk] = []
        var start = 0
        while start < characters.count {
            var limit = start + 1
            while limit < characters.count && positions[limit + 1] - positions[start] <= maxUTF16Units {
                limit += 1
            }
            var end = limit
            if end < characters.count {
                let minimum = start + max(1, (end - start) / 3)
                for candidate in stride(from: end, through: minimum, by: -1) {
                    if candidate >= 2 && characters[candidate - 1] == "\n" && characters[candidate - 2] == "\n" {
                        end = candidate; break
                    }
                }
                if end == limit {
                    for candidate in stride(from: end, through: minimum, by: -1) {
                        if candidate > start && ".!?".contains(characters[candidate - 1]) &&
                            (candidate == characters.count || characters[candidate].isWhitespace) {
                            end = candidate; break
                        }
                    }
                }
                if end == limit {
                    for candidate in stride(from: end, through: minimum, by: -1) {
                        if candidate > start && characters[candidate - 1].isWhitespace {
                            end = candidate; break
                        }
                    }
                }
            }
            let chunkText = String(characters[start..<end])
            result.append(Chunk(index: result.count, offset: positions[start],
                                length: positions[end] - positions[start], text: chunkText))
            start = end
        }
        return result
    }
}
