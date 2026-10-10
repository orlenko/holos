import Darwin
import Foundation
import HolosCore

/// The reservation of a reading's output: a hidden file beside the destination that names the
/// process making it. Readings of different text or settings for one output have different
/// caches (see `ReadingOutput.locate`), possibly under different support folders
/// (`HOLOS_SUPPORT_DIR`) or users, so this is what stops a second one before it renders anything.
/// The destination's folder is the one place every producer of that file finds. The reservation
/// needs neither `flock` on the destination's volume nor that the next producer be the same user:
/// - it is created with `O_CREAT | O_EXCL`, mode 0644, and holds a `Record` (host name, the Mac's
///   hardware UUID, process ID and start time, user ID, creation time), so any user can read who
///   holds it;
/// - an existing one is held while its process runs: on this Mac (the same hardware UUID; two
///   Macs can share a host name), a process with its ID and the same start time (a reused ID has
///   another). One whose process has ended (a run killed before its release) is removed and
///   taken, whoever owns it, under a takeover guard (see `takeOver`), so of two runs taking it
///   over at once exactly one goes on. One from another Mac (a shared network folder), or with no
///   hardware UUID, cannot be checked, one that cannot be read or decoded (a run
///   killed between creating and writing it) is not trusted, and one that cannot be removed
///   (another user's file in a sticky shared folder) stays: each is refused with a message
///   naming the file and who can delete it;
/// - it is removed on release when it still holds this run's record.
/// It is named from the file's conservative identity (see `ReadingPathIdentity.Rule.lock`), so
/// "Book.m4a" and "book.m4a" on a case-insensitive volume, or one name in NFC and NFD, share it.
/// Its name and its guard's are among the names `ReadingOutput` checks against the volume's
/// limits before anything is rendered (see `ReadingOutput.outputFolderNameLength`). Its path is
/// the destination folder as spelled (see `RawFilePath`). A reading without `--output` holds one
/// in its cache, beside its `.m4a`.
final class ReadingOutputReservation: @unchecked Sendable {
    struct Record: Codable, Equatable {
        /// `gethostname`, for messages: two Macs can share a host name.
        var host: String
        var pid: Int32
        /// The process's start time, microseconds since 1970 (see `processStart`).
        var start: Int64
        var uid: UInt32
        /// Seconds since 1970.
        var created: Double
        /// The Mac's hardware UUID (see `machineID`), which decides whether the process can be
        /// checked here; empty when it could not be read.
        var machine: String = ReadingOutputReservation.machineID

        /// This process's record, created now.
        static func current() -> Record {
            let pid = getpid()
            return Record(host: hostName(), pid: pid, start: processStart(pid) ?? 0, uid: getuid(),
                          created: Date().timeIntervalSince1970)
        }
    }

    /// A record is well under this; a larger file is not a reservation.
    static let maximumBytes = 4_096

    let path: String
    let record: Record

    private init(path: String, record: Record) {
        self.path = path
        self.record = record
    }

    /// `.holos-output-<first 32 hex digits of the identity's hash>.lock`.
    static func name(for output: URL) -> String {
        name(hash: sha256(Data(ReadingPathIdentity.key(output).utf8)))
    }

    private static func name(hash: String) -> String { ".holos-output-\(hash.prefix(32)).lock" }

    static let guardSuffix = ".takeover"

    /// The longest name a reservation writes beside the output: its guard's.
    static let longestNameLength = (name(hash: String(repeating: "0", count: 32)) + guardSuffix).utf8.count

    /// The reservation for `output`. A reading without `--output` takes one too, in its cache
    /// (once that exists), so a run given that cache's `.m4a` as its `--output` is refused while
    /// it renders.
    static func acquire(output: URL) throws -> ReadingOutputReservation {
        // The folder as spelled, links resolved (see `RawFilePath`).
        let folder = RawFilePath.resolvingFolder(of: output).deletingLastPathComponent()
        return try acquire(path: RawFilePath.appending(name(for: output), to: folder).path, output: output)
    }

    /// The takeover guard of the reservation at `path` (see `takeOver`).
    static func guardPath(for path: String) -> String { path + guardSuffix }

    /// Where a takeover may be interleaved with another run's, for tests: `found` after a stale
    /// reservation is read and before its guard is taken, `verified` under the guard after the
    /// reservation is checked again and before it is removed.
    enum TakeoverStep: Sendable { case found, verified }

    /// Runs at each `TakeoverStep` (tests).
    @TaskLocal static var takeoverStep: (@Sendable (TakeoverStep) -> Void)? = nil

