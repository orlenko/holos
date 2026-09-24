import Darwin
import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// `AtomicFile.writeStream`, `openForReading`, and the public `readIfPresent`/`removeTree` the post-processor uses
// inside a session (docs/meeting-design.md §1.7, §4.13).

private func streamedMakeSession() async throws -> (root: URL, session: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-streamed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = try SessionArchive.create(root: root, name: "Streamed", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    return (root, archive.directory)
}

private func streamedEntries(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

@Test func writeStreamPublishesTheWholeFile() async throws {
    let (root, session) = try await streamedMakeSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let derived = SessionPaths.derived(session)
    try AtomicFile.ensurePrivateDirectory(derived)
    let url = derived.appendingPathComponent("mic-16k.caf")
    try AtomicFile.writeStream(to: url) { fd in
        try AtomicFile.writeAll(Data("header--body".utf8), fd: fd)
        // The descriptor is read-write: patch the header in place and read it back.
        #expect(pwrite(fd, "HEADER", 6, 0) == 6)
        var buffer = [UInt8](repeating: 0, count: 6)
        #expect(pread(fd, &buffer, 6, 0) == 6)
        #expect(String(decoding: buffer, as: UTF8.self) == "HEADER")
    }
    #expect(try AtomicFile.readIfPresent(url, maxBytes: 1 << 10) == Data("HEADER--body".utf8))
    var info = stat()
    #expect(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    #expect(streamedEntries(derived) == ["mic-16k.caf"])

    // Replaced by a later write, and never replaced with `exclusive`.
    try AtomicFile.writeStream(to: url) { try AtomicFile.writeAll(Data("second".utf8), fd: $0) }
    #expect(try AtomicFile.readIfPresent(url, maxBytes: 1 << 10) == Data("second".utf8))
    #expect(throws: HolosError.self) {
        try AtomicFile.writeStream(to: url, exclusive: true) { try AtomicFile.writeAll(Data("third".utf8), fd: $0) }
    }
    #expect(try AtomicFile.readIfPresent(url, maxBytes: 1 << 10) == Data("second".utf8))
    #expect(streamedEntries(derived) == ["mic-16k.caf"])
}

@Test func writeStreamPublishesNothingWhenFillingFails() async throws {
    let (root, session) = try await streamedMakeSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let derived = SessionPaths.derived(session)
    try AtomicFile.ensurePrivateDirectory(derived)
    let url = derived.appendingPathComponent("mic-16k.caf")
    #expect(throws: CancellationError.self) {
        try AtomicFile.writeStream(to: url) { fd in
            try AtomicFile.writeAll(Data("partial".utf8), fd: fd)
            throw CancellationError()
        }
    }
    #expect(streamedEntries(derived).isEmpty, "No file and no temporary file is left.")
}

@Test func openForReadingRefusesLinks() async throws {
    let (root, session) = try await streamedMakeSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = SessionPaths.manifest(session)
    let handle = try #require(try AtomicFile.openForReading(manifest))
    #expect(try handle.readToEnd() == Data(contentsOf: manifest))
    #expect(try AtomicFile.openForReading(session.appendingPathComponent("missing.json")) == nil)
    #expect(try AtomicFile.openForReading(session.appendingPathComponent("nothing/here.json")) == nil)

    // A link in place of a file, or of a folder inside the session, is refused.
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("secret".utf8).write(to: outside.appendingPathComponent("chunk.caf"))
    try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("linked.json"),
                                               withDestinationURL: manifest)
    #expect(throws: HolosError.self) { try AtomicFile.openForReading(session.appendingPathComponent("linked.json")) }
    try FileManager.default.removeItem(at: session.appendingPathComponent("audio/mic"))
    try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("audio/mic"),
                                               withDestinationURL: outside)
    #expect(throws: HolosError.self) {
        try AtomicFile.openForReading(session.appendingPathComponent("audio/mic/chunk.caf"))
    }
}

@Test func removeTreeDeletesDerivedWithoutFollowingALink() async throws {
    let (root, session) = try await streamedMakeSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let derived = SessionPaths.derived(session)
    try AtomicFile.ensurePrivateDirectory(derived)
    try AtomicFile.write(Data("render".utf8), to: derived.appendingPathComponent("mic-16k.caf"))
    #expect(try AtomicFile.removeTree(["derived"], in: session))
    #expect(!FileManager.default.fileExists(atPath: derived.path))
    #expect(try !AtomicFile.removeTree(["derived"], in: session))

    // A link in place of derived/ is removed itself; its target is untouched.
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
    try FileManager.default.createSymbolicLink(at: derived, withDestinationURL: outside)
    #expect(try AtomicFile.removeTree(["derived"], in: session))
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
}
