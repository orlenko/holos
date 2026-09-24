import Darwin
import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// The processing lease handed from one process to another (docs/meeting-design.md §4.1): `handOff` in the parent,
// `adoptProcessingLease` in the child (`holos session diarize --lease-fd`), and `withUse`.

private func handOffTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-handoff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func handOffMakeSession(in root: URL) async throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Hand-off", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    return archive.directory
}

private func handOffIsCloseOnExec(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFD)
    return flags >= 0 && (flags & FD_CLOEXEC) != 0
}

/// Spawns `/bin/sleep seconds` with `descriptor` at fd 3 and nothing else inherited, as the in-process recorder
/// spawns `holos session diarize --lease-fd 3`.
private func handOffSpawnSleeper(seconds: String, descriptor: Int32) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, descriptor, 3)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    let arguments = ["/bin/sleep", seconds].map { strdup($0) }
    defer { arguments.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, "/bin/sleep", &actions, &attributes, arguments + [nil], nil)
    guard status == 0 else { throw HolosError.io("posix_spawn failed: \(status)") }
    return pid
}

@Test func handedOffLeaseStaysLockedInTheChild() async throws {
    let root = try handOffTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await handOffMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let pid = try lease.handOff { try handOffSpawnSleeper(seconds: "2", descriptor: $0) }
    // The parent has closed its descriptor; the child's copy keeps the lock.
    #expect(try SessionArchive.isProcessing(at: session))
    #expect(throws: HolosError.self) { try SessionArchive.acquireProcessingLease(at: session, retry: .zero) }
    lease.release()
    #expect(try SessionArchive.isProcessing(at: session), "Releasing a handed-off lease does not unlock the child's.")
    var status: Int32 = 0
    #expect(waitpid(pid, &status, 0) == pid)
    #expect(try !SessionArchive.isProcessing(at: session), "The lock ends when the child exits.")
}

@Test func handOffDescriptorNeverHasTheChildsNumber() async throws {
    // dup2 onto the number a descriptor already has keeps close-on-exec, so the child would lose the lock at exec;
    // the descriptor handed to `spawn` is a duplicate above every conventional number.
    let root = try handOffTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await handOffMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let folder = Darwin.open(session.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    defer { Darwin.close(folder) }
    let lockFile = try #require(try AtomicFile.identity(of: ".processing.lock", in: folder))
    let seen = try lease.handOff { descriptor -> Int32 in
        #expect(descriptor >= 10)
        #expect(handOffIsCloseOnExec(descriptor))
        var info = stat()
        #expect(fstat(descriptor, &info) == 0 && FileIdentity(info) == lockFile)
        return Darwin.dup(descriptor)
    }
    defer { Darwin.close(seen) }
    #expect(try SessionArchive.isProcessing(at: session), "The duplicate keeps the lock after the hand-off.")
}

@Test func failedHandOffKeepsTheLease() async throws {
    let root = try handOffTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await handOffMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    #expect(throws: HolosError.self) {
        try lease.handOff { _ in throw HolosError.io("spawn failed") }
    }
    #expect(try SessionArchive.isProcessing(at: session))
    try lease.require(for: session)
    lease.release()
    #expect(try !SessionArchive.isProcessing(at: session))
    #expect(throws: HolosError.self) { try lease.handOff { $0 } }
}

@Test func adoptedLeaseIsTheInheritedLock() async throws {
    let root = try handOffTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await handOffMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    // A dup shares the open file description, as a descriptor inherited through posix_spawn does.
    let inherited = try lease.handOff { Darwin.dup($0) }
    #expect(inherited >= 0)
    #expect(!handOffIsCloseOnExec(inherited))
    let adopted = try SessionArchive.adoptProcessingLease(at: session, descriptor: inherited)
    #expect(adopted.session == session)
    #expect(handOffIsCloseOnExec(inherited), "The adopted descriptor is close-on-exec again.")
    #expect(try SessionArchive.isProcessing(at: session))
    try adopted.require(for: session)
    adopted.release()
    #expect(try !SessionArchive.isProcessing(at: session), "Releasing an adopted lease closes its descriptor.")
}

@Test func adoptionRefusesAnotherSessionsLease() async throws {
    let root = try handOffTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await handOffMakeSession(in: root)
    let second = try await handOffMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: first)
    let inherited = try lease.handOff { Darwin.dup($0) }
    defer { Darwin.close(inherited) }
    let error = #expect(throws: HolosError.self) {
        try SessionArchive.adoptProcessingLease(at: second, descriptor: inherited)
    }
    #expect(error?.errorDescription == "The inherited lock is not this session's processing lease.")
    #expect(fcntl(inherited, F_GETFD) != -1, "A refused descriptor is left open.")
    #expect(try SessionArchive.isProcessing(at: first), "A refused descriptor is left locked.")
    #expect(try !SessionArchive.isProcessing(at: second))

    // A descriptor of another file of the session, and one that is not open, are refused too.
    let manifest = Darwin.open(SessionPaths.manifest(first).path, O_RDONLY | O_CLOEXEC)
    defer { Darwin.close(manifest) }
    #expect(throws: HolosError.self) { try SessionArchive.adoptProcessingLease(at: first, descriptor: manifest) }
    #expect(throws: HolosError.self) { try SessionArchive.adoptProcessingLease(at: first, descriptor: 9_999) }
}

@Test func adoptionRefusesAnUnlockedCopyWhileSomeoneElseHoldsTheLease() async throws {
    let root = try handOffTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await handOffMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    // Another open file description of the right lock file is not the holder's.
    let other = Darwin.open(session.appendingPathComponent(".processing.lock").path, O_RDWR | O_CLOEXEC)
    defer { Darwin.close(other) }
    #expect(other >= 0)
    #expect(throws: HolosError.self) { try SessionArchive.adoptProcessingLease(at: session, descriptor: other) }
}

@Test func withUseKeepsTheLockUntilTheBodyEnds() async throws {
    let root = try handOffTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await handOffMakeSession(in: root)
    let other = try await handOffMakeSession(in: root)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let value = try await lease.withUse(for: session) { () async throws -> Int in
        lease.release()
        #expect(try SessionArchive.isProcessing(at: session), "A release during the use waits for it to end.")
        return 7
    }
    #expect(value == 7)
    #expect(try !SessionArchive.isProcessing(at: session))
    await #expect(throws: HolosError.self) { try await lease.withUse(for: session) { 1 } }

    let foreign = try SessionArchive.acquireProcessingLease(at: other)
    defer { foreign.release() }
    await #expect(throws: HolosError.self) { try await foreign.withUse(for: session) { 1 } }
}
