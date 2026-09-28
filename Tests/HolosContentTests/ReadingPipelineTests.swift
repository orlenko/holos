import AVFoundation
import CryptoKit
import Foundation
import HolosCore
import HolosSynthesis
import Synchronization
import Testing
@testable import HolosContent

@MainActor private final class FakeRenderer: ReadingAudioRenderer {
    var calls: [String] = []
    var failOnCall: Int?
    /// The voices this renderer has; nil for any.
    var voices: Set<String>?

    func checkVoice(_ identifier: String) throws {
        if let voices, !voices.contains(identifier) { throw HolosError.unavailable("No voice \(identifier).") }
    }

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

    /// Once the finished file is published the reading has succeeded: a manifest save or a
    /// cleanup that fails after that is a warning, whether the file was renamed or copied into
    /// place, and a `--resume` finds the reading done.
    @Test func bookkeepingAfterPublishingOnlyWarns() async throws {
        let unsupported: ReadingPublisher.ExclusiveRename = { _, _ in errno = ENOTSUP; return -1 }
        for rename in [ReadingPublisher.systemExclusiveRename, unsupported] {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let place = location(parent)
            let renderer = FakeRenderer()
            let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner(), exclusiveRename: rename,
                                           saveFault: { manifest in
                if manifest.status == "complete" { throw HolosError.io("Simulated full cache volume.") }
            })
            let result = try await pipeline.render(script: script(3), voiceIdentifier: voice, metadata: metadata,
                                                   location: place)
            #expect(result.output == place.output)
            #expect(try Data(contentsOf: place.output) == Data(renderer.calls.joined().utf8))
            #expect(result.warnings.count == 1)
            #expect(result.warnings.first?.contains("could not be marked complete") == true)
            #expect(result.warnings.first?.contains("Simulated full cache volume.") == true)

            let calls = renderer.calls.count
            let resumed = try await ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
                .render(script: script(3), voiceIdentifier: voice, metadata: metadata, location: place, resume: true)
            #expect(renderer.calls.count == calls)
            #expect(resumed.manifest.status == "complete")
            #expect(resumed.manifest.publishing == nil)
            #expect(resumed.warnings.isEmpty)
        }

        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let pipeline = ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner(), removeParts: { _ in
            throw HolosError.io("Simulated removal failure.")
        })
        let result = try await pipeline.render(script: script(2), voiceIdentifier: voice, metadata: metadata,
                                               location: place)
        #expect(result.manifest.status == "complete")
        #expect(FileManager.default.fileExists(atPath: place.output.path))
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.contains("could not be removed") == true)
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

    /// Fields are encoded structurally, so a control character in one never makes it read as two.
    @Test func identityEncodesEveryFieldUnambiguously() {
        func key(_ title: String?, _ author: String?, rate: Float? = nil,
                 _ script: ReadingScript = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["Text."])]))) -> String {
            ReadingPipeline.identity(script: script, voiceIdentifier: voice, rate: rate,
                                     metadata: AudioBookMetadata(title: title, author: author))
        }
        #expect(key("A\u{1}B", nil) != key("A", "B"))
        #expect(key("A", nil) != key("A", ""))
        #expect(key(nil, nil) != key("", nil))
        #expect(key("A", nil, rate: nil) != key("A", nil, rate: 0.5))
        #expect(key("A", nil) == key("A", nil))
        // A chapter title and its text, and segment boundaries, are fields too.
        let one = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["x\u{2}y\u{3}z"])]))
        let two = ReadingScript(document: ReadableDocument(sections: [
            .init(paragraphs: ["x"]), .init(heading: "y", level: 1, paragraphs: ["z"]),
        ]))
        #expect(key("A", nil, one) != key("A", nil, two))
        // A hex SHA-256, which `ReadingOutput` hashes with the output's path.
        let hash = key("A", nil)
        #expect(hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
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

    /// A rate `AVSpeechUtterance` cannot take (JSON cannot even save a non-finite one), a voice the
    /// renderer lacks, a title with nothing readable, or an output that is not a .m4a fails before
    /// anything is created: no cache, source, manifest, or lock, so nothing is left that the same
    /// command could not start over.
    @Test func invalidSettingsFailBeforeAnythingIsCreated() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let renderer = FakeRenderer()
        renderer.voices = [voice]
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        func expectNothingCreated(_ label: String) throws {
            #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty, "\(label)")
        }
        for rate: Float in [.nan, .infinity, -.infinity, -1, 99] {
            for resume in [false, true] {
                await #expect(throws: HolosError.self, "\(rate)") {
                    try await pipeline.render(script: script(2), voiceIdentifier: voice, rate: rate, metadata: metadata,
                                              location: place, resume: resume)
                }
                try expectNothingCreated("\(rate)")
            }
        }
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script(2), voiceIdentifier: "missing.voice", metadata: metadata, location: place)
        }
        try expectNothingCreated("voice")
        for title in ["", " \n\t", "\u{7}\u{200B}"] {
            let untitled = AudioBookMetadata(title: title, author: "Author")
            await #expect(throws: HolosError.self, "\(title.unicodeScalars.map(\.value))") {
                try await pipeline.render(script: script(2), voiceIdentifier: voice, metadata: untitled, location: place)
            }
            try expectNothingCreated("title")
        }
        let wav = ReadingLocation(workDirectory: place.workDirectory, output: parent.appendingPathComponent("Book.wav"))
        await #expect(throws: HolosError.self) {
            try await pipeline.render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: wav)
        }
        try expectNothingCreated("output")
        #expect(renderer.calls.isEmpty)

        // The limits themselves, and no title, are accepted.
        let result = try await pipeline.render(script: script(2), voiceIdentifier: voice, rate: SpeechRate.range.upperBound,
                                               metadata: AudioBookMetadata(title: nil), location: place)
        #expect(result.manifest.rate == SpeechRate.range.upperBound)
        #expect(result.manifest.status == "complete")
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

    /// Caches under different support folders (`HOLOS_SUPPORT_DIR`) for one output: the output's
    /// reservation is in the destination's folder, so the second reading still fails before
    /// rendering. The reservation is readable by every user and names this process; it is gone
    /// once the first finishes.
    @Test func readingsFromDifferentSupportFoldersShareTheOutputReservation() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Books")
        let supports = ["support-a", "support-b"].map { parent.appendingPathComponent($0).appendingPathComponent("Readings") }
        for folder in [destination] + supports {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let output = destination.appendingPathComponent("Book.m4a")
        let first = ReadingLocation(workDirectory: supports[0].appendingPathComponent("Output-a"), output: output)
        let second = ReadingLocation(workDirectory: supports[1].appendingPathComponent("Output-b"), output: output)
        let renderer = GateRenderer()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        let script = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["One short paragraph."])]))
        let other = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["Another paragraph."])]))
        let voice = self.voice
        let metadata = self.metadata
        let active = Task { try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: first) }
        await renderer.waitUntilRendering()
        let name = ReadingOutputReservation.name(for: output)
        #expect(name.utf8.count < ReadingOutput.temporaryNameLength)
        let reservation = destination.appendingPathComponent(name).path
        var info = stat()
        #expect(lstat(reservation, &info) == 0 && info.st_mode & 0o777 == 0o644)
        let record = try JSONDecoder().decode(ReadingOutputReservation.Record.self,
                                              from: Data(contentsOf: URL(fileURLWithPath: reservation)))
        #expect(record.pid == getpid() && record.uid == getuid() && record.host == ReadingOutputReservation.hostName())
        #expect(record.start == ReadingOutputReservation.processStart(getpid()))
        do {
            _ = try await pipeline.render(script: other, voiceIdentifier: voice, metadata: metadata, location: second)
            Issue.record("A reading from another support folder should fail while the first renders.")
        } catch let error as HolosError {
            if case .unavailable(let message) = error {
                #expect(message.contains("Another reading is already being made"))
                #expect(message.contains(reservation))
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(renderer.calls == 1)
        // Nothing of the second reading was created.
        #expect(!FileManager.default.fileExists(atPath: second.workDirectory.path))
        renderer.release()
        #expect(try await active.value.manifest.status == "complete")
        #expect(try Data(contentsOf: output) == Data("One short paragraph.".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Book.m4a"])
    }

    private func writeReservation(_ record: ReadingOutputReservation.Record, at path: String) throws {
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: path))
    }

    /// The process ID of a process that has exited.
    private func endedProcessID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// The message of the `.unavailable` error `body` throws; nil (and an issue) for anything else.
    private func refusal(_ body: () throws -> Void) -> String? {
        do {
            try body()
            Issue.record("Expected a refusal.")
        } catch HolosError.unavailable(let message) {
            return message
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        return nil
    }

    /// A reservation excludes a second holder and goes when released. One whose process has ended
    /// (another process ID, or this one's with another start time: a reused ID), whoever made it,
    /// is taken over; one whose process runs, one from another host, and one that cannot be read
    /// are refused, naming the file, and kept.
    @Test func aReservationIsTakenOverOnlyWhenItsProcessHasEnded() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = parent.appendingPathComponent("support").appendingPathComponent("Output-a")
        let output = parent.appendingPathComponent("Book.m4a")
        let path = parent.appendingPathComponent(ReadingOutputReservation.name(for: output)).path
        do {
            let held = try #require(try ReadingOutputReservation.acquire(output: output, beside: cache))
            let message = refusal { _ = try ReadingOutputReservation.acquire(output: output, beside: cache) }
            #expect(message?.contains("Another reading is already being made for \(output.path)") == true)
            #expect(message?.contains(path) == true)
            withExtendedLifetime(held) {}
        }
        #expect(!FileManager.default.fileExists(atPath: path))

        let live = ReadingOutputReservation.Record.current()
        let ended = [
            ReadingOutputReservation.Record(host: live.host, pid: try endedProcessID(), start: live.start,
                                            uid: live.uid, created: 1),
            ReadingOutputReservation.Record(host: live.host, pid: live.pid, start: live.start - 1,
                                            uid: live.uid, created: 2),
            // Another user's run (its record says so; the file is this user's, in a folder this
            // user can remove files from).
            ReadingOutputReservation.Record(host: live.host, pid: try endedProcessID(), start: 7,
                                            uid: live.uid &+ 1, created: 3),
        ]
        for record in ended {
            try writeReservation(record, at: path)
            do {
                let held = try #require(try ReadingOutputReservation.acquire(output: output, beside: cache))
                #expect(held.record.pid == getpid() && held.record.start == live.start)
                let saved = try JSONDecoder().decode(ReadingOutputReservation.Record.self,
                                                     from: Data(contentsOf: URL(fileURLWithPath: path)))
                #expect(saved == held.record)
                withExtendedLifetime(held) {}
            }
            #expect(!FileManager.default.fileExists(atPath: path))
        }

        let running = ReadingOutputReservation.Record(host: live.host, pid: live.pid, start: live.start,
                                                      uid: live.uid &+ 1, created: 4)
        let elsewhere = ReadingOutputReservation.Record(host: "elsewhere.invalid", pid: try endedProcessID(),
                                                        start: 1, uid: live.uid, created: 5)
        let kept: [(Data, String)] = [
            (try JSONEncoder().encode(running), "Another reading is already being made"),
            (try JSONEncoder().encode(elsewhere), "elsewhere.invalid"),
            (Data(), "does not say which process holds it"),
        ]
        for (contents, expected) in kept {
            try contents.write(to: URL(fileURLWithPath: path))
            let message = refusal { _ = try ReadingOutputReservation.acquire(output: output, beside: cache) }
            #expect(message?.contains(expected) == true)
            #expect(message?.contains(path) == true)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == contents)
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// A stale reservation that cannot be removed here (as another user's file in a shared folder
    /// with the sticky bit) is refused with the file's path and who can delete it.
    @Test func aStaleReservationThatCannotBeRemovedIsRefused() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let cache = parent.appendingPathComponent("support").appendingPathComponent("Output-a")
        let output = destination.appendingPathComponent("Book.m4a")
        let path = destination.appendingPathComponent(ReadingOutputReservation.name(for: output)).path
        let live = ReadingOutputReservation.Record.current()
        try writeReservation(.init(host: live.host, pid: try endedProcessID(), start: 1, uid: live.uid, created: 1),
                             at: path)
        // Read-only: no file in it can be removed, as for another user's in a sticky folder.
        #expect(chmod(destination.path, 0o555) == 0)
        defer { _ = chmod(destination.path, 0o755) }
        let message = refusal { _ = try ReadingOutputReservation.acquire(output: output, beside: cache) }
        #expect(message?.contains(path) == true)
        #expect(message?.contains("can delete it") == true)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// The reservation goes when a reading fails and when it is cancelled.
    @Test func theReservationIsRemovedAfterAFailureAndACancel() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = location(parent)
        let path = parent.appendingPathComponent(ReadingOutputReservation.name(for: place.output)).path
        let voice = self.voice
        let metadata = self.metadata
        let script = script(2)

        let renderer = FakeRenderer()
        renderer.failOnCall = 1
        await #expect(throws: HolosError.self) {
            try await ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
                .render(script: script, voiceIdentifier: voice, metadata: metadata, location: place)
        }
        #expect(!FileManager.default.fileExists(atPath: path))

        let joiner = HangingJoiner()
        let pipeline = ReadingPipeline(renderer: FakeRenderer(), joiner: joiner)
        let task = Task {
            try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                      location: place, resume: true)
        }
        await joiner.waitUntilJoining()
        #expect(FileManager.default.fileExists(atPath: path))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled render should throw.")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// The reservation needs no `flock` on the destination's volume: with every `flock` there
    /// failing as on a volume without it, a second reading from another support folder is still
    /// refused before rendering, and no lock is ever attempted in the destination.
    @Test func theReservationWorksWhereTheDestinationHasNoFlock() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("Books")
        let supports = ["support-a", "support-b"].map { parent.appendingPathComponent($0).appendingPathComponent("Readings") }
        for folder in [destination] + supports {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let output = destination.appendingPathComponent("Book.m4a")
        let first = ReadingLocation(workDirectory: supports[0].appendingPathComponent("Output-a"), output: output)
        let second = ReadingLocation(workDirectory: supports[1].appendingPathComponent("Output-b"), output: output)
        let destinationPath = try #require(realpath(destination.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let attempts = Mutex<[String]>([])
        let cacheLocks = Mutex(0)
        let lockCall: @Sendable (String, Int32) -> Int32 = { path, descriptor in
            if path.hasPrefix(destinationPath + "/") || path.hasPrefix(destination.path + "/") {
                attempts.withLock { $0.append(path) }
                errno = ENOTSUP
                return -1
            }
            cacheLocks.withLock { $0 += 1 }
            return flock(descriptor, LOCK_EX | LOCK_NB)
        }
        let renderer = GateRenderer()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        let script = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["One short paragraph."])]))
        let other = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["Another paragraph."])]))
        let voice = self.voice
        let metadata = self.metadata
        try await ReadingDirectoryLock.$lockCall.withValue(lockCall) {
            let active = Task { try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: first) }
            await renderer.waitUntilRendering()
            do {
                _ = try await pipeline.render(script: other, voiceIdentifier: voice, metadata: metadata, location: second)
                Issue.record("A reading from another support folder should fail while the first renders.")
            } catch HolosError.unavailable(let message) {
                #expect(message.contains("Another reading is already being made"))
            }
            #expect(renderer.calls == 1)
            #expect(!FileManager.default.fileExists(atPath: second.workDirectory.path))
            renderer.release()
            #expect(try await active.value.manifest.status == "complete")
        }
        // The hook was in place (both caches were locked through it), and nothing was locked in the destination.
        #expect(cacheLocks.withLock { $0 } >= 2)
        #expect(attempts.withLock { $0 }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Book.m4a"])
    }

    /// Spellings of one file on this volume: one lock and one cache. The temporary folder is on the
    /// boot volume (APFS: normalization-insensitive, case-insensitive by default).
    @Test func outputIdentityFollowsTheFilesystemsNameRules() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let caseSensitive = ReadingPathIdentity.caseSensitive(parent.path)
        func key(_ url: URL) -> String { ReadingPathIdentity.key(url) }
        let composed = parent.appendingPathComponent("Caf\u{E9}.m4a")
        let decomposed = parent.appendingPathComponent("Cafe\u{301}.m4a")
        #expect(key(composed) == key(decomposed))
        #expect(key(parent.appendingPathComponent("Book.m4a")) != key(parent.appendingPathComponent("Other.m4a")))
        // Case: the new name, and the existing folders' names (their on-disk spelling).
        let upper = parent.appendingPathComponent("BOOK.m4a")
        let otherFolder = parent.deletingLastPathComponent()
            .appendingPathComponent(parent.lastPathComponent.uppercased()).appendingPathComponent("book.m4a")
        #expect((key(upper) == key(parent.appendingPathComponent("book.m4a"))) == !caseSensitive)
        #expect((key(otherFolder) == key(parent.appendingPathComponent("book.m4a"))) == !caseSensitive)
        // A link to the folder, and "..", name the same place.
        let link = parent.appendingPathComponent("link")
        let real = parent.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(key(link.appendingPathComponent("Book.m4a")) == key(real.appendingPathComponent("Book.m4a")))
        #expect(key(URL(fileURLWithPath: real.path + "/../real/Book.m4a")) == key(real.appendingPathComponent("Book.m4a")))
        // An existing file matches its own not-yet-created spellings.
        try Data().write(to: composed)
        #expect(key(composed) == key(decomposed))
        #expect((key(composed) == key(parent.appendingPathComponent("CAF\u{C9}.m4a"))) == !caseSensitive)

        // The cache `locate` picks is the same for every spelling, too.
        let readings = parent.appendingPathComponent("Readings")
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: false)
        func cache(_ url: URL) throws -> URL {
            try ReadingOutput.resolve(output: url.path, name: "x.m4a", identity: "i", readingsRoot: readings)
                .0.workDirectory
        }
        #expect(try cache(decomposed) == cache(composed))
        #expect(try (cache(upper) == cache(parent.appendingPathComponent("book.m4a"))) == !caseSensitive)
    }

    /// On a volume whose case rules cannot be told, "Book.m4a" and "book.m4a" may be two files:
    /// they share the conservative lock, but never a render cache, and `--resume` of one does not
    /// accept the other. On a volume known to ignore case they are one file throughout.
    @Test func locksStayConservativeWhileCachesKeepDistinctSpellings() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        // Normalization as on APFS; case as each query says.
        let unknown: ReadingPathIdentity.VolumeQuery = { _ in .init(caseSensitive: nil, equatesNormalization: true) }
        let insensitive: ReadingPathIdentity.VolumeQuery = { _ in .init(caseSensitive: false, equatesNormalization: true) }
        let sensitive: ReadingPathIdentity.VolumeQuery = { _ in .init(caseSensitive: true, equatesNormalization: true) }
        let upper = parent.appendingPathComponent("Book.m4a")
        let lower = parent.appendingPathComponent("book.m4a")
        let decomposed = parent.appendingPathComponent("Cafe\u{301}.m4a")
        let composed = parent.appendingPathComponent("Caf\u{E9}.m4a")
        func key(_ url: URL, _ rule: ReadingPathIdentity.Rule, _ query: @escaping ReadingPathIdentity.VolumeQuery) -> String {
            ReadingPathIdentity.key(url, rule, volume: query)
        }
        #expect(key(upper, .lock, unknown) == key(lower, .lock, unknown))
        #expect(key(upper, .exact, unknown) != key(lower, .exact, unknown))
        #expect(key(upper, .lock, sensitive) != key(lower, .lock, sensitive))
        #expect(key(upper, .exact, sensitive) != key(lower, .exact, sensitive))
        #expect(key(upper, .lock, insensitive) == key(lower, .lock, insensitive))
        #expect(key(upper, .exact, insensitive) == key(lower, .exact, insensitive))
        for query in [unknown, insensitive, sensitive] {
            #expect(key(decomposed, .exact, query).utf8.elementsEqual(key(composed, .exact, query).utf8))
        }

        let readings = parent.appendingPathComponent("Readings")
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: false)
        func cache(_ url: URL, _ query: @escaping ReadingPathIdentity.VolumeQuery) throws -> URL {
            try ReadingOutput.resolve(output: url.path, name: "x.m4a", identity: "i", readingsRoot: readings,
                                      volume: query).0.workDirectory
        }
        #expect(try cache(upper, unknown) != cache(lower, unknown))
        #expect(try cache(upper, insensitive) == cache(lower, insensitive))
        #expect(try cache(decomposed, unknown) == cache(composed, unknown))

        // `--resume` compares the saved output by exact identity.
        let pipeline = ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner())
        let place = ReadingLocation(workDirectory: parent.appendingPathComponent("work"), output: upper)
        let manifest = try await pipeline.render(script: script(1), voiceIdentifier: voice, metadata: metadata,
                                                 location: place).manifest
        // Removed, so the host volume's own case rules (an existing file resolves to its on-disk
        // name) do not stand in for the simulated ones.
        try FileManager.default.removeItem(at: upper)
        func same(_ url: URL, _ query: @escaping ReadingPathIdentity.VolumeQuery) -> Bool {
            manifest.sameSettings(voiceIdentifier: voice, rate: nil, metadata: metadata, output: url, volume: query)
        }
        #expect(same(upper, unknown))
        #expect(!same(parent.appendingPathComponent("BOOK.m4a"), unknown))
        #expect(!same(parent.appendingPathComponent("BOOK.m4a"), sensitive))
        #expect(same(parent.appendingPathComponent("BOOK.m4a"), insensitive))
    }

    /// On a volume that may keep a name's NFC and NFD spellings apart (a byte-preserving network
    /// share), "Café.m4a" spelled each way is two names: they share the conservative lock, but
    /// never an exact identity, and `--resume` of a reading saved under one does not accept the
    /// other. On APFS and HFS+ (known to equate them) they are one name throughout. `--output`
    /// keeps the spelling typed all the way to the file written and its cache.
    @Test func exactIdentitiesKeepNormalizationUnlessTheVolumeEquatesIt() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let keepsBytes: ReadingPathIdentity.VolumeQuery = { _ in .init(caseSensitive: true, equatesNormalization: nil) }
        let equates: ReadingPathIdentity.VolumeQuery = { _ in .init(caseSensitive: true, equatesNormalization: true) }
        let composedPath = parent.path + "/Caf\u{E9}.m4a"
        let decomposedPath = parent.path + "/Cafe\u{301}.m4a"
        func key(_ path: String, _ rule: ReadingPathIdentity.Rule, _ query: @escaping ReadingPathIdentity.VolumeQuery) -> Data {
            Data(ReadingPathIdentity.key(path: path, rule, volume: query).utf8)
        }
        #expect(key(composedPath, .lock, keepsBytes) == key(decomposedPath, .lock, keepsBytes))
        #expect(key(composedPath, .exact, keepsBytes) != key(decomposedPath, .exact, keepsBytes))
        let spelled = Data("/Caf\u{E9}.m4a".utf8)
        #expect(key(composedPath, .exact, keepsBytes).suffix(spelled.count) == spelled)
        #expect(key(composedPath, .exact, equates) == key(decomposedPath, .exact, equates))
        #expect(ReadingPathIdentity.normalizedName("CAFE\u{301}", caseSensitive: false, composed: false)
            .unicodeScalars.elementsEqual("cafe\u{301}".unicodeScalars))

        // `--output` as typed: Foundation's own file URL would decompose it, so both spellings
        // would name one file and share one cache even where they are two files.
        #expect(Data(URL(fileURLWithPath: composedPath).path.utf8) == Data(decomposedPath.utf8))
        let readings = parent.appendingPathComponent("Readings")
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: false)
        func resolved(_ path: String, _ query: @escaping ReadingPathIdentity.VolumeQuery) throws -> ReadingLocation {
            try ReadingOutput.resolve(output: path, name: "x.m4a", identity: "i", readingsRoot: readings,
                                      volume: query).0
        }
        for path in [composedPath, decomposedPath] {
            #expect(try Data(resolved(path, keepsBytes).output.path.utf8) == Data(path.utf8))
            // "~", ".", and ".." go as `standardizedFileURL` removes them; the spelling stays.
            let roundabout = parent.path + "/./Readings/../" + (path as NSString).lastPathComponent
            #expect(try Data(resolved(roundabout, keepsBytes).output.path.utf8) == Data(path.utf8))
        }
        #expect(try resolved(composedPath, keepsBytes).workDirectory != resolved(decomposedPath, keepsBytes).workDirectory)
        #expect(try resolved(composedPath, equates).workDirectory == resolved(decomposedPath, equates).workDirectory)

        // The file written is the one typed, byte for byte, and so is the manifest's output.
        let pipeline = ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner())
        let place = try resolved(composedPath, keepsBytes)
        let made = try await pipeline.render(script: script(1), voiceIdentifier: voice, metadata: metadata,
                                             location: place).manifest
        func names(_ prefix: String) throws -> [Data] {
            try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(prefix) }
                .map { Data($0.utf8) }
        }
        #expect(try names("Caf") == [Data("Caf\u{E9}.m4a".utf8)])
        #expect(Data(made.output.utf8) == Data(composedPath.utf8))
        // Removed, so the host volume's own rules (an existing file resolves to its on-disk name)
        // do not stand in for the simulated ones.
        try FileManager.default.removeItem(at: place.output)

        // `--resume` compares the saved output byte for byte, then by exact identity.
        func same(_ path: String, _ query: @escaping ReadingPathIdentity.VolumeQuery) throws -> Bool {
            made.sameSettings(voiceIdentifier: voice, rate: nil, metadata: metadata,
                              output: try resolved(path, query).output, volume: query)
        }
        #expect(try same(composedPath, keepsBytes))
        #expect(try !same(decomposedPath, keepsBytes))
        #expect(try same(decomposedPath, equates))

        // A name made here (from a title) is NFC, whatever spelling it came in.
        let title = "Nai\u{308}ve"
        #expect(Data(ReadingOutput.fileName(title: title).utf8) == Data("Na\u{EF}ve.m4a".utf8))
        let named = try ReadingOutput.resolve(output: parent.path, name: title + ".m4a", identity: "i",
                                              readingsRoot: readings, volume: keepsBytes).0
        #expect(Data(named.output.lastPathComponent.utf8) == Data("Na\u{EF}ve.m4a".utf8))
        let fresh = try ReadingOutput.resolve(output: nil, name: title + ".m4a", identity: "i", readingsRoot: readings).0
        let freshName = Data("/Na\u{EF}ve.m4a".utf8)
        #expect(Data(fresh.output.path.utf8).suffix(freshName.count) == freshName)
        _ = try await pipeline.render(script: script(1), voiceIdentifier: voice, metadata: metadata, location: named)
        #expect(try names("Na") == [Data("Na\u{EF}ve.m4a".utf8)])
    }

    /// The volume's format tells whether it equates NFC and NFD names: APFS and HFS+ do; anything
    /// else, or a folder whose volume cannot be read, is unknown.
    @Test func normalizationRulesComeFromTheVolumeFormat() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let type = try #require(ReadingPathIdentity.fileSystemType(parent.path))
        #expect(ReadingPathIdentity.volumeEquatesNormalization(parent.path)
            == (["apfs", "hfs"].contains(type) ? true : nil))
        #expect(ReadingPathIdentity.volumeEquatesNormalization(parent.appendingPathComponent("missing/folder").path) == nil)
    }

    /// A second reading for another spelling of the same file (NFD for NFC, and other case where
    /// the volume ignores it) fails before it renders anything.
    @Test func aSecondReadingForAnotherSpellingOfTheOutputFailsBeforeRendering() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        var aliases = ["Cafe\u{301}.m4a"]
        if !ReadingPathIdentity.caseSensitive(parent.path) { aliases.append("caf\u{E9}.m4a") }
        let renderer = GateRenderer()
        let pipeline = ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
        let script = ReadingScript(document: ReadableDocument(sections: [.init(paragraphs: ["One short paragraph."])]))
        let voice = self.voice
        let metadata = self.metadata
        let first = ReadingLocation(workDirectory: parent.appendingPathComponent("Output-a"),
                                    output: parent.appendingPathComponent("Caf\u{E9}.m4a"))
        let active = Task { try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: first) }
        await renderer.waitUntilRendering()
        for (index, alias) in aliases.enumerated() {
            let second = ReadingLocation(workDirectory: parent.appendingPathComponent("Output-\(index)"),
                                         output: parent.appendingPathComponent(alias))
            do {
                _ = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata, location: second)
                Issue.record("A second reading for \(alias) should fail while the first renders.")
            } catch let error as HolosError {
                if case .unavailable(let message) = error {
                    #expect(message.contains("Another reading is already being made"))
                } else {
                    Issue.record("Unexpected error: \(error)")
                }
            }
        }
        #expect(renderer.calls == 1)
        renderer.release()
        #expect(try await active.value.manifest.status == "complete")
        // Resuming under another spelling finds the finished reading: nothing is rendered again.
        let alias = ReadingLocation(workDirectory: first.workDirectory, output: parent.appendingPathComponent(aliases[0]))
        let resumed = try await pipeline.render(script: script, voiceIdentifier: voice, metadata: metadata,
                                                location: alias, resume: true)
        #expect(resumed.manifest.status == "complete")
        #expect(renderer.calls == 1)
    }

    /// `--print-text` lists the chapters `AudioBookWriter` encodes for the same script: the title
    /// added before a first heading that follows text, no track for a single chapter, and none
    /// without headings.
    @Test(.timeLimit(.minutes(1))) func previewChaptersAreTheChaptersTheFileGets() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let paragraph = "A paragraph with a few words in it."
        let cases: [(ReadableDocument, [String])] = [
            (ReadableDocument(sections: [.init(heading: "Only", level: 2, paragraphs: [paragraph])]), []),
            (ReadableDocument(title: "Book", sections: [.init(heading: "Only", level: 2, paragraphs: [paragraph])]),
             ["Book", "Only"]),
            (ReadableDocument(sections: [.init(paragraphs: [paragraph]),
                                         .init(heading: "Later", level: 2, paragraphs: [paragraph])]),
             ["Beginning", "Later"]),
            (ReadableDocument(title: "Book", sections: [.init(heading: "Book", level: 1, paragraphs: [paragraph]),
                                                        .init(heading: "Two", level: 2, paragraphs: [paragraph]),
                                                        .init(heading: "  ", level: 2, paragraphs: [paragraph])]),
             ["Book", "Two"]),
            (ReadableDocument(title: "Book", sections: [.init(paragraphs: [paragraph, paragraph])]), []),
        ]
        for (index, (document, expected)) in cases.enumerated() {
            let script = ReadingScript(document: document)
            let metadata = AudioBookMetadata(title: document.title)
            let preview = ReadingPreview.chapters(script: script, metadata: metadata)
            #expect(preview == expected, "case \(index)")
            // The file the pipeline would join from the same part plan.
            var parts: [AudioBookPart] = []
            for part in script.parts() {
                let url = parent.appendingPathComponent("case\(index)-part\(part.index).caf")
                try silence(seconds: 0.2, to: url)
                parts.append(AudioBookPart(url: url, silenceBefore: part.index == 0 ? 0
                                               : part.startsSegment ? ReadingAudioFormat.chapterGap : ReadingAudioFormat.partGap,
                                           chapter: part.chapter))
            }
            let summary = try await AudioBookWriter.write(parts: parts, metadata: metadata,
                                                          to: parent.appendingPathComponent("case\(index).m4a"))
            #expect(summary.chapters.map(\.title) == preview, "case \(index)")
        }
    }

    private func silence(seconds: Double, to url: URL) throws {
        let rate = ReadingAudioFormat.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        try #require(buffer.int16ChannelData?[0]).update(repeating: 0, count: Int(frames))
        try file.write(from: buffer)
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

    private struct InjectedFailure: Error {}

    /// A new reading's cache appears whole or not at all: a failure at any step of creating it
    /// (a full disk while writing `source.txt`, say) removes everything that run created, so the
    /// same command simply works again.
    @Test func aFailedCacheCreationLeavesNothingBehind() async throws {
        for step in ReadingCache.Step.allCases {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let place = ReadingLocation(workDirectory: parent.appendingPathComponent("Output-0123456789abcdef"),
                                        output: parent.appendingPathComponent("Book.m4a"))
            let renderer = FakeRenderer()
            let failing = ReadingPipeline(renderer: renderer, joiner: FakeJoiner(), initializationFault: {
                if $0 == step { throw InjectedFailure() }
            })
            await #expect(throws: InjectedFailure.self, "step \(step)") {
                try await failing.render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: place)
            }
            #expect(renderer.calls.isEmpty)
            let left = try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .filter { !($0.hasPrefix(".holos-") && $0.hasSuffix(".lock")) }
            #expect(left.isEmpty, "step \(step): \(left)")

            let retried = try await ReadingPipeline(renderer: renderer, joiner: FakeJoiner())
                .render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: place)
            #expect(retried.manifest.status == "complete", "step \(step)")
        }
    }

    /// What a run killed while creating a cache leaves goes on the next run: its staging folder
    /// (this reading's, or another's that no run is making), and a cache an earlier version left
    /// in place without a manifest. A staging folder whose reading is being made, and a folder
    /// with anything else in it, are kept.
    @Test func leftoversOfAnInterruptedCacheCreationAreRemovedOnTheNextRun() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let place = ReadingLocation(workDirectory: parent.appendingPathComponent("Output-0123456789abcdef"),
                                    output: parent.appendingPathComponent("Book.m4a"))
        func staging(for directory: URL) throws -> URL {
            let url = parent.appendingPathComponent(
                "\(ReadingCache.stagingPrefix)\(ReadingDirectoryLock.key(for: directory))-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("parts"), withIntermediateDirectories: true)
            try Data("text".utf8).write(to: url.appendingPathComponent("source.txt"))
            return url
        }
        let own = try staging(for: place.workDirectory)
        let idle = try staging(for: parent.appendingPathComponent("Output-fedcba9876543210"))
        let busyDirectory = parent.appendingPathComponent("Output-00000000000000ff")
        let busyLock = try ReadingDirectoryLock.acquire(for: busyDirectory)
        let busy = try staging(for: busyDirectory)
        // An earlier version's cache, cut off before its manifest was saved.
        try FileManager.default.createDirectory(at: place.workDirectory.appendingPathComponent("parts"),
                                                withIntermediateDirectories: true)
        try Data("text".utf8).write(to: place.workDirectory.appendingPathComponent("source.txt"))
        try Data("{".utf8).write(to: place.workDirectory.appendingPathComponent(ReadingTemporaries.manifestName()))

        let result = try await ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner())
            .render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: place)
        #expect(result.manifest.status == "complete")
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(!FileManager.default.fileExists(atPath: idle.path))
        #expect(FileManager.default.fileExists(atPath: busy.path))
        withExtendedLifetime(busyLock) {}

        // Anything besides what creating a cache writes, or a folder not named as caches are, is kept.
        let kept = [
            (parent.appendingPathComponent("Output-1111111111111111"), "notes.txt"),
            (parent.appendingPathComponent("work"), nil),
        ]
        for (directory, extra) in kept {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("parts"),
                                                    withIntermediateDirectories: true)
            if let extra { try Data("mine".utf8).write(to: directory.appendingPathComponent(extra)) }
            let other = ReadingLocation(workDirectory: directory, output: parent.appendingPathComponent("Other.m4a"))
            await #expect(throws: HolosError.self) {
                try await ReadingPipeline(renderer: FakeRenderer(), joiner: FakeJoiner())
                    .render(script: script(2), voiceIdentifier: voice, metadata: metadata, location: other)
            }
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("parts").path))
            if let extra { #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(extra).path)) }
        }
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
            // The temporary the book writer encodes a join file into.
            parent.appendingPathComponent(AudioBookWriter.temporaryName(for: ReadingTemporaries.joinName(key: key, run: UUID()))),
            place.workDirectory.appendingPathComponent(ReadingTemporaries.manifestName()),
            parts.appendingPathComponent(".holos-\(UUID().uuidString).caf"),
            parts.appendingPathComponent(".invalid-\(UUID().uuidString)-part0001.caf"),
        ]
        // Another reading's temporary, names that only look similar, and the lock.
        let kept = [
            parent.appendingPathComponent(ReadingTemporaries.joinName(key: "0123456789abcdef", run: UUID())),
            parent.appendingPathComponent(".holos-\(UUID().uuidString).m4a"),
            parent.appendingPathComponent(".holos-join-\(key)-notes.m4a"),
            parent.appendingPathComponent(".holos-join-\(key)-\(UUID().uuidString)-notes.m4a"),
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
