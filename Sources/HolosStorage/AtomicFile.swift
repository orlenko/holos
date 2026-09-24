import Foundation
import Darwin
import os
import HolosCore

/// Crash-safe file writes shared by every Holos file (docs/meeting-design.md §1.7).
///
/// Whole files are published by renaming a fsync'd same-directory temporary file, so a reader sees either the
/// old or the new contents. Journal appends never leave a partial line: a failed append truncates back.
/// Appends to one file must be serialized by the caller (the writer or speaker lock).
public enum AtomicFile {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "storage")

    /// Test hook: while set (a task-local value), an append writes at most this many bytes and then fails
    /// as a full disk would, so tests can check that a failed append leaves no partial line.
    @TaskLocal static var appendFailureAfterBytes: Int? = nil

    /// Writes a same-directory temporary file (O_CREAT|O_EXCL|O_CLOEXEC, `permissions`), fsyncs it,
    /// renames it over `url`, and fsyncs the directory. Leaves no temporary file on failure.
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        try publish(data, to: url, permissions: permissions, exclusive: false)
    }

    /// Like `write`, but fails with `HolosError.invalidInput` if `url` exists
    /// (renamex_np with RENAME_EXCL). For immutable files such as runs.
    public static func create(_ data: Data, at url: URL, permissions: mode_t = 0o600) throws {
        try publish(data, to: url, permissions: permissions, exclusive: true)
    }

    /// Appends with O_APPEND|O_NOFOLLOW|O_CLOEXEC. Records the size first; on any failure (short write,
    /// ENOSPC, fsync error) truncates back to that size before throwing, so a failed append never
    /// leaves a partial line. Creates the file (0600) if missing. `sync: false` skips the fsync.
    public static func append(_ data: Data, to url: URL, permissions: mode_t = 0o600, sync: Bool = true) throws {
        guard url.isFileURL else { throw HolosError.invalidInput("Journal path must be a file URL.") }
        let (fd, created) = try openForAppend(url, permissions: permissions)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not a regular file.")
        }
        let originalSize = info.st_size
        do {
            try writeAll(data, fd: fd, failAfter: appendFailureAfterBytes)
            if sync {
                guard fsync(fd) == 0 else {
                    throw HolosError.io("Cannot save \(url.lastPathComponent): \(errnoText()).")
                }
                if created { try syncDirectory(url.deletingLastPathComponent()) }
            }
        } catch {
            if ftruncate(fd, originalSize) == 0 {
                _ = fsync(fd)
                log.error("Append failed; the journal was truncated back to \(originalSize, privacy: .public) bytes")
            } else {
                log.fault("Append failed and the journal could not be truncated back: \(errnoText(), privacy: .public)")
            }
            throw error
        }
    }

    /// Creates `url` and missing parents as 0700 directories; refuses symlinks and non-directories.
    /// Ancestors that already exist are only required to be directories (they may be reached through
    /// a symlink, as `/var` is on macOS).
    public static func ensurePrivateDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw HolosError.invalidInput("Folder path must be a file URL.") }
        let path = url.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw HolosError.invalidInput("\(url.lastPathComponent) must be a folder, not a file or a symbolic link.")
            }
            return
        }
        guard errno == ENOENT else {
            throw HolosError.io("Cannot inspect folder \(url.lastPathComponent): \(errnoText()).")
        }
        let parent = url.deletingLastPathComponent()
        try ensureExistingOrPrivateParent(parent)
        if mkdir(path, 0o700) != 0 {
            let code = errno
            guard code == EEXIST else {
                throw HolosError.io("Cannot create folder \(url.lastPathComponent): \(errnoText(code)).")
            }
            // Created concurrently by another process; accept it only if it is a real folder.
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw HolosError.invalidInput("\(url.lastPathComponent) must be a folder, not a file or a symbolic link.")
            }
            return
        }
        guard chmod(path, 0o700) == 0 else {
            throw HolosError.io("Cannot make folder \(url.lastPathComponent) private: \(errnoText()).")
        }
        try syncDirectory(parent)
    }

    /// `write(HolosJSON.encoder().encode(value), to: url)`.
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL, permissions: mode_t = 0o600) throws {
        try write(HolosJSON.encoder().encode(value), to: url, permissions: permissions)
    }

    /// Reads a regular file (lstat, no symlinks) of at most `maxBytes` and decodes it with HolosJSON.
    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL, maxBytes: Int = 64 << 20) throws -> T {
        guard let data = try readIfPresent(url, maxBytes: maxBytes) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) does not exist.")
        }
        return try decode(type, from: data, name: url.lastPathComponent)
    }

    // MARK: - Internal helpers

    /// Decodes with HolosJSON, turning a decoding error into `HolosError.invalidInput` that names the file.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, name: String) throws -> T {
        do {
            return try HolosJSON.decoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw HolosError.invalidInput("\(name) is damaged or was not written by Holos (\(describe(error))).")
        } catch {
            throw HolosError.invalidInput("\(name) is damaged or was not written by Holos.")
        }
    }

    /// Reads a regular file without following a symlink; nil when it does not exist.
    static func readIfPresent(_ url: URL, maxBytes: Int) throws -> Data? {
        guard url.isFileURL else { throw HolosError.invalidInput("File path must be a file URL.") }
        // O_NONBLOCK keeps a FIFO planted in place of the file from blocking the open.
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP {
                throw HolosError.invalidInput("\(url.lastPathComponent) is a symbolic link; Holos reads only regular files.")
            }
            throw HolosError.io("Cannot open \(url.lastPathComponent): \(errnoText(code)).")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not a regular file.")
        }
        guard info.st_size <= off_t(maxBytes) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is larger than Holos expects.")
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw HolosError.io("Cannot read \(url.lastPathComponent): \(errnoText()).")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maxBytes else {
                throw HolosError.invalidInput("\(url.lastPathComponent) is larger than Holos expects.")
            }
        }
        return data
    }

    /// Truncates a regular file in place to `size` bytes and fsyncs it.
    static func truncate(_ url: URL, to size: Int64) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw HolosError.io("Cannot open \(url.lastPathComponent): \(errnoText()).") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not a regular file.")
        }
        guard ftruncate(fd, off_t(size)) == 0, fsync(fd) == 0 else {
            throw HolosError.io("Cannot repair \(url.lastPathComponent): \(errnoText()).")
        }
    }

    /// Fsyncs an existing regular file, e.g. a journal appended to with `sync: false`.
    static func sync(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw HolosError.io("Cannot open \(url.lastPathComponent): \(errnoText()).") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw HolosError.io("Cannot save \(url.lastPathComponent): \(errnoText()).") }
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw HolosError.io("Cannot open folder \(url.lastPathComponent): \(errnoText()).") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw HolosError.io("Cannot save folder \(url.lastPathComponent): \(errnoText()).") }
    }

    /// Writes all of `data`. With `failAfter`, writes at most that many bytes and then throws (test hook).
    static func writeAll(_ data: Data, fd: Int32, failAfter: Int? = nil) throws {
        try data.withUnsafeBytes { bytes in
            let total = bytes.count
            let limit = failAfter.map { min(max($0, 0), total) } ?? total
            if let base = bytes.baseAddress {
                var offset = 0
                while offset < limit {
                    let count = Darwin.write(fd, base.advanced(by: offset), limit - offset)
                    if count < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        throw HolosError.io("Cannot write file: \(errnoText(code)).")
                    }
                    guard count > 0 else { throw HolosError.io("Cannot write file: no progress.") }
                    offset += count
                }
            }
            if limit < total { throw HolosError.io("Cannot write file: simulated failure.") }
        }
    }

    static func errnoText(_ code: Int32 = errno) -> String { String(cString: strerror(code)) }

    // MARK: - Private

    private static func publish(_ data: Data, to url: URL, permissions: mode_t, exclusive: Bool) throws {
        guard url.isFileURL else { throw HolosError.invalidInput("File path must be a file URL.") }
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, permissions)
        guard fd >= 0 else {
            throw HolosError.io("Cannot create a temporary file for \(url.lastPathComponent): \(errnoText()).")
        }
        var descriptorOpen = true
        do {
            // The creation mode is filtered by the umask; set the exact permissions.
            guard fchmod(fd, permissions) == 0 else {
                throw HolosError.io("Cannot set permissions of \(url.lastPathComponent): \(errnoText()).")
            }
            try writeAll(data, fd: fd)
            guard fsync(fd) == 0 else { throw HolosError.io("Cannot save \(url.lastPathComponent): \(errnoText()).") }
            Darwin.close(fd)
            descriptorOpen = false
            if exclusive {
                try renameExclusive(temporary, to: url)
            } else if rename(temporary.path, url.path) != 0 {
                throw HolosError.io("Cannot publish \(url.lastPathComponent): \(errnoText()).")
            }
        } catch {
            if descriptorOpen { Darwin.close(fd) }
            unlink(temporary.path)
            throw error
        }
        try syncDirectory(directory)
    }

    private static func renameExclusive(_ temporary: URL, to url: URL) throws {
        if renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 { return }
        var code = errno
        if code == ENOTSUP || code == EINVAL {
            // Volumes without RENAME_EXCL: a hard link is also exclusive and atomic.
            if link(temporary.path, url.path) == 0 {
                unlink(temporary.path)
                return
            }
            code = errno
        }
        if code == EEXIST {
            throw HolosError.invalidInput("\(url.lastPathComponent) already exists and is never replaced.")
        }
        throw HolosError.io("Cannot publish \(url.lastPathComponent): \(errnoText(code)).")
    }

    private static func openForAppend(_ url: URL, permissions: mode_t) throws -> (fd: Int32, created: Bool) {
        let flags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        var fd = Darwin.open(url.path, flags)
        var created = false
        if fd < 0 && errno == ENOENT {
            fd = Darwin.open(url.path, flags | O_CREAT | O_EXCL, permissions)
            if fd >= 0 {
                created = true
                guard fchmod(fd, permissions) == 0 else {
                    let message = errnoText()
                    Darwin.close(fd)
                    throw HolosError.io("Cannot set permissions of \(url.lastPathComponent): \(message).")
                }
            } else if errno == EEXIST {
                fd = Darwin.open(url.path, flags)
            }
        }
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP {
                throw HolosError.invalidInput("\(url.lastPathComponent) is a symbolic link; Holos appends only to regular files.")
            }
            throw HolosError.io("Cannot open \(url.lastPathComponent) for appending: \(errnoText(code)).")
        }
        return (fd, created)
    }

    private static func ensureExistingOrPrivateParent(_ url: URL) throws {
        var info = stat()
        if stat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw HolosError.invalidInput("\(url.lastPathComponent) must be a folder.")
            }
            return
        }
        guard errno == ENOENT else {
            throw HolosError.io("Cannot inspect folder \(url.lastPathComponent): \(errnoText()).")
        }
        try ensurePrivateDirectory(url)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            codingPath.isEmpty ? "top level" : codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
                .joined(separator: ".")
        }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])): missing"
        @unknown default:
            return "unreadable JSON"
        }
    }
}
