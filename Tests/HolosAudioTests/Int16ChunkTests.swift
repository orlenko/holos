import AVFoundation
import Foundation
import HolosCore
import HolosStorage
import Testing
@testable import HolosAudio

private func int16Archive() throws -> (SessionArchive, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-audio-\(UUID().uuidString)")
    let archive = try SessionArchive.create(root: root, name: "Int16", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    return (archive, root)
}

@Test func int16ChunkRoundTripWithinOneStep() async throws {
    let (archive, root) = try int16Archive()
    defer { try? FileManager.default.removeItem(at: root) }
    let values: [Float] = [0.5, -0.25, 0.999, -1.0, 0]
    let writer = AudioChunkWriter(archive: archive)
    try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(samples: values, sampleRate: 48_000,
                                                                          channels: 1, startTime: 0)))
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let chunk = try #require(try SessionArchive.readManifest(at: archive.directory).chunks.first)
    #expect(chunk.frameCount == values.count)
    let file = try AVAudioFile(forReading: archive.directory.appendingPathComponent(chunk.relativePath))
    #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.processingFormat.commonFormat == .pcmFormatFloat32, "Readers keep reading Float32.")
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16))
    try file.read(into: buffer)
    let read = try PCMConversion.copy(buffer, startTime: 0).samples
    #expect(read.count == values.count)
    for (written, readBack) in zip(values, read) {
        #expect(abs(written - readBack) <= 1 / 32_768 + 1e-6, "\(written) read back as \(readBack)")
    }
}

@Test func int16HalvesChunkBytes() async throws {
    let (archive, root) = try int16Archive()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = AudioChunkWriter(archive: archive)
    // 30 s of mono 48 kHz, one second per frame: exactly one full chunk.
    for second in 0..<30 {
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.01)) * 0.5 }
        try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(samples: samples, sampleRate: 48_000,
                                                                              channels: 1, startTime: Double(second))))
    }
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let chunks = try SessionArchive.readManifest(at: archive.directory).chunks
    #expect(chunks.count == 1)
    let chunk = try #require(chunks.first)
    let dataBytes = 30 * 48_000 * 2
    #expect(writer.bytesWritten() == Int64(dataBytes))
    let size = try #require(try FileManager.default.attributesOfItem(
        atPath: archive.directory.appendingPathComponent(chunk.relativePath).path)[.size] as? Int)
    #expect(size >= dataBytes && size <= dataBytes + 4_096, "Int16 data plus a CAF header (\(size) bytes).")
    #expect(writer.lastFrameEnd == 30)
}

private struct Int16Track {
    var samples: [Float] = []
    var formats: [AVAudioFormat] = []
    var chunks: [AudioChunkRecord] = []
}

/// Every sample of every chunk of `archive`'s `track`, in order, with each chunk's file format.
private func int16ReadTrack(_ archive: SessionArchive, track: String) throws -> Int16Track {
    var result = Int16Track()
    result.chunks = try SessionArchive.readManifest(at: archive.directory).chunks.filter { $0.track == track }
    for chunk in result.chunks {
        let file = try AVAudioFile(forReading: archive.directory.appendingPathComponent(chunk.relativePath))
        result.formats.append(file.fileFormat)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        result.samples += try PCMConversion.copy(buffer, startTime: 0).samples
    }
    return result
}

/// A chunk written through its descriptor (as an import writes it) is the chunk `AVAudioFile` writes at its path:
/// the same Int16 file format, frames, and samples, split into the same chunks, each registered and verified.
@Test(arguments: [1, 2])
func descriptorChunksMatchPathChunks(channels: Int) async throws {
    var results: [Int16Track] = []
    for throughDescriptor in [false, true] {
        let (archive, root) = try int16Archive()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = AudioChunkWriter(archive: archive, chunkDuration: 1, throughDescriptor: throughDescriptor)
        // 2.5 s in 0.5 s frames: two full chunks and a partial one.
        for step in 0..<5 {
            let count = 8_000 * channels
            let samples = (0..<count).map { Float(sin(Double(step * count + $0) * 0.013)) * 0.4 }
            try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(
                samples: samples, sampleRate: 16_000, channels: channels, startTime: Double(step) * 0.5)))
        }
        try await writer.finish()
        try await archive.finish(status: ArchiveStatus.complete)
        #expect(try !SessionArchive.inspectRecovery(at: archive.directory).needsAttention)
        results.append(try int16ReadTrack(archive, track: "mic"))
    }
    let (path, descriptor) = (results[0], results[1])
    #expect(descriptor.chunks.count == 3)
    #expect(descriptor.chunks.map(\.frameCount) == path.chunks.map(\.frameCount))
    #expect(descriptor.chunks.map(\.relativePath) == path.chunks.map(\.relativePath))
    #expect(descriptor.formats.map(\.commonFormat) == path.formats.map(\.commonFormat))
    #expect(descriptor.formats.map(\.channelCount) == path.formats.map(\.channelCount))
    #expect(descriptor.formats.map(\.sampleRate) == path.formats.map(\.sampleRate))
    #expect(descriptor.samples.count == 40_000 * channels)
    #expect(descriptor.samples == path.samples)
}

/// Through a descriptor, a chunk is never written over an existing file at its path.
@Test func descriptorChunkRefusesAnExistingFile() async throws {
    let (archive, root) = try int16Archive()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = archive.directory.appendingPathComponent("audio/mic/000001.caf")
    try Data("theirs".utf8).write(to: existing)
    let writer = AudioChunkWriter(archive: archive, throughDescriptor: true)
    let error = await #expect(throws: HolosError.self) {
        try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(samples: [0.1, 0.2],
                                                                              sampleRate: 16_000, channels: 1,
                                                                              startTime: 0)))
    }
    #expect(error?.errorDescription?.contains("Refusing to overwrite") == true)
    #expect(try Data(contentsOf: existing) == Data("theirs".utf8))
}
