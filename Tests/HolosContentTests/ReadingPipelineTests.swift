import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosContent

@MainActor private final class FakeRenderer: ReadingAudioRenderer {
    var calls: [String] = []
    var failOnCall: Int?

    func render(text: String, voiceIdentifier: String?, rate: Float?,
                to output: URL) async throws -> RenderedAudio {
        calls.append(text)
        if calls.count == failOnCall { throw HolosError.unavailable("Simulated render failure.") }
        try Data(text.utf8).write(to: output, options: [.withoutOverwriting])
        return RenderedAudio(url: output, duration: 1, frameCount: 100, sampleRate: 100)
    }
}

/// Concatenates the parts' bytes, so tests can check order and contents without encoding audio.
@MainActor private final class FakeJoiner: ReadingAudioJoiner {
    var joined: [[AudioBookPart]] = []

    func join(parts: [AudioBookPart], metadata: AudioBookMetadata,
              to output: URL) async throws -> AudioBookSummary {
        joined.append(parts)
        var data = Data()
        for part in parts { data += try Data(contentsOf: part.url) }
        try data.write(to: output, options: [.withoutOverwriting])
        return AudioBookSummary(url: output, duration: Double(parts.count), chapters: [])
    }
}

@MainActor private final class GateRenderer: ReadingAudioRenderer {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var permit: CheckedContinuation<Void, Never>?
    var calls = 0

    func render(text: String, voiceIdentifier: String?, rate: Float?,
                to output: URL) async throws -> RenderedAudio {
        calls += 1
        entered = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { permit = $0 }
        try Data(text.utf8).write(to: output, options: [.withoutOverwriting])
        return RenderedAudio(url: output, duration: 1, frameCount: 100, sampleRate: 100)
    }

    func waitUntilRendering() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        permit?.resume()
        permit = nil
    }
}

@MainActor @Suite(.serialized) struct ReadingPipelineTests {
    private let voice = "test.voice"
    private let metadata = AudioBookMetadata(title: "Book", author: "Author")

    private func root() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("holos-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent
    }

    private func location(_ parent: URL) -> ReadingLocation {
        ReadingLocation(workDirectory: parent.appendingPathComponent("work"),
                        output: parent.appendingPathComponent("Book.m4a"))
    }

    private func script(_ paragraphs: Int, sections: Int = 1) -> ReadingScript {
        ReadingScript(document: ReadableDocument(title: "Book", sections: (1...sections).map { index in
            .init(heading: "Chapter \(index)", level: 2,
                  paragraphs: (1...paragraphs).map { "Paragraph \($0) of chapter \(index) has a few words." })
        }))
    }

    @Test func semanticChunksCoverEverySourceUnit() {
        let source = String(repeating: "👩🏽‍💻 Café. Sentence two!\n\n# Markdown *kept*\n", count: 60)
        let chunks = SemanticChunker.chunks(source, maxUTF16Units: 130)
        #expect(chunks.count > 1)
        #expect(chunks.map(\.text).joined() == source)
        #expect(chunks.first?.offset == 0)
        #expect(chunks.last.map { $0.offset + $0.length } == source.utf16.count)
        for (index, chunk) in chunks.enumerated() {
            #expect(chunk.index == index)
            #expect((source as NSString).substring(with: NSRange(location: chunk.offset, length: chunk.length)) == chunk.text)
            #expect(chunk.length <= 130)
        }
    }

    @Test func partsStayInsideSectionsAndStartChapters() {
        let script = script(6, sections: 3)
        let parts = script.parts(maxUTF16Units: 120)
        let text = script.text as NSString
        #expect(script.segments.first?.text == "Book")
        #expect(script.segments.first?.chapter == nil)
        #expect(parts.first?.text == "Book")
        for part in parts {
            #expect(text.substring(with: NSRange(location: part.offset, length: part.length)) == part.text)
            #expect(part.length <= 120)
        }
        #expect(parts.compactMap(\.chapter) == ["Chapter 1", "Chapter 2", "Chapter 3"])
        for part in parts where part.chapter != nil {
            #expect(part.startsSegment)
            #expect(part.text.hasPrefix(part.chapter!))
        }
        // Every section's text is covered by its parts, in order.
        #expect(parts.map(\.text).joined(separator: "") == script.segments.map(\.text).joined())
    }

    @Test func titleIsNotReadTwiceWhenItIsTheFirstHeading() {
        let script = ReadingScript(document: ReadableDocument(title: "Book", sections: [
            .init(heading: "book", level: 1, paragraphs: ["Text."]),
        ]))
        #expect(script.text == "book\n\nText.")
    }

