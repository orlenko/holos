import Darwin
import Foundation
import HolosCore
import HolosStorage
import os
import Synchronization

/// The end of a recording: the one place that writes status.json `exited`, and where the recorder lets go of the
/// locks it still holds at the end (docs/meeting-design.md §4.6 steps 8–9). The recorder ends every run through `finish` (or `finishUnlessWritten`
/// after an error), and gives its processing lease back through `finish` or `release`.
///
/// When `StatusWriter` cannot write `exited` even after its retries, the writer lock and the leases handed here go to
/// an `ExitRetry`, which keeps trying the exited status in the background and releases them once it is written (or
/// once its probe of the session folder fails), so the session reads as busy rather than dead meanwhile. An
/// in-process recorder runs inside the app, which does not exit after a meeting, so the locks must not wait for the
/// process to end. If the process exits first (a child recorder), the system releases them, and recovery finds the
/// status unfinished as for any recorder that ended without saying so.
///
/// Invariants:
/// 1. The first exit (`finish` or `finishUnlessWritten`) closes live text, stops the stopped-request poll, attempts
///    `ControlInbox.closePublication` (its result is not checked), polls requests once more, then tries to write
///    `exited`. A later exit only tries the write again if it has not succeeded.
/// 2. An exit releases the writer lock as its last step, after `exited` was written or a write of it failed; `finish`
///    lets its lease go after that.
/// 3. After a failed write, until an exit here writes `exited`, the writer lock and every lease given to `finish` or
///    `release` go to `exitRetry` instead of being released.
/// 4. Leftover request files and the closed marker are deleted only after `exited` was written (here or by
///    `exitRetry`).
@MainActor
final class RecorderExitSequence {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    private let archive: SessionArchive
    private let status: StatusWriter
    private let liveText: LiveTextPublisher
    private let tuning: RecorderTuning
    private let exitStatusWait: ExitStatusWait?
    /// Polls `control/` once and answers what it finds (the recorder's `answerStoppedRequests`).
    private let answerRequests: @MainActor () async -> Void
    /// The exit was published (or tried): requests are no longer answered.
    private var exited = false
    /// status.json says exited.
    private var exitWritten = false
    /// The exited status could not be written: the session's last lock stays held until it is (`exitRetry`) or this
    /// process exits, so liveness never reads a recorder that is still shutting down as dead.
    private var holdsLocksUntilExit: Bool { exited && !exitWritten }
    /// Keeps trying the exited status in the background once `StatusWriter` gave up, and holds the locks until then.
    private var exitRetry: ExitRetry?
    private var stoppedInbox: Task<Void, Never>?

    init(archive: SessionArchive, status: StatusWriter, liveText: LiveTextPublisher, tuning: RecorderTuning,
         exitStatusWait: ExitStatusWait?, answerRequests: @escaping @MainActor () async -> Void) {
        self.archive = archive
        self.status = status
        self.liveText = liveText
        self.tuning = tuning
        self.exitStatusWait = exitStatusWait
        self.answerRequests = answerRequests
    }

