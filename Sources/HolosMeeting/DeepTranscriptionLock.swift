import Darwin
import Foundation
import HolosCore

/// The one deep transcription pass running on this Mac (docs/meeting-design.md §4.16, "App"): `voiceislocal session
/// deep-transcribe` holds an exclusive `flock` on `<supportRoot>/deep-transcription.lock` for its whole life and
/// writes who it is into the file once it holds it. The kernel lets go of the lock when the process ends, however it
/// ends, so while the lock is held its holder is alive and the pid it wrote is still its own: the app decides that a
/// pass is running only by trying the lock, and saves no process identity of its own.
public enum DeepTranscriptionLock {
    /// Who holds the lock, as it wrote it.
    public struct Holder: Codable, Sendable, Equatable {
        public var pid: Int32
        public var sessionID: String
        /// Run with `--force` (Make Final Transcript Now).
        public var force: Bool

        public init(pid: Int32, sessionID: String, force: Bool) {
            self.pid = pid; self.sessionID = sessionID; self.force = force
        }
    }

    public enum State: Sendable, Equatable {
        /// No pass is running.
        case free
        /// A pass is running: its holder, or nil for the moment between taking the lock and writing it.
        case held(Holder?)
    }

    public static var url: URL { HolosPaths.supportRoot.appendingPathComponent("deep-transcription.lock") }

    /// Why a pass did not start: another holds the lock.
    public static let busyMessage = "Another final transcript is being made on this Mac; try again when it ends."

    /// The lock, held until `release` or the process ends.
    public final class Taken: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

        public func release() {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
        }

        deinit { release() }
    }

    /// Takes the lock for `holder` and writes it into the file. Another process probing the lock (`state`) holds it
    /// for an instant, so a held lock is tried again every 20 ms for `wait`; nil when another pass still holds it.
    public static func take(_ holder: Holder, at url: URL = url, wait: Duration = .seconds(2)) throws -> Taken? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else {
            throw HolosError.io("Cannot open the deep transcription lock: \(errnoText(errno)).")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK, clock.now < deadline else {
                Darwin.close(fd)
                if code == EWOULDBLOCK { return nil }
                throw HolosError.io("Cannot take the deep transcription lock: \(errnoText(code)).")
            }
            usleep(20_000)
        }
        let taken = Taken(descriptor: fd)
        let data = try HolosJSON.encoder(pretty: false).encode(holder)
        guard ftruncate(fd, 0) == 0,
              data.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == data.count else {
            let text = errnoText(errno)
            taken.release()
            throw HolosError.io("Cannot write the deep transcription lock: \(text).")
        }
        return taken
    }

    /// Whether a pass holds the lock now, and who (read while it is held, so its pid is its own). A missing or
    /// unreadable lock file is free: a pass that then starts and finds it held says so (`busyMessage`).
    public static func state(at url: URL = url) -> State {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .free }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_SH | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else { return .free }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return .held(nil) }
            return .held(try? HolosJSON.decoder().decode(Holder.self, from: Data(buffer[..<count])))
        }
        flock(fd, LOCK_UN)
        return .free
    }

    /// Signals the pass on `sessionID` with `signal`, only while it still holds the lock (checked again right before
    /// the signal): its pid is then its own. Returns whether it was signalled.
    @discardableResult
    public static func signal(_ sessionID: String, _ signal: Int32 = SIGTERM, at url: URL = url) -> Bool {
        guard case .held(let holder?) = state(at: url), holder.sessionID == sessionID, holder.pid > 0 else {
            return false
        }
        return kill(holder.pid, signal) == 0
    }

    private static func errnoText(_ code: Int32) -> String { String(cString: strerror(code)) }
}
