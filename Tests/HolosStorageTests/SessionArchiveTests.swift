import Foundation
import AVFoundation
import Testing
import HolosCore
@testable import HolosStorage

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-storage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func archive(in root: URL) throws -> SessionArchive {
    try SessionArchive.create(root: root, name: "A safe display name / with punctuation",
                              source: .microphoneAndSystem, locale: "en-CA", backend: .speech)
}

private func writeCAF(at url: URL, frames: Int = 64, sampleRate: Double = 48_000) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let samples = buffer.floatChannelData else { throw HolosError.invalidInput("Test audio allocation failed.") }
    buffer.frameLength = AVAudioFrameCount(frames)
    for index in 0..<frames { samples[0][index] = 0.1 }
    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
    try file?.write(from: buffer)
    file = nil
}

@Test func archiveRoundTripAndRecoveryInspection() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let directory = writer.directory
    #expect(directory.lastPathComponent == "\(writer.id).holos")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio/mic").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio/system").path))
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)

    let audio = directory.appendingPathComponent("audio/mic/000001.caf")
    try Data([0x63, 0x61, 0x66, 0x66, 1, 2, 3]).write(to: audio)
    try await writer.registerChunk(.init(track: "mic", relativePath: "audio/mic/000001.caf",
                                         start: 0, end: 1, sampleRate: 48_000,
                                         channels: 1, frameCount: 48_000))
    try await writer.recordEvent(kind: "captureStarted", details: ["track": "mic"])
    let transcript = Transcript(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                source: "mic", locale: "en-CA", backend: .speech,
                                segments: [.init(start: 0, end: 1, text: "Hello world")])
    try await writer.saveTranscript(transcript)
    try await writer.finish(status: "complete")

    let manifest = try SessionArchive.readManifest(at: directory)
    #expect(manifest.name == "A safe display name / with punctuation")
    #expect(manifest.status == "complete")
    #expect(manifest.chunks.count == 1)
    #expect(manifest.chunks[0].sha256?.count == 64)
    let decoded = try JSONDecoder.holos.decode(Transcript.self,
        from: Data(contentsOf: directory.appendingPathComponent("transcripts/\(transcript.id).json")))
    #expect(decoded == transcript)
    #expect(try String(contentsOf: directory.appendingPathComponent("exports/transcript.txt"),
                       encoding: .utf8) == "Hello world\n")
    let first = try SessionArchive.inspectRecovery(at: directory)
    let second = try SessionArchive.inspectRecovery(at: directory)
    #expect(first == second)
    #expect(!first.needsAttention)
    #expect(first.events.map(\.sequence) == [1])
}

@Test func refusesTraversalDuplicateSnapshotsAndConcurrentWriter() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    #expect(throws: Error.self) { try SessionArchive.open(at: writer.directory) }
    let traversal = AudioChunkRecord(track: "mic", relativePath: "audio/mic/../secret.caf",
                                     start: 0, end: 1, sampleRate: 48_000,
                                     channels: 1, frameCount: 48_000)
    await #expect(throws: Error.self) { try await writer.registerChunk(traversal) }
    let transcript = Transcript(id: "revision1", source: "mic", locale: "en-CA", backend: .speech)
    try await writer.saveTranscript(transcript)
    await #expect(throws: Error.self) { try await writer.saveTranscript(transcript) }
    let badTranscript = Transcript(id: "../outside", source: "mic", locale: "en-CA", backend: .speech)
    await #expect(throws: Error.self) { try await writer.saveTranscript(badTranscript) }
    try await writer.finish(status: "complete")
}

@Test func interruptedManifestAndTornJournalAreReportedWithoutMutation() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let directory = writer.directory
    let orphan = directory.appendingPathComponent("audio/system/000002.caf")
    try Data([1, 2, 3]).write(to: orphan)
    let partialManifest = directory.appendingPathComponent(".interrupted.tmp")
    try Data("{\"status\":\"broken\"".utf8).write(to: partialManifest)
    try await writer.recordEvent(kind: "started", details: [:])
    let journal = directory.appendingPathComponent("events.jsonl")
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"sequence\":2".utf8))
    try handle.close()
    let before = try Data(contentsOf: journal)
    let first = try SessionArchive.inspectRecovery(at: directory)
    let second = try SessionArchive.inspectRecovery(at: directory)
    #expect(first == second)
    #expect(first.manifest?.status == "recording")
    #expect(first.tornFinalJournalLine)
    #expect(first.events.map(\.sequence) == [1])
    #expect(first.unindexedChunks == ["audio/system/000002.caf"])
    #expect(try Data(contentsOf: journal) == before)
}

@Test func missingAndCorruptChunksAreReported() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let first = writer.directory.appendingPathComponent("audio/mic/first.caf")
    let second = writer.directory.appendingPathComponent("audio/mic/second.caf")
    try Data([1, 2, 3]).write(to: first)
    try Data([4, 5, 6]).write(to: second)
    try await writer.registerChunk(.init(track: "mic", relativePath: "audio/mic/first.caf",
                                         start: 0, end: 1, sampleRate: 1, channels: 1, frameCount: 1))
    try await writer.registerChunk(.init(track: "mic", relativePath: "audio/mic/second.caf",
                                         start: 1, end: 2, sampleRate: 1, channels: 1, frameCount: 1))
    try await writer.finish(status: "complete")
    try FileManager.default.removeItem(at: first)
    try Data([7, 8]).write(to: second)
    let report = try SessionArchive.inspectRecovery(at: writer.directory)
    #expect(report.missingChunks == ["audio/mic/first.caf"])
    #expect(report.corruptChunks == ["audio/mic/second.caf"])
    #expect(report.needsAttention)
    let manifestBefore = try Data(contentsOf: writer.directory.appendingPathComponent("manifest.json"))
    await #expect(throws: Error.self) { try await SessionArchive.recover(at: writer.directory) }
    #expect(try Data(contentsOf: writer.directory.appendingPathComponent("manifest.json")) == manifestBefore)
}

