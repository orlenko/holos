import Foundation
import Darwin
import Testing
import HolosCore
@testable import HolosStorage

private func atomicTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-atomic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func atomicMode(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
}

private func atomicContents(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

@Test func atomicCreateRefusesExisting() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("run.json")
    try AtomicFile.create(Data("first".utf8), at: url)
    let error = #expect(throws: HolosError.self) { try AtomicFile.create(Data("second".utf8), at: url) }
    guard case .invalidInput? = error else { Issue.record("Expected invalidInput, got \(String(describing: error))"); return }
    #expect(try Data(contentsOf: url) == Data("first".utf8))
    #expect(try atomicContents(folder) == ["run.json"])
    #expect(try atomicMode(url) == 0o600)
}

@Test func atomicWriteLeavesNoTemporaryFiles() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("status.json")
    for index in 0..<5 { try AtomicFile.write(Data("value \(index)".utf8), to: url) }
    #expect(try Data(contentsOf: url) == Data("value 4".utf8))
    #expect(try atomicContents(folder) == ["status.json"])

    // A rename that fails (the target is a folder) removes its temporary file.
    let blocked = folder.appendingPathComponent("blocked", isDirectory: true)
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: blocked.appendingPathComponent("child"), withIntermediateDirectories: false)
    #expect(throws: HolosError.self) { try AtomicFile.write(Data("x".utf8), to: blocked) }
    #expect(try atomicContents(folder) == ["blocked", "status.json"])

    // A folder that does not exist fails cleanly.
    #expect(throws: HolosError.self) {
        try AtomicFile.write(Data("x".utf8), to: folder.appendingPathComponent("missing/file.json"))
    }
    #expect(try atomicContents(folder) == ["blocked", "status.json"])
}

@Test func atomicWriteHonoursPermissions() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("transcript.md")
    try AtomicFile.write(Data("generated".utf8), to: url, permissions: 0o400)
    #expect(try atomicMode(url) == 0o400)
    #expect(try Data(contentsOf: url) == Data("generated".utf8))
    #expect(FileManager.default.isReadableFile(atPath: url.path))
    #expect(!FileManager.default.isWritableFile(atPath: url.path))
    let fd = Darwin.open(url.path, O_WRONLY | O_CLOEXEC)
    if fd >= 0 { Darwin.close(fd) }
    #expect(fd < 0)

    // A read-only file can still be replaced atomically.
    try AtomicFile.write(Data("regenerated".utf8), to: url, permissions: 0o400)
    #expect(try Data(contentsOf: url) == Data("regenerated".utf8))
    #expect(try atomicMode(url) == 0o400)

    try AtomicFile.write(Data("private".utf8), to: folder.appendingPathComponent("default.json"))
    #expect(try atomicMode(folder.appendingPathComponent("default.json")) == 0o600)
}

@Test func atomicAppendCreatesPrivateFileAndAppends() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("edits.jsonl")
    try AtomicFile.append(Data("one\n".utf8), to: url)
    try AtomicFile.append(Data("two\n".utf8), to: url, sync: false)
    #expect(try Data(contentsOf: url) == Data("one\ntwo\n".utf8))
    #expect(try atomicMode(url) == 0o600)
}

@Test func atomicAppendFailureTruncatesBack() async throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("events.jsonl")
    try AtomicFile.append(Data("complete line\n".utf8), to: url)
    #expect(throws: HolosError.self) {
        try AtomicFile.$appendFailureAfterBytes.withValue(4) {
            try AtomicFile.append(Data("partial line\n".utf8), to: url)
        }
    }
    #expect(try Data(contentsOf: url) == Data("complete line\n".utf8))
}

@Test func atomicFileRefusesSymlinks() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("target.json")
    try AtomicFile.writeJSON(["key": "value"], to: target)
    let link = folder.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: HolosError.self) { try AtomicFile.readJSON([String: String].self, from: link) }
    #expect(throws: HolosError.self) { try AtomicFile.append(Data("x\n".utf8), to: link) }
    #expect(try AtomicFile.readJSON([String: String].self, from: target) == ["key": "value"])

    let folderLink = folder.appendingPathComponent("folder-link")
    try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
    #expect(throws: HolosError.self) { try AtomicFile.ensurePrivateDirectory(folderLink) }
}

@Test func atomicReadJSONLimitsSizeAndReportsMissingFiles() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("big.json")
    try AtomicFile.writeJSON(Array(repeating: "value", count: 100), to: url)
    #expect(throws: HolosError.self) { try AtomicFile.readJSON([String].self, from: url, maxBytes: 64) }
    #expect(try AtomicFile.readJSON([String].self, from: url).count == 100)
    #expect(throws: HolosError.self) { try AtomicFile.readJSON([String].self, from: folder.appendingPathComponent("none.json")) }
    try Data("{".utf8).write(to: folder.appendingPathComponent("broken.json"))
    #expect(throws: HolosError.self) { try AtomicFile.readJSON([String].self, from: folder.appendingPathComponent("broken.json")) }
}

@Test func ensurePrivateDirectoryCreatesMissingParents() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let nested = folder.appendingPathComponent("a/b/c", isDirectory: true)
    try AtomicFile.ensurePrivateDirectory(nested)
    try AtomicFile.ensurePrivateDirectory(nested)
    #expect(try atomicMode(nested) == 0o700)
    #expect(try atomicMode(folder.appendingPathComponent("a/b")) == 0o700)
    #expect(try atomicMode(folder.appendingPathComponent("a")) == 0o700)
    let file = folder.appendingPathComponent("file")
    try Data().write(to: file)
    #expect(throws: HolosError.self) { try AtomicFile.ensurePrivateDirectory(file) }
}
