import CryptoKit
import Darwin
import Foundation
import HolosCore
import os

/// Installs and removes Tidy Up's Qwen file (`TidyModel`, docs/design.md "Tidy Up"): downloaded from its pinned
/// Hugging Face commit, resuming an unfinished download, or copied from a file already on this Mac; either way kept
/// only once its size and SHA-256 match, then moved into place.
public enum TidyModelInstall {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "tidy")

    /// Appends the bytes of the model file from `offset` on, by calling `write` with each chunk in order. Returns
    /// false, having written nothing, when the source cannot start at `offset` (a server that ignores the range).
    public typealias Fetch = @Sendable (_ offset: Int64, _ write: (Data) throws -> Void) async throws -> Bool

    /// The file that counts as the model: its size and SHA-256 (tests use a small one).
    public struct Pin: Sendable {
        public var size: Int64
        public var sha256: String
        public static let qwen = Pin(size: TidyModel.size, sha256: TidyModel.sha256)
    }

    /// Downloads or copies the model unless it is installed (or `force`). `source`: a model file already on this Mac,
    /// checked and copied instead of downloading. `progress` goes from 0 to 1: the transfer, then the check.
    public static func setUp(force: Bool = false, source: URL? = nil, root: URL = TidyModel.root,
                             fetch: Fetch = huggingFace, notice: @Sendable (String) -> Void,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        try await setUp(force: force, source: source, root: root, pin: .qwen, fetch: fetch, notice: notice,
                        progress: progress)
    }

    static func setUp(force: Bool, source: URL?, root: URL, pin: Pin, fetch: Fetch,
                      notice: @Sendable (String) -> Void,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        if !force, isInstalled(root: root, pin: pin) {
            notice("The Tidy Up model is already installed.")
            progress(1)
            return
        }
        try ensurePrivateDirectory(root)
        let lock = try InstallLock(path: TidyModel.lockFile(root: root).path)
        defer { lock.release() }
        if !force, isInstalled(root: root, pin: pin) {
            notice("The Tidy Up model is already installed.")
            progress(1)
            return
        }
        // A copy is checked under its own name, so a file that turns out not to be the model never costs the person an
        // unfinished download.
        let partial = source == nil ? TidyModel.partialFile(root: root) : TidyModel.copyFile(root: root)
        if let source {
            try copy(source, to: partial, root: root, size: pin.size, notice: notice, progress: { progress(0.5 * $0) })
        } else {
            if force { try removeIfPresent(partial) }
            try await download(to: partial, size: pin.size, fetch: fetch, notice: notice,
                               progress: { progress(0.8 * $0) })
        }
        try Task.checkCancellation()
        notice("Checking the file…")
        let start = source == nil ? 0.8 : 0.5
        let digest = try sha256(of: partial) { progress(start + (1 - start) * $0) }
        guard digest == pin.sha256 else {
            try removeIfPresent(partial)
            throw HolosError.incomplete(source == nil
                ? "The downloaded Tidy Up model is damaged and was deleted. Run voiceislocal setup --tidy-model again."
                : "That file is not \(TidyModel.fileName) as published (its SHA-256 differs), so it was not used.")
        }
        let file = TidyModel.file(root: root)
        try removeIfPresent(file)
        try FileManager.default.moveItem(at: partial, to: file)
        log.info("Tidy Up model installed")
        progress(1)
    }

    private static func isInstalled(root: URL, pin: Pin) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: TidyModel.file(root: root).path))?[.size] as? Int64
        return size == pin.size
    }

    /// Deletes the installed model and any unfinished download (Settings' Remove).
    public static func remove(root: URL = TidyModel.root) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let lock = try InstallLock(path: TidyModel.lockFile(root: root).path)
        defer { lock.release() }
        try removeIfPresent(TidyModel.file(root: root))
        try removeIfPresent(TidyModel.partialFile(root: root))
        try removeIfPresent(TidyModel.copyFile(root: root))
    }

    // MARK: - Transfer

    /// Appends to `partial` from where an earlier download stopped (from the start when the server ignores the range).
    static func download(to partial: URL, size: Int64, fetch: Fetch, notice: @Sendable (String) -> Void,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: partial.path) {
            guard manager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw HolosError.io("Cannot create \(partial.lastPathComponent).")
            }
        }
        var offset = (try manager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        if offset > size {
            try removeIfPresent(partial)
            manager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
            offset = 0
        }
        // Complete already (a run stopped while checking it): only the check is left.
        guard offset < size else { progress(1); return }
        notice(offset > 0 ? "Resuming the Tidy Up model download (\(TidyModel.displayName), about 5.7 GB)…"
            : "Downloading the Tidy Up model (\(TidyModel.displayName), about 5.7 GB)…")
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var written = offset
        let write: (Data) throws -> Void = { chunk in
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            progress(Double(written) / Double(size))
        }
        try handle.seek(toOffset: UInt64(offset))
        if try await !fetch(offset, write) {
            guard offset > 0 else { throw HolosError.unavailable("The Tidy Up model download could not start.") }
            // The server cannot resume: start again from the first byte.
            notice("The download cannot resume here; downloading it from the start.")
            try handle.truncate(atOffset: 0)
            written = 0
            guard try await fetch(0, write) else {
                throw HolosError.unavailable("The Tidy Up model download could not start.")
            }
        }
        try handle.synchronize()
        guard written == size else {
            throw HolosError.incomplete("The Tidy Up model download stopped early. Run voiceislocal setup --tidy-model "
                + "again to resume it.")
        }
    }

    /// Copies `source` (a link is followed) to `partial` when its size is the model's and it is not one of the model's
    /// own files in `root`.
    static func copy(_ source: URL, to partial: URL, root: URL, size expected: Int64,
                     notice: @Sendable (String) -> Void, progress: @escaping @Sendable (Double) -> Void) throws {
        let source = source.resolvingSymlinksInPath()
        let own = [TidyModel.file(root: root), TidyModel.partialFile(root: root), TidyModel.copyFile(root: root)]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard !own.contains(source.standardizedFileURL.path) else {
            throw HolosError.invalidInput("That file is one of the Tidy Up model's own files; give a copy kept elsewhere.")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? -1
        guard size == expected else {
            throw HolosError.invalidInput("That file is not \(TidyModel.fileName) as published (its size differs).")
        }
        notice("Copying \(source.lastPathComponent)…")
        try removeIfPresent(partial)
        try FileManager.default.copyItem(at: source, to: partial)
        progress(1)
    }

    /// The default `Fetch`: the pinned file from Hugging Face, from `offset` on. A response is checked before any of
    /// it is written: the status, and the range or length it says it holds.
    public static let huggingFace: Fetch = { offset, write in
        var request = URLRequest(url: TidyModel.downloadURL)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let remaining = TidyModel.size - offset
        switch http?.statusCode {
        case 206 where http?.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-") == true
            && response.expectedContentLength == remaining:
            break
        case 200 where offset > 0:
            return false
        case 200 where response.expectedContentLength == remaining:
            break
        default:
            throw HolosError.unavailable("Hugging Face did not send the Tidy Up model (HTTP \(http?.statusCode ?? 0), "
                + "\(response.expectedContentLength) bytes). Check the network connection, then try again.")
        }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 20 {
                try Task.checkCancellation()
                try write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try write(buffer) }
        return true
    }

    /// SHA-256 of `url` in lowercase hex, read in 8 MB blocks; `progress` from 0 to 1. Throws when cancelled.
    static func sha256(of url: URL, progress: @Sendable (Double) -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = max(1, (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 1)
        var hasher = SHA256()
        var read: Int64 = 0
        while let block = try handle.read(upToCount: 8 << 20), !block.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: block)
            read += Int64(block.count)
            progress(Double(read) / Double(total))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

/// `flock` on the Tidy Up model's install lock; refuses when another process holds it.
private final class InstallLock {
    private let fd: Int32

    init(path: String) throws {
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HolosError.io("Cannot open the Tidy Up model's install lock.") }
        // A status check holds a shared lock for an instant; wait that out, but not another install.
        for attempt in 0..<20 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK else { break }
            if attempt < 19 { usleep(50_000) }
        }
        close(fd)
        throw HolosError.unavailable("The Tidy Up model is being installed by another process; wait for it to "
            + "finish, then try again.")
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
