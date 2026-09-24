import Foundation
import Darwin
import Synchronization
import HolosCore

/// The one way Holos opens a folder inside a session (`<id>.holos`) without following a symbolic link
/// (docs/meeting-design.md §1.7). Every session-local file operation (reads, writes, appends, locks, listings,
/// folder creation, deletes) starts from a descriptor this returns, then works with `openat`/`mkdirat`/`fstatat`
/// relative to it, so a folder swapped for a link during the call cannot redirect it.
extension AtomicFile {
    static let folderFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Test hook: while set (a task-local value), called with the URL of each folder just before
    /// `openFolder(create: true)` makes it with `mkdirat`, so tests can swap a folder on the way for a link.
    @TaskLocal static var beforeFolderCreate: (@Sendable (URL) -> Void)? = nil

    /// Opens the folder `url` and returns its descriptor (O_CLOEXEC; the caller closes it), or nil when it or a
    /// folder on the way does not exist and `create` is false.
    ///
    /// The base is opened by path and may be reached through a symbolic link (as `/var` is on macOS): inside a
    /// session (a folder above `url` is named `<id>.holos`), the folder holding the nearest session folder;
    /// elsewhere the folder holding `url`, or with `create` its nearest existing ancestor. Every folder below the
    /// base, the session folder included, is opened with `openat` and O_NOFOLLOW, so a symbolic link or file in
    /// its place is refused with `HolosError.invalidInput`.
    ///
    /// A session folder bound to a descriptor (`pinSessionFolder`) is not opened by path at all: `url` at or below
    /// it is opened from that descriptor.
    ///
    /// With `create`, each missing folder below the base (never the session folder above `url`) is made with
    /// `mkdirat`, reopened with O_NOFOLLOW, set to 0700 with `fchmod` on its own descriptor, and its parent is
    /// fsync'd; if a step after `mkdirat` fails, the new folder is removed again, so a retry creates it and fsyncs
    /// its parent (a folder that cannot be removed has its parent fsync'd then, or on the next open).
    static func openFolder(_ url: URL, create: Bool = false) throws -> Int32? {
        guard url.isFileURL else { throw HolosError.invalidInput("Folder path must be a file URL.") }
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/",
              !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HolosError.invalidInput("Invalid folder path.")
        }
        if let (pinned, sessionURL, below) = try pinnedSessionFolder(for: url) {
            // A pinned session folder is never reached by path: everything below it is opened from its descriptor.
            defer { Darwin.close(pinned) }
            return try openFolder(below, in: pinned, baseURL: sessionURL, create: create)
        }
        if components.count == 1 {
            let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw folderOpenError("/", errno) }
            return fd
        }
        var base: Int
        var creatableFrom: Int
        if let anchor = components.dropLast().lastIndex(where: isSessionFolderName) {
            base = anchor
            creatableFrom = anchor + 1
        } else {
            base = components.count - 1
            if create {
                while base > 1, !exists(path(components[..<base])) { base -= 1 }
            }
            creatableFrom = base
        }
        let baseURL = URL(fileURLWithPath: path(components[..<base]), isDirectory: true)
        let baseFD = Darwin.open(baseURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard baseFD >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw folderOpenError(baseURL.lastPathComponent, code)
        }
        defer { Darwin.close(baseFD) }
        return try openFolder(Array(components[base...]), in: baseFD, baseURL: baseURL, create: create,
                              creatableFrom: creatableFrom - base)
    }

    /// Opens `names` one below the other, starting in the open folder `base` (named `baseURL`; not closed),
    /// each with `openat` and O_NOFOLLOW. Returns the last one's descriptor, or nil when one is missing and may
    /// not be created. With `create`, missing folders from index `creatableFrom` on are made as `openFolder(_:)`
    /// describes; `syncParents: false` skips the parent fsync (the caller fsyncs the folders it changed).
    static func openFolder(_ names: [String], in base: Int32, baseURL: URL, create: Bool = false,
                           creatableFrom: Int = 0, syncParents: Bool = true) throws -> Int32? {
        guard names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
            throw HolosError.invalidInput("Invalid folder path.")
        }
        var parent = dup(base)
        guard parent >= 0 else { throw HolosError.io("Cannot open folder \(baseURL.lastPathComponent): \(errnoText()).") }
        var parentURL = baseURL
        for (index, name) in names.enumerated() {
            var next = openat(parent, name, folderFlags)
            var code = errno
            if next < 0, code == ENOENT, create, index >= creatableFrom {
                do {
                    next = try makeFolder(name, in: parent, parentURL: parentURL, syncParent: syncParents)
                    code = errno
                } catch {
                    Darwin.close(parent)
                    throw error
                }
            }
            guard next >= 0 else {
                Darwin.close(parent)
                if code == ENOENT { return nil }
                throw folderOpenError(name, code)
            }
            do {
                try syncParentIfUnsynced(next, in: parent, parentURL: parentURL)
            } catch {
                Darwin.close(next)
                Darwin.close(parent)
                throw error
            }
            Darwin.close(parent)
            parent = next
            parentURL = parentURL.appendingPathComponent(name, isDirectory: true)
        }
        return parent
    }

    /// Opens the folder holding the file `url` (see `openFolder(_:)`) and returns it with the file name; nil
    /// when that folder does not exist. The caller closes the descriptor.
    static func openParentIfPresent(of url: URL) throws -> (fd: Int32, name: String)? {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        guard url.isFileURL, !name.isEmpty, name != "/", name != ".", name != ".." else {
            throw HolosError.invalidInput("Invalid file path.")
        }
        guard let fd = try openFolder(standardized.deletingLastPathComponent()) else { return nil }
        return (fd, name)
    }

    /// Like `openParentIfPresent`, but a missing folder is an error.
    static func openParent(of url: URL) throws -> (fd: Int32, name: String) {
        guard let opened = try openParentIfPresent(of: url) else {
            let folder = url.standardizedFileURL.deletingLastPathComponent().lastPathComponent
            throw HolosError.io("Cannot open folder \(folder): \(errnoText(ENOENT)).")
        }
        return opened
    }

    /// The file type (`S_IFMT` bits) of the entry at `url`, which is not followed if it is a symbolic link;
    /// nil when it or its folder does not exist. The folder holding it is opened with `openFolder(_:)`.
    static func entryType(at url: URL) throws -> mode_t? {
        guard let (parent, name) = try openParentIfPresent(of: url) else { return nil }
        defer { Darwin.close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw HolosError.io("Cannot inspect \(name): \(errnoText(code)).")
        }
        return info.st_mode & S_IFMT
    }

    /// The entries of the folder `url` (opened with `openFolder(_:)`), each with its file type (`S_IFMT` bits,
    /// links not followed), in no particular order; nil when the folder does not exist.
    static func listFolder(_ url: URL) throws -> [(name: String, type: mode_t)]? {
        guard let fd = try openFolder(url) else { return nil }
        guard let folder = fdopendir(fd) else {
            let code = errno
            Darwin.close(fd)
            throw HolosError.io("Cannot list \(url.lastPathComponent): \(errnoText(code)).")
        }
        defer { closedir(folder) }
        var entries: [(name: String, type: mode_t)] = []
        while let entry = readdir(folder) {
            let name: [CChar] = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                raw.prefix(Int(entry.pointee.d_namlen)).map { CChar(bitPattern: $0) } + [0]
            }
            if name == [46, 0] || name == [46, 46, 0] { continue }  // "." and ".."
            var info = stat()
            guard fstatat(dirfd(folder), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let text = String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
            entries.append((text, info.st_mode & S_IFMT))
        }
        return entries
    }

    /// The device and inode of the entry `name` in the open folder `parent`, not following a symbolic link; nil
    /// when it does not exist.
    static func identity(of name: String, in parent: Int32) throws -> FileIdentity? {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw HolosError.io("Cannot inspect \(name): \(errnoText(code)).")
        }
        return FileIdentity(info)
    }

    /// Whether `name` is a session folder name (`<id>.holos`).
    static func isSessionFolderName(_ name: String) -> Bool { name.count > 6 && name.hasSuffix(".holos") }

    /// Binds the session folder path `directory` (named `<id>.holos`) to the open folder `folder` until the returned
    /// pin is released: from then on `openFolder` reaches `directory`, and every folder and file below it, through a
    /// duplicate of `folder` (then `openat` with O_NOFOLLOW below it), never by path. So every Holos file operation
    /// that names the session by path (`write`, `create`, `append`, `sync`, `truncate`, `readIfPresent`,
    /// `removeTree`, `syncDirectory`, `ensurePrivateDirectory`, `createForWriting`, the session locks, `ChunkFile`,
    /// the speaker store, the transcript pointer) works in `folder` even after another program renames the folder,
    /// or one holding it, away and puts a different folder at that path; the one at the path is never touched.
    ///
    /// For a session made in a folder the caller holds open (an import's staging folder). The path is compared after
    /// removing "." and ".." only (`URL.standardized`), so pass the URL the writes use. Throws `invalidInput` for a
    /// path that is not a session folder or is already pinned, `io` when the descriptor cannot be duplicated.
    public static func pinSessionFolder(_ folder: Int32, at directory: URL) throws -> SessionFolderPin {
        guard directory.isFileURL, isSessionFolderName(directory.lastPathComponent) else {
            throw HolosError.invalidInput("Only a session folder can be pinned.")
        }
        let key = pinKey(directory.standardized.pathComponents)
        let copy = fcntl(folder, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw HolosError.io("Cannot keep the session folder open: \(errnoText()).") }
        let token = UUID()
        let added = pinnedFolders.withLock { pins -> Bool in
            guard pins[key] == nil else { return false }
            pins[key] = (copy, token)
            return true
        }
        guard added else {
            Darwin.close(copy)
            throw HolosError.invalidInput("The session folder \(directory.lastPathComponent) is already pinned.")
        }
        return SessionFolderPin(directory: directory, key: key, token: token)
    }

    /// Ends the pin `token` of `key`, closing its descriptor; nothing when that pin already ended.
    static func unpin(_ key: String, token: UUID) {
        let fd = pinnedFolders.withLock { pins -> Int32? in
            guard let pin = pins[key], pin.token == token else { return nil }
            pins[key] = nil
            return pin.fd
        }
        if let fd { Darwin.close(fd) }
    }

    /// Whether a pin covers `url` (for tests).
    static func isPinned(_ url: URL) -> Bool {
        guard let fd = try? pinnedSessionFolder(for: url)?.fd else { return false }
        Darwin.close(fd)
        return true
    }

    /// Session folder paths (`pinKey`) bound to an open descriptor (`pinSessionFolder`), with the pin's token.
    private static let pinnedFolders = Mutex<[String: (fd: Int32, token: UUID)]>([:])

    /// For `url` at or below a pinned session folder: a duplicate of the pinned descriptor (the caller closes it),
    /// the session folder's URL, and the names from it down to `url`. Nil when no pin covers `url`.
    private static func pinnedSessionFolder(for url: URL) throws -> (fd: Int32, sessionURL: URL, below: [String])? {
        let components = url.standardized.pathComponents
        let found = pinnedFolders.withLock { pins -> (fd: Int32, errno: Int32, key: String, index: Int)? in
            guard !pins.isEmpty else { return nil }
            for index in components.indices.reversed() where isSessionFolderName(components[index]) {
                let key = pinKey(components[...index])
                guard let fd = pins[key]?.fd else { continue }
                let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
                return (copy, copy < 0 ? errno : 0, key, index)
            }
            return nil
        }
        guard let found else { return nil }
        guard found.fd >= 0 else {
            throw HolosError.io("Cannot open folder \(components[found.index]): \(errnoText(found.errno)).")
        }
        return (found.fd, URL(fileURLWithPath: found.key, isDirectory: true),
                Array(components[(found.index + 1)...]))
    }

    private static func pinKey<C: Collection>(_ components: C) -> String where C.Element == String {
        NSString.path(withComponents: Array(components))
    }

    // MARK: - Private

    /// Makes `name` in `parent` (0700), returns its descriptor opened with O_NOFOLLOW, and fsyncs `parent`.
    /// A folder made concurrently by someone else is opened like any existing one (-1 with errno on failure).
    private static func makeFolder(_ name: String, in parent: Int32, parentURL: URL, syncParent: Bool) throws -> Int32 {
        beforeFolderCreate?(parentURL.appendingPathComponent(name, isDirectory: true))
        guard mkdirat(parent, name, 0o700) == 0 else {
            let code = errno
            if code == EEXIST { return openat(parent, name, folderFlags) }
            throw HolosError.io("Cannot create folder \(name): \(errnoText(code)).")
        }
        faultPlan?.changed(parentURL, name)
        let fd = injectFault("open \(name)/") ? -1 : openat(parent, name, folderFlags)
        guard fd >= 0 else {
            let code = errno
            discardMadeFolder(name, in: parent, parentURL: parentURL)
            throw folderOpenError(name, code)
        }
        do {
            // The creation mode is filtered by the umask; set it exactly, on the folder this call made.
            guard fchmod(fd, 0o700) == 0 else {
                throw HolosError.io("Cannot make folder \(name) private: \(errnoText()).")
            }
            if syncParent { try syncFolder(parent, parentURL) }
            return fd
        } catch {
            Darwin.close(fd)
            discardMadeFolder(name, in: parent, parentURL: parentURL)
            throw error
        }
    }

    /// Folders `makeFolder` made that it could neither remove nor make durable after a failure (the parent fsync
    /// failed too); the next `openFolder` that reaches one fsyncs its parent first.
    private static let unsyncedFolders = Mutex<Set<FileIdentity>>([])

    /// After a failure that followed `mkdirat` of `name` in `parent`, removes that folder and fsyncs `parent`, so
    /// a retry makes it again and fsyncs its parent (a later open would otherwise find it and return without
    /// making it durable). A folder that cannot be removed is made durable instead: `parent` is fsync'd now or,
    /// if that fails, by the next open that reaches the folder (`unsyncedFolders`).
    private static func discardMadeFolder(_ name: String, in parent: Int32, parentURL: URL) {
        if !injectFault("unlink \(name)"), unlinkat(parent, name, AT_REMOVEDIR) == 0 {
            faultPlan?.changed(parentURL, name)
            _ = fsyncFolder(parent, parentURL)
            return
        }
        log.error("Cannot remove folder \(name, privacy: .public) after a failed create: \(errnoText(), privacy: .public)")
        guard !fsyncFolder(parent, parentURL), let identity = try? identity(of: name, in: parent) else { return }
        unsyncedFolders.withLock { _ = $0.insert(identity) }
    }

    /// Fsyncs `parent` if the open folder `folder` inside it is in `unsyncedFolders`, then forgets it.
    private static func syncParentIfUnsynced(_ folder: Int32, in parent: Int32, parentURL: URL) throws {
        guard unsyncedFolders.withLock({ !$0.isEmpty }) else { return }
        let identity = try FileIdentity(descriptor: folder)
        guard unsyncedFolders.withLock({ $0.contains(identity) }) else { return }
        try syncFolder(parent, parentURL)
        unsyncedFolders.withLock { _ = $0.remove(identity) }
    }

    private static func path(_ components: ArraySlice<String>) -> String {
        NSString.path(withComponents: Array(components))
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 || errno != ENOENT
    }
}

/// A session folder path bound to an open descriptor (`AtomicFile.pinSessionFolder`). The binding ends with
/// `release()` or deinit.
public final class SessionFolderPin: Sendable {
    /// The pinned path, as the caller named it.
    public let directory: URL
    private let key: String
    private let token: UUID

    init(directory: URL, key: String, token: UUID) {
        self.directory = directory
        self.key = key
        self.token = token
    }

    deinit { release() }

    /// Ends the binding: later operations reach `directory` by path again. Later calls do nothing.
    public func release() { AtomicFile.unpin(key, token: token) }
}

/// Which file an open descriptor or a folder entry is: its device and inode, whatever path reached it.
struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    /// The identity of the open file `fd` (`fstat`).
    init(descriptor fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw HolosError.io("Cannot inspect an open file: \(AtomicFile.errnoText()).") }
        self.init(info)
    }
}