@Test func unsafeManifestPathIsRejectedWithoutReadingOutsideArchive() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    var manifest = try SessionArchive.readManifest(at: writer.directory)
    manifest.chunks = [.init(track: "mic", relativePath: "audio/mic/../../outside.caf",
                             start: 0, end: 1, sampleRate: 1, channels: 1, frameCount: 1)]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: writer.directory.appendingPathComponent("manifest.json"))
    #expect(throws: Error.self) { try SessionArchive.readManifest(at: writer.directory) }
    let report = try SessionArchive.inspectRecovery(at: writer.directory)
    #expect(report.manifest == nil)
    #expect(report.manifestError != nil)
}

@Test func activeLockAndProcessingStatus() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    #expect(try SessionArchive.isActive(at: writer.directory))
    await #expect(throws: Error.self) { try await SessionArchive.recover(at: writer.directory) }
    try await writer.setStatus("processing")
    #expect(try SessionArchive.readManifest(at: writer.directory).status == "processing")
    #expect(try SessionArchive.isActive(at: writer.directory))
    try await writer.finish(status: "complete")
    #expect(try !SessionArchive.isActive(at: writer.directory))
}

private func makeStaleArchive(in root: URL) async throws -> URL {
    let writer = try archive(in: root)
    let directory = writer.directory
    let path = "audio/mic/000001.caf"
    try await writer.recordEvent(kind: "chunkOpened", details: [
        "track": "mic", "relativePath": path, "start": "2.5",
        "sampleRate": "48000", "channels": "1",
    ])
    try writeCAF(at: directory.appendingPathComponent(path))
    try writeCAF(at: directory.appendingPathComponent("audio/mic/no-metadata.caf"))
    try await writer.setStatus("processing")
    return directory
}

@Test func recoveryPreservesJournalAndReconstructsTimedCAFOnly() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try await makeStaleArchive(in: root)
    #expect(try !SessionArchive.isActive(at: directory))
    let journal = directory.appendingPathComponent("events.jsonl")
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"sequence\":2".utf8))
    try handle.close()
    let original = try Data(contentsOf: journal)
    let originalAudio = try Data(contentsOf: directory.appendingPathComponent("audio/mic/000001.caf"))

    let first = try await SessionArchive.recover(at: directory)
    #expect(first.manifest?.status == "interrupted")
    #expect(first.manifest?.chunks.count == 1)
    #expect(first.manifest?.chunks[0].relativePath == "audio/mic/000001.caf")
    #expect(first.manifest?.chunks[0].start == 2.5)
    #expect(first.manifest?.chunks[0].frameCount == 64)
    #expect(first.manifest?.chunks[0].end == 2.5 + 64.0 / 48_000)
    #expect(first.manifest?.chunks[0].sha256?.count == 64)
    #expect(first.unrecoveredChunks == ["audio/mic/no-metadata.caf"])
    #expect(first.unindexedChunks == ["audio/mic/no-metadata.caf"])
    #expect(!first.tornFinalJournalLine)
    #expect(first.events.map(\.sequence) == [1, 2])
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("events.before-recovery-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == original)
    #expect(try Data(contentsOf: directory.appendingPathComponent("audio/mic/000001.caf")) == originalAudio)

    let second = try await SessionArchive.recover(at: directory)
    #expect(second.manifest == first.manifest)
    #expect(second.events == first.events)
    #expect(second.unrecoveredChunks == first.unrecoveredChunks)
    #expect(try Data(contentsOf: backups[0]) == original)
    #expect(try Data(contentsOf: directory.appendingPathComponent("audio/mic/000001.caf")) == originalAudio)
}

@Test func markdownExportPreservesSegmentTimeTrackAndSpeakerLabel() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try archive(in: root)
    let transcript = Transcript(source: "meeting", locale: "en-CA", backend: .speech,
        segments: [
            .init(start: 1.25, end: 2.5, text: "First phrase", track: "mic", speakerID: "spk-1"),
            .init(start: 3, end: 4.125, text: "Second phrase", track: "system"),
        ])
    try await writer.saveTranscript(transcript)
    let markdown = try String(contentsOf: writer.directory.appendingPathComponent("exports/transcript.md"),
                              encoding: .utf8)
    #expect(markdown.contains("[00:00:01.250–00:00:02.500] Source: mic"))
    #expect(markdown.contains("Speaker label (not verified identity): spk-1"))
    #expect(markdown.contains("[00:00:03.000–00:00:04.125] Source: system"))
    #expect(markdown.contains("First phrase"))
    #expect(markdown.contains("Second phrase"))
    let plain = try String(contentsOf: writer.directory.appendingPathComponent("exports/transcript.txt"),
                           encoding: .utf8)
    #expect(plain == "First phrase Second phrase\n")
}

private extension JSONDecoder {
    static var holos: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
