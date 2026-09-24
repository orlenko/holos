import Foundation
import HolosCore
import HolosStorage
import os
import Synchronization

/// The only writer of a recorder's `status.json` (docs/meeting-design.md §4.1, §4.6). Every write is atomic, bumps
/// `sequence`, and sets `updatedAt`; a heartbeat rewrites the file every second from launch until `finish`, so the
/// status stays fresh through transcription and post-processing. After a successful `finish` the file says `exited`
/// and later updates are ignored.
public actor StatusWriter {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")
    /// A final write is tried this many times, `finishBackoff` × the attempt number apart.
    static let finishAttempts = 3
    static let finishBackoff: Duration = .milliseconds(100)

    /// Writes one status to its file (atomically, outside tests).
    typealias FileWrite = @Sendable (RecorderStatus, URL) throws -> Void

    private let url: URL
    private var status: RecorderStatus
    /// status.json says exited.
    private var finished = false
    private let interval: Duration
    private let heartbeat: Heartbeat
    private let fileWrite: FileWrite
    /// Tests only: sees every status written, in order.
    private let observer: (@Sendable (RecorderStatus) -> Void)?

    /// Writes `initial` and starts the heartbeat (rewrite every `heartbeat` until `finish`).
    public init(session: URL, initial: RecorderStatus, heartbeat: Duration = .seconds(1)) throws {
        try self.init(session: session, initial: initial, heartbeat: heartbeat, observer: nil)
    }

    /// `write` replaces the atomic file write (tests inject failures).
    init(session: URL, initial: RecorderStatus, heartbeat interval: Duration,
         observer: (@Sendable (RecorderStatus) -> Void)?, write: FileWrite? = nil) throws {
        let statusURL = SessionPaths.status(session)
        let fileWrite = write ?? { status, url in try AtomicFile.writeJSON(status, to: url) }
        var first = initial
        first.sequence += 1
        first.updatedAt = Date()
        try fileWrite(first, statusURL)
        observer?(first)
        url = statusURL
        status = first
        self.fileWrite = fileWrite
        self.observer = observer
        self.interval = interval
        heartbeat = Heartbeat()
        heartbeat.start(every: interval) { [weak self] in await self?.beat() }
    }

    deinit { heartbeat.stop() }

    /// Bumps sequence, sets updatedAt, writes atomically. Does nothing after `finish`. Only `finish` sets phase
    /// `exited`: an update that sets it keeps the previous phase.
    public func update(_ change: @Sendable (inout RecorderStatus) -> Void) throws {
        guard !finished else { return }
        let phase = status.phase
        change(&status)
        if status.phase == .exited { status.phase = phase }
        try write()
    }

    /// Stops the heartbeat and writes phase exited with `exit`, trying `finishAttempts` times. Only a write that
    /// succeeded makes the writer finished. When every attempt fails, the error is thrown, the status keeps its last
    /// written phase, the heartbeat starts again (so the file stays fresh while this process lives), and a later
    /// `finish` tries again.
    public func finish(exit: RecorderExit) async throws {
        guard !finished else { return }
        heartbeat.stop()
        var attempt = 1
        while true {
            // Built each time from the last status written: an update may land during the pause.
            var final = status
            final.phase = .exited
            final.exit = exit
            final.progress = nil
            do {
                try write(final)
                finished = true
                return
            } catch {
                Self.log.error("Session \(self.status.sessionID, privacy: .public): cannot write the exited status (attempt \(attempt, privacy: .public) of \(Self.finishAttempts, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                guard attempt < Self.finishAttempts else {
                    heartbeat.start(every: interval) { [weak self] in await self?.beat() }
                    throw error
                }
            }
            // Not cancellable: a cancelled recorder still needs its exited status.
            let pause = Self.finishBackoff * attempt
            await Task.detached { try? await Task.sleep(for: pause) }.value
            // Another call may have finished meanwhile.
            if finished { return }
            attempt += 1
        }
    }

    public func current() -> RecorderStatus { status }

    private func beat() {
        guard !finished else { return }
        do { try write() } catch {
            Self.log.error("Session \(self.status.sessionID, privacy: .public): cannot refresh status.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write() throws { try write(status) }

    /// Writes `next` with the next sequence and the current time; `status` becomes it only once it is written.
    private func write(_ next: RecorderStatus) throws {
        var next = next
        next.sequence = status.sequence + 1
        next.updatedAt = Date()
        try fileWrite(next, url)
        status = next
        observer?(next)
    }
}

/// A repeating task that calls an action every `interval` until stopped. Beats are due at fixed times from the start,
/// so a slow write does not push every later beat back.
private final class Heartbeat: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func start(every interval: Duration, _ action: @escaping @Sendable () async -> Void) {
        let beat = Task {
            let clock = ContinuousClock()
            var due = clock.now
            while !Task.isCancelled {
                due = due.advanced(by: interval)
                if due < clock.now { due = clock.now }
                do { try await Task.sleep(until: due, clock: clock) } catch { return }
                await action()
            }
        }
        task.withLock { $0 = beat }
    }

    func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
    }
}
