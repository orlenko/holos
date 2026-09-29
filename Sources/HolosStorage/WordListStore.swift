import Darwin
import Foundation
import HolosCore

/// `words.json`, the user's word list (docs/design.md "Word list"), in `<supportRoot>` (Application Support/Holos):
/// written whole and atomically (`AtomicFile.write`, 0600), each change made under an exclusive lock
/// (`words.json.lock`) on the list as it is on disk then, so the app and `voiceislocal words` never lose each
/// other's changes.
public struct WordListStore: Sendable {
    public static let fileName = "words.json"
    static let lockName = "words.json.lock"
    /// A larger file is refused as damaged: 1,000 terms of 100 characters take far less.
    static let maxBytes = 4 << 20

    public let url: URL

    public init(url: URL = WordListStore.defaultURL) {
        self.url = url
    }

    /// `<supportRoot>/words.json`. Tests point `supportRoot` at a temporary folder (`HOLOS_SUPPORT_DIR`).
    public static var defaultURL: URL {
        HolosPaths.supportRoot.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The list on disk; empty when there is no file. Throws for a damaged file, or one written by a newer Voice is
    /// Local (a higher schema version): neither is ever overwritten.
    public func load() throws -> WordList {
        guard let data = try AtomicFile.readIfPresent(url, maxBytes: Self.maxBytes) else { return WordList() }
        do {
            return try HolosJSON.decoder().decode(WordList.self, from: data)
        } catch let error as HolosError {
            throw error
        } catch {
            throw HolosError.invalidInput("\(Self.fileName) is damaged or was not written by Voice is Local.")
        }
    }

    /// Applies `change` to the list as it is on disk, holding the lock, and saves the result when it differs.
    /// Returns the list after the change, what `change` returned, and the file's stamp taken under the lock, so it is
    /// the stamp of that list (another writer waits for the lock).
    @discardableResult
    public func update<T>(_ change: (inout WordList) throws -> T) throws
        -> (list: WordList, result: T, stamp: Stamp?) {
        try withLock {
            var list = try load()
            let before = list
            let result = try change(&list)
            if list != before { try save(list) }
            return (list, result, stamp())
        }
    }

    /// What tells a changed file from the one read before: its inode, size, and modification and status-change
    /// times (an atomic write replaces the inode; `chmod` changes the status-change time). Nil when there is no file.
    public struct Stamp: Sendable, Equatable {
        var inode: UInt64
        var size: Int64
        var modified: [Int]
        var changed: [Int]
    }

    public func stamp() -> Stamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Stamp(inode: info.st_ino, size: info.st_size,
                     modified: [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec],
                     changed: [info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec])
    }

    private func save(_ list: WordList) throws {
        try AtomicFile.write(HolosJSON.encoder().encode(list), to: url, permissions: 0o600)
    }

    /// Runs `body` holding `words.json.lock` (an exclusive flock; the folder is created privately first).
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try AtomicFile.ensurePrivateDirectory(folder)
        let path = folder.appendingPathComponent(Self.lockName, isDirectory: false).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw HolosError.io("Cannot open the word list lock: \(String(cString: strerror(errno))).")
        }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw HolosError.io("Cannot lock the word list: \(String(cString: strerror(errno))).")
            }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
