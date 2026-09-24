import Foundation
import Darwin
import Testing
import HolosCore
@testable import HolosStorage

/// A temporary folder holding an empty `<UUID>.holos` session folder and an `outside` folder.
private func chainFixture() throws -> (folder: URL, session: URL, outside: URL) {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("holos-chain-\(UUID().uuidString)", isDirectory: true)
    let session = folder.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    let outside = folder.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: session, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    return (folder, session, outside)
}

private func chainContents(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

private func chainMode(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
}

private func isInvalid(_ error: HolosError?) -> Bool {
    if case .invalidInput? = error { return true }
    return false
}

/// Replaces `folder` by a symbolic link to `target`, keeping the real folder at `moved`.
private func swapForLink(_ folder: URL, movedTo moved: URL, target: URL) {
    let fm = FileManager.default
    try? fm.moveItem(at: folder, to: moved)
    try? fm.createSymbolicLink(at: folder, withDestinationURL: target)
}

// The review case: `<session>.holos/speakers` is a link and `voice` is missing. `stat` on the parent followed the
// link, and `mkdir`/`chmod` by path then made and changed `voice` outside the session.
@Test func ensurePrivateDirectoryNeverCreatesThroughALinkInASession() throws {
    let (folder, session, outside) = try chainFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    try fm.createSymbolicLink(at: session.appendingPathComponent("speakers"), withDestinationURL: outside)
    #expect(isInvalid(#expect(throws: HolosError.self) {
        try AtomicFile.ensurePrivateDirectory(SessionPaths.voiceDirectory(session))
    }))
    #expect(isInvalid(#expect(throws: HolosError.self) {
        try AtomicFile.ensurePrivateDirectory(session.appendingPathComponent("speakers/voice/deeper", isDirectory: true))
    }))
    #expect(try chainContents(outside).isEmpty)

    // The session folder itself is a link.
    let sessionLink = folder.appendingPathComponent("\(UUID().uuidString).holos")
    try fm.createSymbolicLink(at: sessionLink, withDestinationURL: outside)
    #expect(isInvalid(#expect(throws: HolosError.self) {
        try AtomicFile.ensurePrivateDirectory(sessionLink.appendingPathComponent("speakers", isDirectory: true))
    }))
    #expect(try chainContents(outside).isEmpty)

    // A missing session folder is not made on the way to a folder inside it.
    let missing = folder.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    #expect(throws: HolosError.self) {
        try AtomicFile.ensurePrivateDirectory(missing.appendingPathComponent("speakers", isDirectory: true))
    }
    #expect(!fm.fileExists(atPath: missing.path))
}

@Test func ensurePrivateDirectoryMakesEachFolderRelativeToItsParent() throws {
    let (folder, session, outside) = try chainFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let speakers = SessionPaths.speakers(session)
    let moved = session.appendingPathComponent("moved", isDirectory: true)

    // speakers/ is swapped for a link to `outside` after it was made and before voice/ is: voice/ is still made
    // in the real speakers/ (now at moved/), through its descriptor, never in `outside`.
    let counter = FileSyncCounter()
    try AtomicFile.$fileSyncCounter.withValue(counter) {
        try AtomicFile.$beforeFolderCreate.withValue({ url in
            if url.lastPathComponent == "voice" { swapForLink(speakers, movedTo: moved, target: outside) }
        }) {
            try AtomicFile.ensurePrivateDirectory(SessionPaths.voiceDirectory(session))
        }
    }
    #expect(try chainContents(outside).isEmpty)
    #expect(try chainContents(moved) == ["voice"])
    #expect(try chainMode(moved) == 0o700)
    #expect(try chainMode(moved.appendingPathComponent("voice")) == 0o700)
    // Each new folder's parent was fsync'd once.
    #expect(counter.count(session.lastPathComponent + "/") == 1)
    #expect(counter.count("speakers/") == 1)
}

@Test func speakerFoldersAreMadeInOneChainFromTheSession() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("holos-chain-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let archive = try SessionArchive.create(root: root, name: "Chain", source: .microphoneAndSystem,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    let session = archive.directory
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    let speakers = SessionPaths.speakers(session)
    let moved = session.appendingPathComponent("moved", isDirectory: true)
    let runID = UUID().uuidString
    let result = RecognitionResult(runID: runID, createdAt: Date(),
                                   embeddingModel: EmbeddingModelID(id: "model", revision: "rev"),
                                   thresholds: RecognitionThresholds(likelyMaxDistance: 0, likelyMinMargin: 0.1,
                                                                     possibleMaxDistance: 0.4, minSampleSeconds: 20),
                                   matches: [])

    // speakers/ is swapped for a link between making it and making recognition/: nothing is made or written
    // outside the session, and the write is refused.
    let error = #expect(throws: HolosError.self) {
        try AtomicFile.$beforeFolderCreate.withValue({ url in
            if url.lastPathComponent == "recognition" { swapForLink(speakers, movedTo: moved, target: outside) }
        }) {
            try SessionSpeakerStore.writeRecognition(result, session: session)
        }
    }
    #expect(isInvalid(error))
    #expect(try chainContents(outside).isEmpty)
    #expect(try chainContents(moved) == ["recognition"])
}

