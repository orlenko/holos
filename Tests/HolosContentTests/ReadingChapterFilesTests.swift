import AVFoundation
import Foundation
import HolosSynthesis
import HolosTestSupport
import Testing
@testable import HolosContent

/// A finished reading as a folder of chapters. Real files, written and read back; nothing is played.
@Suite struct ReadingChapterFilesTests {
    private let chapters = [AudioBookChapter(title: "Beginning", start: 0), AudioBookChapter(title: "Chapter 1: The Start", start: 5),
                            AudioBookChapter(title: "Chapter 2", start: 12)]

    @Test func tracksCoverTheWholeReadingInOrder() throws {
        let tracks = try #require(ReadingChapterFiles.tracks(chapters: chapters, duration: 20))
        #expect(tracks.map(\.start) == [0, 5, 12])
        #expect(tracks.map(\.end) == [5, 12, 20])
        #expect(tracks.map(\.fileName) == ["01 Beginning.m4a", "02 Chapter 1- The Start.m4a", "03 Chapter 2.m4a"])
    }

    @Test func oneChapterHasNoTracks() {
        #expect(ReadingChapterFiles.tracks(chapters: [], duration: 20) == nil)
        #expect(ReadingChapterFiles.tracks(chapters: [chapters[0]], duration: 20) == nil)
        #expect(ReadingChapterFiles.tracks(chapters: chapters, duration: 4) == nil)
    }

    @Test func aLongBookKeepsItsNamesInOrder() throws {
        let many = (0..<120).map { AudioBookChapter(title: "Part \($0)", start: Double($0)) }
        let tracks = try #require(ReadingChapterFiles.tracks(chapters: many, duration: 200))
        #expect(tracks[0].fileName == "001 Part 0.m4a")
        #expect(tracks.map(\.fileName) == tracks.map(\.fileName).sorted())
    }

    @Test func thePlaylistListsTheTracksByName() throws {
        let tracks = try #require(ReadingChapterFiles.tracks(chapters: chapters, duration: 20))
        let lines = ReadingChapterFiles.playlist(title: "A Book", tracks: tracks).components(separatedBy: "\n")
        #expect(lines.prefix(4) == ["#EXTM3U", "#PLAYLIST:A Book", "#EXTINF:5,Beginning", "01 Beginning.m4a"])
    }

    @Test func aLineBreakInATitleStaysOnItsLine() throws {
        let tracks = try #require(ReadingChapterFiles.tracks(
            chapters: [AudioBookChapter(title: "One\nPart", start: 0), AudioBookChapter(title: "Two", start: 5)], duration: 9))
        let lines = ReadingChapterFiles.playlist(title: "A Book\nVolume One", tracks: tracks).components(separatedBy: "\n")
        #expect(lines.prefix(4) == ["#EXTM3U", "#PLAYLIST:A Book Volume One", "#EXTINF:5,One Part", tracks[0].fileName])
    }

    /// Two chapters at one moment make one track, not an empty one.
    @Test func chaptersAtTheSameMomentMakeOneTrack() throws {
        let same = [AudioBookChapter(title: "One", start: 0), AudioBookChapter(title: "Two", start: 5),
                    AudioBookChapter(title: "Three", start: 5), AudioBookChapter(title: "Four", start: 8)]
        let tracks = try #require(ReadingChapterFiles.tracks(chapters: same, duration: 10))
        #expect(tracks.map(\.title) == ["One", "Two", "Four"])
        #expect(tracks.map(\.end) == [5, 8, 10])
    }

    private func finishedFile(in folder: URL, seconds: Double) async throws -> URL {
        let rate = ReadingAudioFormat.sampleRate
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true))
        let part = folder.appendingPathComponent("part.caf")
        let file = try AVAudioFile(forWriting: part, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)))
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        let output = folder.appendingPathComponent("book.m4a")
        return try await AudioBookWriter.write(parts: [AudioBookPart(url: part, chapter: "Whole")],
                                               metadata: AudioBookMetadata(title: "A Book"), to: output).url
    }

    /// Each file lasts as long as its chapter, carries its tags, and the folder holds nothing else but the playlist.
    @Test func aFinishedFileBecomesAFolderOfChapters() async throws {
        let temporary = try TemporaryDirectory("chapters")
        defer { temporary.remove() }
        let source = try await finishedFile(in: temporary.url, seconds: 20)
        let parent = temporary.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = try await ReadingChapterFiles.make(from: source, title: "A Book", author: "Jane Writer", chapters: chapters,
                                                        duration: 20, in: parent)
        #expect(folder.lastPathComponent == "A Book")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["01 Beginning.m4a", "02 Chapter 1- The Start.m4a", "03 Chapter 2.m4a", "Playlist.m3u8"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["A Book"])
        for (name, length) in [("01 Beginning.m4a", 5.0), ("02 Chapter 1- The Start.m4a", 7), ("03 Chapter 2.m4a", 8)] {
            let asset = AVURLAsset(url: folder.appendingPathComponent(name))
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - length) < 0.2, "\(name) lasts \(duration)")
        }
        let tags = try await AVURLAsset(url: folder.appendingPathComponent("03 Chapter 2.m4a")).load(.metadata)
        let values = try await tags.asyncMap { try await $0.load(.stringValue) }
        #expect(values.contains("Chapter 2") && values.contains("A Book") && values.contains("Jane Writer"))

        // A second run keeps the first folder.
        let second = try await ReadingChapterFiles.make(from: source, title: "A Book", author: nil, chapters: chapters,
                                                        duration: 20, in: parent)
        #expect(second.lastPathComponent == "A Book 2")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Playlist.m3u8").path))
    }

    /// A title that only just fits a file name still makes a folder.
    @Test func aLongTitleInManyBytesFits() async throws {
        let temporary = try TemporaryDirectory("chapters")
        defer { temporary.remove() }
        let source = try await finishedFile(in: temporary.url, seconds: 20)
        let parent = temporary.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let title = String(repeating: "読", count: 80)
        for _ in 0..<2 {
            let folder = try await ReadingChapterFiles.make(from: source, title: title, author: nil, chapters: chapters, duration: 20, in: parent)
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Playlist.m3u8").path))
        }
    }

    /// A copy that does not finish fails, and leaves nothing.
    @Test func aStalledCopyIsReported() async throws {
        await #expect(throws: (any Error).self) {
            try await ReadingChapterFiles.bounded(by: .milliseconds(10)) {
                try await Task.sleep(for: .seconds(60))
            }
        }
        try await ReadingChapterFiles.bounded(by: .seconds(60)) {}
    }

    /// A failure leaves nothing behind in the folder chosen.
    @Test func aFailureLeavesNothing() async throws {
        let temporary = try TemporaryDirectory("chapters")
        defer { temporary.remove() }
        let parent = temporary.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            _ = try await ReadingChapterFiles.make(from: temporary.url.appendingPathComponent("missing.m4a"), title: "A Book", author: nil,
                                                   chapters: chapters, duration: 20, in: parent)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
