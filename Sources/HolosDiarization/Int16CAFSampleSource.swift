import Accelerate
import AudioToolbox
import Darwin
import FluidAudio
import Foundation
import HolosCore

/// FluidAudio's audio input over a rendered track (`derived/<track>-16k.caf`): a memory map of a CAF file holding
/// 16 kHz mono 16-bit little-endian integer PCM, converted to Float in `copySamples` (docs/meeting-design.md §4.8).
/// A 3 h render stays a 346 MB mapping instead of a 690 MB Float32 copy on disk or in memory.
///
/// The file must not be truncated or rewritten while a source over it exists (reads past a truncation fault); the
/// post-processor owns `derived/` for the whole run.
public struct Int16CAFSampleSource: AudioSampleSource {
    /// The sample rate the diarizer needs.
    public static let sampleRate = 16_000.0

    public let url: URL
    public let sampleCount: Int
    private let file: MappedFile
    /// Byte offset of the first sample in the file.
    private let dataOffset: Int

    /// Maps `url` (a regular file, not a symbolic link) and checks its format. Throws `invalidInput` for anything
    /// but a CAF file of 16 kHz mono 16-bit little-endian signed integer PCM whose audio data lies within the file.
    public init(url: URL) throws {
        guard url.isFileURL else { throw HolosError.invalidInput("Speaker labelling needs a local audio file.") }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw HolosError.invalidInput("Cannot open the rendered audio \(url.path): \(reason).")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            throw HolosError.invalidInput("The rendered audio \(url.path) is empty or not a regular file.")
        }
        let file = try MappedFile(fd: fd, length: Int(info.st_size))
        let layout = try Self.readLayout(of: file, path: url.path)
        self.url = url
        self.file = file
        self.dataOffset = layout.dataOffset
        self.sampleCount = layout.sampleCount
    }

    /// Writes `count` samples starting at sample `offset` to `destination`, as Float in [-1, 1) (Int16 ÷ 32768).
    /// Positions outside the file's samples (a negative offset, or reading past the end, as FluidAudio does for
    /// its last window) are written as silence, so all `count` destination values are always set.
    public func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0 else { return }
        // Destination positions [first, end) hold samples [max(offset, 0), …); the rest is silence.
        let first: Int
        if offset >= 0 {
            first = 0
        } else {
            first = offset <= -count ? count : -offset
        }
        var end = first
        let sourceStart = max(offset, 0)
        if first < count, sourceStart < sampleCount {
            end = first + min(count - first, sampleCount - sourceStart)
        }
        if first > 0 { destination.update(repeating: 0, count: first) }
        if end < count { (destination + end).update(repeating: 0, count: count - end) }
        guard end > first else { return }
        convert(from: sourceStart, count: end - first, into: destination + first)
    }

    // MARK: - Private

    private func convert(from sample: Int, count: Int, into destination: UnsafeMutablePointer<Float>) {
        let source = file.base + dataOffset + 2 * sample
        if 1.littleEndian == 1, Int(bitPattern: source) % MemoryLayout<Int16>.alignment == 0 {
            let integers = source.bindMemory(to: Int16.self, capacity: count)
            vDSP_vflt16(integers, 1, destination, 1, vDSP_Length(count))
            var scale = Float(1.0 / 32_768.0)
            vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(count))
        } else {
            for index in 0..<count {
                let value = Int16(littleEndian: source.loadUnaligned(fromByteOffset: 2 * index, as: Int16.self))
                destination[index] = Float(value) / 32_768
            }
        }
    }

    private struct Layout {
        var dataOffset: Int
        var sampleCount: Int
    }

    /// Reads the CAF header from the mapping (`AudioFileOpenWithCallbacks`), so the format checked is the one of
    /// the bytes that will be read.
    private static func readLayout(of file: MappedFile, path: String) throws -> Layout {
        let unreadable = HolosError.invalidInput("The rendered audio \(path) is not a readable CAF file.")
        var audioFile: AudioFileID?
        let status = AudioFileOpenWithCallbacks(
            Unmanaged.passUnretained(file).toOpaque(),
            { client, position, requested, buffer, actual in
                let file = Unmanaged<MappedFile>.fromOpaque(client).takeUnretainedValue()
                guard position >= 0 else {
                    actual.pointee = 0
                    return kAudioFilePositionError
                }
                let available = position < Int64(file.length) ? file.length - Int(position) : 0
                let count = min(Int(requested), available)
                if count > 0 { buffer.copyMemory(from: file.base + Int(position), byteCount: count) }
                actual.pointee = UInt32(count)
                return noErr
            },
            nil,
            { client in Int64(Unmanaged<MappedFile>.fromOpaque(client).takeUnretainedValue().length) },
            nil,
            kAudioFileCAFType,
            &audioFile)
        guard status == noErr, let audioFile else { throw unreadable }
        defer { AudioFileClose(audioFile) }

        var fileType: AudioFileTypeID = 0
        var format = AudioStreamBasicDescription()
        var dataOffset: Int64 = 0
        var byteCount: UInt64 = 0
        guard property(audioFile, kAudioFilePropertyFileFormat, &fileType),
              property(audioFile, kAudioFilePropertyDataFormat, &format),
              property(audioFile, kAudioFilePropertyDataOffset, &dataOffset),
              property(audioFile, kAudioFilePropertyAudioDataByteCount, &byteCount) else { throw unreadable }
        guard fileType == kAudioFileCAFType else { throw unreadable }

        let flags = format.mFormatFlags
        let isInteger = flags & AudioFormatFlags(kAudioFormatFlagIsFloat) == 0
            && flags & AudioFormatFlags(kAudioFormatFlagIsSignedInteger) != 0
        let isLittleEndian = flags & AudioFormatFlags(kAudioFormatFlagIsBigEndian) == 0
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == sampleRate,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16, format.mBytesPerFrame == 2,
              format.mFramesPerPacket == 1, format.mBytesPerPacket == 2, isInteger, isLittleEndian else {
            throw HolosError.invalidInput(
                "Speaker labelling needs 16 kHz mono 16-bit little-endian integer PCM; \(path) is "
                    + "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) channel(s), "
                    + "\(format.mBitsPerChannel)-bit \(isInteger ? "integer" : "float")"
                    + "\(isLittleEndian ? "" : " big-endian").")
        }
        guard dataOffset >= 0, dataOffset <= Int64(file.length),
              byteCount <= UInt64(Int64(file.length) - dataOffset) else {
            throw HolosError.invalidInput("The rendered audio \(path) ends before its declared length.")
        }
        return Layout(dataOffset: Int(dataOffset), sampleCount: Int(byteCount / 2))
    }

    private static func property<T: BitwiseCopyable>(_ file: AudioFileID, _ id: AudioFilePropertyID,
                                                     _ value: inout T) -> Bool {
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioFileGetProperty(file, id, &size, bytes.baseAddress!)
        }
        return status == noErr && size == UInt32(MemoryLayout<T>.size)
    }
}

/// A read-only, private memory map of a whole file.
///
/// `@unchecked Sendable`: the mapping is created once in `init`, never written (PROT_READ) or remapped, and
/// unmapped only in `deinit`, when no reference to it remains; concurrent reads through `base` from any thread are
/// therefore safe.
final class MappedFile: @unchecked Sendable {
    let base: UnsafeRawPointer
    let length: Int

    init(fd: Int32, length: Int) throws {
        guard length > 0 else { throw HolosError.invalidInput("Cannot map an empty file.") }
        let address = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0)
        guard let address, address != MAP_FAILED else {
            throw HolosError.io("Cannot map the rendered audio into memory: \(String(cString: strerror(errno))).")
        }
        base = UnsafeRawPointer(address)
        self.length = length
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), length)
    }
}
