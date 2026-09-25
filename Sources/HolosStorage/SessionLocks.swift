import Foundation
import Darwin
import Synchronization
import os
import HolosCore

/// Exclusive, long-lived claim on post-stop work for one session. Released by `release()` or deinit.
///
/// Held on `.processing.lock` with `flock`, one open file description per lease, so a second lease in the
/// same process conflicts with the first (locks are not re-entrant; docs/meeting-design.md §1.7).
public final class ProcessingLease: Sendable {
    public let session: URL
    /// The session folder the lease was taken in, from `fstat` of the descriptor its lock file was opened in.
    let folder: FileIdentity
    /// Every read or change of the descriptor, the released flag, and the use count goes through this one mutex,
    /// so `release()` and `beginUse(for:)` are serialized: a use either starts before the release (and keeps the
    /// lock until it ends) or fails.
    private let state: Mutex<State>

    private struct State {
        /// The locked descriptor, or -1 once unlocked and closed.
        var descriptor: Int32
        /// Set by `release()`; no use can start after it.
        var released = false
        /// Operations running under the lease (`beginUse`/`endUse`).
        var users = 0

        /// Hands over the descriptor to unlock when the lease is released and unused, and forgets it.
        mutating func takeIfIdle() -> Int32 {
            guard released, users == 0 else { return -1 }
            let fd = descriptor
            descriptor = -1
            return fd
        }
    }

    /// False for a lease adopted from a parent process (`adoptProcessingLease`): its descriptor shares the parent's
    /// open file description, so letting go only closes it (an explicit unlock would drop the lock for every
    /// process sharing it).
    private let unlocksOnRelease: Bool

    init(session: URL, folder: FileIdentity, descriptor: Int32, unlocksOnRelease: Bool = true) {
        self.session = session
        self.folder = folder
        self.unlocksOnRelease = unlocksOnRelease
        self.state = Mutex(State(descriptor: descriptor))
    }

    deinit { release() }

    /// Releases the lease: no operation can start under it afterwards. The lock is let go at once, or, while an
    /// operation under the lease is still running (`openForMaintenance(at:lease:)`, `recover(at:lease:)`,
    /// `withUse(for:_:)`), when that operation ends, so the lock is never dropped in the middle of one. Later calls
    /// do nothing.
    public func release() {
        let fd = state.withLock { value -> Int32 in
            value.released = true
            return value.takeIfIdle()
        }
        letGo(fd)
    }

    /// Runs `body` under the lease: the lock stays held until `body` returns, even if `release()` is called
    /// meanwhile. Throws `HolosError.invalidInput` (and runs nothing) when the lease was released or was not taken
    /// for `directory` (the same check as `openForMaintenance(at:lease:)`).
    public func withUse<T>(for directory: URL, _ body: () async throws -> T) async throws -> T {
        try beginUse(for: directory)
        defer { endUse() }
        return try await body()
    }

    /// Hands the lease to a child process without a moment in which the lock is free (the in-process recorder's
    /// hand-off to `voiceislocal session diarize --lease-fd 3`, docs/meeting-design.md §4.1). Calls `spawn` with a locked
    /// descriptor that shares the lease's open file description; `spawn` must make the child inherit it (for example
    /// with `posix_spawn_file_actions_adddup2(&actions, descriptor, 3)`). The descriptor is a close-on-exec duplicate
    /// numbered 10 or higher, so it never already has the child's number: `dup2` onto the same number would keep
    /// close-on-exec, and the child would lose the lock at exec. When `spawn` returns, this process closes its
    /// descriptors without unlocking, so the child's copy keeps the lock until the child closes it, and the lease
    /// counts as released here. When `spawn` throws, the lease stays held and the error is rethrown. Throws
    /// `HolosError.invalidInput` (and calls nothing) when the lease was already released.
    public func handOff<T>(_ spawn: (Int32) throws -> T) throws -> T {
        let fd = state.withLock { value -> Int32 in
            guard !value.released, value.descriptor >= 0 else { return -1 }
            // Counted as a use, so a concurrent `release()` cannot unlock or close the descriptor under `spawn`.
            value.users += 1
            return value.descriptor
        }
        guard fd >= 0 else {
            throw HolosError.invalidInput("The processing lease was already released; acquire a new one.")
        }
        let result: T
        do {
            let spare = fcntl(fd, F_DUPFD_CLOEXEC, Self.handOffMinimumDescriptor)
            guard spare >= 0 else {
                throw HolosError.io("Cannot hand the processing lease over: \(AtomicFile.errnoText()).")
            }
            // Closing the duplicate never unlocks: the lease's own descriptor still refers to the description.
            defer { Darwin.close(spare) }
            result = try spawn(spare)
        } catch {
            endUse()
            throw error
        }
        let handed = state.withLock { value -> Int32 in
            value.users -= 1
            value.released = true
            // The child owns the lock now; this descriptor is only closed, never unlocked.
            let descriptor = value.descriptor
            value.descriptor = -1
            return descriptor
        }
        if handed >= 0 { Darwin.close(handed) }
        return result
    }