@Test func sessionReadsNeverFollowALinkedSessionFolder() throws {
    let (folder, session, outside) = try chainFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default
    try AtomicFile.writeJSON(["key": "outside"], to: outside.appendingPathComponent("manifest.json"))
    try AtomicFile.writeJSON(["key": "outside"], to: outside.appendingPathComponent("head.json"))

    // The session folder is a link: reads through it are refused, not redirected.
    let sessionLink = folder.appendingPathComponent("\(UUID().uuidString).holos")
    try fm.createSymbolicLink(at: sessionLink, withDestinationURL: outside)
    #expect(isInvalid(#expect(throws: HolosError.self) {
        try AtomicFile.readJSON([String: String].self, from: sessionLink.appendingPathComponent("manifest.json"))
    }))
    #expect(isInvalid(#expect(throws: HolosError.self) {
        try AtomicFile.readIfPresent(sessionLink.appendingPathComponent("manifest.json"), maxBytes: 1 << 20)
    }))

    // A folder inside the session is a link.
    try fm.createSymbolicLink(at: session.appendingPathComponent("speakers"), withDestinationURL: outside)
    #expect(isInvalid(#expect(throws: HolosError.self) {
        try AtomicFile.readIfPresent(SessionPaths.head(session), maxBytes: 1 << 20)
    }))
    #expect(isInvalid(#expect(throws: HolosError.self) { try SessionSpeakerStore.readHead(session: session) }))
    #expect(isInvalid(#expect(throws: HolosError.self) { try AtomicFile.sync(SessionPaths.head(session)) }))
    #expect(throws: HolosError.self) { try AtomicFile.listFolder(SessionPaths.speakers(session)) }
    #expect(throws: HolosError.self) { try AtomicFile.entryType(at: SessionPaths.head(session)) }

    // A missing folder on the way means a missing file.
    try fm.removeItem(at: session.appendingPathComponent("speakers"))
    #expect(try AtomicFile.readIfPresent(SessionPaths.voiceData("R1", in: session), maxBytes: 1 << 20) == nil)
    #expect(try AtomicFile.entryType(at: SessionPaths.voiceData("R1", in: session)) == nil)
    #expect(try AtomicFile.listFolder(SessionPaths.voiceDirectory(session)) == nil)
}

@Test func sessionLocksOpenTheLockFileRelativeToTheSessionFolder() throws {
    let (folder, session, outside) = try chainFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fm = FileManager.default

    // A session folder that is a link: no lock is taken or probed through it, and no lock file appears outside.
    let sessionLink = folder.appendingPathComponent("\(UUID().uuidString).holos")
    try fm.createSymbolicLink(at: sessionLink, withDestinationURL: outside)
    #expect(isInvalid(#expect(throws: HolosError.self) {
        try SessionLockFile.acquire(SessionLockFile.speakers, in: sessionLink, timeout: .zero)
    }))
    #expect(isInvalid(#expect(throws: HolosError.self) {
        try SessionLockFile.isHeld(SessionLockFile.writer, in: sessionLink)
    }))
    #expect(try chainContents(outside).isEmpty)

    // A lock file that is a link is refused; its target is untouched.
    let target = outside.appendingPathComponent("target")
    try Data("keep".utf8).write(to: target)
    try fm.createSymbolicLink(at: session.appendingPathComponent(SessionLockFile.processing), withDestinationURL: target)
    #expect(throws: HolosError.self) { try SessionLockFile.acquire(SessionLockFile.processing, in: session, timeout: .zero) }
    #expect(throws: HolosError.self) { try SessionLockFile.isHeld(SessionLockFile.processing, in: session) }
    #expect(try Data(contentsOf: target) == Data("keep".utf8))

    // A lock "file" that is a folder is not a lock, so the probe does not report it as free.
    try fm.createDirectory(at: session.appendingPathComponent(SessionLockFile.writer), withIntermediateDirectories: false)
    #expect(isInvalid(#expect(throws: HolosError.self) { try SessionLockFile.isHeld(SessionLockFile.writer, in: session) }))

    // A real session folder still works.
    let fd = try #require(try SessionLockFile.acquire(SessionLockFile.speakers, in: session, timeout: .zero))
    #expect(try SessionLockFile.isHeld(SessionLockFile.speakers, in: session))
    SessionLockFile.unlockAndClose(fd)
    #expect(try !SessionLockFile.isHeld(SessionLockFile.speakers, in: session))
    #expect(try chainMode(session.appendingPathComponent(SessionLockFile.speakers)) == 0o600)
}
