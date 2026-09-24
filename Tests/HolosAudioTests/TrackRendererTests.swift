import AVFoundation
import Foundation
import HolosCore
import HolosStorage
import Testing
@testable import HolosAudio

// MARK: - Helpers (prefixed: docs/meeting-design.md §1.8)

/// One chunk to write: interleaved samples starting at session time `start`.
private struct RendererChunk {
    var start: Double
    var sampleRate: Double
    var channels = 1
    var samples: [Float]
}

private func rendererTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("holos-render-\(UUID().uuidString)", isDirectory: true)
}

/// A finished session whose `track` has exactly `chunks` (Float32 CAF, like `AudioChunkWriter`), registered in the
/// manifest in the given order. Chunks may overlap, as legacy archives' could.
private func rendererMakeSession(_ chunks: [RendererChunk], track: String = "mic",
                                 in root: URL) async throws -> (session: URL, manifest: SessionManifest) {
    let archive = try SessionArchive.create(root: root, name: "Render", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    for (index, chunk) in chunks.enumerated() {
        let path = String(format: "audio/%@/%06d.caf", track, index + 1)
        let frame = try PCMFrame(samples: chunk.samples, sampleRate: chunk.sampleRate, channels: chunk.channels,
                                 startTime: chunk.start)
        let buffer = try PCMConversion.makeBuffer(frame)
        var settings = buffer.format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: archive.directory.appendingPathComponent(path), settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
        try await archive.registerChunk(AudioChunkRecord(
            track: track, relativePath: path, start: chunk.start,
            end: chunk.start + Double(frame.frameCount) / chunk.sampleRate, sampleRate: chunk.sampleRate,
            channels: chunk.channels, frameCount: frame.frameCount))
    }
    try await archive.finish(status: ArchiveStatus.complete)
    return (archive.directory, try SessionArchive.readManifest(at: archive.directory))
}

private func rendererTone(seconds: Double, sampleRate: Double, frequency: Double = 1_000,
                          amplitude: Float = 0.5) -> [Float] {
    let count = Int((seconds * sampleRate).rounded())
    return (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
}

/// The render's samples as Float (Int16 ÷ 32,768).
private func rendererSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(max(1, file.length))))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

private func rendererRMS(_ samples: [Float], from start: Double, to end: Double, rate: Double = 16_000) -> Double {
    let lower = max(0, Int(start * rate))
    let upper = min(samples.count, Int(end * rate))
    guard upper > lower else { return 0 }
    let sum = samples[lower..<upper].reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sum / Double(upper - lower)).squareRoot()
}

private func rendererOutput(_ session: URL) -> URL {
    SessionPaths.render(track: "mic", in: session)
}

// MARK: - Rendering

@Test func rendererFillsShortGapsWithSilence() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 48_000, samples: rendererTone(seconds: 1, sampleRate: 48_000)),
        RendererChunk(start: 3.5, sampleRate: 48_000, samples: rendererTone(seconds: 1, sampleRate: 48_000)),
    ], in: root)
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                            to: rendererOutput(session))
    #expect(rendered.frameCount == 72_000)
    #expect(rendered.sampleRate == 16_000)
    #expect(rendered.timeMap == [RenderSpan(renderStart: 0, sessionStart: 0, duration: 4.5)])
    let samples = try rendererSamples(rendered.url)
    #expect(samples.count == 72_000)
    #expect(rendererRMS(samples, from: 1.05, to: 3.45) < 0.001)
    // A 0.5 sine has an RMS of about 0.354.
    #expect(abs(rendererRMS(samples, from: 0.1, to: 0.9) - 0.354) < 0.02)
    #expect(abs(rendererRMS(samples, from: 3.6, to: 4.4) - 0.354) < 0.02)
}

@Test func rendererCompressesLongGaps() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 16_000, samples: rendererTone(seconds: 10, sampleRate: 16_000)),
        RendererChunk(start: 200, sampleRate: 16_000, samples: rendererTone(seconds: 10, sampleRate: 16_000)),
    ], in: root)
    #expect(TrackRenderer.renderedSeconds(manifest: manifest, track: "mic") == 25)
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                            to: rendererOutput(session))
    #expect(rendered.frameCount == 400_000)
    #expect(rendered.timeMap == [RenderSpan(renderStart: 0, sessionStart: 0, duration: 10),
                                 RenderSpan(renderStart: 15, sessionStart: 200, duration: 10)])
    #expect(RenderTimeMap.sessionTime(16.0, map: rendered.timeMap) == 201.0)
    let samples = try rendererSamples(rendered.url)
    #expect(samples.count == 400_000)
    #expect(rendererRMS(samples, from: 10.05, to: 14.95) < 0.001)
    #expect(rendererRMS(samples, from: 15.1, to: 24.9) > 0.3)
}

