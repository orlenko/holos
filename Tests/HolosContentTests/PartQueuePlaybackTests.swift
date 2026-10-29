import AVFoundation
import Foundation
import HolosSynthesis
import HolosTestSupport
import Testing
@testable import HolosContent

/// Plays nothing: records what is queued, and plays it to its end only when a test says so (`playNext`).
@MainActor final class QueueOutput: ReadingSegmentOutput {
    struct Queued {
        let frames: Int
        let played: @MainActor () -> Void
    }

    var queued: [Queued] = []
    var playing = false
    var playedFrames: Int64 = 0
    var onInterrupted: (() -> Void)?

    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor () -> Void) throws {
        queued.append(Queued(frames: Int(buffer.frameLength), played: played))
    }

    func play() throws { playing = true }
    func pause() { playing = false }

    func stop() {
        playing = false
        queued = []
        playedFrames = 0
    }

    /// Plays the first buffer queued to its end.
    func playNext() {
        let first = queued.removeFirst()
        playedFrames += Int64(first.frames)
        first.played()
    }
}

/// Part files for tests: tones at 8,000 frames a second (the lowest rate a CAF keeps), so half a second of silence
/// is 4,000 frames.
struct PartFiles {
    static let rate = 8_000.0
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    /// Part `index` of `total`, `seconds` long, written as a 16-bit CAF like a renderer's.
    func part(_ index: Int, of total: Int, seconds: Double, rate: Double = PartFiles.rate,
              startsSection: Bool = false) throws -> ReadingMadePart {
        let url = folder.appendingPathComponent("part\(index).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16,
                                   interleaved: true)
        let frames = AVAudioFrameCount((seconds * rate).rounded())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.int16ChannelData?[0])
        for sample in 0..<Int(frames) { samples[sample] = Int16(6_000 * sin(Double(sample) * 2 * .pi * 330 / rate)) }
        try file.write(from: buffer)
        let silence = ReadingAudioFormat.silenceBefore(part: index, startsSection: startsSection)
        return ReadingMadePart(index: index, total: total, audio: url, duration: Double(frames) / rate,
                               silenceBefore: silence)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

@MainActor @Suite struct PartQueuePlaybackTests {
    /// Parts play in order after their silence; run dry, it waits engaged (not an end, not an error) at the end of
    /// what is made, and goes on once the next part is made; a part made while paused does not start it.
    @Test func partsPlayInOrderAndTheQueueWaitsForTheNext() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let feed = ReadingPartFeed()
        let output = QueueOutput()
        let playback = PartQueuePlayback(feed: feed, output: output)
        var ends: [PartQueuePlayback.End] = []
        playback.onEnd = { ends.append($0) }
        feed.add(try files.part(0, of: 3, seconds: 1))
        #expect(playback.play())
        #expect(await eventually { output.queued.count == 1 })
        // The first part has no silence before it.
        #expect(output.queued.map(\.frames) == [8_000])
        #expect(output.playing)
        #expect(!playback.isWaiting)
        #expect(!playback.isDurationFinal)

        output.playNext()
        #expect(playback.isWaiting)
        #expect(playback.isPlaying)
        #expect(playback.currentTime == 1)

        feed.add(try files.part(1, of: 3, seconds: 2))
        #expect(await eventually { output.queued.count == 2 })
        #expect(output.queued.map(\.frames) == [4_000, 16_000])
        #expect(output.playing)
        #expect(!playback.isWaiting)
        output.playNext()
        #expect(playback.currentTime == 1.5)
        #expect(playback.duration == 1 + 0.5 + 2)

        playback.pause()
        feed.add(try files.part(2, of: 3, seconds: 1))
        #expect(await eventually { output.queued.count == 3 })
        #expect(!output.playing)
        #expect(!playback.isPlaying)
        #expect(playback.isDurationFinal)
        #expect(ends.isEmpty)
    }