    /// The lowest number `handOff` gives its descriptor: above the standard streams and the conventional fd 3.
    static let handOffMinimumDescriptor: Int32 = 10

    /// Unlocks (unless adopted) and closes `fd`; nothing for -1.
    private func letGo(_ fd: Int32) {
        guard fd >= 0 else { return }
        if unlocksOnRelease {
            SessionLockFile.unlockAndClose(fd)
        } else {
            Darwin.close(fd)
        }
    }

    /// False once `release()` was called.
    var isHeld: Bool { state.withLock { !$0.released } }

    /// Starts an operation under the lease, which keeps the lock held until the matching `endUse()` even if
    /// `release()` is called meanwhile. Throws `HolosError.invalidInput` (and starts nothing) unless this lease is
    /// not released and was taken for `directory`: the folder `directory` opens to through
    /// `AtomicFile.openFolder` (never through a symbolic link in its place) must have the device and inode
    /// (`fstat`) of the folder the lease was taken in.
    func beginUse(for directory: URL) throws {
        let started = state.withLock { value -> Bool in
            guard !value.released else { return false }
            value.users += 1
            return true
        }
        guard started else {
            throw HolosError.invalidInput("The processing lease was already released; acquire a new one.")
        }
        do {
            let fd = try SessionLockFile.openSessionFolder(directory)
            defer { Darwin.close(fd) }
            guard try FileIdentity(descriptor: fd) == folder else {
                throw HolosError.invalidInput("The processing lease belongs to another session.")
            }
        } catch {
            endUse()
            throw error
        }
    }

    /// Ends an operation started by `beginUse(for:)`; the last one to end after `release()` unlocks.
    func endUse() {
        let fd = state.withLock { value -> Int32 in
            precondition(value.users > 0, "ProcessingLease.endUse without beginUse")
            value.users -= 1
            return value.takeIfIdle()
        }
        letGo(fd)
    }

    /// A check only, for tests: `beginUse(for:)` then `endUse()`. Work that relies on the lease runs between
    /// `beginUse` and `endUse` instead, so a concurrent `release()` cannot unlock under it.
    func require(for directory: URL) throws {
        try beginUse(for: directory)
        endUse()
    }
}

extension SessionArchive {
    /// Throws `HolosError.unavailable("Another Voice is Local process is processing this session.")` after `retry`.
    public nonisolated static func acquireProcessingLease(at session: URL,
                                                          retry: Duration = .seconds(1)) throws -> ProcessingLease {
        try SessionLockFile.requireSession(session)
        // The lock file and the lease's folder identity come from one descriptor of the session folder.
        let folder = try SessionLockFile.openSessionFolder(session)
        defer { Darwin.close(folder) }
        let identity = try FileIdentity(descriptor: folder)
        guard let fd = try SessionLockFile.acquire(SessionLockFile.processing, inFolder: folder,
                                                   timeout: retry) else {
            throw HolosError.unavailable("Another Voice is Local process is processing this session.")
        }
        return ProcessingLease(session: session, folder: identity, descriptor: fd)
    }

    /// Like `acquireProcessingLease(at:retry:)`, in the session folder open as `folder` (not closed) rather than
    /// wherever `session` leads: the lock file and the lease's folder identity both come from `folder`. `session` is
    /// only the name the lease reports. The folder must hold a plain `manifest.json`.
    public nonisolated static func acquireProcessingLease(inFolder folder: Int32, session: URL,
                                                          retry: Duration = .seconds(1)) throws -> ProcessingLease {
        var info = stat()
        guard fstatat(folder, "manifest.json", &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("\(session.lastPathComponent) is not a Voice is Local session folder.")
        }
        let identity = try FileIdentity(descriptor: folder)
        guard let fd = try SessionLockFile.acquire(SessionLockFile.processing, inFolder: folder,
                                                   timeout: retry) else {
            throw HolosError.unavailable("Another Voice is Local process is processing this session.")
        }
        return ProcessingLease(session: session, folder: identity, descriptor: fd)
    }

