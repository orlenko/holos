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

@Test func removeTreeStaysInsideItsRoot() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    let root = folder.appendingPathComponent("root", isDirectory: true)
    let outside = folder.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    try fm.createDirectory(at: outside.appendingPathComponent("b"), withIntermediateDirectories: true)
    let kept = outside.appendingPathComponent("b/kept.txt")
    try Data("keep".utf8).write(to: kept)

    for bad in [[], [""], ["."], [".."], ["a/b"], ["a", ".."]] {
        #expect(throws: HolosError.self) { try AtomicFile.removeTree(bad, in: root) }
    }
    #expect(try AtomicFile.removeTree(["missing", "b"], in: root) == false)
    #expect(try AtomicFile.removeTree(["a", "missing"], in: root) == false)

    // A symbolic link as the root or as an intermediate folder is refused; the target is untouched.
    let rootLink = folder.appendingPathComponent("root-link")
    try fm.createSymbolicLink(at: rootLink, withDestinationURL: outside)
    #expect(throws: HolosError.self) { try AtomicFile.removeTree(["b"], in: rootLink) }
    try fm.createSymbolicLink(at: root.appendingPathComponent("via"), withDestinationURL: outside)
    #expect(throws: HolosError.self) { try AtomicFile.removeTree(["via", "b"], in: root) }
    #expect(fm.fileExists(atPath: kept.path))

    // A single file and a whole folder.
    let file = root.appendingPathComponent("a/b/file.txt")
    try Data("x".utf8).write(to: file)
    #expect(try AtomicFile.removeTree(["a", "b", "file.txt"], in: root))
    #expect(!fm.fileExists(atPath: file.path))
    #expect(try AtomicFile.removeTree(["a"], in: root))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("a").path))
    #expect(fm.fileExists(atPath: kept.path))
}

private func expectInvalidInput(_ body: () throws -> Void) {
    let error = #expect(throws: HolosError.self) { try body() }
    guard case .invalidInput? = error else { Issue.record("Expected invalidInput, got \(String(describing: error))"); return }
}

@Test func failedAppendRemovesTheFileItCreatedSoARetryPublishesIt() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("edits.jsonl")
    let folderKey = folder.lastPathComponent + "/"

    // A short write on the first append of a new journal leaves no file behind.
    #expect(throws: HolosError.self) {
        try AtomicFile.$appendFailureAfterBytes.withValue(2) { try AtomicFile.append(Data("one\n".utf8), to: url) }
    }
    #expect(try atomicContents(folder).isEmpty)

    // So does a folder fsync that fails after the contents were saved.
    #expect(throws: HolosError.self) {
        try AtomicFile.$failFolderSync.withValue(true) { try AtomicFile.append(Data("one\n".utf8), to: url) }
    }
    #expect(try atomicContents(folder).isEmpty)

    // The retry creates the file again, so it fsyncs the folder too.
    let counter = FileSyncCounter()
    try AtomicFile.$fileSyncCounter.withValue(counter) { try AtomicFile.append(Data("one\n".utf8), to: url) }
    #expect(counter.count(folderKey) == 1)
    #expect(try Data(contentsOf: url) == Data("one\n".utf8))

    // A later append to the existing file does not.
    try AtomicFile.$fileSyncCounter.withValue(counter) { try AtomicFile.append(Data("two\n".utf8), to: url) }
    #expect(counter.count(folderKey) == 1)
}

@Test func unsyncedAppendStillPublishesANewFile() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("events.jsonl")
    let counter = FileSyncCounter()
    try AtomicFile.$fileSyncCounter.withValue(counter) {
        try AtomicFile.append(Data("one\n".utf8), to: url, sync: false)
        try AtomicFile.append(Data("two\n".utf8), to: url, sync: false)
    }
    #expect(counter.count(folder.lastPathComponent + "/") == 1)
    #expect(counter.count("events.jsonl") == 0)
}

@Test func createCanBeRetriedAfterAFailedFolderSync() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("run.json")
    #expect(throws: HolosError.self) {
        try AtomicFile.$failFolderSync.withValue(true) { try AtomicFile.create(Data("run".utf8), at: url) }
    }
    #expect(try atomicContents(folder).isEmpty)
    let counter = FileSyncCounter()
    try AtomicFile.$fileSyncCounter.withValue(counter) { try AtomicFile.create(Data("run".utf8), at: url) }
    #expect(counter.count(folder.lastPathComponent + "/") == 1)
    #expect(try Data(contentsOf: url) == Data("run".utf8))
}