    @Test func finishedReadingIsOneFileAndResumeIsANoOp() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let renderer = FakeRenderer()
        let joiner = FakeJoiner()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: joiner)
        let script = script(8, sections: 2)
        let result = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                               location: place, maxPartUTF16Units: 120)
        #expect(result.output == place.output)
        #expect(result.manifest.status == "complete")
        #expect(result.manifest.parts.count > 3)
        #expect(result.manifest.outputSHA256 != nil)
        #expect(try Data(contentsOf: place.output) == Data(renderer.calls.joined().utf8))
        #expect(!FileManager.default.fileExists(atPath: place.workDirectory.appendingPathComponent("parts").path))
        #expect(try String(contentsOf: place.workDirectory.appendingPathComponent("source.txt"), encoding: .utf8) == script.text)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".holos-") && $0.hasSuffix(".m4a") }
        #expect(leftovers.isEmpty)

        // Pauses: none before the first part, longer before a section than within one.
        let parts = try #require(joiner.joined.first)
        #expect(parts[0].silenceBefore == 0)
        for (part, planned) in zip(parts, result.manifest.parts).dropFirst() {
            #expect(part.silenceBefore == (planned.startsSection ? ReadingAudioFormat.chapterGap : ReadingAudioFormat.partGap))
            #expect(part.chapter == planned.chapter)
        }

        let calls = renderer.calls.count
        _ = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                      location: place, resume: true, maxPartUTF16Units: 120)
        #expect(renderer.calls.count == calls)
        #expect(joiner.joined.count == 1)

        // Deleting the finished file and resuming makes it again.
        try FileManager.default.removeItem(at: place.output)
        let again = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                              location: place, resume: true, maxPartUTF16Units: 120)
        #expect(again.manifest.status == "complete")
        #expect(renderer.calls.count == calls * 2)
        #expect(FileManager.default.fileExists(atPath: place.output.path))
    }

    @Test func failedPartResumesAndRerendersOnlyMissingOrTamperedParts() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let renderer = FakeRenderer()
        renderer.failOnCall = 4
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        let script = script(10)
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                      location: place, maxPartUTF16Units: 120)
        }
        let manifestURL = place.workDirectory.appendingPathComponent("manifest.json")
        let partial = try JSONDecoder().decode(ReadingManifest.self, from: Data(contentsOf: manifestURL))
        #expect(partial.status == "incomplete")
        #expect(partial.parts.prefix(3).allSatisfy { $0.status == "complete" })
        #expect(partial.parts[3].status == "pending")
        #expect(!FileManager.default.fileExists(atPath: place.output.path))

        let tampered = place.workDirectory.appendingPathComponent(partial.parts[0].relativeAudioPath)
        try Data("tampered".utf8).write(to: tampered)
        renderer.failOnCall = nil
        let calls = renderer.calls.count
        let completed = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                                  location: place, resume: true, maxPartUTF16Units: 120)
        #expect(completed.manifest.status == "complete")
        // Part 1 again (tampered), then parts 4 and on; parts 2 and 3 are reused.
        #expect(renderer.calls.count - calls == 1 + completed.manifest.parts.count - 3)
        let expected = script.parts(maxUTF16Units: 120).map(\.text).joined()
        #expect(try Data(contentsOf: place.output) == Data(expected.utf8))
    }

    @Test func resumeRejectsChangedSettingsAndExistingOutputIsKept() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let pipeline = ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner())
        let script = script(2)
        _ = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: place)
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, rate: 0.6, metadata: metadata,
                                      location: place, resume: true)
        }
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: "other.voice", metadata: metadata,
                                      location: place, resume: true)
        }
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: self.script(3), voiceIdentifier: voice, metadata: metadata,
                                      location: place, resume: true)
        }

        // A new reading never replaces a file that is already there.
        let other = ReadingLocation(workDirectory: parent.appendingPathComponent("other"), output: place.output)
        let before = try Data(contentsOf: place.output)
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: other)
        }
        #expect(try Data(contentsOf: place.output) == before)
    }

    @Test func concurrentResumeCannotWriteIntoActiveReading() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let renderer = GateRenderer()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        let script = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["One short paragraph."])]))
        let voice = self.voice
        let metadata = self.metadata
        let active = Task { try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: place) }
        await renderer.waitUntilRendering()
        do {
            _ = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                          location: place, resume: true)
            Issue.record("Concurrent resume should fail while rendering holds the directory lock.")
        } catch let error as HolosError {
            if case .unavailable = error {} else { Issue.record("Unexpected error: \(error)") }
        }
        renderer.release()
        let completed = try await active.value
        #expect(completed.manifest.status == "complete")
        _ = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                      location: place, resume: true)
        #expect(renderer.calls == 1)
    }
}
