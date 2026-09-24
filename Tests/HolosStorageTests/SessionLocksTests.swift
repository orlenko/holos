import Foundation
import Darwin
import Testing
import HolosCore
@testable import HolosStorage

private func locksTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-locks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A finished session: no writer, no lease.
private func locksMakeSession(in root: URL) async throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Locks", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    return archive.directory
}

private func isUnavailable(_ error: HolosError?) -> Bool {
    if case .unavailable? = error { return true }
    return false
}

/// Every descriptor of this process open on the file at `url` (same device and inode).
private func descriptors(openOn url: URL) -> [Int32] {
    var target = stat()
    guard stat(url.path, &target) == 0 else { return [] }
    let limit = min(getdtablesize(), 65_536)
    var found: [Int32] = []
    for fd in 0..<limit {
        var info = stat()
        if fstat(fd, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino { found.append(fd) }
    }
    return found
}

private func isCloseOnExec(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFD)
    return flags >= 0 && (flags & FD_CLOEXEC) != 0
}

@Test func speakerLockTimesOutForSecondHolder() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await locksMakeSession(in: root)
    let result = try SessionArchive.withSpeakerLock(at: session) { () -> Int in
        let waited = ContinuousClock().measure {
            let error = #expect(throws: HolosError.self) {
                try SessionArchive.withSpeakerLock(at: session, timeout: .milliseconds(100)) {}
            }
            #expect(isUnavailable(error))
        }
        #expect(waited >= .milliseconds(100))
        return 7
    }
    #expect(result == 7)
    #expect(try SessionArchive.withSpeakerLock(at: session, timeout: .milliseconds(100)) { 8 } == 8)
}

@Test func speakerLockIsReleasedWhenTheBodyThrows() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await locksMakeSession(in: root)
    #expect(throws: HolosError.self) {
        try SessionArchive.withSpeakerLock(at: session) { throw HolosError.io("body failed") }
    }
    try SessionArchive.withSpeakerLock(at: session, timeout: .zero) {}
}

@Test func processingLeaseIsExclusive() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await locksMakeSession(in: root)
    #expect(try !SessionArchive.isProcessing(at: session))
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    #expect(lease.session == session)
    let waited = ContinuousClock().measure {
        let error = #expect(throws: HolosError.self) {
            try SessionArchive.acquireProcessingLease(at: session, retry: .milliseconds(200))
        }
        #expect(isUnavailable(error))
    }
    #expect(waited >= .milliseconds(200))
    #expect(try SessionArchive.isProcessing(at: session))
    lease.release()
    #expect(try !SessionArchive.isProcessing(at: session))
    lease.release()
    let again = try SessionArchive.acquireProcessingLease(at: session, retry: .zero)
    #expect(try SessionArchive.isProcessing(at: session))
    again.release()
}

@Test func leaseAcquisitionSurvivesAProbe() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await locksMakeSession(in: root)
    let path = session.appendingPathComponent(SessionLockFile.processing).path
    let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    try #require(fd >= 0)
    try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
    // The holder lets go 200 ms after the acquisition first finds the lock held, so the acquisition always polls
    // a held lock and then takes it once free. It cannot succeed without that contention: this descriptor keeps
    // the lock until then. The generous retry keeps a late release under load from failing the test.
    let lease = try SessionLockFile.$onContention.withValue({
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
    }) {
        try SessionArchive.acquireProcessingLease(at: session, retry: .seconds(30))
    }
    #expect(try SessionArchive.isProcessing(at: session))
    lease.release()
}

@Test func leaseReleasedOnDeinit() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await locksMakeSession(in: root)
    func processingWhileHeld() throws -> Bool {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { withExtendedLifetime(lease) {} }
        return try SessionArchive.isProcessing(at: session)
    }
    #expect(try processingWhileHeld())
    #expect(try !SessionArchive.isProcessing(at: session))
}

@Test func lockDescriptorsAreCloseOnExec() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try SessionArchive.create(root: root, name: "Locks", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    let session = archive.directory

    let writer = descriptors(openOn: session.appendingPathComponent(SessionLockFile.writer))
    #expect(!writer.isEmpty)
    #expect(writer.allSatisfy(isCloseOnExec))

    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let processing = descriptors(openOn: session.appendingPathComponent(SessionLockFile.processing))
    #expect(!processing.isEmpty)
    #expect(processing.allSatisfy(isCloseOnExec))

    try SessionArchive.withSpeakerLock(at: session) {
        let speakers = descriptors(openOn: session.appendingPathComponent(SessionLockFile.speakers))
        #expect(!speakers.isEmpty)
        #expect(speakers.allSatisfy(isCloseOnExec))
    }
    lease.release()
    try await archive.finish(status: ArchiveStatus.complete)
    #expect(descriptors(openOn: session.appendingPathComponent(SessionLockFile.writer)).isEmpty)
    #expect(descriptors(openOn: session.appendingPathComponent(SessionLockFile.processing)).isEmpty)
}

@Test func locksRefuseAMissingSessionFolder() throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("\(UUID().uuidString).holos")
    #expect(throws: HolosError.self) { try SessionArchive.acquireProcessingLease(at: missing, retry: .zero) }
    #expect(throws: HolosError.self) { try SessionArchive.withSpeakerLock(at: missing) {} }
    #expect(throws: HolosError.self) { try SessionArchive.isProcessing(at: missing) }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}
