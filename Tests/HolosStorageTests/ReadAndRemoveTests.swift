import Darwin
import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// `AtomicFile.readAndRemove` (the vocabulary hand-off file, docs/meeting-design.md §4.12) and `removeTree` on a
// Holos-created folder in the temporary folder (`voiceislocal say`): a path that is not a verified regular file, or a link
// inside a Holos folder, is never followed or removed recursively.

private func handOffFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-handoff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func handOffEntries(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

private func expectHandOffInvalidInput(_ body: () throws -> Void) {
    let error = #expect(throws: HolosError.self) { try body() }
    guard case .invalidInput? = error else { Issue.record("Expected invalidInput, got \(String(describing: error))"); return }
}

@Test func readAndRemoveReadsThenUnlinksARegularFile() throws {
    let folder = try handOffFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("vocabulary.json")
    try Data("names".utf8).write(to: url)
    #expect(try AtomicFile.readAndRemove(url, maxBytes: 1024) == Data("names".utf8))
    #expect(handOffEntries(folder).isEmpty)
    #expect(try AtomicFile.readAndRemove(url, maxBytes: 1024) == nil, "Missing: nil.")
    #expect(try AtomicFile.readAndRemove(folder.appendingPathComponent("missing/v.json"), maxBytes: 1024) == nil)
}

@Test func readAndRemoveRemovesAVerifiedFileEvenWhenTooLarge() throws {
    let folder = try handOffFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("vocabulary.json")
    try Data(repeating: 65, count: 64).write(to: url)
    expectHandOffInvalidInput { _ = try AtomicFile.readAndRemove(url, maxBytes: 16) }
    #expect(handOffEntries(folder).isEmpty, "A verified regular file is private data: removed whatever happened.")
}

@Test func readAndRemoveLeavesAFolderAndItsContentsAlone() throws {
    let folder = try handOffFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let documents = folder.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
    let kept = documents.appendingPathComponent("report.txt")
    try Data("keep".utf8).write(to: kept)
    expectHandOffInvalidInput { _ = try AtomicFile.readAndRemove(documents, maxBytes: 1024) }
    #expect(try Data(contentsOf: kept) == Data("keep".utf8))
    #expect(handOffEntries(folder) == ["Documents"])
}

@Test func readAndRemoveLeavesALinkAndItsTargetAlone() throws {
    let folder = try handOffFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    let target = folder.appendingPathComponent("target.json")
    try Data("keep".utf8).write(to: target)
    let fileLink = folder.appendingPathComponent("file-link.json")
    try fm.createSymbolicLink(at: fileLink, withDestinationURL: target)
    expectHandOffInvalidInput { _ = try AtomicFile.readAndRemove(fileLink, maxBytes: 1024) }

    let targetFolder = folder.appendingPathComponent("target-folder", isDirectory: true)
    try fm.createDirectory(at: targetFolder, withIntermediateDirectories: false)
    try Data("keep".utf8).write(to: targetFolder.appendingPathComponent("inside.txt"))
    let folderLink = folder.appendingPathComponent("folder-link")
    try fm.createSymbolicLink(at: folderLink, withDestinationURL: targetFolder)
    expectHandOffInvalidInput { _ = try AtomicFile.readAndRemove(folderLink, maxBytes: 1024) }

    #expect(handOffEntries(folder) == ["file-link.json", "folder-link", "target-folder", "target.json"])
    #expect(try Data(contentsOf: target) == Data("keep".utf8))
    #expect(handOffEntries(targetFolder) == ["inside.txt"])
}

@Test func readAndRemoveLeavesAFIFOAlone() throws {
    let folder = try handOffFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fifo = folder.appendingPathComponent("vocabulary.json")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    expectHandOffInvalidInput { _ = try AtomicFile.readAndRemove(fifo, maxBytes: 1024) }
    #expect(handOffEntries(folder) == ["vocabulary.json"])
}

/// Another process that can write to the folder renames a different file onto the hand-off file's name after it was
/// verified: at either moment (before it is moved aside, or after, just before the unlink), the replacement survives
/// with its contents, the verified file's data is still returned, and no aside folder is left behind.
@Test(arguments: [AtomicFile.HandOffRemovalStage.beforeMove, .beforeUnlink])
func readAndRemoveNeverDeletesAFileSwappedInAfterTheCheck(stage: AtomicFile.HandOffRemovalStage) throws {
    let folder = try handOffFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("vocabulary.json")
    try Data("names".utf8).write(to: url)
    let data = try AtomicFile.$handOffRemovalHook.withValue({ current, folder in
        guard current == stage else { return }
        let other = folder.appendingPathComponent("other.json")
        try? Data("someone else's".utf8).write(to: other)
        #expect(rename(other.path, folder.appendingPathComponent("vocabulary.json").path) == 0)
    }) {
        try AtomicFile.readAndRemove(url, maxBytes: 1024)
    }
    #expect(data == Data("names".utf8))
    #expect(handOffEntries(folder) == ["vocabulary.json"], "Only the replacement is left, and no aside folder.")
    #expect(try Data(contentsOf: url) == Data("someone else's".utf8))
}

/// `removeRegularFile` (the app's vocabulary and command-output clean-up) removes only the regular file it checked
/// and accepted: never a file swapped in after the check, a file `accept` refuses, or a link.
@Test(arguments: [AtomicFile.HandOffRemovalStage.beforeMove, .beforeUnlink])
func removeRegularFileNeverDeletesAFileSwappedInAfterTheCheck(stage: AtomicFile.HandOffRemovalStage) throws {
    let folder = try handOffFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("holos-vocabulary-1.json")
    try Data("names".utf8).write(to: url)
    let removed = AtomicFile.$handOffRemovalHook.withValue({ current, folder in
        guard current == stage else { return }
        let other = folder.appendingPathComponent("other.json")
        try? Data("someone else's".utf8).write(to: other)
        #expect(rename(other.path, folder.appendingPathComponent("holos-vocabulary-1.json").path) == 0)
    }) {
        AtomicFile.removeRegularFile(url)
    }
    #expect(removed == (stage == .beforeUnlink), "Removed only when the checked file was the one moved aside.")
    #expect(handOffEntries(folder) == ["holos-vocabulary-1.json"])
    #expect(try Data(contentsOf: url) == Data("someone else's".utf8))
    #expect(!AtomicFile.removeRegularFile(url) { _ in false }, "A file `accept` refuses stays.")
    let link = folder.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    #expect(!AtomicFile.removeRegularFile(link))
    #expect(AtomicFile.removeRegularFile(url))
    #expect(handOffEntries(folder) == ["link.json"])
}

private func removalFolders(_ folder: URL) -> [URL] {
    handOffEntries(folder).filter { $0.hasPrefix(".holos-remove-") }.map { folder.appendingPathComponent($0) }
}

/// A removal interrupted after the verified file was moved aside (here the unlink fails; a crash leaves the same
/// state) strands `.holos-remove-*/file`. The sweep finishes it once the folder is older than the cutoff: the file
/// and its folder go. A folder that is too new is left for a removal that may still be running.
@Test func strandedRemovalFolderIsFinishedBySweep() throws {
    let folder = try handOffFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("holos-vocabulary-1.json")
    try Data("private names".utf8).write(to: url)
    let removed = AtomicFile.$handOffRemovalHook.withValue({ stage, folder in
        guard stage == .beforeUnlink else { return }
        for aside in removalFolders(folder) { #expect(chmod(aside.path, 0o500) == 0) }
    }) {
        AtomicFile.removeRegularFile(url)
    }
    #expect(!removed)
    let stranded = removalFolders(folder)
    try #require(stranded.count == 1)
    #expect(chmod(stranded[0].path, 0o700) == 0)
    #expect(handOffEntries(stranded[0]) == ["file"], "The failed unlink leaves the verified file aside.")

    AtomicFile.removeStrandedRemovalFolders(in: folder, olderThan: Date().addingTimeInterval(-3_600))
    #expect(handOffEntries(stranded[0]) == ["file"], "A folder newer than the cutoff is left alone.")

    AtomicFile.removeStrandedRemovalFolders(in: folder, olderThan: Date().addingTimeInterval(60))
    #expect(handOffEntries(folder).isEmpty, "The verified file and its folder are removed.")
}

/// The sweep removes only the file a removal folder's name records. A replacement left aside, a folder other users
/// could write to, and a link named like a removal folder are left alone.
@Test func strandedRemovalSweepRemovesOnlyTheRecordedFile() throws {
    let fm = FileManager.default
    let folder = try handOffFolder()
    defer { try? fm.removeItem(at: folder) }
    func makeAside(for file: URL, mode: mode_t = 0o700) throws -> URL {
        var info = stat()
        #expect(lstat(file.path, &info) == 0)
        let aside = folder.appendingPathComponent(AtomicFile.removalFolderName(device: info.st_dev, inode: info.st_ino))
        #expect(mkdir(aside.path, 0o700) == 0)
        #expect(chmod(aside.path, mode) == 0)
        return aside
    }

    // A replacement: the folder names one file (still linked elsewhere), a different file is in it.
    let original = folder.appendingPathComponent("original.json")
    try Data("mine".utf8).write(to: original)
    let replacementAside = try makeAside(for: original)
    try Data("someone else's".utf8).write(to: replacementAside.appendingPathComponent("file"))

    // A folder others can write to, holding the recorded file.
    let shared = folder.appendingPathComponent("shared.json")
    try Data("names".utf8).write(to: shared)
    let sharedAside = try makeAside(for: shared, mode: 0o777)
    #expect(rename(shared.path, sharedAside.appendingPathComponent("file").path) == 0)

    // A link named like a removal folder, leading to a folder holding the recorded file.
    let target = folder.appendingPathComponent("target", isDirectory: true)
    try fm.createDirectory(at: target, withIntermediateDirectories: false)
    let targetFile = target.appendingPathComponent("file")
    try Data("keep".utf8).write(to: targetFile)
    let linkAside = try makeAside(for: targetFile)
    #expect(rmdir(linkAside.path) == 0)
    try fm.createSymbolicLink(at: linkAside, withDestinationURL: target)

    AtomicFile.removeStrandedRemovalFolders(in: folder, olderThan: Date().addingTimeInterval(60))
    #expect(try Data(contentsOf: replacementAside.appendingPathComponent("file")) == Data("someone else's".utf8))
    #expect(try Data(contentsOf: original) == Data("mine".utf8))
    #expect(handOffEntries(sharedAside) == ["file"])
    #expect(try Data(contentsOf: targetFile) == Data("keep".utf8))
    #expect(handOffEntries(folder).count == 5)
    #expect(chmod(sharedAside.path, 0o700) == 0)
}

/// `voiceislocal say` removes its own `holos-say-<UUID>` folder with `removeTree` from the resolved temporary folder: the
/// folder goes, a link inside it is removed itself, and the link's target survives.
@Test func removeTreeRemovesAHolosTemporaryFolderWithoutFollowingLinks() throws {
    let fm = FileManager.default
    let outside = try handOffFolder()
    defer { try? fm.removeItem(at: outside) }
    let kept = outside.appendingPathComponent("kept.txt")
    try Data("keep".utf8).write(to: kept)

    let parent = fm.temporaryDirectory.resolvingSymlinksInPath()
    let temporary = parent.appendingPathComponent("holos-say-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temporary) }
    try Data("audio".utf8).write(to: temporary.appendingPathComponent("speech.m4a"))
    try fm.createSymbolicLink(at: temporary.appendingPathComponent("link"), withDestinationURL: outside)

    #expect(try AtomicFile.removeTree([temporary.lastPathComponent], in: parent))
    #expect(!fm.fileExists(atPath: temporary.path))
    #expect(try Data(contentsOf: kept) == Data("keep".utf8))
    #expect(handOffEntries(outside) == ["kept.txt"])
}
