import Darwin
import Foundation
import HolosCore
import HolosStorage
import Testing

private func screenStoreFixture() async throws -> (URL, SessionArchive) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-screen-store-\(UUID().uuidString)")
    let archive = try SessionArchive.create(root: root, name: "Synthetic slides", source: .microphone,
                                           locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.audioOnly)
    return (root, archive)
}

@Test func screenContextEvidenceIsTimedBoundedAndNeverAddsVocabulary() {
    let line = ScreenTextLine(text: "ExampleTool Cloud", x: 0, y: 0, width: 0.5, height: 0.1, confidence: 0.9)
    let frame = ScreenKeyframe(start: 10, end: 20, lines: [line])
    let record = ScreenContextRecord(sessionID: "id", frames: [frame])
    #expect(record.words(from: 12, to: 13) == ["ExampleTool Cloud"])
    #expect(record.words(from: 0, to: 9).isEmpty)
    #expect(record.words(from: 21, to: 25).isEmpty)
    #expect(record.words(from: .nan, to: 25).isEmpty)
    #expect(record.words(from: 12, to: 13, maximumCharacters: 4).isEmpty)
    #expect(record.candidates(excluding: ["cloud"], from: 12, to: 13) == ["ExampleTool"])
}

@Test func screenContextIsPrivateAndDeletedWithAudio() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let frame = ScreenKeyframe(start: 1, end: 2, lines: [])
    let record = ScreenContextRecord(sessionID: archive.id, frames: [frame])
    try ScreenContextStore.write(record, session: archive.directory)
    let image = try ScreenContextStore.image(frame.id, session: archive.directory)
    try AtomicFile.create(Data([1, 2]), at: image)
    #expect(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) == record)
    var info = stat()
    #expect(lstat(ScreenContextStore.directory(archive.directory).path, &info) == 0 && info.st_mode & 0o777 == 0o700)
    #expect(lstat(image.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    let lease = try SessionArchive.acquireProcessingLease(at: archive.directory)
    defer { lease.release() }
    try SessionDeletion.deleteAudio(session: archive.directory, lease: lease)
    #expect(!FileManager.default.fileExists(atPath: ScreenContextStore.directory(archive.directory).path))
    #expect(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) == nil)
    #expect(throws: (any Error).self) {
        try ScreenContextStore.update(session: archive.directory, sessionID: archive.id) { $0.frames = [frame] }
    }
    #expect(!FileManager.default.fileExists(atPath: ScreenContextStore.directory(archive.directory).path),
            "Late capture/OCR callbacks cannot recreate deleted screen evidence.")
}

@Test func screenContextRefusesWrongOwnerInvalidTimesAndPathTraversal() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try ScreenContextStore.write(ScreenContextRecord(sessionID: "other"), session: archive.directory)
    #expect(throws: (any Error).self) { try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) }
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id,
        frames: [ScreenKeyframe(start: 3, end: 2)]), session: archive.directory)
    #expect(throws: (any Error).self) { try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) }
    #expect(throws: (any Error).self) { try ScreenContextStore.image("../../outside", session: archive.directory) }
}

@Test func screenContextNeverFollowsPlantedDirectoryLink() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: ScreenContextStore.directory(archive.directory), withDestinationURL: outside)
    #expect(throws: (any Error).self) {
        try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id), session: archive.directory)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}
