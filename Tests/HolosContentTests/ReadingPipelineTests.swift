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
    private func root() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("holos-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent
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

    @Test func resumeRepairsMissingOrTamperedPartsAndRejectsSettingsChange() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("book")
        let source = String(repeating: "Paragraph one. Paragraph two!\n\n", count: 240)
        let renderer = FakeRenderer()
        let pipeline = ReadingPipeline(renderer: renderer)
        let initial = try await pipeline.render(text: source, to: directory)
        #expect(initial.status == "complete")
        #expect(initial.parts.count > 1)
        #expect(initial.parts.allSatisfy { $0.status == "complete" && $0.audioSHA256 != nil })
        #expect(try String(contentsOf: directory.appendingPathComponent("source.txt"), encoding: .utf8) == source)
        let playlist = try String(contentsOf: directory.appendingPathComponent("playlist.m3u8"), encoding: .utf8)
        #expect(playlist.components(separatedBy: "\n").filter { $0.hasPrefix("parts/") } == initial.parts.map(\.relativeAudioPath))

        let originalCalls = renderer.calls.count
        _ = try await pipeline.render(text: source, to: directory, resume: true)
        #expect(renderer.calls.count == originalCalls)
        try Data("#EXTM3U\nparts/part9999.m4a\n".utf8)
            .write(to: directory.appendingPathComponent("playlist.m3u8"))
        _ = try await pipeline.render(text: source, to: directory, resume: true)
        #expect(try String(contentsOf: directory.appendingPathComponent("playlist.m3u8"), encoding: .utf8) == playlist)
        #expect(renderer.calls.count == originalCalls)
        let missing = directory.appendingPathComponent(initial.parts[1].relativeAudioPath)
        try FileManager.default.removeItem(at: missing)
        _ = try await pipeline.render(text: source, to: directory, resume: true)
        #expect(renderer.calls.count == originalCalls + 1)

        let tampered = directory.appendingPathComponent(initial.parts[0].relativeAudioPath)
        try Data("tampered".utf8).write(to: tampered)
        _ = try await pipeline.render(text: source, to: directory, resume: true)
        #expect(renderer.calls.count == originalCalls + 2)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("parts").path)
        #expect(quarantined.contains { $0.hasPrefix(".invalid-") })
        await #expect(throws: HolosError.self) {
            try await pipeline.render(text: source, rate: 0.6, to: directory, resume: true)
        }
    }

    @Test func failedPartLeavesExplicitIncompleteManifestAndResumes() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("book")
        let source = String(repeating: "A sentence with words.\n\n", count: 260)
        let renderer = FakeRenderer()
        renderer.failOnCall = 2
        let pipeline = ReadingPipeline(renderer: renderer)
        await #expect(throws: HolosError.self) {
            try await pipeline.render(text: source, to: directory)
        }
        let partial = try JSONDecoder().decode(ReadingManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        #expect(partial.status == "incomplete")
        #expect(partial.parts[0].status == "complete")
        #expect(partial.parts[1].status == "pending")
        let playlist = try String(contentsOf: directory.appendingPathComponent("playlist.m3u8"), encoding: .utf8)
        #expect(playlist.contains("#HOLOS-INCOMPLETE"))
        #expect(!playlist.contains("parts/"))
        renderer.failOnCall = nil
        let completed = try await pipeline.render(text: source, to: directory, resume: true)
        #expect(completed.status == "complete")
        #expect(renderer.calls.count == completed.parts.count + 1)
    }

    @Test func concurrentResumeCannotWriteIntoActiveReading() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("book")
        let renderer = GateRenderer()
        let pipeline = ReadingPipeline(renderer: renderer)
        let active = Task { try await pipeline.render(text: "One short paragraph.", to: directory) }
        await renderer.waitUntilRendering()
        do {
            _ = try await pipeline.render(text: "One short paragraph.", to: directory, resume: true)
            Issue.record("Concurrent resume should fail while rendering holds the directory lock.")
        } catch let error as HolosError {
            if case .unavailable = error {} else { Issue.record("Unexpected error: \(error)") }
        }
        renderer.release()
        let completed = try await active.value
        #expect(completed.status == "complete")
        _ = try await pipeline.render(text: "One short paragraph.", to: directory, resume: true)
        #expect(renderer.calls == 1)
    }
}
