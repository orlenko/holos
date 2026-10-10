import Darwin
import Foundation
import HolosCore

/// Creating a new reading's cache as one step: it is made under a temporary name beside its
/// place (`.holos-init-<lock key>-<UUID>`), filled (`parts`, `source.txt`, the first manifest), and
/// only then renamed into place. A cache is therefore never at its place without a manifest, and
/// a failure removes everything the run created, so the reading can simply be started again.
enum ReadingCache {
    /// The steps of `create`, after each of which a test may fail it.
    enum Step: CaseIterable { case directory, parts, source, manifest }

    static let stagingPrefix = ".holos-init-"

    /// `.holos-init-<lock key>-<UUID>`, a new cache's name while it is made.
    static func stagingName(key: String) -> String { "\(stagingPrefix)\(key)-\(UUID().uuidString)" }

    /// `directory`'s contents, made beside it and renamed into place. Fails, leaving nothing,
    /// when anything is in the way.
    static func create(_ directory: URL, source: Data, manifest: ReadingManifest,
                       fault: (Step) throws -> Void = { _ in }) throws {
        let folder = ReadingDirectoryLock.folder(beside: directory)
        let staging = folder.appendingPathComponent(
            stagingName(key: ReadingDirectoryLock.key(for: directory)), isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try fault(.directory)
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("parts"),
                                                    withIntermediateDirectories: false)
            try fault(.parts)
            try source.write(to: staging.appendingPathComponent("source.txt"), options: [.withoutOverwriting])
            try fault(.source)
            try save(manifest, to: staging.appendingPathComponent(ReadingManifest.fileName))
            try fault(.manifest)
            try commit(staging, to: folder.appendingPathComponent(directory.lastPathComponent))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Renames the filled cache into place, never over anything there: exclusively where the
    /// volume can, else with rename(2), which replaces only an empty folder.
    private static func commit(_ staging: URL, to directory: URL) throws {
        if ReadingPublisher.systemExclusiveRename(staging.path, directory.path) == 0 { return }
        var error = errno
        if error == ENOTSUP || error == EINVAL || error == ENOSYS {
            if rename(staging.path, directory.path) == 0 { return }
            error = errno
        }
        if error == EEXIST || error == ENOTEMPTY || error == ENOTDIR || error == EISDIR {
            throw HolosError.invalidInput("A reading already exists at \(directory.path). Use --resume to continue it.")
        }
        throw HolosError.io("Could not create the reading cache \(directory.path): \(String(cString: strerror(error)))")
    }

    /// Removes the caches that runs killed in the middle of `create` left beside `directory`:
    /// this reading's (whose lock the caller holds), and any other reading's whose lock no run
    /// holds. Only folders owned by this user and named as `create` names them are touched.
    static func sweep(beside directory: URL) {
        let folder = ReadingDirectoryLock.folder(beside: directory)
        let own = ReadingDirectoryLock.key(for: directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            guard let key = stagingKey(name) else { continue }
            let staging = folder.appendingPathComponent(name, isDirectory: true)
            var metadata = stat()
            guard lstat(staging.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid() else { continue }
            if key == own {
                try? FileManager.default.removeItem(at: staging)
            } else if let lock = ReadingDirectoryLock.acquireIfIdle(key: key, in: folder) {
                withExtendedLifetime(lock) { try? FileManager.default.removeItem(at: staging) }
            }
        }
    }

    /// The lock key in a name `create` gives, or nil for any other name.
    static func stagingKey(_ name: String) -> String? {
        guard name.hasPrefix(stagingPrefix) else { return nil }
        let rest = name.dropFirst(stagingPrefix.count)
        guard rest.count == 64 + 1 + 36 else { return nil }
        let key = rest.prefix(64)
        guard key.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }), rest.dropFirst(64).first == "-",
              UUID(uuidString: String(rest.suffix(36))) != nil else { return nil }
        return String(key)
    }

    /// Removes a cache that an earlier version (which created it in place) left half made: a
    /// folder owned by this user, named as caches are (`Output-<16 hex digits>` or a UUID), with
    /// no manifest and nothing in it but what that creation writes (an empty `parts`,
    /// `source.txt`, a manifest being saved). Returns whether it was removed; anything else is kept.
    static func removeAbandoned(_ directory: URL) -> Bool {
        guard isCacheName(directory.lastPathComponent) else { return false }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        var files: [String] = []
        var parts: String?
        for name in names {
            let path = directory.appendingPathComponent(name).path
            var entry = stat()
            guard lstat(path, &entry) == 0, entry.st_uid == getuid() else { return false }
            let type = entry.st_mode & S_IFMT
            if name == "parts", type == S_IFDIR,
               (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true {
                parts = path
            } else if type == S_IFREG, name == "source.txt"
                        || ReadingTemporaries.uuid(between: ReadingTemporaries.manifestPrefix,
                                                   and: ReadingTemporaries.manifestSuffix, in: name) != nil {
                files.append(path)
            } else {
                return false
            }
        }
        for path in files { _ = unlink(path) }
        if let parts { _ = rmdir(parts) }
        return rmdir(directory.path) == 0
    }

    /// `Output-<16 lowercase hex digits>` (a reading with `--output`) or a UUID (one without).
    static func isCacheName(_ name: String) -> Bool {
        if UUID(uuidString: name) != nil { return true }
        let prefix = "Output-"
        guard name.hasPrefix(prefix) else { return false }
        let digest = name.dropFirst(prefix.count)
        return digest.count == 16 && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }
}
