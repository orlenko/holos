import Foundation
import CryptoKit
import AVFoundation
import Darwin
import HolosCore

public struct AudioChunkRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var track: String
    public var relativePath: String
    public var start: Double
    public var end: Double
    public var sampleRate: Double
    public var channels: Int
    public var frameCount: Int
    public var sha256: String?

    public init(id: String = UUID().uuidString, track: String, relativePath: String,
                start: Double, end: Double, sampleRate: Double, channels: Int,
                frameCount: Int, sha256: String? = nil) {
        self.id = id; self.track = track; self.relativePath = relativePath
        self.start = start; self.end = end; self.sampleRate = sampleRate
        self.channels = channels; self.frameCount = frameCount; self.sha256 = sha256
    }
}

public struct SessionManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var createdAt: Date
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    public var status: String
    public var chunks: [AudioChunkRecord]

    public init(schemaVersion: Int = 1, id: String, name: String, createdAt: Date,
                source: AudioSource, locale: String, backend: SpeechBackend,
                status: String, chunks: [AudioChunkRecord] = []) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name
        self.createdAt = createdAt; self.source = source; self.locale = locale
        self.backend = backend; self.status = status; self.chunks = chunks
    }
}

public struct ArchiveEvent: Codable, Sendable, Equatable {
    public let sequence: Int
    public let at: Date
    public let kind: String
    public let details: [String: String]
}

public struct RecoveryReport: Sendable, Equatable {
    public let manifest: SessionManifest?
    public let manifestError: String?
    public let events: [ArchiveEvent]
    public let tornFinalJournalLine: Bool
    public let missingChunks: [String]
    public let corruptChunks: [String]
    public let unindexedChunks: [String]
    public let unrecoveredChunks: [String]

    public var needsAttention: Bool {
        manifestError != nil || tornFinalJournalLine || !missingChunks.isEmpty ||
        !corruptChunks.isEmpty || !unindexedChunks.isEmpty || !unrecoveredChunks.isEmpty
    }
}

