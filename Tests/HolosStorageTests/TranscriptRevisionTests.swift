import Foundation
import HolosCore
@testable import HolosStorage
import Testing

// `SessionArchive.saveTranscriptRevision`: a transcription in another language kept beside the current transcript,
// never made current (docs/meeting-design.md §4.14).

private func revisionRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-revision-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func revisionTranscript(locale: String, createdAt seconds: TimeInterval) -> Transcript {
    Transcript(createdAt: Date(timeIntervalSince1970: seconds), source: "mic", locale: locale, backend: .speech,
               segments: [TranscriptSegment(start: 0, end: 1, text: "word", track: "mic")])
}

@Test func revisionIsSavedWithoutBecomingCurrent() async throws {
    let root = try revisionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SessionArchive.create(root: root, name: "Revision", source: .microphone, locale: "fr-CA",
                                           backend: .speech)
    let current = revisionTranscript(locale: "fr-CA", createdAt: 1_790_000_000)
    try await writer.saveTranscript(current, writeLegacyExports: false)
    let pass = revisionTranscript(locale: "en-CA", createdAt: 1_790_000_100)
    try await writer.saveTranscriptRevision(pass)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == current.id)
    let saved = try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(pass.id, in: writer.directory))
    #expect(saved.locale == "en-CA")
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.pendingTranscript(writer.directory).path))
    // Revisions are immutable.
    await #expect(throws: HolosError.self) { try await writer.saveTranscriptRevision(pass) }
    try await writer.finish(status: ArchiveStatus.complete)
    #expect(try !SessionArchive.inspectRecovery(at: writer.directory).needsAttention)
}

@Test func revisionPinsTheCurrentTranscriptOfAnArchiveWithoutAPointer() async throws {
    let root = try revisionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SessionArchive.create(root: root, name: "Legacy", source: .microphone, locale: "fr-CA",
                                           backend: .speech)
    let legacy = revisionTranscript(locale: "fr-CA", createdAt: 1_790_000_000)
    try await writer.saveTranscript(legacy)
    try FileManager.default.removeItem(at: SessionPaths.transcriptPointer(writer.directory))
    // The newer revision would be taken for the current one without a pointer: the save writes the pointer first.
    let pass = revisionTranscript(locale: "en-CA", createdAt: 1_790_000_100)
    try await writer.saveTranscriptRevision(pass)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == legacy.id)
    #expect(FileManager.default.fileExists(atPath: SessionPaths.transcriptPointer(writer.directory).path))
    try await writer.finish(status: ArchiveStatus.complete)
}

@Test func revisionNeedsACurrentTranscript() async throws {
    let root = try revisionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SessionArchive.create(root: root, name: "Empty", source: .microphone, locale: "fr-CA",
                                           backend: .speech)
    await #expect(throws: HolosError.self) {
        try await writer.saveTranscriptRevision(revisionTranscript(locale: "en-CA", createdAt: 1_790_000_000))
    }
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == nil)
    try await writer.finish(status: ArchiveStatus.audioOnly)
}
