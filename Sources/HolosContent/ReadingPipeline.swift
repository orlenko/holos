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

public struct ReadingManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let sourceSHA256: String
    public let voiceIdentifier: String
    public let rate: Float?
    public let title: String?
    public let author: String?
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
}

public struct ReadingResult: Sendable, Equatable {
    public let output: URL
    public let manifest: ReadingManifest
}

@MainActor public protocol ReadingAudioRenderer {
    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio
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

    private let renderer: any ReadingAudioRenderer
    private let joiner: any ReadingAudioJoiner

    public init(renderer: any ReadingAudioRenderer = NativeSpeechRenderer(),
                joiner: any ReadingAudioJoiner = AudioBookJoiner()) {
        self.renderer = renderer
        self.joiner = joiner
    }

    public func render(script: ReadingScript, voiceIdentifier: String, rate: Float? = nil,
                       metadata: AudioBookMetadata, location: ReadingLocation,
                       resume: Bool = false, maxPartUTF16Units: Int = 3_000) async throws -> ReadingResult {
        let directory = location.workDirectory
        let output = location.output
        guard directory.isFileURL, output.isFileURL else {
            throw HolosError.invalidInput("Reading locations must be file URLs.")
        }
        let text = script.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HolosError.invalidInput("Reading source is empty.")
        }
        let writerLock = try ReadingDirectoryLock.acquire(for: directory)
        defer { withExtendedLifetime(writerLock) {} }
        let planned = script.parts(maxUTF16Units: maxPartUTF16Units)
        let sourceHash = sha256(Data(text.utf8))
        let sourceURL = directory.appendingPathComponent("source.txt")
        let manifestURL = directory.appendingPathComponent("manifest.json")
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
            manifest = try JSONDecoder().decode(ReadingManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion == ReadingManifest.currentSchemaVersion,
                  manifest.sourceSHA256 == sourceHash,
                  manifest.voiceIdentifier == voiceIdentifier, manifest.rate == rate,
                  manifest.title == metadata.title, manifest.author == metadata.author,
                  manifest.output == output.path,
                  (try? Data(contentsOf: sourceURL)) == Data(text.utf8) else {
                throw HolosError.invalidInput("Reading source, voice, rate, title, or output differs from the saved reading.")
            }
            guard manifest.parts.count == expected.count,
                  zip(manifest.parts, expected).allSatisfy({ Self.samePlan($0, $1) }) else {
                throw HolosError.invalidInput("Reading part boundaries differ from the saved reading.")
            }
        } else {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw HolosError.invalidInput("A reading already exists at \(directory.path). Use --resume to continue it.")
            }
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw HolosError.invalidInput("Reading output already exists: \(output.path)")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("parts"),
                                                    withIntermediateDirectories: false)
            try Data(text.utf8).write(to: sourceURL, options: [.withoutOverwriting])
            manifest = ReadingManifest(schemaVersion: ReadingManifest.currentSchemaVersion,
                                       sourceSHA256: sourceHash, voiceIdentifier: voiceIdentifier, rate: rate,
                                       title: metadata.title, author: metadata.author, output: output.path,
                                       outputSHA256: nil, duration: nil, chapters: [],
                                       status: "incomplete", parts: expected)
            try save(manifest, to: manifestURL)
        }

        // Finished before (possibly interrupted right after publishing): nothing to do.
        if let published = manifest.outputSHA256,
           (try? sha256(Data(contentsOf: output))) == published {
            if manifest.status != "complete" {
                manifest.status = "complete"
                try save(manifest, to: manifestURL)
            }
            removeParts(in: directory)
            return ReadingResult(output: output, manifest: manifest)
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
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
                (try? sha256(Data(contentsOf: audio))) == part.audioSHA256
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
                manifest.parts[part.index].audioSHA256 = try sha256(Data(contentsOf: result.url))
                manifest.parts[part.index].duration = result.duration
                try save(manifest, to: manifestURL)
            } catch {
                manifest.status = "incomplete"
                try? save(manifest, to: manifestURL)
                throw HolosError.incomplete("Reading stopped at part \(part.index + 1) of \(planned.count): \(error.localizedDescription)")
            }
        }

        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".holos-\(UUID().uuidString).\(ReadingAudioFormat.fileExtension)")
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
        manifest.outputSHA256 = try sha256(Data(contentsOf: temporary))
        manifest.duration = summary.duration
        manifest.chapters = summary.chapters
        try save(manifest, to: manifestURL)
        if link(temporary.path, output.path) != 0 {
            let message = String(cString: strerror(errno))
            manifest.outputSHA256 = nil
            try? save(manifest, to: manifestURL)
            throw HolosError.io("Could not save \(output.path): \(message)")
        }
        manifest.status = "complete"
        try save(manifest, to: manifestURL)
        removeParts(in: directory)
        return ReadingResult(output: output, manifest: manifest)
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

/// A persistent sibling lock serializes new renders and resumes across processes.
/// The lock file is intentionally kept so another process cannot lock a replacement inode.
final class ReadingDirectoryLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(for directory: URL) throws -> ReadingDirectoryLock {
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        let parent = canonical.deletingLastPathComponent()
        let key = sha256(Data(canonical.path.utf8))
        let path = parent.appendingPathComponent(".holos-reading-\(key).lock").path
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
                throw HolosError.unavailable("Reading directory is already being rendered: \(directory.path)")
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

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func save(_ manifest: ReadingManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try atomicWrite(encoder.encode(manifest), to: url)
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".holos-\(UUID().uuidString).tmp")
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