    /// The made parts play after making failed, then the failure is told (never the end); a part that is not made is
    /// never waited for.
    @Test func aFailureIsToldOnceTheMadePartsHavePlayed() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let feed = ReadingPartFeed()
        let output = QueueOutput()
        let playback = PartQueuePlayback(feed: feed, output: output)
        var ends: [PartQueuePlayback.End] = []
        playback.onEnd = { ends.append($0) }
        feed.add(try files.part(0, of: 4, seconds: 1))
        feed.add(try files.part(1, of: 4, seconds: 1))
        #expect(playback.play())
        #expect(await eventually { output.queued.count == 3 })
        feed.finish(.failed("The voice is gone."))
        output.playNext()
        output.playNext()
        #expect(ends.isEmpty)
        output.playNext()
        #expect(ends == [.failed("Playback stopped at part 3 of 4: The voice is gone.")])
        #expect(!playback.isPlaying)
    }

    /// Once making has finished, nothing more is queued: at the end of the parts queued, the place where the next
    /// part's silence starts is handed over; until stopped, play and pause only say whether the file is to play.
    @Test func theRestIsHandedOverOnceMakingHasFinished() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let feed = ReadingPartFeed()
        let output = QueueOutput()
        let playback = PartQueuePlayback(feed: feed, output: output)
        var handoffs: [TimeInterval] = []
        playback.onHandoff = { handoffs.append($0) }
        for index in 0..<3 { feed.add(try files.part(index, of: 3, seconds: 1)) }
        #expect(playback.play())
        // Two parts ahead: part 0, then part 1 with its silence.
        #expect(await eventually { output.queued.count == 3 })
        feed.finish(.finished)
        output.playNext()
        output.playNext()
        #expect(handoffs.isEmpty)
        output.playNext()
        #expect(handoffs == [2.5])
        #expect(playback.isPlaying)
        #expect(output.queued.isEmpty)
        playback.pause()
        #expect(!playback.isPlaying)
        #expect(playback.play())
        #expect(playback.isPlaying)
        playback.stop()
        #expect(!playback.play())
    }

    /// A part gone from the cache (the reading was published meanwhile) is waited on, never an error, and the rest
    /// is handed over once making is known to have finished.
    @Test func aPartGoneFromTheCacheWaitsForTheEnd() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let feed = ReadingPartFeed()
        let output = QueueOutput()
        let playback = PartQueuePlayback(feed: feed, output: output)
        var ends: [PartQueuePlayback.End] = []
        var handoffs: [TimeInterval] = []
        playback.onEnd = { ends.append($0) }
        playback.onHandoff = { handoffs.append($0) }
        feed.add(try files.part(0, of: 2, seconds: 1))
        let second = try files.part(1, of: 2, seconds: 1)
        try FileManager.default.removeItem(at: second.audio)
        feed.add(second)
        #expect(playback.play())
        #expect(await eventually { output.queued.count == 1 })
        output.playNext()
        #expect(await eventually { playback.isWaiting })
        #expect(ends.isEmpty)
        feed.finish(.finished)
        // Once the read of the gone part has come back.
        #expect(await eventually { handoffs == [1] })
        #expect(ends.isEmpty)
    }

    /// The last part played is the end of the reading; making stopped is a stop, told as one.
    @Test func theLastPartEndsItAndAStopIsAStop() async throws {
        let files = try PartFiles()
        defer { files.remove() }
        let feed = ReadingPartFeed()
        let output = QueueOutput()
        let playback = PartQueuePlayback(feed: feed, output: output)
        var ends: [PartQueuePlayback.End] = []
        playback.onEnd = { ends.append($0) }
        feed.add(try files.part(0, of: 2, seconds: 1))
        feed.add(try files.part(1, of: 2, seconds: 1))
        #expect(playback.play())
        #expect(await eventually { output.queued.count == 3 })
        output.playNext()
        output.playNext()
        output.playNext()
        #expect(ends == [.finished])

        let stopped = ReadingPartFeed()
        let otherOutput = QueueOutput()
        let other = PartQueuePlayback(feed: stopped, output: otherOutput)
        other.onEnd = { ends.append($0) }
        stopped.add(try files.part(0, of: 2, seconds: 1))
        #expect(other.play())
        #expect(await eventually { otherOutput.queued.count == 1 })
        stopped.finish(.stopped)
        // What is made still plays; then it ends as stopped.
        #expect(ends == [.finished])
        otherOutput.playNext()
        #expect(ends == [.finished, .stopped])
    }
}
