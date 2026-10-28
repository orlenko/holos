import Darwin
import Foundation
import HolosCore

/// `pronunciations.json`, the user's pronunciation list (docs/design.md "Pronunciations"), in `<supportRoot>`
/// (Application Support/Holos): read as a `VersionedFile`, written whole and atomically (`AtomicFile.write`, 0600),
/// each change made under an exclusive lock (`pronunciations.json.lock`) on the list as it is on disk then, so the app
/// and `voiceislocal pronunciations` never lose each other's changes.
public struct PronunciationStore: Sendable {
    public static let fileName = "pronunciations.json"
    static let lockName = "pronunciations.json.lock"
    /// A larger file is refused as damaged: 1,000 entries of two 100-character strings take far less.
    static let maxBytes = 4 << 20
    static let file = VersionedFile<PronunciationList>(fileName, current: PronunciationList.currentSchemaVersion,
                                                       maxBytes: maxBytes, damage: .plain)

    public let url: URL

    public init(url: URL = PronunciationStore.defaultURL) {
        self.url = url
    }

    /// `<supportRoot>/pronunciations.json`. Tests point `supportRoot` at a temporary folder (`HOLOS_SUPPORT_DIR`).
    public static var defaultURL: URL {
        HolosPaths.supportRoot.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The list on disk; empty when there is no file. Throws for a damaged file, or one written by a newer Voice is
    /// Local: neither is ever overwritten.
    public func load() throws -> PronunciationList {
        try Self.file.read(url) ?? PronunciationList()
    }

    /// Applies `change` to the list as it is on disk, holding the lock, and saves the result when it differs. Returns
    /// the list after the change and what `change` returned.
    @discardableResult
    public func update<T>(_ change: (inout PronunciationList) throws -> T) throws -> (list: PronunciationList, result: T) {
        try withLock {
            var list = try load()
            let before = list
            let result = try change(&list)
            if list != before {
                try AtomicFile.write(HolosJSON.encoder().encode(list), to: url, permissions: 0o600)
            }
            return (list, result)
        }
    }

    /// Runs `body` holding `pronunciations.json.lock` (an exclusive flock; the folder is created privately first).
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try AtomicFile.ensurePrivateDirectory(folder)
        let path = folder.appendingPathComponent(Self.lockName, isDirectory: false).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw HolosError.io("Cannot open the pronunciation list lock: \(String(cString: strerror(errno))).")
        }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw HolosError.io("Cannot lock the pronunciation list: \(String(cString: strerror(errno))).")
            }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

extension PronunciationList: ValidatedDecodable {
    /// Every entry is as `set` keeps it: both sides cleaned and within `maximumLength`, written forms distinct, at
    /// most `maximumEntries`. A file edited by hand into anything else is damaged, never half used.
    public func validate(file: String) throws {
        var seen: Set<String> = []
        for entry in entries {
            guard WordList.cleaned(entry.written) == entry.written, WordList.cleaned(entry.sayAs) == entry.sayAs,
                  entry.written.count <= Self.maximumLength, entry.sayAs.count <= Self.maximumLength,
                  seen.insert(entry.written).inserted else {
                throw HolosError.invalidInput("\(file) is damaged or was not written by Voice is Local.")
            }
        }
        guard entries.count <= Self.maximumEntries else {
            throw HolosError.invalidInput("\(file) is damaged or was not written by Voice is Local.")
        }
    }
}
