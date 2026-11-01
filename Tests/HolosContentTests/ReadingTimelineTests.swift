import Foundation
import HolosSynthesis
import Testing
@testable import HolosContent

@Suite struct ReadingTimelineTests {
    private static let format = ReadingFormatSettings.current

    private func manifest(_ parts: [ReadingPart]) -> ReadingManifest {
        ReadingManifest(kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
                        sourceSHA256: "", voiceIdentifier: "voice", rate: nil, title: nil, author: nil, language: nil,
                        comment: "", format: Self.format, output: "/tmp/out.m4a", outputSHA256: nil, duration: nil,
                        chapters: [], status: "complete", parts: parts)
    }

    private func parts(_ pieces: [(text: String, offset: Int, duration: Double?, section: Bool)]) -> [ReadingPart] {
        pieces.enumerated().map { index, piece in
            ReadingPart(index: index, sourceUTF16Offset: piece.offset, sourceUTF16Length: piece.text.utf16.count,
                        textSHA256: sha256(Data(piece.text.utf8)), relativeAudioPath: "", chapter: nil,
                        startsSection: piece.section, status: "complete", audioSHA256: nil, duration: piece.duration)
        }
    }

    @Test func partsStartAfterTheSilencesBeforeThemAndSentencesInProportion() throws {
        let first = "One two. Three four."
        let second = "Five six."
        let third = "Seven."
        let text = first + " " + second + "\n\n" + third
        let planned = parts([(first, 0, 10, true), (second, 21, 4, false), (third, 32, 2, true)])
        let timeline = try #require(ReadingTimeline(manifest: manifest(planned), text: text))
        #expect(timeline.spans.map { (text as NSString).substring(with: $0.range) }
            == ["One two.", "Three four.", "Five six.", "Seven."])
        let gap = Self.format.partGap, chapter = Self.format.chapterGap
        #expect(timeline.spans[0].start == 0)
        #expect(abs(timeline.spans[1].start - 10 * 9 / 20) < 0.001)
        #expect(timeline.spans[2].start == 10 + gap)
        #expect(timeline.spans[3].start == 10 + gap + 4 + chapter)
    }

    @Test func aTimeFindsTheSentenceBeingSpoken() throws {
        let text = "One two. Three four."
        let timeline = try #require(ReadingTimeline(manifest: manifest(parts([(text, 0, 10, true)])), text: text))
        let spoken = { (time: Double) in timeline.span(at: time).map { (text as NSString).substring(with: $0.range) } }
        #expect(spoken(-1) == "One two.")
        #expect(spoken(0) == "One two.")
        #expect(spoken(4.4) == "One two.")
        #expect(spoken(4.6) == "Three four.")
        #expect(spoken(99) == "Three four.")
        #expect(spoken(.nan) == nil)
    }

    @Test func noTimelineForAnotherTextOrUnknownDurations() {
        let text = "One two. Three four."
        let good = parts([(text, 0, 10, true)])
        #expect(ReadingTimeline(manifest: manifest(good), text: "One two. Three more.") == nil)
        #expect(ReadingTimeline(manifest: manifest(good), text: "Short") == nil)
        #expect(ReadingTimeline(manifest: manifest(parts([(text, 0, nil, true)])), text: text) == nil)
        #expect(ReadingTimeline(manifest: manifest(parts([(text, 0, .infinity, true)])), text: text) == nil)
        #expect(ReadingTimeline(manifest: manifest([]), text: text) == nil)
    }

    @Test func textOutsideTheBasicPlaneKeepsItsOffsets() throws {
        let text = "😀 Hello there. Second one."
        let timeline = try #require(ReadingTimeline(manifest: manifest(parts([(text, 0, 10, true)])), text: text))
        #expect((text as NSString).substring(with: timeline.spans.last!.range) == "Second one.")
    }

    /// Show Text's text and the spoken script's are one string, so a part's offsets apply to what the window shows.
    @Test(arguments: [
        ReadableDocument(title: "A Title", sections: [.init(heading: "Start", level: 1, paragraphs: ["One.", "Two."]),
                                                      .init(heading: "Next", level: 2, paragraphs: ["Three."])]),
        ReadableDocument(title: "Same", sections: [.init(heading: "Same", level: 1, paragraphs: ["One."])]),
        ReadableDocument(sections: [.init(paragraphs: ["Only.", "Text."])]),
    ])
    func theShownTextIsTheScriptsText(document: ReadableDocument) throws {
        let script = ReadingScript(document: document)
        #expect(document.plainText == script.text)
        var planned = ReadingPipeline.plan(script.parts())
        for index in planned.indices { planned[index].duration = 1 }
        #expect(ReadingTimeline(manifest: manifest(planned), text: document.plainText) != nil)
    }

    /// The finished file's silences come from the one rule the timeline counts them by.
    @Test func thePlannedPartsKeepTheJoinersSilences() {
        let script = ReadingScript(document: ReadableDocument(sections: [
            .init(heading: "A", level: 1, paragraphs: [String(repeating: "Word word word. ", count: 400)]),
            .init(heading: "B", level: 1, paragraphs: ["End."]),
        ]))
        let planned = ReadingPipeline.plan(script.parts())
        #expect(planned.count >= 3)
        #expect(planned[0].silenceBefore(Self.format) == 0)
        #expect(planned[1].silenceBefore(Self.format) == Self.format.partGap)
        #expect(planned.last?.silenceBefore(Self.format) == Self.format.chapterGap)
    }

    @Test func loadReadsTheManifestInTheCacheAndNothingElse() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let text = "One two. Three four."
        var entry = ReadingEntry(source: .web(try #require(URL(string: "https://example.com"))),
                                 requestedVoice: nil, speed: 1)
        #expect(await ReadingTimeline.load(for: entry, text: text) == nil)
        entry.cache = folder.path
        #expect(await ReadingTimeline.load(for: entry, text: text) == nil)
        try JSONEncoder().encode(manifest(parts([(text, 0, 10, true)])))
            .write(to: folder.appendingPathComponent(ReadingManifest.fileName))
        #expect(await ReadingTimeline.load(for: entry, text: text)?.spans.count == 2)
    }
}
