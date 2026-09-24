import Foundation
import Testing
import HolosCore
@testable import HolosStorage

private func pointerTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pointer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func pointerArchive(in root: URL) throws -> SessionArchive {
    try SessionArchive.create(root: root, name: "Pointer", source: .microphone, locale: "en-CA", backend: .speech)
}

private func pointerTranscript(createdAt seconds: TimeInterval, text: String = "Hello") -> Transcript {
    Transcript(createdAt: Date(timeIntervalSince1970: seconds), source: "mic", locale: "en-CA", backend: .speech,
               segments: [TranscriptSegment(start: 0, end: 1, text: text, track: "mic")])
}

@Test func transcriptPointerFollowsLatestSave() async throws {
    let root = try pointerTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try pointerArchive(in: root)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == nil)
    // B is saved last but carries the older date: the pointer, not the date, decides.
    let a = pointerTranscript(createdAt: 1_790_000_001)
    let b = pointerTranscript(createdAt: 1_790_000_000)
    try await writer.saveTranscript(a, writeLegacyExports: false)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == a.id)
    try await writer.saveTranscript(b, writeLegacyExports: false)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == b.id)
    try await writer.finish(status: ArchiveStatus.complete)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == b.id)
    let pointer = try AtomicFile.readJSON(TranscriptPointer.self, from: SessionPaths.transcriptPointer(writer.directory))
    #expect(pointer.transcriptID == b.id)
    #expect(pointer.schemaVersion == 1)
}

@Test func legacyArchiveWithoutPointer() async throws {
    let root = try pointerTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try pointerArchive(in: root)
    let only = pointerTranscript(createdAt: 1_790_000_000)
    try await writer.saveTranscript(only)
    try await writer.finish(status: ArchiveStatus.complete)
    try FileManager.default.removeItem(at: SessionPaths.transcriptPointer(writer.directory))
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == only.id)

    // Several revisions and no pointer: the newest createdAt wins.
    let newer = pointerTranscript(createdAt: 1_790_000_100)
    try AtomicFile.writeJSON(newer, to: SessionPaths.transcript(newer.id, in: writer.directory))
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == newer.id)
    #expect(try !SessionArchive.inspectRecovery(at: writer.directory).needsAttention)
}

@Test func saveTranscriptCanSkipLegacyExports() async throws {
    let root = try pointerTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try pointerArchive(in: root)
    let transcript = pointerTranscript(createdAt: 1_790_000_000)
    try await writer.saveTranscript(transcript, writeLegacyExports: false)
    try await writer.finish(status: ArchiveStatus.complete)
    #expect(try FileManager.default.contentsOfDirectory(atPath: SessionPaths.exports(writer.directory).path) == [])
    #expect(FileManager.default.fileExists(atPath: SessionPaths.transcript(transcript.id, in: writer.directory).path))
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == transcript.id)
}

@Test func pointerFromANewerHolosIsRefused() async throws {
    let root = try pointerTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try pointerArchive(in: root)
    let transcript = pointerTranscript(createdAt: 1_790_000_000)
    try await writer.saveTranscript(transcript, writeLegacyExports: false)
    try await writer.finish(status: ArchiveStatus.complete)
    try AtomicFile.writeJSON(TranscriptPointer(schemaVersion: 2, transcriptID: transcript.id),
                             to: SessionPaths.transcriptPointer(writer.directory))
    let error = #expect(throws: HolosError.self) { try SessionArchive.currentTranscriptID(at: writer.directory) }
    guard case .unavailable? = error else { Issue.record("Expected unavailable, got \(String(describing: error))"); return }
}

@Test func retryDoesNotOverwriteAnUnreadablePointer() async throws {
    let root = try pointerTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try pointerArchive(in: root)
    let a = pointerTranscript(createdAt: 1_790_000_000, text: "A")
    let b = pointerTranscript(createdAt: 1_790_000_001, text: "B")
    try await writer.saveTranscript(a, writeLegacyExports: false)
    try await writer.saveTranscript(b, writeLegacyExports: false)
    let pointerURL = SessionPaths.transcriptPointer(writer.directory)

    // A pointer from a newer Holos: retrying A is refused as newer and leaves the pointer alone.
    try AtomicFile.writeJSON(TranscriptPointer(schemaVersion: 2, transcriptID: b.id), to: pointerURL)
    let newer = try Data(contentsOf: pointerURL)
    let error = await #expect(throws: HolosError.self) { try await writer.saveTranscript(a, writeLegacyExports: false) }
    guard case .unavailable? = error else { Issue.record("Expected unavailable, got \(String(describing: error))"); return }
    #expect(try Data(contentsOf: pointerURL) == newer)

    // A damaged pointer is refused too, not replaced.
    let damaged = Data("{not json".utf8)
    try AtomicFile.write(damaged, to: pointerURL)
    await #expect(throws: HolosError.self) { try await writer.saveTranscript(a, writeLegacyExports: false) }
    #expect(try Data(contentsOf: pointerURL) == damaged)

    // A missing pointer still lets the retry finish.
    try FileManager.default.removeItem(at: pointerURL)
    try await writer.saveTranscript(a, writeLegacyExports: false)
    #expect(try SessionArchive.currentTranscriptID(at: writer.directory) == a.id)
    try await writer.finish(status: ArchiveStatus.complete)
}

@Test func pointerToAMissingRevisionIsReported() async throws {
    let root = try pointerTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try pointerArchive(in: root)
    let transcript = pointerTranscript(createdAt: 1_790_000_000)
    try await writer.saveTranscript(transcript, writeLegacyExports: false)
    try await writer.finish(status: ArchiveStatus.complete)
    try FileManager.default.removeItem(at: SessionPaths.transcript(transcript.id, in: writer.directory))
    #expect(throws: HolosError.self) { try SessionArchive.currentTranscriptID(at: writer.directory) }
}

@Test func transcriptIDCannotShadowThePointer() async throws {
    let root = try pointerTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try pointerArchive(in: root)
    for id in ["current", "Current"] {
        let transcript = Transcript(id: id, source: "mic", locale: "en-CA", backend: .speech)
        await #expect(throws: HolosError.self) { try await writer.saveTranscript(transcript) }
    }
    try await writer.finish(status: ArchiveStatus.complete)
}
