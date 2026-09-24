import AVFoundation
import Foundation
import Testing
import HolosCore
@testable import HolosDiarization

@Suite struct SampleSourceTests {
    @Test func sampleSourceReadsInt16CAF() throws {
        let folder = try sourceTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ramp-16k.caf")
        let count = 48_000
        try sourceWriteCAF(url, sampleRate: 16_000, channels: 1, frames: count) { frame, _ in sourceRamp(frame) }

        let source = try Int16CAFSampleSource(url: url)

        #expect(source.sampleCount == count)
        for offset in [0, 1_000, count - 1] {
            let length = min(16, count - offset)
            let samples = sourceCopy(source, offset: offset, count: length)
            #expect(samples == (offset..<(offset + length)).map { Float(sourceRamp($0)) / 32_768 })
        }
        #expect(sourceCopy(source, offset: count - 1, count: 1) == [Float(sourceRamp(count - 1)) / 32_768])
    }

    @Test func readsPastEitherEndAreSilence() throws {
        let folder = try sourceTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ramp-16k.caf")
        let count = 1_000
        try sourceWriteCAF(url, sampleRate: 16_000, channels: 1, frames: count) { frame, _ in sourceRamp(frame) }
        let source = try Int16CAFSampleSource(url: url)
        let expected = { (index: Int) -> Float in
            (0..<count).contains(index) ? Float(sourceRamp(index)) / 32_768 : 0
        }

        // FluidAudio asks for whole windows past the end and expects the rest untouched or silent.
        #expect(sourceCopy(source, offset: count - 2, count: 5) == (count - 2..<count + 3).map(expected))
        #expect(sourceCopy(source, offset: -3, count: 5) == (-3..<2).map(expected))
        #expect(sourceCopy(source, offset: count + 10, count: 3) == [0, 0, 0])
        #expect(sourceCopy(source, offset: -10, count: 4) == [0, 0, 0, 0])
        #expect(sourceCopy(source, offset: Int.max - 1, count: 2) == [0, 0])
        #expect(sourceCopy(source, offset: -5, count: count + 10) == (-5..<count + 5).map(expected))
    }

    @Test func sampleSourceReadsUnalignedData() throws {
        let folder = try sourceTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("odd-offset.caf")
        let values = (0..<500).map { Int16(truncatingIfNeeded: $0 * 131 - 30_000) }
        // A one-byte free chunk before the data puts the first sample at an odd byte offset.
        try sourceHandMadeCAF(url, sampleRate: 16_000, channels: 1, bits: 16, littleEndian: true, freeBytes: 1,
                              samples: values)

        let source = try Int16CAFSampleSource(url: url)

        #expect(source.sampleCount == values.count)
        #expect(sourceCopy(source, offset: 0, count: values.count) == values.map { Float($0) / 32_768 })
        #expect(sourceCopy(source, offset: 3, count: 2) == [Float(values[3]) / 32_768, Float(values[4]) / 32_768])
    }

    @Test func sampleSourceRejectsOtherFormats() throws {
        let folder = try sourceTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wideband = folder.appendingPathComponent("48k.caf")
        try sourceWriteCAF(wideband, sampleRate: 48_000, channels: 1, frames: 480) { frame, _ in sourceRamp(frame) }
        let stereo = folder.appendingPathComponent("stereo.caf")
        try sourceWriteCAF(stereo, sampleRate: 16_000, channels: 2, frames: 160) { frame, _ in sourceRamp(frame) }
        let bigEndian = folder.appendingPathComponent("big-endian.caf")
        try sourceHandMadeCAF(bigEndian, sampleRate: 16_000, channels: 1, bits: 16, littleEndian: false, freeBytes: 0,
                              samples: [1, 2, 3])
        let float = folder.appendingPathComponent("float.caf")
        let floatFile = try AVAudioFile(forWriting: float, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVAudioFileTypeKey: kAudioFileCAFType,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        floatFile.close()
        let wave = folder.appendingPathComponent("mono.wav")
        try sourceWriteCAF(wave, sampleRate: 16_000, channels: 1, frames: 160, fileType: kAudioFileWAVEType) { f, _ in
            sourceRamp(f)
        }
        let text = folder.appendingPathComponent("text.caf")
        try Data("not audio".utf8).write(to: text)
        let empty = folder.appendingPathComponent("empty.caf")
        try Data().write(to: empty)

        for url in [wideband, stereo, bigEndian, float, wave, text, empty,
                    folder.appendingPathComponent("missing.caf")] {
            #expect(throws: HolosError.self, "\(url.lastPathComponent)") { try Int16CAFSampleSource(url: url) }
        }
    }

    @Test func sampleSourceRefusesSymbolicLinks() throws {
        let folder = try sourceTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ramp.caf")
        try sourceWriteCAF(url, sampleRate: 16_000, channels: 1, frames: 16) { frame, _ in sourceRamp(frame) }
        let link = folder.appendingPathComponent("link.caf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: HolosError.self) { try Int16CAFSampleSource(url: link) }
    }
}

// MARK: - Helpers (prefixed: other test files in this target may declare their own)

/// A ramp that covers the Int16 range, including both extremes.
private func sourceRamp(_ index: Int) -> Int16 {
    Int16(truncatingIfNeeded: index * 97 - 32_768)
}

private func sourceTemporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("holos-samples-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sourceCopy(_ source: Int16CAFSampleSource, offset: Int, count: Int) -> [Float] {
    var samples = [Float](repeating: .nan, count: count)
    samples.withUnsafeMutableBufferPointer { buffer in
        try? source.copySamples(into: buffer.baseAddress!, offset: offset, count: count)
    }
    return samples
}

/// Writes 16-bit little-endian integer PCM through AVAudioFile, sample values exactly as given.
private func sourceWriteCAF(_ url: URL, sampleRate: Double, channels: Int, frames: Int,
                            fileType: AudioFileTypeID = kAudioFileCAFType,
                            value: (_ frame: Int, _ channel: Int) -> Int16) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false, AVAudioFileTypeKey: fileType,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = try #require(buffer.int16ChannelData)[0]
    for frame in 0..<frames {
        for channel in 0..<channels { samples[frame * channels + channel] = value(frame, channel) }
    }
    try file.write(from: buffer)
    file.close()
}

/// A CAF file built byte by byte: header, `desc`, an optional `free` chunk of `freeBytes`, and `data`.
private func sourceHandMadeCAF(_ url: URL, sampleRate: Double, channels: UInt32, bits: UInt32, littleEndian: Bool,
                               freeBytes: Int, samples: [Int16]) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    func chunk(_ type: String, size: Int64) {
        data.append(contentsOf: Array(type.utf8))
        append(size)
    }
    data.append(contentsOf: Array("caff".utf8))
    append(UInt16(1))
    append(UInt16(0))
    chunk("desc", size: 32)
    append(sampleRate.bitPattern)
    data.append(contentsOf: Array("lpcm".utf8))
    append(UInt32(littleEndian ? 2 : 0)) // kCAFLinearPCMFormatFlagIsLittleEndian
    append(UInt32(bits / 8) * channels)   // bytes per packet
    append(UInt32(1))                     // frames per packet
    append(channels)
    append(bits)
    if freeBytes > 0 {
        chunk("free", size: Int64(freeBytes))
        data.append(Data(count: freeBytes))
    }
    chunk("data", size: Int64(4 + samples.count * 2))
    append(UInt32(0)) // edit count
    for sample in samples {
        let stored = littleEndian ? sample.littleEndian : sample.bigEndian
        withUnsafeBytes(of: stored) { data.append(contentsOf: $0) }
    }
    try data.write(to: url)
}