@Test func ensurePrivateDirectoryCanBeRetriedAfterAFailedParentSync() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let child = folder.appendingPathComponent("speakers", isDirectory: true)
    #expect(throws: HolosError.self) {
        try AtomicFile.$failFolderSync.withValue(true) { try AtomicFile.ensurePrivateDirectory(child) }
    }
    #expect(try atomicContents(folder).isEmpty)
    let counter = FileSyncCounter()
    try AtomicFile.$fileSyncCounter.withValue(counter) { try AtomicFile.ensurePrivateDirectory(child) }
    #expect(counter.count(folder.lastPathComponent + "/") == 1)
    #expect(try atomicMode(child) == 0o700)
}

@Test func writesRefuseASymbolicLinkInPlaceOfTheirFolder() throws {
    let folder = try atomicTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    let outside = folder.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: outside.appendingPathComponent("voice"), withIntermediateDirectories: true)
    let journal = outside.appendingPathComponent("edits.jsonl")
    try Data("kept\n".utf8).write(to: journal)

    // Outside a session: the folder holding the file must not be a symbolic link.
    let link = folder.appendingPathComponent("link")
    try fm.createSymbolicLink(at: link, withDestinationURL: outside)
    expectInvalidInput { try AtomicFile.write(Data("x".utf8), to: link.appendingPathComponent("status.json")) }
    expectInvalidInput { try AtomicFile.create(Data("x".utf8), at: link.appendingPathComponent("run.json")) }
    expectInvalidInput { try AtomicFile.append(Data("x\n".utf8), to: link.appendingPathComponent("edits.jsonl")) }
    expectInvalidInput { try AtomicFile.truncate(link.appendingPathComponent("edits.jsonl"), to: 0) }

    // Inside a session: no folder from the session folder down may be one (speakers/ here, above speakers/voice).
    let session = folder.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    try fm.createDirectory(at: session, withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: session.appendingPathComponent("speakers"), withDestinationURL: outside)
    let voice = session.appendingPathComponent("speakers/voice/run.json")
    expectInvalidInput { try AtomicFile.write(Data("x".utf8), to: voice) }
    expectInvalidInput { try AtomicFile.create(Data("x".utf8), at: voice) }
    expectInvalidInput { try AtomicFile.append(Data("x\n".utf8), to: voice) }
    expectInvalidInput { try AtomicFile.append(Data("x\n".utf8), to: session.appendingPathComponent("speakers/edits.jsonl")) }
    expectInvalidInput { try AtomicFile.truncate(session.appendingPathComponent("speakers/edits.jsonl"), to: 0) }

    // A session folder that is itself a symbolic link is refused as well.
    let sessionLink = folder.appendingPathComponent("\(UUID().uuidString).holos")
    try fm.createSymbolicLink(at: sessionLink, withDestinationURL: outside)
    expectInvalidInput { try AtomicFile.write(Data("x".utf8), to: sessionLink.appendingPathComponent("voice/run.json")) }

    #expect(try atomicContents(outside) == ["edits.jsonl", "voice"])
    #expect(try atomicContents(outside.appendingPathComponent("voice")).isEmpty)
    #expect(try Data(contentsOf: journal) == Data("kept\n".utf8))

    // Real folders still work, including one reached through a symbolic link above the session folder.
    try fm.removeItem(at: session.appendingPathComponent("speakers"))
    try AtomicFile.ensurePrivateDirectory(session.appendingPathComponent("speakers/voice", isDirectory: true))
    try AtomicFile.write(Data("x".utf8), to: voice)
    try AtomicFile.append(Data("x\n".utf8), to: session.appendingPathComponent("speakers/edits.jsonl"))
    #expect(try Data(contentsOf: voice) == Data("x".utf8))
    let alias = folder.appendingPathComponent("alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: folder)
    let aliased = alias.appendingPathComponent(session.lastPathComponent).appendingPathComponent("speakers/voice/run.json")
    try AtomicFile.write(Data("y".utf8), to: aliased)
    #expect(try Data(contentsOf: voice) == Data("y".utf8))
}
