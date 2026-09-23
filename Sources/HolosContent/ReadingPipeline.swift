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
    public var status: String
    public var audioSHA256: String?
    public var duration: Double?
}

public struct ReadingManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sourceSHA256: String
    public let voiceIdentifier: String
    public let rate: Float?
    public var status: String
    public var parts: [ReadingPart]
}

@MainActor public protocol ReadingAudioRenderer {
    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio
}

extension NativeSpeechRenderer: ReadingAudioRenderer {}

@MainActor public final class ReadingPipeline {
    private let renderer: any ReadingAudioRenderer
    public init(renderer: any ReadingAudioRenderer = NativeSpeechRenderer()) {
        self.renderer = renderer
    }

    public func render(text: String, voiceIdentifier: String? = nil, rate: Float? = nil,
                       to directory: URL, resume: Bool = false) async throws -> ReadingManifest {
        guard directory.isFileURL else { throw HolosError.invalidInput("Reading output must be a file URL.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HolosError.invalidInput("Reading source is empty.")
        }
        let writerLock = try ReadingDirectoryLock.acquire(for: directory)
        defer { withExtendedLifetime(writerLock) {} }
        let voice = try selectedVoice(identifier: voiceIdentifier)
        let chunks = SemanticChunker.chunks(text)
        let sourceHash = sha256(Data(text.utf8))
        let sourceURL = directory.appendingPathComponent("source.txt")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let playlistURL = directory.appendingPathComponent("playlist.m3u8")
        var manifest: ReadingManifest

        if resume {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw HolosError.invalidInput("No reading exists to resume at \(directory.path).")
            }
            manifest = try JSONDecoder().decode(ReadingManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion == 1, manifest.sourceSHA256 == sourceHash,
                  manifest.voiceIdentifier == voice, manifest.rate == rate,
                  (try? Data(contentsOf: sourceURL)) == Data(text.utf8),
                  manifest.parts.count == chunks.count else {
                throw HolosError.invalidInput("Reading source, voice, or rate differs from the saved manifest.")
            }
            for (saved, chunk) in zip(manifest.parts, chunks) {
                guard saved.index == chunk.index,
                      saved.sourceUTF16Offset == chunk.offset,
                      saved.sourceUTF16Length == chunk.length,
                      saved.textSHA256 == sha256(Data(chunk.text.utf8)),
                      saved.relativeAudioPath == String(format: "parts/part%04d.m4a", chunk.index + 1) else {
                    throw HolosError.invalidInput("Reading chunk boundaries differ from the saved manifest.")
                }
            }
        } else {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw HolosError.invalidInput("Reading output already exists: \(directory.path). Use --resume to continue it.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("parts"),
                                                    withIntermediateDirectories: false)
            try Data(text.utf8).write(to: sourceURL, options: [.withoutOverwriting])
            manifest = ReadingManifest(schemaVersion: 1, sourceSHA256: sourceHash,
                                       voiceIdentifier: voice, rate: rate, status: "incomplete",
                                       parts: chunks.map { chunk in
                ReadingPart(index: chunk.index, sourceUTF16Offset: chunk.offset,
                            sourceUTF16Length: chunk.length,
                            textSHA256: sha256(Data(chunk.text.utf8)),
                            relativeAudioPath: String(format: "parts/part%04d.m4a", chunk.index + 1),
                            status: "pending")
            })
            try save(manifest, to: manifestURL)
        }

        // A playlist is usable only when every part has passed checksum verification.
        var mustRender = false
        for index in manifest.parts.indices {
            let part = manifest.parts[index]
            let audio = directory.appendingPathComponent(part.relativeAudioPath)
            let valid = part.status == "complete" && part.audioSHA256 != nil &&
                (try? sha256(Data(contentsOf: audio))) == part.audioSHA256
            if !valid {
                manifest.parts[index].status = "pending"
                manifest.parts[index].audioSHA256 = nil
                manifest.parts[index].duration = nil
                mustRender = true
            }
        }
        let completePlaylist = Data(("#EXTM3U\n" + manifest.parts.map { $0.relativeAudioPath }.joined(separator: "\n") + "\n").utf8)
        if !mustRender && manifest.status == "complete" &&
            (try? Data(contentsOf: playlistURL)) == completePlaylist {
            return manifest
        }
        manifest.status = "incomplete"
        try save(manifest, to: manifestURL)
        try atomicWrite(Data("#EXTM3U\n#HOLOS-INCOMPLETE\n".utf8), to: playlistURL)

        for chunk in chunks {
            try Task.checkCancellation()
            if manifest.parts[chunk.index].status == "complete" { continue }
            let audio = directory.appendingPathComponent(manifest.parts[chunk.index].relativeAudioPath)
            if FileManager.default.fileExists(atPath: audio.path) {
                let quarantined = audio.deletingLastPathComponent()
                    .appendingPathComponent(".invalid-\(UUID().uuidString)-\(audio.lastPathComponent)")
                try FileManager.default.moveItem(at: audio, to: quarantined)
            }
            do {
                let result = try await renderer.render(text: chunk.text, voiceIdentifier: voice,
                                                       rate: rate, to: audio)
                guard result.url.standardizedFileURL == audio.standardizedFileURL else {
                    throw HolosError.io("Speech renderer returned an unexpected part path.")
                }
                manifest.parts[chunk.index].status = "complete"
                manifest.parts[chunk.index].audioSHA256 = try sha256(Data(contentsOf: result.url))
                manifest.parts[chunk.index].duration = result.duration
                try save(manifest, to: manifestURL)
            } catch {
                manifest.status = "incomplete"
                try? save(manifest, to: manifestURL)
                throw HolosError.incomplete("Reading stopped at part \(chunk.index + 1) of \(chunks.count): \(error.localizedDescription)")
            }
        }
        try atomicWrite(completePlaylist, to: playlistURL)
        manifest.status = "complete"
        try save(manifest, to: manifestURL)
        return manifest
    }

    private func selectedVoice(identifier: String?) throws -> String {
        let voices = NativeSpeechRenderer.voices()
        if let identifier {
            guard voices.contains(where: { $0.id == identifier }) else {
                throw HolosError.unavailable("Speech voice is unavailable: \(identifier)")
            }
            return identifier
        }
        return try NativeSpeechRenderer.defaultVoiceIdentifier()
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
