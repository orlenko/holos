import Darwin
import Foundation
import HolosCore

/// Moves a finished file into place without ever replacing a file that is already there, and
/// without needing hard links (exFAT and many network volumes have none). Every file the speech
/// renderer and the reading pipeline publish (a rendered part, a finished reading) goes through
/// `publish`.
public enum ExclusivePublisher {
    /// Renames the first path to the second, failing with EEXIST when the second exists.
    public typealias ExclusiveRename = @Sendable (String, String) -> Int32

    public static let systemExclusiveRename: ExclusiveRename = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }

    /// Which file a path named at one moment: its volume, inode, and creation time. A file
    /// removed and another created at the same path (even reusing the inode number) compare unequal.
    public struct FileIdentity: Codable, Sendable, Equatable {
        public let device: Int64
        public let inode: UInt64
        public let birthSeconds: Int64
        public let birthNanoseconds: Int64

        public init(_ metadata: stat) {
            device = Int64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
            birthSeconds = Int64(metadata.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(metadata.st_birthtimespec.tv_nsec)
        }

        /// The regular file at `url` (a link is not followed), or nil.
        public static func of(_ url: URL) -> FileIdentity? {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else { return nil }
            return FileIdentity(metadata)
        }

        /// The regular file at `url` (a link is not followed); nil when nothing is there or it is not a regular
        /// file. Any other failure (an I/O error, a stale handle on a network volume, a permission) throws: it says
        /// nothing about which file is there.
        public static func lookup(_ url: URL) throws -> FileIdentity? {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                let error = errno
                if error == ENOENT { return nil }
                throw HolosError.io("Could not check \(url.path): \(String(cString: strerror(error)))")
            }
            return (metadata.st_mode & S_IFMT) == S_IFREG ? FileIdentity(metadata) : nil
        }
    }

    /// How the fallback copy runs: its chunk size, and a hook called with each chunk's number
    /// after it is written (tests slow the copy down or cancel it there).
    struct CopyPacing: Sendable {
        var chunkSize = 1 << 20
        var afterChunk: @Sendable (Int) -> Void = { _ in }
    }

    /// Moves `source` to `destination`. `source` must be in the destination's directory (every
    /// caller writes it there), so the move never crosses volumes. The rename is exclusive
    /// (`renamex_np` with `RENAME_EXCL`). Volumes that cannot rename exclusively get the
    /// destination created exclusively (`O_EXCL`) and the bytes copied into that open file (never
    /// a plain rename or a hard link: a rename over the pathname would replace whatever is there
    /// by then, and many such volumes have no hard links); `claimed` gets the new file's identity
    /// before any byte is written, so a copy a crash cuts off can be recognized later. On failure
    /// only that file is removed, and only while it is still the one at `destination`. `source`
    /// is removed once published. A file already at `destination` fails with `existing` and the
    /// path.
    ///
    /// `isCancelled` is asked between chunks of the copy; when it says yes, the copy stops with
    /// `CancellationError` and the partial file is removed (as on any failure). It must report the
    /// cancellation of whoever asked for the file: the default, the current task's, is right only
    /// when the caller is that task (a render finished from a delegate callback passes its own).
    public static func publish(_ source: URL, to destination: URL,
                               exclusiveRename: ExclusiveRename = systemExclusiveRename,
                               existing: String = "Output already exists",
                               isCancelled: () -> Bool = { Task.isCancelled },
                               claimed: (FileIdentity) throws -> Void = { _ in }) throws {
        try publish(source, to: destination, exclusiveRename: exclusiveRename, existing: existing,
                    isCancelled: isCancelled, pacing: CopyPacing(), claimed: claimed)
    }

    static func publish(_ source: URL, to destination: URL,
                        exclusiveRename: ExclusiveRename, existing: String,
                        isCancelled: () -> Bool, pacing: CopyPacing,
                        claimed: (FileIdentity) throws -> Void = { _ in }) throws {
        if exclusiveRename(source.path, destination.path) == 0 { return }
        let error = errno
        guard error == ENOTSUP || error == EINVAL || error == ENOSYS else {
            throw failure(destination, error, existing: existing)
        }
        try copyExclusively(source, to: destination, existing: existing, isCancelled: isCancelled,
                            pacing: pacing, claimed: claimed)
        _ = unlink(source.path)
    }

    /// What `removeVerified` did.
    public enum Removal: Sendable, Equatable {
        /// The file was the one asked for, and it is gone (or `dispose` took it).
        case removed
        /// Nothing was at the path.
        case absent
        /// The file there was another one: it was put back untouched, or, when that failed, is kept at `keptAt`.
        case notMatching(keptAt: String?)
        /// It could not be moved aside, or `dispose` failed (`reason`): it is back in place, or, when that failed,
        /// kept at `keptAt`.
        case failed(reason: String, keptAt: String?)

        /// Whether no file of the one asked for is at the path any more.
        public var isGone: Bool {
            switch self {
            case .removed, .absent, .notMatching: true
            case .failed: false
            }
        }
    }

    /// The prefix of the name a file is moved aside to (see `removeVerified`).
    public static let removalPrefix = ".holos-delete-"
    /// The longest name `removeVerified` writes beside the file: its private folder, or the file's new name (a
    /// caller's `token` is at most `removalPrefix`, a UUID, and a short suffix such as ".partial").
    public static let removalNameLength = (removalPrefix + UUID().uuidString + ".partial").utf8.count

    /// Removes the file at `url` only when it is the very one `matches` accepts. Checking a path and then removing it
    /// are two steps, between which another process (a sync client, a second Mac on a share) could put another file
    /// there, so the file is first moved aside, and checked where nothing else can take its place: into a private
    /// folder (mode 0700) made beside it for this call (same volume, so the file itself moves, not a copy), under its
    /// own name (the Trash shows it). The folder is new and empty when the file is renamed into it, so that rename
    /// replaces nothing, whether or not the volume can rename exclusively.
    /// A file that does not match, that cannot be checked (`matches` throws), or that `dispose` refuses, goes back to
    /// `url` only with an operation that cannot replace a file put there meanwhile (see `restore`); where the volume
    /// has none, it stays aside and the result says where. `dispose` defaults to removing it. Every removal of a
    /// reading's file that depends on which file is there goes through here.
    ///
    /// `token` names the private folder (it starts with `removalPrefix`; default: a new UUID). A caller that must
    /// find a file left there after a crash (a reading's Delete) gives one it can derive again; when something is
    /// already there, nothing is moved.
    public static func removeVerified(_ url: URL, token: String? = nil, matches: (URL) throws -> Bool,
                                      dispose: (URL) throws -> Void = removeFile) -> Removal {
        let folder = url.deletingLastPathComponent()
        let holding = spelled(folder.path + "/" + (token ?? removalPrefix + UUID().uuidString), isDirectory: true)
        guard mkdir(holding.path, 0o700) == 0 else {
            return .failed(reason: String(cString: strerror(errno)), keptAt: nil)
        }
        // Removed when empty: a file that could not go back stays in it, named in the result.
        defer { _ = rmdir(holding.path) }
        let staged = spelled(holding.path + "/" + url.lastPathComponent)
        guard rename(url.path, staged.path) == 0 else {
            let error = errno
            return error == ENOENT ? .absent : .failed(reason: String(cString: strerror(error)), keptAt: nil)
        }
        let isOwn: Bool
        do {
            isOwn = try matches(staged)
        } catch {
            return .failed(reason: error.localizedDescription, keptAt: restore(staged, to: url))
        }
        guard isOwn else { return .notMatching(keptAt: restore(staged, to: url)) }
        do {
            try dispose(staged)
        } catch {
            return .failed(reason: error.localizedDescription, keptAt: restore(staged, to: url))
        }
        return .removed
    }

    /// Moves `staged` back to `url` without ever replacing a file there: an exclusive rename, else (a volume without
    /// one) a hard link to `url`, which fails when anything is there, and then the staged name removed. Nil when it
    /// is back; else where it is kept (a file took its place, or the volume has neither). The calls are parameters
    /// for tests (a volume without them).
    static func restore(_ staged: URL, to url: URL, exclusiveRename: ExclusiveRename = systemExclusiveRename,
                        hardLink: (String, String) -> Int32 = { link($0, $1) }) -> String? {
        if exclusiveRename(staged.path, url.path) == 0 { return nil }
        guard errno == ENOTSUP || errno == EINVAL || errno == ENOSYS else { return staged.path }
        guard hardLink(staged.path, url.path) == 0 else { return staged.path }
        // A second name left aside keeps the file's data alive: it is reported, for the caller to deal with.
        return unlink(staged.path) == 0 ? nil : staged.path
    }

    /// `unlink`, for `removeVerified`; a file already gone is not an error.
    public static func removeFile(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw HolosError.io("Could not remove \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Removes `url` when it is still the file `identity` describes (see `removeVerified`); anything else is kept.
    /// Checked before it is moved too, so another file at the path is never moved at all (on a volume that can
    /// neither rename exclusively nor link, it could not be put back); one that cannot be checked is a failure.
    @discardableResult
    public static func removeIfIdentical(_ url: URL, to identity: FileIdentity, token: String? = nil) -> Removal {
        do {
            guard let current = try FileIdentity.lookup(url) else {
                var metadata = stat()
                return lstat(url.path, &metadata) == 0 ? .notMatching(keptAt: nil) : .absent
            }
            guard current == identity else { return .notMatching(keptAt: nil) }
        } catch {
            return .failed(reason: error.localizedDescription, keptAt: nil)
        }
        return removeVerified(url, token: token) { staged in try FileIdentity.lookup(staged) == identity }
    }

    /// A file URL whose path keeps `path`'s bytes as given (`URL(fileURLWithPath:)` would decompose its names).
    private static func spelled(_ path: String, isDirectory: Bool = false) -> URL {
        path.withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: isDirectory, relativeTo: nil) }
    }

    private static func copyExclusively(_ source: URL, to destination: URL, existing: String,
                                        isCancelled: () -> Bool, pacing: CopyPacing,
                                        claimed: (FileIdentity) throws -> Void) throws {
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw failure(source, errno, existing: existing) }
        defer { close(input) }
        let output = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o666)
        guard output >= 0 else { throw failure(destination, errno, existing: existing) }
        var metadata = stat()
        guard fstat(output, &metadata) == 0 else {
            // Without its identity, this empty file cannot be told apart from one put in its
            // place, so it is left alone.
            let error = errno
            close(output)
            throw failure(destination, error, existing: existing)
        }
        let identity = FileIdentity(metadata)
        var isOpen = true
        do {
            try claimed(identity)
            try copy(from: input, to: output, destination: destination, existing: existing,
                     isCancelled: isCancelled, pacing: pacing)
            if fsync(output) != 0, errno != ENOTSUP, errno != EINVAL {
                throw failure(destination, errno, existing: existing)
            }
            isOpen = false
            if close(output) != 0 { throw failure(destination, errno, existing: existing) }
            guard FileIdentity.of(destination) == identity else {
                throw HolosError.io("\(destination.path) was replaced while it was being saved; the other file is kept.")
            }
        } catch {
            if isOpen { close(output) }
            removeIfIdentical(destination, to: identity)
            throw error
        }
    }

    private static func copy(from input: Int32, to output: Int32, destination: URL, existing: String,
                             isCancelled: () -> Bool, pacing: CopyPacing) throws {
        let size = max(1, pacing.chunkSize)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var chunk = 0
        while true {
            // A cancelled render or reading (Ctrl-C) stops here, and the partial copy is removed.
            if isCancelled() { throw CancellationError() }
            let count = read(input, buffer, size)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure(destination, errno, existing: existing)
            }
            var offset = 0
            while offset < count {
                let written = write(output, buffer + offset, count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure(destination, errno, existing: existing)
                }
                offset += written
            }
            chunk += 1
            pacing.afterChunk(chunk)
        }
    }

    private static func failure(_ destination: URL, _ error: Int32, existing: String) -> HolosError {
        if error == EEXIST { return .invalidInput("\(existing): \(destination.path)") }
        return .io("Could not save \(destination.path): \(String(cString: strerror(error)))")
    }
}
