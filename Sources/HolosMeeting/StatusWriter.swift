import Foundation
import HolosCore
import HolosStorage
import os
import Synchronization

/// The only writer of a recorder's `status.json` (docs/meeting-design.md §4.1, §4.6). Every write is atomic, bumps
/// `sequence`, and sets `updatedAt`; a heartbeat rewrites the file every second from launch until `finish`, so the
/// status stays fresh through transcription and post-processing. After `finish` the file says `exited` and later
/// updates are ignored.
public actor StatusWriter {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    private let url: URL
    private var status: RecorderStatus
    private var finished = false
    private let heartbeat: Heartbeat
    /// Tests only: sees every status written, in order.
    private let observer: (@Sendable (RecorderStatus) -> Void)?

    /// Writes `initial` and starts the heartbeat (rewrite every `heartbeat` until `finish`).
    public init(session: URL, initial: RecorderStatus, heartbeat: Duration = .seconds(1)) throws {
        try self.init(session: session, initial: initial, heartbeat: heartbeat, observer: nil)
    }

    init(session: URL, initial: RecorderStatus, heartbeat interval: Duration,
         observer: (@Sendable (RecorderStatus) -> Void)?) throws {
        let statusURL = SessionPaths.status(session)
        var first = initial
        first.sequence += 1
        first.updatedAt = Date()
        try AtomicFile.writeJSON(first, to: statusURL)
        observer?(first)
        url = statusURL
        status = first
        self.observer = observer
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

    /// Writes phase exited with `exit` and stops the heartbeat.
    public func finish(exit: RecorderExit) throws {
        guard !finished else { return }
        finished = true
        heartbeat.stop()
        status.phase = .exited
        status.exit = exit
        status.progress = nil
        try write()
    }

    public func current() -> RecorderStatus { status }

    private func beat() {
        guard !finished else { return }
        do { try write() } catch {
            Self.log.error("Session \(self.status.sessionID, privacy: .public): cannot refresh status.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write() throws {
        status.sequence += 1
        status.updatedAt = Date()
        try AtomicFile.writeJSON(status, to: url)
        observer?(status)
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
