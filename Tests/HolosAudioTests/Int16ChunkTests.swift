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