    /// Creates the reservation at `path` for `output`, taking over one whose process has ended.
    static func acquire(path: String, output: URL) throws -> ReadingOutputReservation {
        let mine = Record.current()
        // A retry follows a holder's release, or a takeover that found the reservation changed.
        for _ in 0..<3 {
            if let made = try create(mine, at: path, output: output) { return made }
            switch holder(at: path) {
            case .gone:
                continue
            case .unreadable(let reason):
                throw HolosError.unavailable("Another reading may be under way for \(output.path): its reservation \(path) \(reason). If no reading of that file is running, delete \(path).")
            case .running(let record):
                throw HolosError.unavailable("Another reading is already being made for \(output.path): process \(record.pid) of \(userName(record.uid)), since \(date(record.created)). Its reservation is \(path).")
            case .otherHost(let record):
                throw HolosError.unavailable("Another reading is already being made for \(output.path) on \(computer(record)) (process \(record.pid) of user ID \(record.uid), since \(date(record.created))), which cannot be checked from here. If no reading of that file is running there, delete \(path).")
            case .ended(let record, let owner, let file):
                takeoverStep?(.found)
                if let made = try takeOver(path: path, stale: record, owner: owner, file: file, mine: mine,
                                           output: output) {
                    return made
                }
            }
        }
        throw HolosError.unavailable("Another reading is already being made for \(output.path). Its reservation is \(path).")
    }

    /// Creates the reservation at `path` holding `record`; nil when a file is already there.
    private static func create(_ record: Record, at path: String, output: URL) throws -> ReadingOutputReservation? {
        let descriptor = open(RawFilePath.system(path), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else {
            let error = errno
            guard error == EEXIST else {
                throw HolosError.io("Could not reserve \(output.path) with \(path): \(String(cString: strerror(error)))")
            }
            return nil
        }
        try write(record, to: descriptor, path: path, output: output)
        return ReadingOutputReservation(path: path, record: record)
    }

    /// Replaces the reservation at `path`, the file `file` holding `stale` (made by a process
    /// that has ended), with this run's (`mine`); nil when the reservation changed since it was
    /// read, for the caller to read again.
    ///
    /// Checking that `path` is still that file and removing it are two steps, and between them
    /// another run could replace it, so both happen only while holding the reservation's takeover
    /// guard (`guardPath(for:)`): a file created with `O_CREAT | O_EXCL`, holding this run's
    /// record, and removed once this run's reservation is in place. Only a guard holder removes
    /// a reservation it did not make, so the file checked under the guard is the file removed; a
    /// run that finds the guard held is refused (see `takeGuard`); and a run that read the same
    /// stale reservation but takes the guard later finds this run's reservation instead and does
    /// not touch it.
    private static func takeOver(path: String, stale: Record, owner: uid_t, file: (device: dev_t, inode: ino_t),
                                 mine: Record, output: URL) throws -> ReadingOutputReservation? {
        let guardPath = guardPath(for: path)
        try takeGuard(guardPath, reservation: path, stale: stale, owner: owner, mine: mine, output: output)
        defer { removeIfHolding(guardPath, mine) }
        guard case .ended(let current, _, let still) = holder(at: path), current == stale,
              still.device == file.device, still.inode == file.inode else { return nil }
        takeoverStep?(.verified)
        guard unlink(RawFilePath.system(path)) == 0 || errno == ENOENT else {
            let reason = String(cString: strerror(errno))
            throw HolosError.unavailable("A reading for \(output.path) that is no longer running (process \(stale.pid) of \(userName(stale.uid))) left its reservation \(path), and it cannot be removed here: \(reason). \(userName(owner).capitalizedFirst), who owns it, or an administrator can delete it.")
        }
        return try create(mine, at: path, output: output)
    }

    /// Creates the takeover guard at `guardPath` holding `mine`, or refuses, naming the
    /// reservation and its guard, while another run holds it. A guard is never removed by a run
    /// that did not make it, so there is no check-then-remove step for two runs to interleave in.
    /// One whose run has ended (killed during its takeover, a few system calls long) is refused
    /// like one that cannot be read: the message names the file to delete once no reading of the
    /// output runs.
    private static func takeGuard(_ guardPath: String, reservation path: String, stale: Record, owner: uid_t,
                                  mine: Record, output: URL) throws {
        for _ in 0..<2 {
            let descriptor = open(RawFilePath.system(guardPath), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o644)
            if descriptor >= 0 {
                try write(mine, to: descriptor, path: guardPath, output: output)
                return
            }
            let error = errno
            guard error == EEXIST else {
                // Nothing can be created beside it (a read-only folder, or another user's sticky one).
                throw HolosError.unavailable("A reading for \(output.path) that is no longer running (process \(stale.pid) of \(userName(stale.uid))) left its reservation \(path), and it cannot be replaced here: \(String(cString: strerror(error))). \(userName(owner).capitalizedFirst), who owns it, or an administrator can delete it.")
            }
            switch holder(at: guardPath) {
            case .gone:
                continue
            case .running(let record):
                throw HolosError.unavailable("Another reading is already being made for \(output.path): process \(record.pid) of \(userName(record.uid)) is taking over its reservation \(path) (with \(guardPath)).")
            case .otherHost(let record):
                throw HolosError.unavailable("Another reading is already being made for \(output.path): process \(record.pid) of user ID \(record.uid) on \(computer(record)) is taking over its reservation \(path) (with \(guardPath)), which cannot be checked from here. If no reading of that file is running there, delete \(guardPath).")
            case .unreadable(let reason):
                throw HolosError.unavailable("Another reading may be taking over the reservation \(path) of \(output.path): its takeover file \(guardPath) \(reason). If no reading of that file is running, delete \(guardPath).")
            case .ended(let record, let guardOwner, _):
                throw HolosError.unavailable("A reading of \(output.path) (process \(record.pid) of \(userName(record.uid))) stopped while taking over its reservation \(path) and left the takeover file \(guardPath). If no reading of that file is running, delete \(guardPath) (\(userName(guardOwner)) owns it).")
            }
        }
        throw HolosError.unavailable("Another reading is already being made for \(output.path): its reservation \(path) is being taken over (with \(guardPath)).")
    }

    /// Writes `record` into the reservation (or guard) just created, readable by every user
    /// whatever the umask. One that cannot be written is removed.
    private static func write(_ record: Record, to descriptor: Int32, path: String, output: URL) throws {
        defer { close(descriptor) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Strings and numbers only: this cannot fail.
        guard let data = try? encoder.encode(record) else { preconditionFailure("Reservation did not encode.") }
        var failure: Int32 = fchmod(descriptor, 0o644) == 0 ? 0 : errno
        if failure == 0 {
            failure = data.withUnsafeBytes { bytes -> Int32 in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    offset += written
                }
                return 0
            }
        }
        guard failure == 0 else {
            _ = unlink(RawFilePath.system(path))
            throw HolosError.io("Could not reserve \(output.path) with \(path): \(String(cString: strerror(failure)))")
        }
    }

    enum Holder {
        /// Removed since it was found.
        case gone
        /// Why it cannot be trusted, as "cannot be read (reason)".
        case unreadable(String)
        /// Its process runs on this Mac.
        case running(Record)
        /// Made on another Mac (or its Mac cannot be told).
        case otherHost(Record)
        /// Made on this Mac by a process that has ended; `owner` is the file's owner, `file` which
        /// file was read.
        case ended(Record, owner: uid_t, file: (device: dev_t, inode: ino_t))
    }

    /// Who holds the reservation at `path`.
    static func holder(at path: String) -> Holder {
        let descriptor = open(RawFilePath.system(path), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            let error = errno
            return error == ENOENT ? .gone : .unreadable("cannot be read (\(String(cString: strerror(error))))")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .unreadable("is not a regular file")
        }
        guard let data = readAll(descriptor), let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return .unreadable("does not say which process holds it")
        }
        // Only a record from this Mac (by hardware UUID; host names can repeat) can be checked here.
        guard !record.machine.isEmpty, record.machine == machineID else { return .otherHost(record) }
        if let start = processStart(record.pid), start == record.start { return .running(record) }
        return .ended(record, owner: metadata.st_uid, file: (metadata.st_dev, metadata.st_ino))
    }

