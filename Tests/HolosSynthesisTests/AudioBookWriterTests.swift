import AVFoundation
import Foundation
import HolosCore
import Synchronization
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

    @Test func textIsShortenedOnCharacterBoundaries() {
        #expect(AudioBookWriter.fileText(String(repeating: "é", count: 5), maximumBytes: 5) == "éé")
        let person = "👩🏽‍💻"  // 15 UTF-8 bytes, one character
        #expect(AudioBookWriter.fileText(person + person + person, maximumBytes: 29) == person)
        #expect(AudioBookWriter.fileText("a" + person, maximumBytes: 15) == "a")
        #expect(AudioBookWriter.fileText(person, maximumBytes: 14) == nil)
        #expect(AudioBookWriter.fileText("  Short  ") == "Short")
        #expect(AudioBookWriter.fileText(" \n ") == nil)
        #expect(AudioBookWriter.fileText(nil) == nil)
    }

    @Test func languageTagsAreOnlyOnesTheWriterAccepts() {
        #expect(AudioBookMetadata.languageTag("en") == "en")
        #expect(AudioBookMetadata.languageTag("EN_us") == "en-US")
        #expect(AudioBookMetadata.languageTag("zh-hant-tw") == "zh-Hant-TW")
        #expect(AudioBookMetadata.languageTag("es-419") == "es-419")
        #expect(AudioBookMetadata.languageTag("en-GB-oxendict") == "en-GB")
        for rejected in ["english", "und", "qq", "x-klingon", "", "en GB", "12"] {
            #expect(AudioBookMetadata.languageTag(rejected) == nil, "\(rejected)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func longTitlesAndABadLanguageStillMakeAValidFile() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.caf")
        let second = folder.appendingPathComponent("b.caf")
        try tone(seconds: 1, to: first)
        try tone(seconds: 1, to: second)
        // 70,000 bytes of two-byte characters: a raw 65,535-byte prefix would split the last one.
        let long = String(repeating: "é", count: 35_000)
        let output = folder.appendingPathComponent("long.m4a")
        let summary = try await AudioBookWriter.write(
            parts: [AudioBookPart(url: first, chapter: long), AudioBookPart(url: second, silenceBefore: 0.5, chapter: "Two")],
            metadata: AudioBookMetadata(title: long, author: long, language: "english"), to: output)
        let shortened = String(repeating: "é", count: 32_767)
        #expect(summary.chapters.map(\.title) == [shortened, "Two"])

        let asset = AVURLAsset(url: output)
        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: try #require(locales.first),
                                                               containingItemsWithCommonKeys: [])
        var titles: [String] = []
        for group in groups { titles.append(try await group.items.first?.load(.stringValue) ?? "") }
        #expect(titles == [shortened, "Two"])
        var tags: [String: String] = [:]
        for item in try await asset.load(.metadata) {
            if let identifier = item.identifier, let value = try await item.load(.stringValue) { tags[identifier.rawValue] = value }
        }
        #expect(tags[AVMetadataIdentifier.iTunesMetadataSongName.rawValue] == shortened)
        #expect(tags[AVMetadataIdentifier.iTunesMetadataArtist.rawValue] == shortened)
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

    /// The chapter rules the writer and `--print-text` share.
    @Test func chapterPlanRules() {
        typealias Plan = AudioBookChapterPlan
        func titles(_ parts: [(String?, Int)], _ book: String? = "Book") -> [String] {
            Plan.marks(parts.map { (chapter: $0.0, position: $0.1) }, bookTitle: book).map(\.title)
        }
        #expect(titles([("One", 0), ("Two", 5)]) == ["One", "Two"])
        #expect(titles([(nil, 0), ("One", 5)]) == ["Book", "One"])
        #expect(titles([(nil, 0), ("One", 5)], "  ") == ["Beginning", "One"])
        #expect(titles([("Only", 0), (nil, 5)]).isEmpty)
        #expect(titles([(nil, 0), (nil, 5)]).isEmpty)
        // Blank titles, and a chapter at or before the previous one's start, are dropped.
        #expect(titles([("One", 0), (" \n", 3), ("Same", 0), ("Two", 5)]) == ["One", "Two"])
        #expect(Plan.titles([nil, "A", "B"], bookTitle: "Book") == ["Book", "A", "B"])
        // A later chapter with the book's name keeps it; the opening is "Beginning", so no two
        // chapters are named after the book.
        #expect(titles([(nil, 0), ("Book", 5)]) == ["Beginning", "Book"])
        #expect(titles([(nil, 0), ("One", 3), ("BOOK", 5)]) == ["Beginning", "One", "BOOK"])
        #expect(titles([(nil, 0), ("One", 3), ("Bóók", 5)], "Book") == ["Beginning", "One", "Bóók"])
    }

    private struct InjectedFailure: Error, Equatable {
        let side: String
    }

    /// The furthest audio frame the writer has come to append.
    private final class Furthest: Sendable {
        private let frame = Mutex<Int64>(0)
        var value: Int64 { frame.withLock { $0 } }
        func reach(_ value: Int64) { frame.withLock { $0 = max($0, value) } }
    }

    /// Four ten-second chapters: long enough that each side runs ahead of the other and waits.
    private func fourChapters(in folder: URL) throws -> [AudioBookPart] {
        try ["One", "Two", "Three", "Four"].enumerated().map { index, chapter in
            let url = folder.appendingPathComponent("part\(index).caf")
            try tone(seconds: 10, to: url)
            return AudioBookPart(url: url, silenceBefore: index == 0 ? 0 : 0.5, chapter: chapter)
        }
    }

    /// A chapter that fails before the chapter input is finished ends the render with that error:
    /// the audio side, which the writer holds back behind the chapters, is released and stopped,
    /// and the partial file is removed. The failure waits for the audio to pass the last appended
    /// chapter's start, then a moment more, so the audio is being held back when it comes.
    @Test(.timeLimit(.minutes(1))) func aChapterFailureEndsTheRenderAndLeavesNoFile() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parts = try fourChapters(in: folder)
        // Where each chapter starts, in frames: at the half second of silence before its part.
        let chapterStarts: [Int64] = [0, 220_500, 452_025]
        for failing in [0, 1, 3] {
            let output = folder.appendingPathComponent("chapter\(failing).m4a")
            let audioFrame = Furthest()
            // The writer lets the audio run a few seconds past the start of the last chapter
            // appended (or the beginning), then holds it back: four buffers in, it gets there.
            let reachable = (failing == 0 ? 0 : chapterStarts[failing - 1]) + 4 * 8_192
            let faults = AudioBookWriter.Faults(
                chapter: { index in
                    guard index == failing else { return }
                    // A poll budget, not a deadline: the failure comes either way.
                    for _ in 0..<500 where audioFrame.value < reachable {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    throw InjectedFailure(side: "chapter")
                },
                audio: { frame in audioFrame.reach(frame) })
            await #expect(throws: InjectedFailure(side: "chapter"), "\(failing)") {
                try await AudioBookWriter.write(parts: parts, metadata: AudioBookMetadata(title: "Book"), to: output,
                                                faults: faults)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path), "\(failing)")
        }
    }

    /// The same for audio that fails partway, with the chapter side waiting on it.
    @Test(.timeLimit(.minutes(1))) func anAudioFailureEndsTheRenderAndLeavesNoFile() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parts = try fourChapters(in: folder)
        for failing: Int64 in [0, 15 * 22_050, 35 * 22_050] {
            let output = folder.appendingPathComponent("audio\(failing).m4a")
            let faults = AudioBookWriter.Faults(audio: { frame in
                if frame >= failing { throw InjectedFailure(side: "audio") }
            })
            await #expect(throws: InjectedFailure(side: "audio"), "\(failing)") {
                try await AudioBookWriter.write(parts: parts, metadata: AudioBookMetadata(title: "Book"), to: output,
                                                faults: faults)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path), "\(failing)")
        }
        // Without a fault the same parts make a book with all four chapters.
        let output = folder.appendingPathComponent("whole.m4a")
        let summary = try await AudioBookWriter.write(parts: parts, metadata: AudioBookMetadata(title: "Book"), to: output)
        #expect(summary.chapters.map(\.title) == ["One", "Two", "Three", "Four"])
    }

    /// Files in `folder` other than the parts.
    private func others(in folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix("part") })
    }

    /// Two writers to one file: both pass the "already exists" check before either has written
    /// anything; one finishes and publishes, then the other fails. The finished file stays, and
    /// the failed writer removes only its own temporary.
    @Test(.timeLimit(.minutes(1))) func aFailedWriterLeavesAnotherWritersFile() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parts = try fourChapters(in: folder)
        let output = folder.appendingPathComponent("Book.m4a")
        let path = output.path
        let encoding = Furthest()
        let failing = Task {
            try await AudioBookWriter.write(
                parts: parts, metadata: AudioBookMetadata(title: "Book"), to: output,
                faults: AudioBookWriter.Faults(audio: { frame in
                    guard frame > 0 else { return }
                    encoding.reach(frame)
                    // A poll budget, not a deadline: the failure comes either way.
                    for _ in 0..<3_000 where !FileManager.default.fileExists(atPath: path) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    throw InjectedFailure(side: "audio")
                }))
        }
        // The first writer is past its check and encoding before the second starts.
        for _ in 0..<3_000 where encoding.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(encoding.value > 0)
        let summary = try await AudioBookWriter.write(parts: parts, metadata: AudioBookMetadata(title: "Other"), to: output)
        await #expect(throws: InjectedFailure(side: "audio")) { try await failing.value }
        #expect(summary.chapters.map(\.title) == ["One", "Two", "Three", "Four"])
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - summary.duration) < 0.05)
        #expect(try others(in: folder) == ["Book.m4a"])
    }

    /// A file put at the output while the book is encoded is kept, whether the writer then fails
    /// or finishes (it cannot publish over the file); neither leaves its temporary behind.
    @Test(.timeLimit(.minutes(1))) func aFileReplacedDuringEncodingIsNotDeleted() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parts = try fourChapters(in: folder)
        let theirs = Data("someone else's file".utf8)
        for fails in [true, false] {
            let output = folder.appendingPathComponent("Book-\(fails).m4a")
            let faults = AudioBookWriter.Faults(audio: { frame in
                guard frame > 0, !FileManager.default.fileExists(atPath: output.path) else { return }
                try theirs.write(to: output, options: [.withoutOverwriting])
                if fails { throw InjectedFailure(side: "audio") }
            })
            await #expect(throws: (any Error).self, "\(fails)") {
                try await AudioBookWriter.write(parts: parts, metadata: AudioBookMetadata(title: "Book"), to: output,
                                                faults: faults)
            }
            #expect(try Data(contentsOf: output) == theirs, "\(fails)")
        }
        #expect(try others(in: folder) == ["Book-true.m4a", "Book-false.m4a"])
    }

    /// The temporary is hidden, beside the output, and named after it; a name too long for that
    /// gets a fixed stem.
    @Test func temporaryNamesFollowTheOutput() {
        let name = AudioBookWriter.temporaryName(for: "Book.m4a")
        #expect(name.hasPrefix(".Book-") && name.hasSuffix(".m4a") && name.utf8.count == ".Book-.m4a".utf8.count + 36)
        #expect(AudioBookWriter.temporaryName(for: ".hidden.m4a").hasPrefix(".hidden-"))
        let long = AudioBookWriter.temporaryName(for: String(repeating: "a", count: 240) + ".m4a")
        #expect(long.hasPrefix(".holos-book-") && long.hasSuffix(".m4a"))
    }

    /// Silence that would overflow the frame count (or is not a number) is an error, never a trap.
    @Test(.timeLimit(.minutes(1))) func absurdSilenceIsRejected() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let part = folder.appendingPathComponent("a.caf")
        try tone(seconds: 0.1, to: part)
        for silence in [1e300, Double.greatestFiniteMagnitude, .infinity, .nan, -1, AudioBookWriter.maximumSilence + 1] {
            let output = folder.appendingPathComponent("out.m4a")
            await #expect(throws: HolosError.self, "\(silence)") {
                try await AudioBookWriter.write(parts: [AudioBookPart(url: part), AudioBookPart(url: part, silenceBefore: silence)],
                                                metadata: AudioBookMetadata(title: nil), to: output)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }
}
