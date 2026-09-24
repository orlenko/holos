import Foundation
import Darwin
import Synchronization
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

// MARK: - Release racing a use of the lease

/// `.writer.lock` held from a descriptor of its own, so a maintenance operation must wait for it (and calls the
/// `onContention` hook) after it has validated its lease. `let go()` is idempotent.
private final class WriterHolder: Sendable {
    private let fd: Mutex<Int32>

    init(_ session: URL) throws {
        let path = session.appendingPathComponent(SessionLockFile.writer).path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        self.fd = Mutex(fd)
    }

    func letGo() {
        let fd = self.fd.withLock { value -> Int32 in
            let current = value
            value = -1
            return current
        }
        if fd >= 0 {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
    }
}

/// `isProcessing` answers seen from inside the operation, probing from a second descriptor.
private final class LeaseProbes: Sendable {
    private let values = Mutex<[Bool]>([])
    func probe(_ session: URL) {
        let held = (try? SessionArchive.isProcessing(at: session)) ?? false
        values.withLock { $0.append(held) }
    }
    var all: [Bool] { values.withLock { $0 } }
}

private func isInvalidInput(_ error: HolosError?) -> Bool {
    if case .invalidInput? = error { return true }
    return false
}

@Test func leaseReleasedDuringMaintenanceOpenStaysLockedUntilTheOpenEnds() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await locksMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let writer = try WriterHolder(session)
    defer { writer.letGo() }
    let probes = LeaseProbes()
    // The release lands after the lease was validated and before the writer lock is held.
    let maintenance = try SessionLockFile.$onContention.withValue({
        lease.release()
        probes.probe(session)
        writer.letGo()
    }) {
        try SessionArchive.openForMaintenance(at: session, lease: lease)
    }
    #expect(probes.all == [true])
    #expect(try SessionArchive.isActive(at: session))
    // The open has ended, so the pending release has let the lease go.
    #expect(try !SessionArchive.isProcessing(at: session))
    try await maintenance.finish(status: ArchiveStatus.complete)
    let error = #expect(throws: HolosError.self) { try SessionArchive.openForMaintenance(at: session, lease: lease) }
    #expect(isInvalidInput(error))
}

@Test func leaseReleasedDuringRecoveryStaysLockedUntilRecoveryEnds() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await locksMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let writer = try WriterHolder(session)
    defer { writer.letGo() }
    let probes = LeaseProbes()
    _ = try await SessionLockFile.$onContention.withValue({
        lease.release()
        probes.probe(session)
        writer.letGo()
    }) {
        try await SessionArchive.recover(at: session, lease: lease)
    }
    #expect(probes.all == [true])
    #expect(try !SessionArchive.isProcessing(at: session))
    #expect(try !SessionArchive.isActive(at: session))
}

/// `release()` from another thread races `openForMaintenance(at:lease:)` and `recover(at:lease:)`: each either
/// fails with "already released" before doing anything, or finishes with the lease locked throughout.
@Test func leaseReleaseRacingItsUseNeverUnlocksMidOperation() async throws {
    let root = try locksTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await locksMakeSession(in: root)
    for iteration in 0..<40 {
        let lease = try SessionArchive.acquireProcessingLease(at: session, retry: .seconds(5))
        let writer = try WriterHolder(session)
        let probes = LeaseProbes()
        let hook: @Sendable () -> Void = {
            probes.probe(session)
            writer.letGo()
        }
        let delay = UInt32.random(in: 0...400)
        let released = DispatchSemaphore(value: 0)
        Thread {
            usleep(delay)
            lease.release()
            released.signal()
        }.start()
        var failure: HolosError?
        do {
            if iteration.isMultiple(of: 2) {
                let maintenance = try SessionLockFile.$onContention.withValue(hook) {
                    try SessionArchive.openForMaintenance(at: session, lease: lease)
                }
                try await maintenance.finish(status: ArchiveStatus.complete)
            } else {
                _ = try await SessionLockFile.$onContention.withValue(hook) {
                    try await SessionArchive.recover(at: session, lease: lease)
                }
            }
        } catch let error as HolosError {
            failure = error
        }
        writer.letGo()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                released.wait()
                continuation.resume()
            }
        }
        if let failure {
            #expect(isInvalidInput(failure), "iteration \(iteration): \(failure)")
            #expect(probes.all.isEmpty, "iteration \(iteration)")
        } else {
            // The probe inside the operation, after validation and whenever the release landed, sees the lease held.
            #expect(probes.all == [true], "iteration \(iteration)")
        }
        #expect(try !SessionArchive.isProcessing(at: session), "iteration \(iteration)")
        #expect(try !SessionArchive.isActive(at: session), "iteration \(iteration)")
    }
}