    /// After capture stops, every request is acknowledged `ignored` once a second until exit (§4.6).
    func answerRequestsWhileStopping() {
        guard stoppedInbox == nil else { return }
        let interval = tuning.stoppedPoll
        let answerRequests = self.answerRequests
        stoppedInbox = Task {
            while !Task.isCancelled {
                await answerRequests()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Ends the recording: `exitStatus(exit)`, then the processing lease, if there is one, goes (invariant 2).
    func finish(_ exit: RecorderExit, releasing lease: ProcessingLease? = nil) async {
        await exitStatus(exit)
        release(lease)
    }

    /// Ends a run that failed after its audio was saved: `finish` with the exit `makeExit` builds when status.json
    /// does not say exited yet; otherwise only makes sure the writer lock is released.
    func finishUnlessWritten(_ makeExit: () -> RecorderExit) async {
        if !exitWritten {
            await exitStatus(makeExit())
        } else {
            await releaseWriterLock()
        }
    }

    /// Releases the processing lease, unless the exited status could not be written: then `exitRetry` holds it.
    func release(_ lease: ProcessingLease?) {
        guard let lease else { return }
        if holdsLocksUntilExit, let exitRetry {
            exitRetry.hold(lease)
        } else {
            lease.release()
        }
    }

    /// Stops answering requests (after a last answer), writes phase `exited`, deletes leftover requests, and only then
    /// releases the writer lock, so for a caller that finished the archive keeping it, `RecorderChannel.liveness`
    /// never sees the session unlocked before it says exited. Called again, it tries the exited status again if it was
    /// not written, then makes sure the writer lock is released.
    ///
    /// Requests are closed before the last answer (`ControlInbox.closePublication`; a failure to close is not
    /// checked): a sender that publishes after a successful close withdraws its request (`RecorderChannel.send`), so
    /// the last poll sees every request that will not be withdrawn. Leftovers are deleted, and the marker removed,
    /// only once status.json says exited, which refuses requests by itself from then on.
    private func exitStatus(_ exit: RecorderExit) async {
        if !exited {
            exited = true
            await liveText.close()
            if let stoppedInbox {
                stoppedInbox.cancel()
                await stoppedInbox.value
                self.stoppedInbox = nil
            }
            ControlInbox.closePublication(session: archive.directory)
            await answerRequests()
            await writeExit(exit)
        } else if !exitWritten {
            await writeExit(exit)
        }
        if exitWritten {
            ControlInbox.removeLeftovers(session: archive.directory)
            ControlInbox.removeClosedMarker(session: archive.directory)
        }
        await releaseWriterLock()
    }

    private func writeExit(_ exit: RecorderExit) async {
        do {
            try await status.finish(exit: exit)
            exitWritten = true
        } catch {
            Self.log.error("Session \(self.archive.id, privacy: .public): cannot write the exited status; its locks stay held until it is written: \(error.localizedDescription, privacy: .public)")
            if let exitRetry {
                exitRetry.use(exit)
            } else {
                let retry = ExitRetry(session: archive.directory, sessionID: archive.id, exit: exit)
                retry.start(status: status, first: tuning.exitRetry, limit: tuning.exitRetryLimit)
                exitRetry = retry
                exitStatusWait?.track(retry)
            }
        }
    }

    /// Releases the writer lock, unless the exited status could not be written: then `exitRetry` holds it.
    private func releaseWriterLock() async {
        if holdsLocksUntilExit, let exitRetry {
            await exitRetry.hold(archive)
        } else {
            await archive.releaseLock()
        }
    }
}

/// The session locks of a recorder whose status.json could not be made to say exited, and the background retry that
/// lets them go. `StatusWriter` keeps the status fresh meanwhile (its heartbeat runs again after a failed finish), so
/// the session reads as busy, not dead. The exited status is tried again `first` after the failure, then twice as
/// long after each failure up to `limit`; once it is written, leftover requests are deleted and the writer lock,
/// then the lease, are released, as `RecorderExitSequence` does when the first write
/// succeeds. When `lstat` of the session
/// folder fails, for any reason (the folder is gone, or it cannot be probed), the retry stops and the locks go without
/// `exited`. The process exiting first releases them too.
///
/// Invariants:
/// 1. The retry task ends after a write of `exited` succeeds or after the `lstat` probe of the session folder fails;
///    only then does it call `releaseHeld`, which sets `done`. `done` is never cleared.
/// 2. Before `done`, `hold` keeps the lock it is given; from `done` on, it releases it at once. `releaseHeld` releases
///    what was kept: the writer lock, then the leases.
/// 3. Each attempt writes the exit stored when the attempt began; `use` changes the exit for later attempts only.
///    Leftover requests and the closed marker are removed only after a write succeeded.
/// 4. `finished()` returns `written` once `done` is set. A caller already waiting is resumed by `releaseHeld` after
///    the held locks are released; a caller arriving once `done` is set returns at once, possibly before they are.
final class ExitRetry: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    private struct State {
        /// The retry has ended (see invariant 1): locks handed over from now on go at once.
        var done = false
        /// The exit to write: the one the recorder tried last.
        var exit: RecorderExit
        var archive: SessionArchive?
        var leases: [ProcessingLease] = []
        /// status.json was made to say exited (false when the retry stopped because the folder is gone).
        var written = false
        /// Callers of `finished()` waiting for the retry to end.
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    private let session: URL
    private let sessionID: String
    private let state: Mutex<State>

    init(session: URL, sessionID: String, exit: RecorderExit) {
        self.session = session
        self.sessionID = sessionID
        state = Mutex(State(exit: exit))
    }

    /// The recorder tried another exit and could not write it either: the retry writes that one.
    func use(_ exit: RecorderExit) {
        state.withLock { $0.exit = exit }
    }

    /// Keeps the writer lock of `archive` until the exited status is written; releases it now if it already is.
    func hold(_ archive: SessionArchive) async {
        let now = state.withLock { value -> Bool in
            guard !value.done else { return true }
            value.archive = archive
            return false
        }
        if now { await archive.releaseLock() }
    }

    /// Keeps `lease` until the exited status is written; releases it now if it already is.
    func hold(_ lease: ProcessingLease) {
        let now = state.withLock { value -> Bool in
            guard !value.done else { return true }
            value.leases.append(lease)
            return false
        }
        if now { lease.release() }
    }

    /// Retries `status.finish(exit:)` in the background until it succeeds or the session folder is gone, then lets
    /// the held locks go. The task keeps `status` (and this object) alive until then.
    func start(status: StatusWriter, first: Duration, limit: Duration) {
        Task.detached { [self] in
            var delay = first
            while true {
                try? await Task.sleep(for: delay)
                guard Self.sessionExists(session) else {
                    Self.log.notice("Session \(self.sessionID, privacy: .public): its folder is gone; releasing its locks")
                    break
                }
                do {
                    try await status.finish(exit: state.withLock { $0.exit })
                    Self.log.notice("Session \(self.sessionID, privacy: .public): wrote the exited status on a later try")
                    ControlInbox.removeLeftovers(session: session)
                    ControlInbox.removeClosedMarker(session: session)
                    state.withLock { $0.written = true }
                    break
                } catch {
                    delay = min(delay * 2, limit)
                }
            }
            await releaseHeld()
        }
    }

    /// Returns once the retry has ended and let the locks go: true when it wrote the exited status, false when it
    /// stopped because the session folder is gone.
    func finished() async -> Bool {
        await withCheckedContinuation { continuation in
            let result = state.withLock { value -> Bool? in
                guard !value.done else { return value.written }
                value.waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    /// Lets the held locks go, then tells the waiters (`finished()`) how the retry ended.
    private func releaseHeld() async {
        let (archive, leases, waiters, written) = state.withLock { value in
            value.done = true
            defer { value.archive = nil; value.leases = []; value.waiters = [] }
            return (value.archive, value.leases, value.waiters, value.written)
        }
        await archive?.releaseLock()
        for lease in leases { lease.release() }
        for waiter in waiters { waiter.resume(returning: written) }
    }

    private static func sessionExists(_ session: URL) -> Bool {
        var info = stat()
        return lstat(session.path, &info) == 0
    }
}

/// Lets a recorder running inside the app (`InProcessLauncher`) wait, after `RecordingWorkflow.run` returns, for an
/// exited status the recording could not write at once (`RecordingDependencies.exitStatusWait`): until then the
/// recording has not ended, its locks are still held, and the app keeps following it and waits for it before quitting.
///
/// Invariants:
/// 1. It refers to at most one `ExitRetry`, the last one `track` was given.
/// 2. `retrying` is true from the first `track` on and is never cleared.
/// 3. `finished()` returns true at once when nothing was tracked, otherwise what the tracked retry's `finished()`
///    returns.
public final class ExitStatusWait: Sendable {
    private let retry = Mutex<ExitRetry?>(nil)

    public init() {}

    func track(_ retry: ExitRetry) { self.retry.withLock { $0 = retry } }

    /// True when the exited status is being retried in the background.
    public var retrying: Bool { retry.withLock { $0 != nil } }

    /// Returns at once when no retry was started, else once it ends: true when the exited status is written (or was
    /// never retried), false when the retry stopped because the session folder is gone.
    public func finished() async -> Bool {
        guard let retry = retry.withLock({ $0 }) else { return true }
        return await retry.finished()
    }
}
