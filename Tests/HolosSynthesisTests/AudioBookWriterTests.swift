import AVFoundation
import Foundation
import HolosCore
import Testing
@testable import HolosSynthesis

@Suite(.serialized) struct AudioBookWriterTests {
    /// A 16-bit mono CAF tone, the format `NativeSpeechRenderer` writes for reading parts.
    private func tone(seconds: Double, rate: Double = 22_050, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.int16ChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = Int16(6_000 * sin(Double(index) * 2 * .pi * 330 / rate)) }
        try file.write(from: buffer)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holos-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test(.timeLimit(.minutes(1))) func partsBecomeOneAACFileWithChaptersAndMetadata() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var parts: [AudioBookPart] = []
        for (index, chapter) in ["Opening", nil, "Middle", "End"].enumerated() {
            let url = folder.appendingPathComponent("part\(index).caf")
            try tone(seconds: 3, to: url)
            parts.append(AudioBookPart(url: url, silenceBefore: index == 0 ? 0 : 0.5, chapter: chapter))
        }
        let output = folder.appendingPathComponent("Book.m4a")
        let summary = try await AudioBookWriter.write(
            parts: parts, metadata: AudioBookMetadata(title: "A Book", author: "Someone", language: "en"), to: output)
        #expect(abs(summary.duration - 13.5) < 0.001)
        #expect(summary.chapters.map(\.title) == ["Opening", "Middle", "End"])
        #expect(summary.chapters.map(\.start) == [0, 6.5, 10])

        let asset = AVURLAsset(url: output)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let description = try #require(try await audio.load(.formatDescriptions).first)
        let stream = try #require(description.audioStreamBasicDescription)
        #expect(stream.mFormatID == kAudioFormatMPEG4AAC)
        #expect(stream.mSampleRate == ReadingAudioFormat.sampleRate)
        #expect(stream.mChannelsPerFrame == 1)
        #expect(abs(try await asset.load(.duration).seconds - 13.5) < 0.05)

        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: try #require(locales.first),
                                                               containingItemsWithCommonKeys: [])
        var titles: [String] = []
        for group in groups { titles.append(try await group.items.first?.load(.stringValue) ?? "") }
        #expect(titles == ["Opening", "Middle", "End"])
        #expect(groups.map { ($0.timeRange.start.seconds * 10).rounded() / 10 } == [0, 6.5, 10])

        var tags: [String: String] = [:]
        for item in try await asset.load(.metadata) {
            if let identifier = item.identifier, let value = try await item.load(.stringValue) { tags[identifier.rawValue] = value }
        }
        #expect(tags[AVMetadataIdentifier.iTunesMetadataSongName.rawValue] == "A Book")
        #expect(tags[AVMetadataIdentifier.iTunesMetadataArtist.rawValue] == "Someone")
        #expect(tags[AVMetadataIdentifier.iTunesMetadataEncodingTool.rawValue] == "Voice is Local")
    }

    @Test(.timeLimit(.minutes(1))) func chapterBeforeTheFirstHeadingAndNoTrackForOneChapter() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.caf")
        let second = folder.appendingPathComponent("b.caf")
        try tone(seconds: 1, to: first)
        try tone(seconds: 1, to: second)

        let untitledStart = try await AudioBookWriter.write(
            parts: [AudioBookPart(url: first), AudioBookPart(url: second, silenceBefore: 1, chapter: "Heading")],
            metadata: AudioBookMetadata(title: "Doc"), to: folder.appendingPathComponent("one.m4a"))
        #expect(untitledStart.chapters == [AudioBookChapter(title: "Doc", start: 0),
                                           AudioBookChapter(title: "Heading", start: 1)])

        let single = folder.appendingPathComponent("two.m4a")
        let oneChapter = try await AudioBookWriter.write(
            parts: [AudioBookPart(url: first, chapter: "Only"), AudioBookPart(url: second, silenceBefore: 0.5)],
            metadata: AudioBookMetadata(title: nil), to: single)
        #expect(oneChapter.chapters.isEmpty)
        #expect(try await AVURLAsset(url: single).loadTracks(withMediaType: .text).isEmpty)

        await #expect(throws: HolosError.self) {
            try await AudioBookWriter.write(parts: [AudioBookPart(url: first)], metadata: AudioBookMetadata(title: nil), to: single)
        }
    }
}
