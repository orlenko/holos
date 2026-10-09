import CryptoKit
import Darwin
import Foundation
import HolosCore
import Synchronization

/// Calls `onExit` once, on its own queue, when the process `pid` ends (a quit, a crash, a SIGKILL). `isAlive` says
/// whether that process still runs: asked once the watch is registered, so a process that ended before (no exit event
/// comes for it, and its pid may belong to another one by then) is seen too. `voiceislocal say` started by the app
/// (`--parent-pid`) watches the app this way, with `getppid() == pid`: its parent is the app until the app ends.
public final class ProcessExitWatch: @unchecked Sendable {
    private let source: any DispatchSourceProcess
    private final class Once: Sendable {
        let done = Mutex(false)
        /// True the first time only.
        func take() -> Bool { done.withLock { value in defer { value = true }; return !value } }
    }

    private let once = Once()

    public init(pid: Int32, isAlive: @escaping @Sendable () -> Bool, onExit: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "ca.orlenko.holos.process-exit")
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        let fire: @Sendable () -> Void = { [once] in if once.take() { onExit() } }
        source.setEventHandler(handler: fire)
        source.resume()
        queue.async { if !isAlive() { fire() } }
    }

    /// Whether the process was seen to end.
    public var fired: Bool { once.done.withLock { $0 } }

    public func cancel() { source.cancel() }
}

/// One `voiceislocal say` at a time writes a given output: a helper left running by an app that ended (a crash) holds
/// the lock until it exits, and the helper the relaunched app starts for the same part waits for it. The lock files
/// live in a folder of the temporary directory (never beside the output, in a reading's folder), one per output path,
/// and stay there: removing one while another process waits on it would let two hold it.
public enum NaturalOutputLock {
    public static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("holos-output-locks", isDirectory: true)
    }

    /// The lock file for `output` in `folder`.
    public static func file(for output: URL, in folder: URL = folder) -> URL {
        let path = output.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(output.lastPathComponent).path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(digest).lock")
    }

    /// Waits, polling every `interval`, until no other process (or descriptor) holds the lock for `output`; returns
    /// the descriptor that holds it now (`release`, or the process's exit, lets it go). `waiting` is called once when
    /// the lock is held by another. A cancellation ends the wait with `CancellationError`.
    public static func acquire(for output: URL, in folder: URL = folder, interval: Duration = .milliseconds(200),
                               waiting: @Sendable () -> Void = {}) async throws -> Int32 {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = file(for: output, in: folder)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw HolosError.io("Could not open \(url.path): \(String(cString: strerror(errno)))")
        }
        var told = false
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                let reason = String(cString: strerror(errno))
                close(descriptor)
                throw HolosError.io("Could not lock \(url.path): \(reason)")
            }
            if !told {
                told = true
                waiting()
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    public static func release(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// How `voiceislocal say` renders for the app (`--parent-pid`).
public enum NaturalHelperRun {
    /// Runs `work` once no other process holds the lock of `output` (`NaturalOutputLock`: an earlier helper, left
    /// running by an app that ended, is waited for; `waiting` says so once), and cancels it when the process `parent`
    /// ends (`isAlive` false): `work`'s own cleanup runs, then `parentEnded`, and the error says the app quit.
    @MainActor public static func whileParentRuns<T: Sendable>(
        _ parent: Int32, isAlive: @escaping @Sendable () -> Bool, output: URL,
        lockFolder: URL = NaturalOutputLock.folder, interval: Duration = .milliseconds(200), waiting: @escaping @Sendable () -> Void = {},
        parentEnded: () -> Void = {}, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let task = Task { @MainActor in
            let lock = try await NaturalOutputLock.acquire(for: output, in: lockFolder, interval: interval,
                                                           waiting: waiting)
            defer { NaturalOutputLock.release(lock) }
            return try await work()
        }
        let watch = ProcessExitWatch(pid: parent, isAlive: isAlive) { task.cancel() }
        defer { watch.cancel() }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            guard watch.fired else { throw error }
            parentEnded()
            throw HolosError.incomplete("The app that started this render has quit.")
        }
    }
}
