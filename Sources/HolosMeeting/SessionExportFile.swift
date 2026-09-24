import Darwin
import Foundation
import HolosCore
import HolosStorage

extension SessionExports {
    /// Writes `data` to a new file at `url` for `holos session export --output` (docs/meeting-design.md §5.7):
    /// never over an existing file or symbolic link, even one another process creates meanwhile, and private (0600)
    /// because the transcript may hold confidential speech.
    ///
    /// Symbolic links in the folder part of `url` are resolved first (for example /tmp → /private/tmp on macOS):
    /// `AtomicFile.create` opens the folder holding the file with O_NOFOLLOW, which is right for session files but
    /// would refuse an ordinary user path. The last component is never followed.
    /// Returns the path written. Throws `HolosError.invalidInput` when something already has that name.
    @discardableResult
    public static func writeNewFile(_ data: Data, at url: URL) throws -> URL {
        let target = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
        let exists = HolosError.invalidInput(
            "\(url.path) already exists; Holos never replaces a file here. Choose another name.")
        guard !entryExists(target) else { throw exists }
        do {
            try AtomicFile.create(data, at: target, permissions: 0o600)
        } catch HolosError.invalidInput where entryExists(target) {
            throw exists
        }
        return target
    }

    /// Whether anything, even a dangling symbolic link, has this path.
    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
