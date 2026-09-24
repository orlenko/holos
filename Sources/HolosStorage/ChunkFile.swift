import Foundation
import AudioToolbox
import CryptoKit
import Darwin
import HolosCore

/// What `ChunkFile.read(at:sync:)` found in a finalized audio chunk, all from one open descriptor.
struct ChunkReading: Sendable, Equatable {
    var sampleRate: Double
    var channels: Int
    var frames: Int64
    var sha256: String
}

/// Reads audio chunks (`audio/<track>/<id>.caf`) through one descriptor opened relative to its folder, which is
/// opened with `AtomicFile.openFolder` (O_NOFOLLOW from the session folder down), never by path. Both the audio
/// format and the SHA-256 come from that descriptor, and the call refuses when the file changed while it was
/// read or when the entry at `url`, reached again through the folder chain, is no longer the file it read.
enum ChunkFile {
    enum Stage: Sendable { case beforeOpen, afterOpen }

    /// Test hook: while set (a task-local value), called with the chunk's URL before its folder chain is opened
    /// and again once the chunk is open, before anything is read, so tests can swap files or folders.
    @TaskLocal static var readHook: (@Sendable (URL, Stage) -> Void)? = nil

    /// The chunk's SHA-256 (lowercase hex). `sync` also fsyncs it.
    static func hash(at url: URL, sync: Bool = false) throws -> String {
        try withOpenChunk(url, sync: sync) { fd, _ in try sha256(fd) }
    }

    /// The chunk's format, length in frames (as `AVAudioFile.length` reports it), and SHA-256. `sync` also
    /// fsyncs it.
    static func read(at url: URL, sync: Bool = false) throws -> ChunkReading {
        try withOpenChunk(url, sync: sync) { fd, info in
            let format = try audioFormat(fd, size: Int64(info.st_size))
            return ChunkReading(sampleRate: format.sampleRate, channels: format.channels, frames: format.frames,
                                sha256: try sha256(fd))
        }
    }

    // MARK: - Private

    private static func withOpenChunk<T>(_ url: URL, sync: Bool, _ body: (Int32, stat) throws -> T) throws -> T {
        let notAChunk = HolosError.invalidInput("Audio chunk is missing, empty, or not a regular file.")
        readHook?(url, .beforeOpen)
        guard let (folder, name) = try AtomicFile.openParentIfPresent(of: url) else { throw notAChunk }
        defer { Darwin.close(folder) }
        // O_NONBLOCK keeps a FIFO planted in place of the chunk from blocking the open.
        let fd = openat(folder, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ELOOP { throw notAChunk }
            throw HolosError.io("Cannot open audio chunk.")
        }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG, opened.st_size > 0 else {
            throw notAChunk
        }
        readHook?(url, .afterOpen)
        let result = try body(fd, opened)
        var finished = stat()
        guard fstat(fd, &finished) == 0, finished.st_size == opened.st_size,
              finished.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              finished.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw HolosError.incomplete("Audio chunk changed while it was read.")
        }
        // The path must still lead, through the folder chain, to the file this call read.
        guard let (again, againName) = try AtomicFile.openParentIfPresent(of: url) else {
            throw HolosError.incomplete("Audio chunk was moved while it was read.")
        }
        defer { Darwin.close(again) }
        guard try AtomicFile.identity(of: againName, in: again) == FileIdentity(opened) else {
            throw HolosError.incomplete("Audio chunk was replaced while it was read.")
        }
        if sync, fsync(fd) != 0 { throw HolosError.io("Cannot sync audio chunk.") }
        return result
    }

    private static func sha256(_ fd: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, offset) }
            if count < 0 {
                if errno == EINTR { continue }
                throw HolosError.io("Cannot read audio chunk.")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            offset += off_t(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The open file an `AudioFileOpenWithCallbacks` reader reads from.
    private final class Source {
        let fd: Int32
        let size: Int64
        init(fd: Int32, size: Int64) { self.fd = fd; self.size = size }
    }

    /// Reads the CAF header through `fd` (`AudioFileOpenWithCallbacks` with `pread`, wrapped in an ExtAudioFile,
    /// as `AVAudioFile` reads it), so nothing is opened by path.
    private static func audioFormat(_ fd: Int32, size: Int64) throws -> (sampleRate: Double, channels: Int,
                                                                          frames: Int64) {
        let unreadable = HolosError.invalidInput("Audio chunk is not readable audio.")
        let source = Source(fd: fd, size: size)
        return try withExtendedLifetime(source) {
            var file: AudioFileID?
            let status = AudioFileOpenWithCallbacks(
                Unmanaged.passUnretained(source).toOpaque(),
                { client, position, requested, buffer, actual in
                    let source = Unmanaged<ChunkFile.Source>.fromOpaque(client).takeUnretainedValue()
                    var done = 0
                    while done < Int(requested) {
                        let count = Darwin.pread(source.fd, buffer.advanced(by: done), Int(requested) - done,
                                                 off_t(position) + off_t(done))
                        if count < 0 {
                            if errno == EINTR { continue }
                            actual.pointee = UInt32(done)
                            return kAudioFileUnspecifiedError
                        }
                        if count == 0 { break }
                        done += count
                    }
                    actual.pointee = UInt32(done)
                    return noErr
                },
                nil,
                { client in Unmanaged<ChunkFile.Source>.fromOpaque(client).takeUnretainedValue().size },
                nil,
                kAudioFileCAFType,
                &file)
            guard status == noErr, let file else { throw unreadable }
            defer { AudioFileClose(file) }
            var wrapped: ExtAudioFileRef?
            guard ExtAudioFileWrapAudioFileID(file, false, &wrapped) == noErr, let wrapped else { throw unreadable }
            defer { ExtAudioFileDispose(wrapped) }
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var frames: Int64 = 0
            var framesSize = UInt32(MemoryLayout<Int64>.size)
            guard ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileDataFormat, &formatSize,
                                          &format) == noErr,
                  ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileLengthFrames, &framesSize,
                                          &frames) == noErr else { throw unreadable }
            return (format.mSampleRate, Int(format.mChannelsPerFrame), frames)
        }
    }
}
