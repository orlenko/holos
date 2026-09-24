import Darwin
import Foundation
import HolosCore
import os

/// The recorder's side of `control/` (docs/meeting-design.md §4.1): reads and removes request files published by
/// `RecorderChannel.send`.
///
/// Only regular files named `<UUID>.json` of at most 4 KiB are considered (no dot prefix, so a sender's
/// `.<UUID>.tmp` is left alone; checked with `lstat`, so a symbolic link is never followed). Every considered file is
/// deleted once read. A file that does not decode, has a `schemaVersion` other than 1, belongs to another session,
/// names an unknown command, or whose ID is not its file name is rejected. Labels are cut to 200 characters. The
/// session folder and `control/` are opened without following a symbolic link, and every file is reached relative
/// to them.
public struct ControlInbox: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")
    static let maxRequestBytes = 4_096
    static let maxLabelLength = 200

    public enum Item: Sendable, Equatable {
        case request(ControlRequest)
        case rejected(file: String, reason: String)
    }

    public let session: URL
    public let sessionID: String
    /// A problem with `control/` itself is logged once, not on every poll.
    private var reportedFolderProblem = false

    public init(session: URL, sessionID: String) {
        self.session = session; self.sessionID = sessionID
    }

    /// Reads and removes valid or invalid request files (rules above); returns rejected files first (by name), then
    /// requests in (sentAtNanos, id) order, never by `createdAt`.
    public mutating func poll() -> [Item] {
        let folder: Int32
        switch Self.openControlFolder(session) {
        case .missing:
            return []
        case .unusable(let reason):
            if !reportedFolderProblem {
                reportedFolderProblem = true
                let id = sessionID
                Self.log.error("Session \(id, privacy: .public): control requests unreadable: \(reason, privacy: .public)")
            }
            return []
        case .opened(let descriptor):
            folder = descriptor
        }
        defer { Darwin.close(folder) }
        var rejected: [Item] = []
        var requests: [ControlRequest] = []
        for name in Self.entries(of: folder).sorted() where Self.isRequestFileName(name) {
            switch take(name, in: folder) {
            case .gone: continue
            case .rejected(let reason): rejected.append(.rejected(file: name, reason: reason))
            case .request(let request): requests.append(request)
            }
        }
        requests.sort { ($0.sentAtNanos ?? 0, $0.id) < ($1.sentAtNanos ?? 0, $1.id) }
        return rejected + requests.map(Item.request)
    }

    /// Deletes every request file (`<name>.json`, no dot prefix) left in `control/`, as the recorder does at exit.
    /// Returns how many it removed.
    @discardableResult
    public static func removeLeftovers(session: URL) -> Int {
        guard case .opened(let folder) = openControlFolder(session) else { return 0 }
        defer { Darwin.close(folder) }
        var removed = 0
        for name in entries(of: folder) where !name.hasPrefix(".") && name.hasSuffix(".json") {
            if remove(name, in: folder) { removed += 1 }
        }
        return removed
    }

    // MARK: - One file

    private enum Taken {
        case request(ControlRequest)
        case rejected(String)
        /// Removed by someone else meanwhile.
        case gone
    }

    private func take(_ name: String, in folder: Int32) -> Taken {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .gone : .rejected("It cannot be inspected: \(String(cString: strerror(errno))).")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            Self.remove(name, in: folder)
            return .rejected("It is not a regular file.")
        }
        guard info.st_size <= Self.maxRequestBytes else {
            Self.remove(name, in: folder)
            return .rejected("It is larger than 4 KiB.")
        }
        let data: Data
        switch Self.read(name, in: folder) {
        case .success(let bytes): data = bytes
        case .failure(let problem):
            if case .gone = problem { return .gone }
            Self.remove(name, in: folder)
            return .rejected(problem.reason)
        }
        Self.remove(name, in: folder)
        return decode(data, fileName: name)
    }

    private func decode(_ data: Data, fileName: String) -> Taken {
        struct Header: Decodable {
            var schemaVersion: Int?
            var id: String?
            var sessionID: String?
            var command: String?
        }
        let decoder = HolosJSON.decoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            return .rejected("It is not a control request.")
        }
        guard header.schemaVersion == 1 else {
            return .rejected("Its schema version is not supported.")
        }
        guard header.sessionID == sessionID else { return .rejected("It is for another session.") }
        guard let command = header.command, ControlCommand(rawValue: command) != nil else {
            return .rejected("Its command is unknown.")
        }
        guard header.id.map({ "\($0).json" }) == fileName else {
            return .rejected("Its ID does not match its file name.")
        }
        guard var request = try? decoder.decode(ControlRequest.self, from: data) else {
            return .rejected("It is not a control request.")
        }
        if let label = request.label, label.count > Self.maxLabelLength {
            request.label = String(label.prefix(Self.maxLabelLength))
        }
        return .request(request)
    }

    // MARK: - Descriptors

    private enum Folder {
        case opened(Int32)
        case missing
        case unusable(String)
    }

    private enum ReadProblem: Error {
        case gone
        case unreadable(String)

        var reason: String {
            switch self {
            case .gone: "It was removed."
            case .unreadable(let reason): reason
            }
        }
    }

    /// Opens `control/` in `session`, both without following a symbolic link.
    private static func openControlFolder(_ session: URL) -> Folder {
        guard session.isFileURL else { return .unusable("the session is not a file URL") }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let sessionFD = Darwin.open(session.path, flags)
        guard sessionFD >= 0 else {
            return errno == ENOENT ? .missing : .unusable("the session folder cannot be opened (\(errno))")
        }
        defer { Darwin.close(sessionFD) }
        let folder = openat(sessionFD, "control", flags)
        guard folder >= 0 else {
            let code = errno
            if code == ENOENT { return .missing }
            if code == ELOOP || code == ENOTDIR { return .unusable("control is not a folder") }
            return .unusable("control cannot be opened (\(code))")
        }
        return .opened(folder)
    }

    /// The names in the open folder `folder` (not closed).
    private static func entries(of folder: Int32) -> [String] {
        let copy = dup(folder)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else {
            Darwin.close(copy)
            return []
        }
        defer { closedir(directory) }
        // fdopendir shares the offset with `folder`; start from the beginning.
        rewinddir(directory)
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func isRequestFileName(_ name: String) -> Bool {
        guard !name.hasPrefix("."), name.hasSuffix(".json") else { return false }
        return UUID(uuidString: String(name.dropLast(5))) != nil
    }

    private static func read(_ name: String, in folder: Int32) -> Result<Data, ReadProblem> {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return .failure(.gone) }
            return .failure(.unreadable("It cannot be opened: \(String(cString: strerror(code))).") )
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.unreadable("It is not a regular file."))
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maxRequestBytes + 1)
        while data.count <= maxRequestBytes {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.unreadable("It cannot be read: \(String(cString: strerror(errno)))."))
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count <= maxRequestBytes else { return .failure(.unreadable("It is larger than 4 KiB.")) }
        return .success(data)
    }

    /// Removes the entry itself (a symbolic link, never its target; an empty folder). False when it could not.
    @discardableResult
    private static func remove(_ name: String, in folder: Int32) -> Bool {
        if unlinkat(folder, name, 0) == 0 { return true }
        if errno == ENOENT { return false }
        if (errno == EPERM || errno == EISDIR), unlinkat(folder, name, AT_REMOVEDIR) == 0 { return true }
        log.error("Cannot remove the control file \(name, privacy: .private): \(String(cString: strerror(errno)), privacy: .public)")
        return false
    }
}
