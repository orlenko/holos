import Foundation
import Darwin
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
    /// With `create`, each missing folder below the base (never the session folder above `url`) is made with
    /// `mkdirat`, set to 0700 with `fchmod` on its own descriptor, and its parent is fsync'd; if that fails, the
    /// new folder is removed again, so a retry creates it and fsyncs its parent.
    static func openFolder(_ url: URL, create: Bool = false) throws -> Int32? {
        guard url.isFileURL else { throw HolosError.invalidInput("Folder path must be a file URL.") }
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/",
              !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HolosError.invalidInput("Invalid folder path.")
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

    /// Whether `name` is a session folder name (`<id>.holos`).
    static func isSessionFolderName(_ name: String) -> Bool { name.count > 6 && name.hasSuffix(".holos") }

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
        let fd = openat(parent, name, folderFlags)
        guard fd >= 0 else { throw folderOpenError(name, errno) }
        do {
            // The creation mode is filtered by the umask; set it exactly, on the folder this call made.
            guard fchmod(fd, 0o700) == 0 else {
                throw HolosError.io("Cannot make folder \(name) private: \(errnoText()).")
            }
            if syncParent { try syncFolder(parent, parentURL) }
            return fd
        } catch {
            // Remove the folder this call made, so a retry makes it again and fsyncs its parent. A later open would
            // otherwise find it and return without making it durable.
            Darwin.close(fd)
            if !injectFault("unlink \(name)"), unlinkat(parent, name, AT_REMOVEDIR) == 0 {
                faultPlan?.changed(parentURL, name)
                _ = fsyncFolder(parent, parentURL)
            } else {
                log.error("Cannot remove folder \(name, privacy: .public) after a failed create: \(errnoText(), privacy: .public)")
            }
            throw error
        }
    }

    private static func path(_ components: ArraySlice<String>) -> String {
        NSString.path(withComponents: Array(components))
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 || errno != ENOENT
    }
}