@Test func rendererCompressesALongLeadIn() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 90, sampleRate: 16_000, samples: rendererTone(seconds: 2, sampleRate: 16_000)),
    ], in: root)
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                            to: rendererOutput(session))
    #expect(rendered.timeMap == [RenderSpan(renderStart: 5, sessionStart: 90, duration: 2)])
    #expect(rendered.frameCount == 112_000)
    #expect(RenderTimeMap.sessionTime(2.0, map: rendered.timeMap) == 90)
}

@Test func timeMapSplitsSegmentsAcrossCompressedGap() {
    let map = [RenderSpan(renderStart: 0, sessionStart: 0, duration: 10),
               RenderSpan(renderStart: 15, sessionStart: 200, duration: 10)]
    let vector = FloatVector([1, 0])
    let output = DiarizerOutput(
        segments: [RawDiarizationSegment(speaker: "S1", start: 8, end: 17, quality: 0.9),
                   RawDiarizationSegment(speaker: "S2", start: 11, end: 14),
                   RawDiarizationSegment(speaker: "S2", start: 20, end: 22)],
        centroids: ["S1": vector],
        windows: [EmbeddingWindow(speaker: "S1", start: 5, end: 16, vector: vector)],
        processingSeconds: 3)
    let mapped = RenderTimeMap.map(output, map: map)
    #expect(mapped.segments == [RawDiarizationSegment(speaker: "S1", start: 8, end: 10, quality: 0.9),
                                RawDiarizationSegment(speaker: "S1", start: 200, end: 202, quality: 0.9),
                                RawDiarizationSegment(speaker: "S2", start: 205, end: 207)])
    #expect(mapped.windows == [EmbeddingWindow(speaker: "S1", start: 5, end: 10, vector: vector),
                               EmbeddingWindow(speaker: "S1", start: 200, end: 201, vector: vector)])
    #expect(mapped.centroids == output.centroids)
    #expect(mapped.processingSeconds == 3)
    // Inside inserted silence a time snaps to the nearest span edge.
    #expect(RenderTimeMap.sessionTime(12, map: map) == 10)
    #expect(RenderTimeMap.sessionTime(14, map: map) == 200)
    #expect(RenderTimeMap.sessionTime(30, map: map) == 210)
    #expect(RenderTimeMap.sessionTime(3, map: map) == 3)
    #expect(RenderTimeMap.sessionTime(3, map: []) == 3)
}

@Test func rendererKeepsSessionTiming() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var second = [Float](repeating: 0, count: 72_000)
    second[24_000] = 1   // 2.0 s on the session timeline
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 48_000, samples: [Float](repeating: 0, count: 72_000)),
        RendererChunk(start: 1.5, sampleRate: 48_000, samples: second),
    ], in: root)
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                            to: rendererOutput(session))
    let samples = try rendererSamples(rendered.url)
    #expect(samples.count == 48_000)
    let peak = try #require(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) })
    #expect(abs(peak - 32_000) <= 32, "The click lands at frame \(peak).")
}

@Test func rendererDownmixesStereo() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // L = R = 0.5 and L = 0.25, R = 0.75 both average to 0.5.
    var interleaved: [Float] = []
    for _ in 0..<8_000 { interleaved += [0.5, 0.5] }
    for _ in 0..<8_000 { interleaved += [0.25, 0.75] }
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 16_000, channels: 2, samples: interleaved),
    ], in: root)
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                            to: rendererOutput(session))
    let samples = try rendererSamples(rendered.url)
    #expect(samples.count == 16_000)
    #expect(samples.allSatisfy { abs($0 - 0.5) <= 1.0 / 32_768 })

    // Resampled stereo keeps the level within a few Int16 steps.
    let root48 = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root48) }
    let (session48, manifest48) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 48_000, channels: 2, samples: [Float](repeating: 0.5, count: 96_000)),
    ], in: root48)
    let resampled = try rendererSamples(TrackRenderer.render(session: session48, manifest: manifest48, track: "mic",
                                                             to: rendererOutput(session48)).url)
    #expect(resampled[1_600..<14_400].allSatisfy { abs($0 - 0.5) < 0.002 })
}

@Test func rendererRejectsMissingChunk() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 16_000, samples: [Float](repeating: 0.1, count: 16_000)),
        RendererChunk(start: 1, sampleRate: 16_000, samples: [Float](repeating: 0.1, count: 16_000)),
    ], in: root)
    try FileManager.default.removeItem(at: session.appendingPathComponent(manifest.chunks[1].relativePath))
    #expect(throws: HolosError.self) {
        try TrackRenderer.render(session: session, manifest: manifest, track: "mic", to: rendererOutput(session))
    }
    #expect(!FileManager.default.fileExists(atPath: rendererOutput(session).path))
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: SessionPaths.derived(session).path)) ?? []
    #expect(leftovers.isEmpty, "A failed render leaves no temporary file.")
    #expect(throws: HolosError.self) {
        try TrackRenderer.render(session: session, manifest: manifest, track: "system", to: rendererOutput(session))
    }
}

