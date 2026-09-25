import AudioToolbox
import AVFoundation
import Darwin
import Foundation
import HolosCore

/// An audio chunk written as `AVAudioFile(forWriting:)` writes it (CAF, 16-bit little-endian integer PCM, converted
/// from the Float32 processing format on write), but through a descriptor the caller opened rather than by path:
/// `AudioFileInitializeWithCallbacks` with `pread`/`pwrite`, wrapped in an ExtAudioFile. So the samples reach the
/// file that was created (`AtomicFile.createForWriting`), whatever its path leads to meanwhile.
final class DescriptorChunkFile {
    /// The open file the callbacks read and write. Owned: closed by `close()` or deinit.
    private final class Sink {
        var fd: Int32
        init(fd: Int32) { self.fd = fd }
    }

    private let sink: Sink
    private var file: AudioFileID?
    private var converter: ExtAudioFileRef?
    let processingFormat: AVAudioFormat

    /// Takes ownership of `fd` (a new, empty regular file open read-write) and starts a CAF file in it with the
    /// settings `AudioChunkWriter` gives `AVAudioFile`: 16-bit integer PCM at `format`'s sample rate and channels,
    /// written from `format` (standard Float32, deinterleaved). On a throw, `fd` is closed.
    init(fd: Int32, format: AVAudioFormat) throws {
        sink = Sink(fd: fd)
        processingFormat = format
        let channels = format.channelCount
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        var created: AudioFileID?
        let status = AudioFileInitializeWithCallbacks(
            Unmanaged.passUnretained(sink).toOpaque(), Self.read, Self.write, Self.getSize, Self.setSize,
            kAudioFileCAFType, &fileFormat, [], &created)
        guard status == noErr, let created else {
            Darwin.close(fd)
            sink.fd = -1
            throw HolosError.io("Cannot start an audio chunk (\(status)).")
        }
        file = created
        do {
            var wrapped: ExtAudioFileRef?
            try Self.check(ExtAudioFileWrapAudioFileID(created, true, &wrapped), "start")
            guard let wrapped else { throw HolosError.io("Cannot start an audio chunk.") }
            converter = wrapped
            if let layout = format.channelLayout {
                try Self.check(ExtAudioFileSetProperty(wrapped, kExtAudioFileProperty_FileChannelLayout,
                                                       Self.size(of: layout.layout), layout.layout), "start")
            }
            try Self.check(ExtAudioFileSetProperty(wrapped, kExtAudioFileProperty_ClientDataFormat,
                                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                                   format.streamDescription), "start")
        } catch {
            abandon()
            throw error
        }
    }

    deinit { abandon() }

    /// Appends `buffer` (in `processingFormat`).
    func write(from buffer: AVAudioPCMBuffer) throws {
        guard let converter else { throw HolosError.io("Missing audio writer.") }
        try Self.check(ExtAudioFileWrite(converter, buffer.frameLength, buffer.audioBufferList), "write")
    }

    /// Finishes the file (its header records the length) and fsyncs it, then reads its format and length back
    /// through the same descriptor, as `AVAudioFile(forReading:)` would report them, and closes it.
    func close() throws -> (sampleRate: Double, channels: Int, frames: Int64) {
        defer { abandon() }
        guard let converter, let file else { throw HolosError.io("Missing audio writer.") }
        self.converter = nil
        try Self.check(ExtAudioFileDispose(converter), "finish")
        self.file = nil
        try Self.check(AudioFileClose(file), "finish")
        guard fsync(sink.fd) == 0 else { throw HolosError.io("Cannot save an audio chunk: \(String(cString: strerror(errno))).") }
        return try readBack()
    }

    /// The format and length of the finished file, read through the descriptor.
    private func readBack() throws -> (sampleRate: Double, channels: Int, frames: Int64) {
        var opened: AudioFileID?
        try Self.check(AudioFileOpenWithCallbacks(Unmanaged.passUnretained(sink).toOpaque(), Self.read, nil,
                                                  Self.getSize, nil, kAudioFileCAFType, &opened), "read back")
        guard let opened else { throw HolosError.io("Cannot read back an audio chunk.") }
        defer { AudioFileClose(opened) }
        var wrapped: ExtAudioFileRef?
        try Self.check(ExtAudioFileWrapAudioFileID(opened, false, &wrapped), "read back")
        guard let wrapped else { throw HolosError.io("Cannot read back an audio chunk.") }
        defer { ExtAudioFileDispose(wrapped) }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var frames: Int64 = 0
        var framesSize = UInt32(MemoryLayout<Int64>.size)
        try Self.check(ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileDataFormat, &formatSize, &format),
                       "read back")
        try Self.check(ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileLengthFrames, &framesSize, &frames),
                       "read back")
        return (format.mSampleRate, Int(format.mChannelsPerFrame), frames)
    }

    /// Lets go of the converter, the file, and the descriptor, without finishing anything.
    private func abandon() {
        if let converter { ExtAudioFileDispose(converter) }
        converter = nil
        if let file { AudioFileClose(file) }
        file = nil
        if sink.fd >= 0 { Darwin.close(sink.fd) }
        sink.fd = -1
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw HolosError.io("Cannot \(step) an audio chunk (\(status)).") }
    }

    /// The byte size of `layout` with its channel descriptions.
    private static func size(of layout: UnsafePointer<AudioChannelLayout>) -> UInt32 {
        let descriptions = Int(layout.pointee.mNumberChannelDescriptions)
        let base = MemoryLayout<AudioChannelLayout>.size - MemoryLayout<AudioChannelDescription>.size
        return UInt32(base + max(1, descriptions) * MemoryLayout<AudioChannelDescription>.size)
    }

    private static func sink(_ client: UnsafeMutableRawPointer) -> Sink {
        Unmanaged<Sink>.fromOpaque(client).takeUnretainedValue()
    }

    private static let read: AudioFile_ReadProc = { client, position, requested, buffer, actual in
        let fd = DescriptorChunkFile.sink(client).fd
        var done = 0
        while done < Int(requested) {
            let count = Darwin.pread(fd, buffer.advanced(by: done), Int(requested) - done, off_t(position) + off_t(done))
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
    }

    private static let write: AudioFile_WriteProc = { client, position, requested, buffer, actual in
        let fd = DescriptorChunkFile.sink(client).fd
        var done = 0
        while done < Int(requested) {
            let count = Darwin.pwrite(fd, buffer.advanced(by: done), Int(requested) - done, off_t(position) + off_t(done))
            if count < 0 {
                if errno == EINTR { continue }
                actual.pointee = UInt32(done)
                return kAudioFileUnspecifiedError
            }
            if count == 0 { break }
            done += count
        }
        actual.pointee = UInt32(done)
        return done == Int(requested) ? noErr : kAudioFileUnspecifiedError
    }

    private static let getSize: AudioFile_GetSizeProc = { client in
        var info = stat()
        guard fstat(DescriptorChunkFile.sink(client).fd, &info) == 0 else { return 0 }
        return Int64(info.st_size)
    }

    private static let setSize: AudioFile_SetSizeProc = { client, size in
        ftruncate(DescriptorChunkFile.sink(client).fd, off_t(size)) == 0 ? noErr : kAudioFileUnspecifiedError
    }
}
