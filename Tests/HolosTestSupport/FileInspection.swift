import Darwin
import Foundation

/// What a test looks at on disk.
public enum FileInspection {
    public struct Unreadable: Error, CustomStringConvertible {
        public let description: String
    }

    /// The permission bits of `url` itself (`lstat`: a symbolic link is not followed), nil when it is missing.
    public static func mode(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    /// The POSIX permissions FileManager reports for `url` (a symbolic link is followed).
    public static func permissions(_ url: URL) throws -> Int {
        guard let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber else { throw Unreadable(description: "No POSIX permissions for \(url.path).") }
        return value.intValue
    }

    /// Whether `url` leads to something: a symbolic link is followed, so a dangling one does not exist.
    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Whether there is an entry at `url` itself (`lstat`): a symbolic link counts, even a dangling one. Use it to
    /// check that something was removed.
    public static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The names directly inside `folder`, sorted; throws when it cannot be listed.
    public static func entries(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// The names directly inside `folder`, sorted; none when it cannot be listed.
    public static func entriesIfAny(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Every regular file under `folder` by relative path, with its bytes, for "nothing changed" checks.
    public static func files(in folder: URL) -> [String: Data] {
        let prefix = folder.standardizedFileURL.path + "/"
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
        }
        return result
    }
}
