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
    /// The locked descriptor, or -1 once released.
    private let descriptor: Mutex<Int32>

    init(session: URL, descriptor: Int32) {
        self.session = session
        self.descriptor = Mutex(descriptor)
    }

    deinit { release() }

    /// Releases the lease. Later calls do nothing.
    public func release() {
        let fd = descriptor.withLock { value -> Int32 in
            let current = value
            value = -1
            return current
        }
        if fd >= 0 { SessionLockFile.unlockAndClose(fd) }
    }

    var isHeld: Bool { descriptor.withLock { $0 >= 0 } }

    /// Throws `HolosError.invalidInput` unless this lease is held and was taken for `directory`.
    func require(for directory: URL) throws {
        guard isHeld else {
            throw HolosError.invalidInput("The processing lease was already released; acquire a new one.")
        }
        guard SessionLockFile.sameFolder(session, directory) else {
            throw HolosError.invalidInput("The processing lease belongs to another session.")
        }
    }
}

extension SessionArchive {
    /// Throws `HolosError.unavailable("Another Holos process is processing this session.")` after `retry`.
    public nonisolated static func acquireProcessingLease(at session: URL,
                                                          retry: Duration = .seconds(1)) throws -> ProcessingLease {
        guard let fd = try SessionLockFile.acquire(SessionLockFile.processing, in: session, timeout: retry) else {
            throw HolosError.unavailable("Another Holos process is processing this session.")
        }
        return ProcessingLease(session: session, descriptor: fd)
    }

    /// True while some process holds the processing lease. A probe: it takes the lock without waiting and
    /// releases it at once, which cannot make a concurrent acquisition fail (acquisitions retry).
    public nonisolated static func isProcessing(at session: URL) throws -> Bool {
        try SessionLockFile.isHeld(SessionLockFile.processing, in: session)
    }

    /// Polls `flock(LOCK_EX|LOCK_NB)` every 20 ms up to `timeout`, runs `body`, unlocks.
    /// Throws `HolosError.unavailable("Speaker labels are being saved by another Holos window or command; try again.")`.
    /// Not re-entrant: never call it, or anything that takes the speaker lock, from inside `body`.
    public nonisolated static func withSpeakerLock<T>(at session: URL, timeout: Duration = .seconds(2),
                                                      _ body: () throws -> T) throws -> T {
        guard let fd = try SessionLockFile.acquire(SessionLockFile.speakers, in: session, timeout: timeout) else {
            throw HolosError.unavailable("Speaker labels are being saved by another Holos window or command; try again.")
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

    /// Opens (creating it 0600 if needed) the lock file `name` in `session` and takes `LOCK_EX`, polling every
    /// 20 ms until `timeout`. Returns the locked descriptor (O_CLOEXEC), or nil when another holder kept the lock
    /// for the whole timeout. Always makes at least one attempt.
    static func acquire(_ name: String, in session: URL, timeout: Duration) throws -> Int32? {
        try requireSessionFolder(session)
        let path = session.appendingPathComponent(name, isDirectory: false).path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw HolosError.io("Cannot open the session lock: \(AtomicFile.errnoText()).")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, .zero))
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else {
                Darwin.close(fd)
                throw HolosError.io("Cannot lock the session: \(AtomicFile.errnoText(code)).")
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
        try requireSessionFolder(session)
        let path = session.appendingPathComponent(name, isDirectory: false).path
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return false }
            throw HolosError.io("Cannot inspect the session lock: \(AtomicFile.errnoText()).")
        }
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

    /// The session folder must exist and be a real folder (not a symlink).
    static func requireSessionFolder(_ session: URL) throws {
        var info = stat()
        guard session.isFileURL, lstat(session.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw HolosError.invalidInput("The session folder is missing or is not a regular folder.")
        }
    }

    /// Whether two URLs name the same folder (same device and inode), whatever their spelling.
    static func sameFolder(_ first: URL, _ second: URL) -> Bool {
        var a = stat()
        var b = stat()
        guard first.isFileURL, second.isFileURL, stat(first.path, &a) == 0, stat(second.path, &b) == 0 else {
            return false
        }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private static func pause(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        guard seconds > 0 || attoseconds > 0 else { return }
        var request = timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1_000_000_000))
        var remaining = timespec()
        while nanosleep(&request, &remaining) != 0 && errno == EINTR { request = remaining }
    }
}
