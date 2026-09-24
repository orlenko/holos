import AVFoundation
import Foundation
import HolosCore
import HolosStorage
import Testing
@testable import HolosAudio

/// Chunks roll over without losing samples, and a gap of 50 ms or more (docs/meeting-design.md §2.3) starts a new
/// chunk at its own time with an `audioDiscontinuity`. The Int16 chunks read back these values exactly.
@Test func chunkRolloverPreservesSamplesAndGaps() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-audio-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try SessionArchive.create(root: root, name: "Test", source: .microphoneAndSystem, locale: "en-CA", backend: .speech)
    let writer = AudioChunkWriter(archive: archive, chunkDuration: 0.015)
    for (start, value) in [(0.0, Float(0.25)), (0.01, Float(-0.25)), (0.075, Float(0.5))] {
        let frame = try PCMFrame(samples: [Float](repeating: value, count: 480), sampleRate: 48000, channels: 1, startTime: start)
        try await writer.append(CapturedAudio(track: "mic", frame: frame))
    }
    let stereo = try PCMFrame(samples: [Float](repeating: 0.125, count: 960), sampleRate: 48000, channels: 2, startTime: 0.003)
    try await writer.append(CapturedAudio(track: "system", frame: stereo))
    try await writer.finish()
    try await archive.finish(status: "complete")
    let manifest = try SessionArchive.readManifest(at: archive.directory)
    let mic = manifest.chunks.filter { $0.track == "mic" }.sorted { $0.start < $1.start }
    #expect(mic.count == 2)
    #expect(mic.map(\.frameCount) == [960, 480])
    #expect(abs(mic[0].end - 0.02) < 0.000_001)
    #expect(abs(mic[1].start - 0.075) < 0.000_001)
    let file = try AVAudioFile(forReading: archive.directory.appendingPathComponent(mic[0].relativePath))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 960))
    try file.read(into: buffer)
    let read = try PCMConversion.copy(buffer, startTime: 0)
    #expect(read.samples == [Float](repeating: 0.25, count: 480) + [Float](repeating: -0.25, count: 480))
    let report = try SessionArchive.inspectRecovery(at: archive.directory)
    #expect(!report.needsAttention)
    #expect(report.events.contains {
        $0.kind == "audioDiscontinuity" && $0.details["nextStart"] == "0.075" && $0.details["reason"] == "timestampGap"
    })
    #expect(manifest.chunks.first { $0.track == "system" }?.start == 0.003)
}

@Test func reopeningWriterNeverOverwritesExistingAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-audio-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try SessionArchive.create(root: root, name: "Test", source: .microphone, locale: "en-CA", backend: .speech)
    let frame = try PCMFrame(samples: [Float](repeating: 0.2, count: 480), sampleRate: 48000, channels: 1, startTime: 0)
    let writer = AudioChunkWriter(archive: archive)
    try await writer.append(CapturedAudio(track: "mic", frame: frame))
    try await writer.finish()
    let path = archive.directory.appendingPathComponent("audio/mic/000001.caf")
    let before = try Data(contentsOf: path)
    let second = AudioChunkWriter(archive: archive)
    await #expect(throws: HolosError.self) { try await second.append(CapturedAudio(track: "mic", frame: frame)) }
    #expect(try Data(contentsOf: path) == before)
    try await archive.finish(status: "complete")
}
