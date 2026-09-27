import CryptoKit
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

/// Writes part of the joined file, then waits until its task is cancelled.
@MainActor private final class HangingJoiner: ReadingAudioJoiner {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    var temporary: URL?

    func join(parts: [AudioBookPart], metadata: AudioBookMetadata,
              to output: URL) async throws -> AudioBookSummary {
        try Data("partial".utf8).write(to: output, options: [.withoutOverwriting])
        temporary = output
        entered = true
        arrival?.resume()
        arrival = nil
        while true { try await Task.sleep(for: .seconds(3_600)) }
    }

    func waitUntilJoining() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
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

        // Every value written into the file is checked, language included: an explicit voice
        // keeps the voice the same when only the document's language changes.
        var french = metadata
        french.language = "fr"
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: french,
                                      location: place, resume: true)
        }
        var retitled = metadata
        retitled.author = "Someone Else"
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: retitled,
                                      location: place, resume: true)
        }
        var commented = metadata
        commented.comment = "Other"
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: commented,
                                      location: place, resume: true)
        }
        // Unchanged settings still resume.
        _ = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                      location: place, resume: true)

        // A new reading never replaces a file that is already there.
        let other = ReadingLocation(workDirectory: parent.appendingPathComponent("other"), output: place.output)
        let before = try Data(contentsOf: place.output)
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: other)
        }
        #expect(try Data(contentsOf: place.output) == before)
    }

    @Test func manifestRecordsEverySettingAndIdentityCoversThem() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        var withLanguage = metadata
        withLanguage.language = "en"
        let result = try await ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner())
            .render(script: script(2), voiceIdentifier: voice, rate: 0.5, metadata: withLanguage, location: place)
        #expect(result.manifest.kind == ReadingManifest.readingKind)
        #expect(result.manifest.language == "en")
        #expect(result.manifest.comment == withLanguage.comment)
        #expect(result.manifest.format == .current)
        #expect(ReadingManifest.isReading(place.workDirectory.appendingPathComponent(ReadingManifest.fileName)))

        let base = ReadingPipeline.identity(script: script(2), voiceIdentifier: voice, rate: 0.5, metadata: withLanguage)
        var french = withLanguage
        french.language = "fr"
        #expect(ReadingPipeline.identity(script: script(2), voiceIdentifier: voice, rate: 0.5, metadata: french) != base)
        // Same text, different chapter structure.
        let flat = ReadingScript(document: ReadableDocument(title: "Book", sections: [.init(paragraphs: [
            "Chapter 1", "Paragraph 1 of chapter 1 has a few words.", "Paragraph 2 of chapter 1 has a few words.",
        ])]))
        #expect(flat.text == script(2).text)
        #expect(ReadingPipeline.identity(script: flat, voiceIdentifier: voice, rate: 0.5, metadata: withLanguage) != base)
    }

    @Test func badDestinationFailsBeforeAnythingIsRendered() async throws {
        let parent = try root()
        let locked = parent.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: parent)
        }
        try Data("x".utf8).write(to: parent.appendingPathComponent("file.txt"))
        let renderer = FakeRenderer()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        let outputs = ["Missing/Book.m4a", "file.txt/Book.m4a", "Locked/Book.m4a"].map { parent.appendingPathComponent($0) }
        for (index, output) in outputs.enumerated() {
            let place = ReadingLocation(workDirectory: parent.appendingPathComponent("work\(index)"), output: output)
            await #expect(throws: HolosError.self, "\(output.path)") {
                try await pipeline.render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: place)
            }
            #expect(!FileManager.default.fileExists(atPath: place.workDirectory.path))
        }
        // A cache folder that cannot take the cache fails the same way.
        let cacheless = ReadingLocation(workDirectory: locked.appendingPathComponent("work"),
                                        output: parent.appendingPathComponent("Book.m4a"))
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: cacheless)
        }
        #expect(renderer.calls.isEmpty)

        // The layout without --output: the finished file inside a cache that does not exist yet.
        let inside = ReadingLocation(workDirectory: parent.appendingPathComponent("Reading"),
                                     output: parent.appendingPathComponent("Reading/Book.m4a"))
        let result = try await pipeline.render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: inside)
        #expect(result.manifest.status == "complete")
        #expect(FileManager.default.fileExists(atPath: inside.output.path))
    }

    @Test func publishesWhereExclusiveRenameIsUnsupported() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let renderer = FakeRenderer()
        // Like exFAT or an SMB share: no exclusive rename (and no hard links).
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner(), exclusiveRename: { _, _ in
            errno = ENOTSUP
            return -1
        })
        let result = try await pipeline.render(script: script(3), voiceIdentifier: voice, metadata: metadata, location: place)
        #expect(result.manifest.status == "complete")
        #expect(try Data(contentsOf: place.output) == Data(renderer.calls.joined().utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".holos-") && $0.hasSuffix(".m4a") }
        #expect(leftovers.isEmpty)
    }

    @Test func publicationNeverReplacesAnExistingFile() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent(".holos-source.m4a")
        let destination = parent.appendingPathComponent("Book.m4a")
        let unsupported: ReadingPublisher.ExclusiveRename = { _, _ in
            errno = ENOTSUP
            return -1
        }
        for exclusiveRename in [ReadingPublisher.systemExclusiveRename, unsupported] {
            try Data("new".utf8).write(to: source)
            try Data("old".utf8).write(to: destination)
            #expect(throws: HolosError.self) {
                try ReadingPublisher.publish(source, to: destination, exclusiveRename: exclusiveRename)
            }
            #expect(try Data(contentsOf: destination) == Data("old".utf8))
            #expect(try Data(contentsOf: source) == Data("new".utf8))

            try FileManager.default.removeItem(at: destination)
            try ReadingPublisher.publish(source, to: destination, exclusiveRename: exclusiveRename)
            #expect(try Data(contentsOf: destination) == Data("new".utf8))
            #expect(!FileManager.default.fileExists(atPath: source.path))
            try FileManager.default.removeItem(at: destination)
        }

        // Another failure is reported and leaves nothing behind.
        try Data("new".utf8).write(to: source)
        #expect(throws: HolosError.self) {
            try ReadingPublisher.publish(source, to: destination, exclusiveRename: { _, _ in
                errno = EIO
                return -1
            })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func resumeRejectsAnUnrelatedManifest() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        try FileManager.default.createDirectory(at: place.workDirectory, withIntermediateDirectories: false)
        try Data(#"{"name": "web-app"}"#.utf8).write(to: place.workDirectory.appendingPathComponent("manifest.json"))
        await #expect(throws: HolosError.self) {
            try await ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner())
                .render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: place, resume: true)
        }
        #expect(try Data(contentsOf: place.workDirectory.appendingPathComponent("manifest.json")) == Data(#"{"name": "web-app"}"#.utf8))
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

    @Test func aSecondReadingForTheSameOutputFailsBeforeRendering() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let output = parent.appendingPathComponent("Book.m4a")
        // Different text or settings: different caches (as `ReadingOutput.locate` keys them), one output.
        let first = ReadingLocation(workDirectory: parent.appendingPathComponent("Output-a"), output: output)
        let second = ReadingLocation(workDirectory: parent.appendingPathComponent("Output-b"), output: output)
        let renderer = GateRenderer()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        let script = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["One short paragraph."])]))
        let other = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["Another paragraph."])]))
        let voice = self.voice
        let metadata = self.metadata
        let active = Task { try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: first) }
        await renderer.waitUntilRendering()
        do {
            _ = try await pipeline.render(script: other, voiceIdentifier: voice, metadata: metadata, location: second)
            Issue.record("A second reading for the same output should fail while the first renders.")
        } catch let error as HolosError {
            if case .unavailable(let message) = error {
                #expect(message.contains("Another reading is already being made"))
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(renderer.calls == 1)
        renderer.release()
        #expect(try await active.value.manifest.status == "complete")
        #expect(try Data(contentsOf: output) == Data("One short paragraph.".utf8))
    }

    private func manifest(_ place: ReadingLocation) throws -> ReadingManifest {
        try JSONDecoder().decode(ReadingManifest.self,
                                 from: Data(contentsOf: place.workDirectory.appendingPathComponent(ReadingManifest.fileName)))
    }

    private func write(_ manifest: ReadingManifest, _ place: ReadingLocation) throws {
        try JSONEncoder().encode(manifest)
            .write(to: place.workDirectory.appendingPathComponent(ReadingManifest.fileName))
    }

    private func joinTemporaries(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(ReadingTemporaries.joinPrefix) }
    }

    @Test func streamedChecksumMatchesWholeFileChecksum() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("large.bin")
        // Several read chunks and a partial last one.
        var data = Data(count: (3 << 20) + 12_345)
        for index in data.indices { data[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 11) }
        try data.write(to: file)
        let whole = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try fileSHA256(file) == whole)
        try Data().write(to: parent.appendingPathComponent("empty.bin"))
        #expect(try fileSHA256(parent.appendingPathComponent("empty.bin"))
            == SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())
    }

    @Test func fallbackPublicationCopiesIntoItsOwnFileAndNeverReplacesAnother() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent(".holos-source.m4a")
        let destination = parent.appendingPathComponent("Book.m4a")
        let unsupported: ReadingPublisher.ExclusiveRename = { _, _ in
            errno = ENOTSUP
            return -1
        }
        var large = Data(count: (2 << 20) + 777)
        for index in large.indices { large[index] = UInt8(truncatingIfNeeded: index) }

        // The destination's identity is reported before any byte is written, and it is the
        // file that ends up there.
        try large.write(to: source)
        var claimed: ReadingFileIdentity?
        try ReadingPublisher.publish(source, to: destination, exclusiveRename: unsupported) { identity throws in
            #expect(try Data(contentsOf: destination).isEmpty)
            claimed = identity
        }
        #expect(try Data(contentsOf: destination) == large)
        #expect(claimed != nil && ReadingFileIdentity.of(destination) == claimed)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: destination)

        // Replaced after it was claimed: the replacement is kept and publishing fails.
        try large.write(to: source)
        #expect(throws: HolosError.self) {
            try ReadingPublisher.publish(source, to: destination, exclusiveRename: unsupported) { _ in
                try FileManager.default.removeItem(at: destination)
                try Data("theirs".utf8).write(to: destination, options: [.withoutOverwriting])
            }
        }
        #expect(try Data(contentsOf: destination) == Data("theirs".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: destination)

        // A failure after the claim removes only the file this publication created.
        struct Refused: Error {}
        #expect(throws: Refused.self) {
            try ReadingPublisher.publish(source, to: destination, exclusiveRename: unsupported) { _ in throw Refused() }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func fallbackPublicationFailsWhenTheDestinationAppearsFirst() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let destination = place.output
        // Another process creates the file between the failed exclusive rename and the exclusive create.
        let pipeline = ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner(), exclusiveRename: { _, target in
            _ = try? Data("theirs".utf8).write(to: URL(fileURLWithPath: target), options: [.withoutOverwriting])
            errno = ENOTSUP
            return -1
        })
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script(3), voiceIdentifier: voice, metadata: metadata, location: place)
        }
        #expect(try Data(contentsOf: destination) == Data("theirs".utf8))
        #expect(try joinTemporaries(parent).isEmpty)
        let saved = try manifest(place)
        #expect(saved.status == "incomplete")
        #expect(saved.outputSHA256 == nil)
        #expect(saved.publishing == nil)
        // Their file stays in the way until it is moved; then the reading resumes and publishes.
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script(3), voiceIdentifier: voice, metadata: metadata,
                                      location: place, resume: true)
        }
        #expect(try Data(contentsOf: destination) == Data("theirs".utf8))
        try FileManager.default.removeItem(at: destination)
        let resumed = try await ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner())
            .render(script: script(3), voiceIdentifier: voice, metadata: metadata, location: place, resume: true)
        #expect(resumed.manifest.status == "complete")
    }

    @Test func resumeRecognizesItsOwnCopyCutOffByACrash() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let unsupported: ReadingPublisher.ExclusiveRename = { _, _ in
            errno = ENOTSUP
            return -1
        }
        let renderer = FakeRenderer()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner(), exclusiveRename: unsupported)
        let script = script(3)
        let finished = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: place)
        #expect(finished.manifest.publishing == nil)
        let full = try Data(contentsOf: place.output)

        // The state a crash in the middle of the copy leaves: the destination's identity is saved,
        // and the file holds only part of the reading.
        var crashed = try manifest(place)
        crashed.status = "incomplete"
        crashed.publishing = try #require(ReadingFileIdentity.of(place.output))
        try write(crashed, place)
        let handle = try FileHandle(forWritingTo: place.output)
        try handle.truncate(atOffset: UInt64(full.count / 2))
        try handle.close()
        let resumed = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                                location: place, resume: true)
        #expect(resumed.manifest.status == "complete")
        #expect(resumed.manifest.publishing == nil)
        #expect(try Data(contentsOf: place.output) == full)

        // A file someone else put there after the crash is not this reading's, whatever the manifest says.
        var stale = try manifest(place)
        stale.status = "incomplete"
        stale.publishing = try #require(ReadingFileIdentity.of(place.output))
        try write(stale, place)
        try FileManager.default.removeItem(at: place.output)
        try Data("theirs".utf8).write(to: place.output)
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                      location: place, resume: true)
        }
        #expect(try Data(contentsOf: place.output) == Data("theirs".utf8))
    }

    @Test func resumeSweepsOnlyThisReadingsStaleTemporaries() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let renderer = FakeRenderer()
        renderer.failOnCall = 2
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        let script = script(6)
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                      location: place, maxPartUTF16Units: 120)
        }
        let key = ReadingTemporaries.key(for: place.workDirectory)
        let parts = place.workDirectory.appendingPathComponent("parts")
        // Left by earlier runs of this reading that were killed before their cleanup ran.
        let stale = [
            parent.appendingPathComponent(ReadingTemporaries.joinName(key: key, run: UUID())),
            parent.appendingPathComponent(ReadingTemporaries.joinName(key: key, run: UUID())),
            place.workDirectory.appendingPathComponent(ReadingTemporaries.manifestName()),
            parts.appendingPathComponent(".holos-\(UUID().uuidString).caf"),
            parts.appendingPathComponent(".invalid-\(UUID().uuidString)-part0001.caf"),
        ]
        // Another reading's temporary, names that only look similar, and the lock.
        let kept = [
            parent.appendingPathComponent(ReadingTemporaries.joinName(key: "0123456789abcdef", run: UUID())),
            parent.appendingPathComponent(".holos-\(UUID().uuidString).m4a"),
            parent.appendingPathComponent(".holos-join-\(key)-notes.m4a"),
            parent.appendingPathComponent("Other.m4a"),
            place.workDirectory.appendingPathComponent(".holos-manifest-mine.tmp"),
            parts.appendingPathComponent(".holos-notes.caf"),
        ]
        for file in stale + kept { try Data("x".utf8).write(to: file) }
        let locks = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".holos-reading-") }
        #expect(locks.count == 1)

        renderer.failOnCall = nil
        let result = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                               location: place, resume: true, maxPartUTF16Units: 120)
        #expect(result.manifest.status == "complete")
        for file in stale { #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)") }
        // The parts folder goes with its contents once the reading is published.
        for file in kept where file.deletingLastPathComponent() != parts {
            #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".holos-reading-") } == locks)
    }

    @Test func sweepKeepsForeignNamesInsideTheCache() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let work = parent.appendingPathComponent("work")
        let parts = work.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let current = UUID()
        let key = ReadingTemporaries.key(for: work)
        let active = parent.appendingPathComponent(ReadingTemporaries.joinName(key: key, run: current))
        let stale = parts.appendingPathComponent(".holos-\(UUID().uuidString).m4a")
        let kept = [active, parts.appendingPathComponent("part0001.caf"),
                    parts.appendingPathComponent(".invalid-\(UUID().uuidString)"),
                    parts.appendingPathComponent(".holos-\(UUID().uuidString).")]
        for file in kept + [stale] { try Data("x".utf8).write(to: file) }
        ReadingTemporaries.sweep(workDirectory: work, outputFolder: parent, key: key, currentRun: current)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        for file in kept { #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)") }
    }

    @Test func cancellingTheRenderRemovesThePartlyJoinedFileAndKeepsParts() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let renderer = FakeRenderer()
        let joiner = HangingJoiner()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: joiner)
        let script = script(3)
        let voice = self.voice
        let metadata = self.metadata
        let task = Task { try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: place) }
        // What `voiceislocal read` does on SIGINT: the latch cancels the render task once.
        let latch = InterruptLatch { task.cancel() }
        await joiner.waitUntilJoining()
        let temporary = try #require(joiner.temporary)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(latch.fire(SIGINT))
        #expect(!latch.fire(SIGTERM))
        #expect(latch.signal == SIGINT)
        #expect(InterruptLatch.exitCode(for: SIGINT) == 130)
        #expect(InterruptLatch.exitCode(for: SIGTERM) == 143)
        do {
            _ = try await task.value
            Issue.record("A cancelled render should throw.")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try joinTemporaries(parent).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: place.output.path))
        let saved = try manifest(place)
        #expect(saved.parts.allSatisfy { $0.status == "complete" })

        // --resume reuses every rendered part.
        let calls = renderer.calls.count
        let resumed = try await ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
            .render(script: script, voiceIdentifier: voice, metadata: metadata, location: place, resume: true)
        #expect(resumed.manifest.status == "complete")
        #expect(renderer.calls.count == calls)
    }
}