@Test func rendererTrimsOverlappingChunks() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Chunk 2 starts 0.2 s before chunk 1 ends; its first 0.2 s must not be written.
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 16_000, samples: [Float](repeating: 0.25, count: 16_000)),
        RendererChunk(start: 0.8, sampleRate: 16_000,
                      samples: [Float](repeating: -0.5, count: 3_200) + [Float](repeating: 0.5, count: 12_800)),
    ], in: root)
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                            to: rendererOutput(session))
    #expect(rendered.frameCount == 28_800, "The render spans the timeline, 0–1.8 s.")
    #expect(rendered.timeMap == [RenderSpan(renderStart: 0, sessionStart: 0, duration: 1.8)])
    let samples = try rendererSamples(rendered.url)
    #expect(samples.count == 28_800)
    #expect(samples[0..<16_000].allSatisfy { $0 == 0.25 })
    #expect(samples[16_000...].allSatisfy { $0 == 0.5 })

    // A chunk entirely inside audio already placed is skipped.
    let inner = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: inner) }
    let (innerSession, innerManifest) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 16_000, samples: [Float](repeating: 0.25, count: 32_000)),
        RendererChunk(start: 0.5, sampleRate: 16_000, samples: [Float](repeating: -0.5, count: 8_000)),
    ], in: inner)
    let innerSamples = try rendererSamples(TrackRenderer.render(session: innerSession, manifest: innerManifest,
                                                                track: "mic", to: rendererOutput(innerSession)).url)
    #expect(innerSamples.count == 32_000)
    #expect(innerSamples.allSatisfy { $0 == 0.25 })
}

@Test func renderIsSixteenKilohertzMonoInt16CAF() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 0.25, sampleRate: 44_100, samples: rendererTone(seconds: 0.5, sampleRate: 44_100)),
    ], in: root)
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                            to: rendererOutput(session))
    let file = try AVAudioFile(forReading: rendered.url)
    let format = file.fileFormat.streamDescription.pointee
    #expect(format.mFormatID == kAudioFormatLinearPCM)
    #expect(format.mSampleRate == 16_000)
    #expect(format.mChannelsPerFrame == 1)
    #expect(format.mBitsPerChannel == 16)
    #expect(format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
    #expect(format.mFormatFlags & kAudioFormatFlagIsFloat == 0)
    #expect(format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0)
    #expect(format.mBytesPerFrame == 2 && format.mBytesPerPacket == 2 && format.mFramesPerPacket == 1)
    // What the diarizer's sample source checks (HolosDiarization Int16CAFSampleSource): a CAF whose audio bytes
    // lie within the file.
    var audioFile: AudioFileID?
    #expect(AudioFileOpenURL(rendered.url as CFURL, .readPermission, 0, &audioFile) == noErr)
    let opened = try #require(audioFile)
    defer { AudioFileClose(opened) }
    var fileType: AudioFileTypeID = 0
    var typeSize = UInt32(MemoryLayout<AudioFileTypeID>.size)
    var byteCount: UInt64 = 0
    var countSize = UInt32(MemoryLayout<UInt64>.size)
    var dataOffset: Int64 = 0
    var offsetSize = UInt32(MemoryLayout<Int64>.size)
    #expect(AudioFileGetProperty(opened, kAudioFilePropertyFileFormat, &typeSize, &fileType) == noErr)
    #expect(AudioFileGetProperty(opened, kAudioFilePropertyAudioDataByteCount, &countSize, &byteCount) == noErr)
    #expect(AudioFileGetProperty(opened, kAudioFilePropertyDataOffset, &offsetSize, &dataOffset) == noErr)
    #expect(fileType == kAudioFileCAFType)
    #expect(byteCount == 24_000)
    let size = try FileManager.default.attributesOfItem(atPath: rendered.url.path)[.size] as? Int64
    #expect(dataOffset + Int64(byteCount) <= (size ?? 0))
    #expect(file.length == 12_000)
    #expect(rendered.frameCount == 12_000)
    var info = stat()
    #expect(stat(rendered.url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
}

@Test func cancelledRenderPublishesNothing() async throws {
    let root = rendererTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, manifest) = try await rendererMakeSession([
        RendererChunk(start: 0, sampleRate: 16_000, samples: [Float](repeating: 0.1, count: 16_000)),
    ], in: root)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try TrackRenderer.render(session: session, manifest: manifest, track: "mic",
                                        to: rendererOutput(session))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: rendererOutput(session).path))
}
