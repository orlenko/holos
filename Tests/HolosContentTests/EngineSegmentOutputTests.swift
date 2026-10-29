import AVFoundation
import Foundation
import HolosSynthesis
import HolosTestSupport
import Testing
@testable import HolosContent

/// The real output, rendered offline (`AVAudioEngine` manual rendering: no output device, nothing heard), and the
/// joined file's timeline against the one the parts play by.
@MainActor @Suite(.serialized) struct EngineSegmentOutputTests {
    private static let rate = 22_050.0

    private func samples(_ url: URL) throws -> [Float] {
        let read = try PartQueuePlayback.readPart(url).buffer
        let channel = try #require(read.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(read.frameLength)))
    }

    /// Parts read from their files play back to back with exactly the silence the finished file puts before each,
    /// sample for sample, and the end is reported once the last has played.
    @Test(.timeLimit(.minutes(1))) func partsPlaySampleForSampleWithTheirSilence() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let output = EngineSegmentOutput(manualRendering: true)
        let feed = ReadingPartFeed()
        let playback = PartQueuePlayback(feed: feed, output: output)
        var ends: [PartQueuePlayback.End] = []
        playback.onEnd = { ends.append($0) }
        let first = try files.part(0, of: 2, seconds: 0.2, rate: Self.rate)
        let second = try files.part(1, of: 2, seconds: 0.3, rate: Self.rate, startsSection: true)
        feed.add(first)
        feed.add(second)
        #expect(playback.play())
        #expect(await eventually { playback.next == 2 })

        let silence = Int(ReadingAudioFormat.silenceFrames(ReadingAudioFormat.chapterGap, rate: Self.rate))
        let expected = try samples(first.audio) + [Float](repeating: 0, count: silence) + samples(second.audio)
        let rendered = try output.renderManually(frames: AVAudioFrameCount(expected.count))
        let channel = try #require(rendered.floatChannelData?[0])
        let played = Array(UnsafeBufferPointer(start: channel, count: Int(rendered.frameLength)))
        #expect(played.count == expected.count)
        let worst = zip(played, expected).map { abs($0 - $1) }.max() ?? .infinity
        #expect(worst < 1e-6)
        #expect(await eventually { ends == [.finished] })
    }

    /// The joined `.m4a` (AAC, its encoder delay included) is silent across each gap where the parts' timeline puts
    /// it, and sounds right before and after: playing the file from a gap's start, as the handoff does, lands in that
    /// gap's silence.
    @Test(.timeLimit(.minutes(1))) func theJoinedFileHasItsGapsWhereThePartsTimelinePutsThem() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let parts = [
            try files.part(0, of: 3, seconds: 1, rate: Self.rate),
            try files.part(1, of: 3, seconds: 1, rate: Self.rate),
            try files.part(2, of: 3, seconds: 1, rate: Self.rate, startsSection: true),
        ]
        let joined = files.folder.appendingPathComponent("Joined.m4a")
        _ = try await AudioBookWriter.write(
            parts: parts.map { AudioBookPart(url: $0.audio, silenceBefore: $0.silenceBefore) },
            metadata: AudioBookMetadata(title: "Joined"), to: joined)
        let file = try AVAudioFile(forReading: joined)
        let rate = file.processingFormat.sampleRate
        let decoded = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: decoded)
        let audio = Array(UnsafeBufferPointer(start: try #require(decoded.floatChannelData?[0]),
                                              count: Int(decoded.frameLength)))
        func rms(from start: Double, to end: Double) -> Float {
            let range = max(0, Int(start * rate))..<min(audio.count, Int(end * rate))
            guard !range.isEmpty else { return 0 }
            return (audio[range].reduce(0) { $0 + $1 * $1 } / Float(range.count)).squareRoot()
        }
        var place = 0.0
        for part in parts {
            if part.silenceBefore > 0 {
                let gapStart = place
                let gapEnd = gapStart + Double(ReadingAudioFormat.silenceFrames(part.silenceBefore, rate: Self.rate))
                    / Self.rate
                #expect(rms(from: gapStart - 0.06, to: gapStart - 0.01) > 0.05)
                #expect(rms(from: gapStart + 0.05, to: gapEnd - 0.05) < 0.001)
                #expect(rms(from: gapEnd + 0.01, to: gapEnd + 0.06) > 0.05)
                place = gapEnd
            }
            place += part.duration
        }
    }
}