    /// Adopts `descriptor`, inherited from a parent that handed its lease over (`ProcessingLease.handOff`,
    /// `voiceislocal session diarize --lease-fd`, docs/meeting-design.md §4.1), as this process's lease, without acquiring
    /// one (the lease is not re-entrant).
    ///
    /// Refuses with `HolosError.invalidInput("The inherited lock is not this session's processing lease.")` unless
    /// `fstat(descriptor)` has the device and inode of this session's `.processing.lock` (reached through the folder
    /// chain) and `flock(descriptor, LOCK_EX | LOCK_NB)` succeeds, which it does at once when the descriptor shares
    /// the parent's locked open file description. A refused descriptor is left open and unchanged.
    ///
    /// The adopted descriptor gets close-on-exec again (inheriting it cleared the flag) and belongs to the lease:
    /// `release()` closes it without unlocking, so the lock ends when every process sharing the description has
    /// closed it.
    public nonisolated static func adoptProcessingLease(at session: URL, descriptor: Int32) throws -> ProcessingLease {
        let foreign = HolosError.invalidInput("The inherited lock is not this session's processing lease.")
        try SessionLockFile.requireSession(session)
        let folder = try SessionLockFile.openSessionFolder(session)
        defer { Darwin.close(folder) }
        let identity = try FileIdentity(descriptor: folder)
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let leaseFile = try AtomicFile.identity(of: SessionLockFile.processing, in: folder),
              FileIdentity(info) == leaseFile else {
            throw foreign
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            throw foreign
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw HolosError.io("Cannot protect the inherited lock: \(AtomicFile.errnoText()).")
        }
        return ProcessingLease(session: session, folder: identity, descriptor: descriptor, unlocksOnRelease: false)
    }

    /// True while some process holds the processing lease. A probe: it takes the lock without waiting and
    /// releases it at once, which cannot make a concurrent acquisition fail (acquisitions retry).
    public nonisolated static func isProcessing(at session: URL) throws -> Bool {
        try SessionLockFile.isHeld(SessionLockFile.processing, in: session)
    }

    /// Polls `flock(LOCK_EX|LOCK_NB)` every 20 ms up to `timeout`, runs `body`, unlocks.
    /// Throws `HolosError.unavailable("Speaker labels are being saved by another Voice is Local window or command; try again.")`.
    /// Not re-entrant: never call it, or anything that takes the speaker lock, from inside `body`.
    public nonisolated static func withSpeakerLock<T>(at session: URL, timeout: Duration = .seconds(2),
                                                      _ body: () throws -> T) throws -> T {
        try SessionLockFile.requireSession(session)
        guard let fd = try SessionLockFile.acquire(SessionLockFile.speakers, in: session, timeout: timeout) else {
            throw HolosError.unavailable("Speaker labels are being saved by another Voice is Local window or command; try again.")
        }
        defer { SessionLockFile.unlockAndClose(fd) }
        return try body()
    }
}

/// `flock` files in the session folder (docs/meeting-design.md §1.7).
enum SessionLockFile {
    static let writer = ".writer.lock"
    static let processing = ".processing.lock"
    static let speakers = ".speakers.lock"