/// The only mutable owner of a session archive. A POSIX advisory lock is held until finish or deinit.
public actor SessionArchive {
    public nonisolated let directory: URL
    public nonisolated let id: String

    private var manifest: SessionManifest
    private var nextSequence: Int
    private var lockFD: Int32
    private var closed = false

    private init(directory: URL, manifest: SessionManifest, nextSequence: Int, lockFD: Int32) {
        self.directory = directory; self.id = manifest.id; self.manifest = manifest
        self.nextSequence = nextSequence; self.lockFD = lockFD
    }

    deinit { if lockFD >= 0 { Darwin.close(lockFD) } }

    public static func create(root: URL, name: String, source: AudioSource,
                              locale: String, backend: SpeechBackend) throws -> SessionArchive {
        guard root.isFileURL, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !locale.isEmpty else { throw HolosError.invalidInput("Invalid archive root, name, or locale.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let directory = root.appendingPathComponent("\(id).holos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        guard chmod(directory.path, 0o700) == 0 else {
            throw HolosError.io("Cannot make session directory private.")
        }
        do {
            for path in ["audio/mic", "audio/system", "transcripts", "exports"] {
                let child = directory.appendingPathComponent(path, isDirectory: true)
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
                guard chmod(child.path, 0o700) == 0 else {
                    throw HolosError.io("Cannot make archive directory private.")
                }
            }
            guard chmod(directory.appendingPathComponent("audio").path, 0o700) == 0 else {
                throw HolosError.io("Cannot make audio directory private.")
            }
            let fd = try acquireLock(directory)
            do {
                let manifest = SessionManifest(id: id, name: name, createdAt: Date(),
                                               source: source, locale: locale, backend: backend,
                                               status: "recording")
                try atomicWrite(try encode(manifest), to: directory.appendingPathComponent("manifest.json"))
                try append(Data(), to: directory.appendingPathComponent("events.jsonl"))
                try syncDirectory(directory)
                return SessionArchive(directory: directory, manifest: manifest,
                                      nextSequence: 1, lockFD: fd)
            } catch {
                Darwin.close(fd)
                throw error
            }
        } catch {
            // A failed creation leaves its distinct directory for inspection; never delete user data.
            throw error
        }
    }

    /// Reopens an unfinished archive after a process exits; refuses a second active writer.
    public static func open(at directory: URL) throws -> SessionArchive {
        try requireSafeLayout(directory)
        let manifest = try readManifest(at: directory)
        guard manifest.status == "recording" else {
            throw HolosError.invalidInput("Only a recording archive can be reopened.")
        }
        let fd = try acquireLock(directory)
        do {
            let report = try inspectRecovery(at: directory)
            guard report.manifestError == nil, !report.tornFinalJournalLine else {
                throw HolosError.incomplete("Repair the journal before reopening this archive.")
            }
            return SessionArchive(directory: directory, manifest: manifest,
                                  nextSequence: (report.events.last?.sequence ?? 0) + 1, lockFD: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func registerChunk(_ chunk: AudioChunkRecord) throws {
        try ensureOpen()
        guard Self.validToken(chunk.id), (chunk.track == "mic" || chunk.track == "system"),
              Self.validChunkPath(chunk.relativePath, track: chunk.track),
              chunk.start.isFinite, chunk.end.isFinite, chunk.end > chunk.start, chunk.start >= 0,
              chunk.sampleRate.isFinite, chunk.sampleRate > 0, chunk.channels > 0, chunk.frameCount > 0,
              !manifest.chunks.contains(where: { $0.id == chunk.id || $0.relativePath == chunk.relativePath }) else {
            throw HolosError.invalidInput("Invalid or duplicate audio chunk metadata.")
        }
        let url = directory.appendingPathComponent(chunk.relativePath)
        let digest = try Self.hashChunk(at: url, sync: true)
        if let expected = chunk.sha256, expected.lowercased() != digest {
            throw HolosError.invalidInput("Audio chunk checksum does not match its file.")
        }
        var finalized = chunk
        finalized.sha256 = digest
        var updated = manifest
        updated.chunks.append(finalized)
        try Self.atomicWrite(try Self.encode(updated), to: directory.appendingPathComponent("manifest.json"))
        manifest = updated
    }

    public func recordEvent(kind: String, details: [String: String]) throws {
        try ensureOpen()
        guard !kind.isEmpty else { throw HolosError.invalidInput("Event kind is empty.") }
        let event = ArchiveEvent(sequence: nextSequence, at: Date(), kind: kind, details: details)
        var line = try Self.encode(event, pretty: false)
        line.append(0x0A)
        try Self.append(line, to: directory.appendingPathComponent("events.jsonl"))
        nextSequence += 1
    }

    public func saveTranscript(_ transcript: Transcript) throws {
        try ensureOpen()
        guard Self.validToken(transcript.id) else { throw HolosError.invalidInput("Invalid transcript ID.") }
        let snapshot = directory.appendingPathComponent("transcripts/\(transcript.id).json")
        guard !FileManager.default.fileExists(atPath: snapshot.path) else {
            throw HolosError.invalidInput("Transcript revision already exists.")
        }
        try Self.atomicWrite(try Self.encode(transcript), to: snapshot)
        let text = transcript.text + "\n"
        try Self.atomicWrite(Data(text.utf8), to: directory.appendingPathComponent("exports/transcript.txt"))
        var markdown = "# \(manifest.name)\n\n"
        for segment in transcript.segments {
            let source = segment.track ?? "unknown source"
            markdown += "### [\(Self.timestamp(segment.start))–\(Self.timestamp(segment.end))] Source: \(source)\n\n"
            if let speakerID = segment.speakerID {
                markdown += "Speaker label (not verified identity): \(speakerID)\n\n"
            }
            markdown += "\(segment.text)\n\n"
        }
        try Self.atomicWrite(Data(markdown.utf8), to: directory.appendingPathComponent("exports/transcript.md"))
    }

    public func finish(status: String) throws {
        try ensureOpen()
        guard !status.isEmpty, status != "recording" else {
            throw HolosError.invalidInput("Finish requires a final status.")
        }
        var updated = manifest
        updated.status = status
        try Self.atomicWrite(try Self.encode(updated), to: directory.appendingPathComponent("manifest.json"))
        manifest = updated
        closed = true
        Darwin.close(lockFD)
        lockFD = -1
    }

    /// Persist a lifecycle state while retaining the exclusive writer lock.
    public func setStatus(_ status: String) throws {
        try ensureOpen()
        guard !status.isEmpty else { throw HolosError.invalidInput("Status is empty.") }
        var updated = manifest
        updated.status = status
        try Self.atomicWrite(try Self.encode(updated), to: directory.appendingPathComponent("manifest.json"))
        manifest = updated
    }

    private func ensureOpen() throws {
        if closed { throw HolosError.invalidInput("Archive writer is closed.") }
    }

    public nonisolated static func readManifest(at directory: URL) throws -> SessionManifest {
        guard directory.isFileURL, plainDirectory(directory),
              plainFile(directory.appendingPathComponent("manifest.json")) else {
            throw HolosError.invalidInput("Archive or manifest is not a regular path.")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try decoder().decode(SessionManifest.self, from: data)
        guard manifest.schemaVersion == 1, validToken(manifest.id),
              directory.lastPathComponent == "\(manifest.id).holos",
              !manifest.name.isEmpty, !manifest.locale.isEmpty, !manifest.status.isEmpty,
              Set(manifest.chunks.map(\.id)).count == manifest.chunks.count,
              Set(manifest.chunks.map(\.relativePath)).count == manifest.chunks.count,
              manifest.chunks.allSatisfy({ chunk in
                  validToken(chunk.id) && (chunk.track == "mic" || chunk.track == "system") &&
                  validChunkPath(chunk.relativePath, track: chunk.track) &&
                  chunk.start.isFinite && chunk.start >= 0 && chunk.end.isFinite && chunk.end > chunk.start &&
                  chunk.sampleRate.isFinite && chunk.sampleRate > 0 &&
                  chunk.channels > 0 && chunk.frameCount > 0
              }) else {
            throw HolosError.invalidInput("Unsupported or mismatched session manifest.")
        }
        return manifest
    }

    /// Checks the actual archive writer lock, without creating or changing a file.
    public nonisolated static func isActive(at directory: URL) throws -> Bool {
        try requireSafeLayout(directory)
        let lock = directory.appendingPathComponent(".writer.lock")
        let fd = Darwin.open(lock.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return false }
            throw HolosError.io("Cannot inspect archive writer lock.")
        }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        if errno == EWOULDBLOCK { return true }
        throw HolosError.io("Cannot inspect archive writer lock.")
    }

    /// Repairs only a stale, structurally valid archive. Raw audio and damaged finalized chunks are never rewritten.
    public nonisolated static func recover(at directory: URL) async throws -> RecoveryReport {
        try requireSafeLayout(directory)
        let fd = try acquireLock(directory)
        defer { Darwin.close(fd) }
        let before = try inspectRecovery(at: directory)
        guard var manifest = before.manifest else {
            throw HolosError.incomplete("Cannot recover an archive without a valid manifest.")
        }
        guard before.missingChunks.isEmpty, before.corruptChunks.isEmpty else {
            throw HolosError.incomplete("Finalized audio is missing or corrupt; recovery did not change the archive.")
        }

        let opened = Dictionary(before.events.compactMap { event -> (String, ArchiveEvent)? in
            guard event.kind == "chunkOpened", let path = event.details["relativePath"] else { return nil }
            return (path, event)
        }, uniquingKeysWith: { _, latest in latest })
        var unrecovered: [String] = []
        var recovered: [String] = []
        for path in before.unindexedChunks {
            guard let event = opened[path],
                  let track = event.details["track"],
                  validChunkPath(path, track: track),
                  let startText = event.details["start"], let start = Double(startText),
                  start.isFinite, start >= 0,
                  let rateText = event.details["sampleRate"], let rate = Double(rateText),
                  rate.isFinite, rate > 0,
                  let channelText = event.details["channels"], let channels = Int(channelText), channels > 0 else {
                unrecovered.append(path); continue
            }
            let url = directory.appendingPathComponent(path)
            guard plainFile(url) else { unrecovered.append(path); continue }
            do {
                let file = try AVAudioFile(forReading: url)
                let actualRate = file.fileFormat.sampleRate
                let actualChannels = Int(file.fileFormat.channelCount)
                let frames = file.length
                guard frames > 0, frames <= Int.max, actualRate == rate,
                      actualChannels == channels else {
                    unrecovered.append(path); continue
                }
                let end = start + Double(frames) / rate
                guard end.isFinite, end > start else { unrecovered.append(path); continue }
                let digest = try hashChunk(at: url, sync: true)
                let basename = String(url.deletingPathExtension().lastPathComponent)
                var recoveredID = "recovered-\(track)-\(basename)"
                if manifest.chunks.contains(where: { $0.id == recoveredID }) {
                    recoveredID = UUID().uuidString
                }
                manifest.chunks.append(AudioChunkRecord(id: recoveredID,
                    track: track, relativePath: path, start: start, end: end,
                    sampleRate: rate, channels: channels, frameCount: Int(frames), sha256: digest))
                recovered.append(path)
            } catch { unrecovered.append(path) }
        }
        let wasStale = manifest.status == "recording" || manifest.status == "processing"
        if wasStale { manifest.status = "interrupted" }
        let changed = wasStale || !recovered.isEmpty || before.tornFinalJournalLine
        if changed {
            let journal = directory.appendingPathComponent("events.jsonl")
            if before.tornFinalJournalLine {
                let original = try Data(contentsOf: journal)
                let backup = directory.appendingPathComponent("events.before-recovery-\(UUID().uuidString).jsonl")
                try atomicWrite(original, to: backup)
                let complete = original.lastIndex(of: 0x0A).map { Data(original.prefix($0 + 1)) } ?? Data()
                try atomicWrite(complete, to: journal)
            }
            let details = [
                "chunks": recovered.joined(separator: ","),
                "unrecovered": unrecovered.joined(separator: ","),
                "previousStatus": before.manifest?.status ?? "unknown",
            ]
            if before.tornFinalJournalLine || before.events.last?.kind != "archiveRecovered" ||
                before.events.last?.details != details {
                let event = ArchiveEvent(sequence: (before.events.last?.sequence ?? 0) + 1,
                                         at: Date(), kind: "archiveRecovered", details: details)
                var line = try encode(event, pretty: false)
                line.append(0x0A)
                try append(line, to: journal)
            }
            try atomicWrite(try encode(manifest), to: directory.appendingPathComponent("manifest.json"))
        }
        let after = try inspectRecovery(at: directory)
        return RecoveryReport(manifest: after.manifest, manifestError: after.manifestError,
                              events: after.events, tornFinalJournalLine: after.tornFinalJournalLine,
                              missingChunks: after.missingChunks, corruptChunks: after.corruptChunks,
                              unindexedChunks: after.unindexedChunks,
                              unrecoveredChunks: unrecovered.sorted())
    }

    /// Read-only inspection. It never repairs, deletes, or rewrites archive contents.
    public nonisolated static func inspectRecovery(at directory: URL) throws -> RecoveryReport {
        guard directory.isFileURL else { throw HolosError.invalidInput("Archive path must be a file URL.") }
        var manifest: SessionManifest?
        var manifestError: String?
        do { manifest = try readManifest(at: directory) }
        catch { manifestError = String(describing: error) }

        let journal = directory.appendingPathComponent("events.jsonl")
        var events: [ArchiveEvent] = []
        var torn = false
        if FileManager.default.fileExists(atPath: journal.path) {
            let data = try Data(contentsOf: journal)
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if data.last != 0x0A && !data.isEmpty {
                lines.removeLast()
                torn = true
            } else if lines.last?.isEmpty == true { lines.removeLast() }
            for line in lines {
                guard let event = try? decoder().decode(ArchiveEvent.self, from: Data(line)),
                      event.sequence == (events.last?.sequence ?? 0) + 1 else {
                    throw HolosError.incomplete("Invalid event journal before its final line.")
                }
                events.append(event)
            }
        }

        var missing: [String] = []
        var corrupt: [String] = []
        let indexed = Set(manifest?.chunks.map(\.relativePath) ?? [])
        for chunk in manifest?.chunks ?? [] {
            guard validChunkPath(chunk.relativePath, track: chunk.track) else {
                corrupt.append(chunk.relativePath); continue
            }
            let url = directory.appendingPathComponent(chunk.relativePath)
            if !FileManager.default.fileExists(atPath: url.path) { missing.append(chunk.relativePath); continue }
            do {
                let hash = try hashChunk(at: url)
                if chunk.sha256 == nil || chunk.sha256?.lowercased() != hash { corrupt.append(chunk.relativePath) }
            } catch { corrupt.append(chunk.relativePath) }
        }
        var unindexed: [String] = []
        for track in ["mic", "system"] {
            let trackURL = directory.appendingPathComponent("audio/\(track)")
            guard plainDirectory(trackURL) else { continue }
            for url in (try? FileManager.default.contentsOfDirectory(at: trackURL, includingPropertiesForKeys: nil)) ?? [] {
                let path = "audio/\(track)/\(url.lastPathComponent)"
                if validChunkPath(path, track: track), !indexed.contains(path) { unindexed.append(path) }
            }
        }
        return RecoveryReport(manifest: manifest, manifestError: manifestError,
                              events: events, tornFinalJournalLine: torn,
                              missingChunks: missing.sorted(), corruptChunks: corrupt.sorted(),
                              unindexedChunks: unindexed.sorted(), unrecoveredChunks: [])
    }

    private nonisolated static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
            ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }
    }

    private nonisolated static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 1_000 else {
            return "??:??:??.???"
        }
        let milliseconds = Int((seconds * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let remainder = (milliseconds / 1_000) % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, remainder, milliseconds % 1_000)
    }

    private nonisolated static func plainDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private nonisolated static func plainFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private nonisolated static func requireSafeLayout(_ directory: URL) throws {
        guard directory.isFileURL, plainDirectory(directory),
              ["audio", "audio/mic", "audio/system", "transcripts", "exports"].allSatisfy({
                  plainDirectory(directory.appendingPathComponent($0))
              }) else {
            throw HolosError.invalidInput("Archive contains an unsafe or incomplete directory layout.")
        }
    }

    private nonisolated static func validChunkPath(_ path: String, track: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "audio" && parts[1] == Substring(track) &&
               parts[2].hasSuffix(".caf") && validToken(String(parts[2].dropLast(4)))
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private nonisolated static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(value)
    }

    private nonisolated static func acquireLock(_ directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent(".writer.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HolosError.io("Cannot open session lock: \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw HolosError.unavailable("Session archive already has an active writer.")
        }
        return fd
    }

    private nonisolated static func hashChunk(at url: URL, sync: Bool = false) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            throw HolosError.invalidInput("Audio chunk is missing, empty, or not a regular file.")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw HolosError.io("Cannot open audio chunk.") }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_ino == info.st_ino else {
            throw HolosError.invalidInput("Audio chunk changed while opening.")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw HolosError.io("Cannot read audio chunk.")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var finished = stat()
        guard fstat(fd, &finished) == 0, finished.st_size == opened.st_size,
              finished.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              finished.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw HolosError.incomplete("Audio chunk changed while hashing.")
        }
        if sync, fsync(fd) != 0 { throw HolosError.io("Cannot sync audio chunk.") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HolosError.io("Cannot create archive temporary file.") }
        var openFD = true
        do {
            try writeAll(data, fd: fd)
            guard fsync(fd) == 0 else { throw HolosError.io("Cannot sync archive file.") }
            Darwin.close(fd)
            openFD = false
            guard rename(temporary.path, url.path) == 0 else { throw HolosError.io("Cannot publish archive file.") }
            try syncDirectory(url.deletingLastPathComponent())
        } catch {
            if openFD { Darwin.close(fd) }
            unlink(temporary.path)
            throw error
        }
    }

    private nonisolated static func append(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HolosError.io("Cannot open archive journal.") }
        defer { Darwin.close(fd) }
        try writeAll(data, fd: fd)
        guard fsync(fd) == 0 else { throw HolosError.io("Cannot sync archive journal.") }
    }

    private nonisolated static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HolosError.io("Cannot write archive file.") }
                offset += count
            }
        }
    }

    private nonisolated static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw HolosError.io("Cannot open archive directory.") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw HolosError.io("Cannot sync archive directory.") }
    }
}
