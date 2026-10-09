import Foundation
import HolosCore

/// Calls `onChange` on `queue` when an entry of `folder` is added, removed, or renamed (an atomic save replaces a
/// file by renaming it into place), until the watcher is released. The app watches its corrections this way, so a
/// list changed by `voiceislocal eval apply` is loaded as it runs.
public final class FolderWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    public init?(folder: URL, queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                           eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// `corrections.json`, the learned corrections (`CorrectionList`): where it is, reading and writing it, and its lock.
extension CorrectionList {
    /// `<supportRoot>/corrections.json`, beside `words.json`: Application Support/Holos, or `HOLOS_SUPPORT_DIR` when
    /// set, so a scratch or test support folder never reads or changes the user's real corrections.
    public static var defaultURL: URL {
        HolosPaths.supportRoot.appendingPathComponent("corrections.json")
    }

    public static func load(from url: URL) throws -> CorrectionList {
        guard FileManager.default.fileExists(atPath: url.path) else { return CorrectionList() }
        return try JSONDecoder().decode(CorrectionList.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reads the list at `url`, applies `change`, and saves it when it changed, all under an exclusive lock
    /// (`flock` on "<file>.lock" beside it). Every writer of the file — the app and `voiceislocal eval apply` —
    /// changes it only through here, so one never saves over what another added in between. Returns the list as
    /// saved (or as read, when `change` left it alone) and what `change` returned. Nothing is written when the
    /// file cannot be read.
    public static func update<T>(at url: URL, _ change: (inout CorrectionList) throws -> T) throws
        -> (list: CorrectionList, result: T) {
        try withFileLock(for: url) {
            var list = try load(from: url)
            let before = list
            let result = try change(&list)
            if list != before { try list.save(to: url) }
            return (list, result)
        }
    }

    /// Runs `body` holding the exclusive lock of the corrections file at `url` (waits for another holder).
    public static func withFileLock<T>(for url: URL, _ body: () throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockPath = folder.appendingPathComponent(url.lastPathComponent + ".lock").path
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: lockPath])
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            // A volume without flock (some network shares) fails too: changing the list unlocked could lose what
            // another writer added in between.
            guard errno == EINTR else {
                throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: lockPath])
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