    private static let pollInterval: Duration = .milliseconds(20)
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "storage")

    /// Test hook: while set (a task-local value), `acquire` calls it once when its first attempt finds the lock
    /// held, before it starts waiting.
    @TaskLocal static var onContention: (@Sendable () -> Void)? = nil

    /// Opens (creating it 0600 if needed) the lock file `name` in `session` and takes `LOCK_EX`, polling every
    /// 20 ms until `timeout`. Returns the locked descriptor (O_CLOEXEC), or nil when another holder kept the lock
    /// for the whole timeout. Always makes at least one attempt.
    static func acquire(_ name: String, in session: URL, timeout: Duration) throws -> Int32? {
        let folder = try openSessionFolder(session)
        defer { Darwin.close(folder) }
        return try acquire(name, inFolder: folder, timeout: timeout)
    }

    /// Like `acquire(_:in:timeout:)`, in the open session folder `folder` (not closed).
    static func acquire(_ name: String, inFolder folder: Int32, timeout: Duration) throws -> Int32? {
        guard let fd = try openLockFile(name, inFolder: folder, create: true) else {
            throw HolosError.io("Cannot open the session lock: \(AtomicFile.errnoText(ENOENT)).")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))
        var contended = false
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else {
                Darwin.close(fd)
                throw HolosError.io("Cannot lock the session: \(AtomicFile.errnoText(code)).")
            }
            if !contended {
                contended = true
                onContention?()
            }
            let now = clock.now
            guard now < deadline else {
                Darwin.close(fd)
                return nil
            }
            pause(min(pollInterval, now.duration(to: deadline)))
        }
    }

    /// True when another open file description holds the lock. Missing lock file → false.
    static func isHeld(_ name: String, in session: URL) throws -> Bool {
        guard let fd = try openLockFile(name, in: session, create: false) else { return false }
        defer { Darwin.close(fd) }
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                return false
            }
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK { return true }
            throw HolosError.io("Cannot inspect the session lock: \(AtomicFile.errnoText(code)).")
        }
    }

    static func unlockAndClose(_ fd: Int32) {
        if flock(fd, LOCK_UN) != 0 {
            log.error("Cannot unlock a session lock: \(AtomicFile.errnoText(), privacy: .public)")
        }
        Darwin.close(fd)
    }

    /// Opens the lock file `name` in the session folder, which is opened with `AtomicFile.openFolder` (O_NOFOLLOW),
    /// relative to it with `openat` and O_NOFOLLOW; with `create`, makes it 0600 if missing. Nil when it does not
    /// exist and `create` is false. Refuses anything but a regular file (O_NONBLOCK keeps a FIFO from blocking).
    private static func openLockFile(_ name: String, in session: URL, create: Bool) throws -> Int32? {
        let folder = try openSessionFolder(session)
        defer { Darwin.close(folder) }
        return try openLockFile(name, inFolder: folder, create: create)
    }

    private static func openLockFile(_ name: String, inFolder folder: Int32, create: Bool) throws -> Int32? {
        let flags = create ? O_CREAT | O_RDWR : O_RDONLY
        var fd = openat(folder, name, flags | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        // When two threads create the same new lock file at once, macOS can fail the second O_CREAT open with
        // ENOENT although the file then exists; opening again finds it.
        var retries = 3
        while fd < 0, create, errno == ENOENT, retries > 0 {
            retries -= 1
            fd = openat(folder, name, flags | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT, !create { return nil }
            throw HolosError.io("Cannot open the session lock: \(AtomicFile.errnoText(code)).")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw HolosError.invalidInput("The session lock \(name) is not a regular file.")
        }
        return fd
    }

    /// Opens the session folder with `AtomicFile.openFolder` (never through a symbolic link in its place).
    /// The caller closes the descriptor.
    static func openSessionFolder(_ session: URL) throws -> Int32 {
        let notAFolder = HolosError.invalidInput("The session folder is missing or is not a regular folder.")
        guard session.isFileURL else { throw notAFolder }
        let fd: Int32?
        do {
            fd = try AtomicFile.openFolder(session)
        } catch HolosError.invalidInput {
            throw notAFolder
        }
        guard let fd else { throw notAFolder }
        return fd
    }

    /// The session folder must exist and be a real folder (not a symlink).
    static func requireSessionFolder(_ session: URL) throws {
        Darwin.close(try openSessionFolder(session))
    }

    /// Like `requireSessionFolder`, and the folder must hold a plain `manifest.json`, so taking a lease or the
    /// speaker lock never leaves a lock file in a folder that is not a session.
    static func requireSession(_ session: URL) throws {
        let folder = try openSessionFolder(session)
        defer { Darwin.close(folder) }
        var info = stat()
        guard fstatat(folder, "manifest.json", &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("\(session.lastPathComponent) is not a Voice is Local session folder.")
        }
    }

    private static func pause(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        guard seconds > 0 || attoseconds > 0 else { return }
        var request = timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1_000_000_000))
        var remaining = timespec()
        while nanosleep(&request, &remaining) != 0 && errno == EINTR { request = remaining }
    }
}