    private static func readAll(_ descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        while data.count <= maximumBytes {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
        }
        return nil
    }

    /// When process `pid` started, in microseconds since 1970; nil when no such process runs (a
    /// zombie, which has ended, included).
    static func processStart(_ pid: Int32) -> Int64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid, Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }

    /// This Mac's hardware UUID (`gethostuuid`), the same for every process and user on it and
    /// different on every other Mac, whatever their host names; empty when it cannot be read.
    static let machineID: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&bytes, &wait) == 0 else { return "" }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }()

    /// The computer a record from another Mac names, for messages.
    private static func computer(_ record: Record) -> String {
        guard !record.host.isEmpty else { return "another computer" }
        return record.host == hostName() ? "another computer also named \(record.host)" : record.host
    }

    static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func userName(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "user ID \(uid)" }
        return "user \(String(cString: name))"
    }

    private static func date(_ seconds: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    /// Removes the file at `path` (a reservation or its guard) when it still holds `record`: one
    /// removed by hand and made again by another run is that run's.
    private static func removeIfHolding(_ path: String, _ record: Record) {
        let descriptor = open(RawFilePath.system(path), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return }
        let data = readAll(descriptor)
        close(descriptor)
        guard let data, (try? JSONDecoder().decode(Record.self, from: data)) == record else { return }
        _ = unlink(RawFilePath.system(path))
    }

    /// Whether `release` ran.
    private let released = NSLock()
    private var isReleased = false

    /// Removes the reservation now (see `removeIfHolding`), where the caller runs (a render does it off the main
    /// actor: the output folder may be on a slow share); once.
    func release() {
        released.lock()
        defer { released.unlock() }
        guard !isReleased else { return }
        isReleased = true
        Self.removeIfHolding(path, record)
    }

    deinit { release() }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
