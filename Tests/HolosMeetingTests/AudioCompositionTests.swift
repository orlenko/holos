import AVFoundation
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// SessionAudioComposition (docs/meeting-design.md §5.10, PR9): the review window's playback of a session's chunks on
// the session timeline. Chunks are generated 8 kHz Int16 CAF files. Helpers are prefixed `composition`.

private let compositionRate = 8_000.0

/// A chunk file at `audio/<track>/<name>.caf` in `session` holding `seconds` of a quiet tone, and its manifest record.
private func compositionChunk(_ session: URL, track: String, name: String, start: Double,
                              seconds: Double) throws -> AudioChunkRecord {
    let relativePath = "audio/\(track)/\(name).caf"
    let url = session.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let frames = Int((seconds * compositionRate).rounded())
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: compositionRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<frames { samples[index] = Float(sin(Double(index) * 0.05) * 0.01) }
    try file.write(from: buffer)
    return AudioChunkRecord(track: track, relativePath: relativePath, start: start, end: start + seconds,
                            sampleRate: compositionRate, channels: 1, frameCount: frames)
}

private func compositionManifest(_ chunks: [AudioChunkRecord]) -> SessionManifest {
    SessionManifest(id: UUID().uuidString, name: "Composition", createdAt: Date(), source: .microphone,
                    locale: "en-CA", backend: .speech, status: "complete", chunks: chunks)
}

/// The non-empty segments of a composition track: (session start, source start, duration) in seconds.
private func compositionSegments(_ track: AVCompositionTrack) -> [(at: Double, from: Double, seconds: Double)] {
    track.segments.filter { !$0.isEmpty }.map { segment in
        (segment.timeMapping.target.start.seconds, segment.timeMapping.source.start.seconds,
         segment.timeMapping.target.duration.seconds)
    }
}

private func compositionClose(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }

@Test(.timeLimit(.minutes(1)))
func compositionPlacesChunksAtSessionTimes() async throws {
    let temp = try TemporaryDirectory("composition")
    defer { temp.remove() }
    let session = temp.url.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    let chunks = [
        try compositionChunk(session, track: "mic", name: "000001", start: 0, seconds: 30),
        try compositionChunk(session, track: "mic", name: "000002", start: 30, seconds: 30),
        try compositionChunk(session, track: "mic", name: "000003", start: 65, seconds: 30),
    ]
    let composition = try await SessionAudioComposition.make(session: session, manifest: compositionManifest(chunks))

    #expect(composition.tracks.count == 1)
    let track = try #require(composition.tracks.first)
    let segments = compositionSegments(track)
    #expect(segments.count == 3)
    for (segment, expected) in zip(segments, [(0.0, 30.0), (30.0, 30.0), (65.0, 30.0)]) {
        #expect(compositionClose(segment.at, expected.0))
        #expect(compositionClose(segment.seconds, expected.1))
        #expect(compositionClose(segment.from, 0))
    }
    // The pause between 60 and 65 s is silence, not a shift of the later audio.
    #expect(track.segments.contains { $0.isEmpty && compositionClose($0.timeMapping.target.start.seconds, 60) })
    #expect(compositionClose(composition.duration.seconds, 95))
}

@Test(.timeLimit(.minutes(1)))
func compositionTrimsOverlappingChunks() async throws {
    let temp = try TemporaryDirectory("composition")
    defer { temp.remove() }
    let session = temp.url.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    // Legacy archives (before frame continuity) could write a chunk that starts before the previous one ended.
    let chunks = [
        try compositionChunk(session, track: "mic", name: "000001", start: 0, seconds: 30),
        try compositionChunk(session, track: "mic", name: "000002", start: 29.8, seconds: 30.2),
    ]
    let composition = try await SessionAudioComposition.make(session: session, manifest: compositionManifest(chunks))

    let track = try #require(composition.tracks.first)
    let segments = compositionSegments(track)
    #expect(segments.count == 2)
    #expect(compositionClose(segments[0].at, 0) && compositionClose(segments[0].seconds, 30))
    #expect(compositionClose(segments[1].at, 30), "The second chunk is inserted from 30.0.")
    #expect(compositionClose(segments[1].from, 0.2), "Its first 0.2 s, already heard, are left out.")
    #expect(compositionClose(segments[1].seconds, 30))
    #expect(segments[0].at + segments[0].seconds <= segments[1].at + 0.000_001, "No overlap.")
    #expect(compositionClose(composition.duration.seconds, 60))
}

@Test(.timeLimit(.minutes(1)))
func compositionKeepsTracksApartAndSkipsMissingChunks() async throws {
    let temp = try TemporaryDirectory("composition")
    defer { temp.remove() }
    let session = temp.url.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    var missing = try compositionChunk(session, track: "system", name: "000002", start: 10, seconds: 10)
    try FileManager.default.removeItem(at: session.appendingPathComponent(missing.relativePath))
    missing.id = "missing"
    let chunks = [
        try compositionChunk(session, track: "system", name: "000001", start: 0, seconds: 10),
        missing,
        try compositionChunk(session, track: "system", name: "000003", start: 20, seconds: 5),
        try compositionChunk(session, track: "mic", name: "000001", start: 2, seconds: 20),
        AudioChunkRecord(track: "mic", relativePath: "../outside.caf", start: 30, end: 40,
                         sampleRate: compositionRate, channels: 1, frameCount: 80_000),
    ]
    let composition = try await SessionAudioComposition.make(session: session, manifest: compositionManifest(chunks))

    #expect(composition.tracks.count == 2)
    let mic = compositionSegments(composition.tracks[0])
    let system = compositionSegments(composition.tracks[1])
    #expect(mic.count == 1 && compositionClose(mic[0].at, 2) && compositionClose(mic[0].seconds, 20))
    #expect(system.map(\.at).count == 2)
    #expect(compositionClose(system[0].at, 0) && compositionClose(system[1].at, 20))
    #expect(compositionClose(composition.duration.seconds, 25))
}

@Test(.timeLimit(.minutes(1)))
func compositionWithoutAudioIsRefused() async throws {
    let temp = try TemporaryDirectory("composition")
    defer { temp.remove() }
    let session = temp.url.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    let record = AudioChunkRecord(track: "mic", relativePath: "audio/mic/000001.caf", start: 0, end: 30,
                                  sampleRate: compositionRate, channels: 1, frameCount: 240_000)
    await #expect(throws: HolosError.self) {
        _ = try await SessionAudioComposition.make(session: session, manifest: compositionManifest([record]))
    }
}
