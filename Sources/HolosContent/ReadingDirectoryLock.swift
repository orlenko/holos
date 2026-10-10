import Darwin
import Foundation
import HolosCore

/// A sibling lock serializes new renders and resumes of one cache across processes: `flock` on a
/// hidden file in the cache's parent (the support folder). The file is intentionally kept so
/// another process cannot lock a replacement inode. An explicit output is reserved separately,
/// beside the destination (see `ReadingOutputReservation`).
final class ReadingDirectoryLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// A hash of the directory's filesystem identity (see `ReadingPathIdentity`).
    static func key(for directory: URL) -> String {
        sha256(Data(ReadingPathIdentity.key(directory).utf8))
    }

    /// `.holos-reading-<key>.lock`, in the cache's parent.
    static func lockName(key: String) -> String { ".holos-reading-\(key).lock" }

    static func acquire(for directory: URL) throws -> ReadingDirectoryLock {
        try acquire(name: lockName(key: key(for: directory)), beside: directory,
                    busy: "Reading directory is already being rendered: \(directory.path)")
    }

    /// Takes the place of `flock(descriptor, LOCK_EX | LOCK_NB)` on the lock file at `path` (tests).
    @TaskLocal static var lockCall: (@Sendable (_ path: String, _ descriptor: Int32) -> Int32)? = nil

    /// The folder a cache's locks are kept in: the cache's parent, links resolved.
    static func folder(beside directory: URL) -> URL {
        directory.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// The lock of the cache whose `key` is given, in `folder`, when no run holds it; else nil.
    static func acquireIfIdle(key: String, in folder: URL) -> ReadingDirectoryLock? {
        try? acquire(name: lockName(key: key), in: folder, busy: "")
    }

    private static func acquire(name: String, beside directory: URL, busy: String) throws -> ReadingDirectoryLock {
        try acquire(name: name, in: folder(beside: directory), busy: busy)
    }

    /// Opens (creating if needed) and locks `name` in `parent`.
    private static func acquire(name: String, in parent: URL, busy: String) throws -> ReadingDirectoryLock {
        let path = parent.appendingPathComponent(name).path
        var descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if descriptor < 0 && errno == EEXIST {
            descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw HolosError.io("Could not open reading lock: \(String(cString: strerror(errno)))")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(descriptor)
            throw HolosError.io("Reading lock is not a regular file owned by this user.")
        }
        guard (lockCall?(path, descriptor) ?? flock(descriptor, LOCK_EX | LOCK_NB)) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw HolosError.unavailable(busy)
            }
            throw HolosError.io("Could not acquire reading lock: \(String(cString: strerror(error)))")
        }
        return ReadingDirectoryLock(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
