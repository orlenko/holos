import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosContent

/// Writes each part's text as its audio, with a duration of one second per call; fails the call `failOnCall`.
@MainActor private final class TextRenderer: ReadingAudioRenderer {
    var calls = 0
    var failOnCall: Int?

    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL) async throws -> RenderedAudio {
        calls += 1
        if calls == failOnCall { throw HolosError.unavailable("Simulated render failure.") }
        try Data(text.utf8).write(to: output, options: [.withoutOverwriting])
        return RenderedAudio(url: output, duration: Double(calls), frameCount: 100, sampleRate: 100)
    }
}

/// Concatenates the parts' bytes without encoding audio.
@MainActor private final class ConcatenatingJoiner: ReadingAudioJoiner {
    func join(parts: [AudioBookPart], metadata: AudioBookMetadata, to output: URL) async throws -> AudioBookSummary {
        var data = Data()
        for part in parts { data += try Data(contentsOf: part.url) }
        try data.write(to: output, options: [.withoutOverwriting])
        return AudioBookSummary(url: output, duration: Double(parts.count), chapters: [])
    }
}

/// `partMade`: each part as soon as it is made and saved, so a reading can play before it is finished.
@MainActor @Suite(.serialized) struct ReadingPipelinePartMadeTests {
    private let voice = "test.voice"
    private let metadata = AudioBookMetadata(title: "Book")

    private func root() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("holos-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent
    }

    private func location(_ parent: URL) -> ReadingLocation {
        ReadingLocation(workDirectory: parent.appendingPathComponent("work"),
                        output: parent.appendingPathComponent("Book.m4a"))
    }

    private func script(_ paragraphs: Int, sections: Int) -> ReadingScript {
        ReadingScript(document: ReadableDocument(title: "Book", sections: (1...sections).map { index in
            .init(heading: "Chapter \(index)", level: 2,
                  paragraphs: (1...paragraphs).map { "Paragraph \($0) of chapter \(index) has a few words." })
        }))
    }

    /// Every part once, in order, while its file is in the cache with the text rendered for it, its duration as
    /// rendered, and the silence the joined file puts before it.
    @Test func eachPartIsReportedOnceItIsMade() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let script = script(4, sections: 2)
        let planned = script.parts(maxUTF16Units: 120)
        #expect(planned.count > 3)
        #expect(planned.dropFirst().contains { $0.startsSegment })
        var made: [ReadingMadePart] = []
        var texts: [String] = []
        let result = try await ReadingPipeline(renderer: TextRenderer(), joiner: ConcatenatingJoiner()).render(
            script: script, voiceIdentifier: voice, metadata: metadata, location: location(parent),
            maxPartUTF16Units: 120, partMade: { part in
                made.append(part)
                texts.append((try? String(contentsOf: part.audio, encoding: .utf8)) ?? "")
            })
        #expect(made.map(\.index) == Array(planned.indices))
        #expect(made.allSatisfy { $0.total == planned.count })
        #expect(texts == planned.map(\.text))
        #expect(made.map(\.duration) == planned.indices.map { Double($0 + 1) })
        #expect(made.map(\.silenceBefore) == planned.map {
            ReadingAudioFormat.silenceBefore(part: $0.index, startsSection: $0.startsSegment)
        })
        // Gone once the finished file is published.
        #expect(made.allSatisfy { !FileManager.default.fileExists(atPath: $0.audio.path) })
        #expect(result.manifest.status == "complete")
    }

    /// A part that fails is never reported; a resume reports the parts it keeps (after checking them), then each
    /// part it makes.
    @Test func aResumeReportsTheKeptPartsThenTheNewOnes() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let renderer = TextRenderer()
        renderer.failOnCall = 4
        let pipeline = ReadingPipeline(renderer: renderer, joiner: ConcatenatingJoiner())
        let script = script(6, sections: 1)
        let total = script.parts(maxUTF16Units: 120).count
        var made: [Int] = []
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: place,
                                      maxPartUTF16Units: 120, partMade: { made.append($0.index) })
        }
        #expect(made == [0, 1, 2])

        // The first part changed on disk since: it is made again, after the two kept ones are reported.
        let first = place.workDirectory.appendingPathComponent(ReadingPipeline.partPath(0))
        try Data("changed".utf8).write(to: first)
        renderer.failOnCall = nil
        made = []
        _ = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: place,
                                      resume: true, maxPartUTF16Units: 120, partMade: { made.append($0.index) })
        #expect(made == [1, 2, 0] + Array(3..<total))
    }
}
