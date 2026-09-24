import Darwin
import Foundation
import HolosCore
import HolosStorage
import os

/// Whether a recorder is behind a session folder, judged from its locks and `status.json` (docs/meeting-design.md
/// §4.1).
public enum RecorderLiveness: String, Sendable, Equatable {
    /// Writer lock held, and status.json absent or fresh with phase starting…transcribing.
    case capturing
    /// Processing lease held and status.json fresh with phase postprocessing (the recorder's own post-processing).
    case processing
    /// A lock is held by something else: recover, rebuild, `session diarize`, delete, or a stale status.
    case maintenance
    /// No lock held and status.json phase == exited.
    case exited
    /// No lock held and status.json missing or not exited: interrupted if the manifest says recording/processing.
    case dead
}

/// The app's and the CLI's side of the recorder protocol: `status.json` to read, `control/` to write
/// (docs/meeting-design.md §4.1). Stateless file IO.
public enum RecorderChannel {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")
    /// A status older than this is stale.
    static let freshSeconds = 10.0
    static let maxStatusBytes = 1 << 20

    /// Reads status.json; nil when absent. Throws on a newer schemaVersion.
    public static func readStatus(session: URL) throws -> RecorderStatus? {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.status(session), maxBytes: maxStatusBytes) else {
            return nil
        }
        struct Header: Decodable { var schemaVersion: Int }
        let decoder = HolosJSON.decoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw HolosError.invalidInput("status.json is damaged or was not written by Holos.")
        }
        guard header.schemaVersion <= 1 else {
            throw HolosError.unavailable("status.json was written by a newer Holos; update Holos to read it.")
        }
        do {
            return try decoder.decode(RecorderStatus.self, from: data)
        } catch {
            throw HolosError.invalidInput("status.json is damaged or was not written by Holos.")
        }
    }

    /// Publishes one request atomically with `sentAtNanos` from mach_continuous_time; creates control/ (0700).
    /// Refuses (`unavailable`) when the session has no manifest yet (the recorder is still starting; stop it
    /// with SIGTERM instead), when status.json says exited, or when only a maintenance command holds the session's
    /// locks (`maintenanceOnly`): no recorder would ever read or remove the request.
    ///
    /// Publication is closed on the recorder's way out (docs/meeting-design.md §4.6): before its last inbox poll it
    /// creates `control/.closed`; it then polls, writes exited, deletes leftover requests, and removes the marker.
    /// Once the request is published, `send` checks the marker and then status.json. Either one means the recorder may
    /// have polled for the last time, so the request is withdrawn: if the withdrawal removed it, the send is refused;
    /// if the recorder had already taken it, that last poll answers it before exited is written, and the send
    /// succeeds, unless status.json already says exited without its answer (a leftover the recorder deleted). A
    /// request published before the marker existed is seen by the last poll. So a send that succeeds is always
    /// answered, and `--no-wait` never reports a request that nothing will read.
    @discardableResult
    public static func send(_ command: ControlCommand, label: String? = nil, session: URL,
                            sessionID: String, sender: String) throws -> ControlRequest {
        try send(command, label: label, session: session, sessionID: sessionID, sender: sender, step: nil)
    }

    /// The points in `send` at which tests run the recorder's exit steps.
    enum SendStep: Sendable, Equatable {
        /// The checks before publishing are done; nothing is published yet.
        case checked
        case published
        /// `control/.closed` was checked.
        case checkedPublication
        /// status.json was read after publishing (only when publication was open).
        case checkedStatus
        /// The request was withdrawn, or found taken (only when the recorder may have polled for the last time).
        case withdrew
    }

    /// `send`, with `afterPublish` run between publishing the request and the checks after it (tests: a recorder
    /// that exits in that window).
    static func send(_ command: ControlCommand, label: String? = nil, session: URL, sessionID: String,
                     sender: String, afterPublish: (() throws -> Void)?) throws -> ControlRequest {
        try send(command, label: label, session: session, sessionID: sessionID, sender: sender, step: { step in
            if step == .published { try afterPublish?() }
        })
    }

    /// `send`, with `step` run at each `SendStep` (tests: every interleaving with the recorder's exit).
    static func send(_ command: ControlCommand, label: String? = nil, session: URL, sessionID: String,
                     sender: String, step: ((SendStep) throws -> Void)?) throws -> ControlRequest {
        guard SessionArchive.validToken(sessionID), UUID(uuidString: sessionID) != nil else {
            throw HolosError.invalidInput("Expected a session UUID.")
        }
        let manifest: SessionManifest
        do {
            manifest = try SessionArchive.readManifest(at: session)
        } catch {
            throw HolosError.unavailable("The recorder is still starting and cannot take requests yet; stop it with SIGTERM instead.")
        }
        guard manifest.id == sessionID else { throw HolosError.invalidInput("Session identity mismatch.") }
        if ControlInbox.isPublicationClosed(session: session) { throw HolosError.unavailable(exitingMessage) }
        if let status = try readStatus(session: session), status.phase == .exited {
            throw HolosError.unavailable(exitedMessage)
        }
        if maintenanceOnly(session: session) {
            throw HolosError.unavailable("No recorder is running for this session: another Holos command (recovery, rebuild, speaker labelling, or deletion) is using it. Try again when it finishes.")
        }
        try step?(.checked)
        let request = ControlRequest(sessionID: sessionID, command: command,
                                     label: label.map { String($0.prefix(ControlInbox.maxLabelLength)) },
                                     sentAtNanos: continuousNanoseconds(), sender: sender)
        let folder = SessionPaths.controlDirectory(session)
        try AtomicFile.ensurePrivateDirectory(folder)
        // A same-folder `.<UUID>.tmp`, fsync'd and renamed into place: the recorder never sees a partial request.
        try AtomicFile.create(try HolosJSON.encoder().encode(request),
                              at: folder.appendingPathComponent("\(request.id).json", isDirectory: false))
        try step?(.published)
        // The marker first: the recorder removes it only after writing exited, so a check that misses it because it
        // is already gone is followed by a status read that says exited.
        let closed = ControlInbox.isPublicationClosed(session: session)
        try step?(.checkedPublication)
        if !closed {
            guard (try? readStatus(session: session))?.phase == .exited else { return request }
            try step?(.checkedStatus)
        }
        let removed = ControlInbox.removeRequest(id: request.id, session: session)
        try step?(.withdrew)
        let status = try? readStatus(session: session)
        let exited = status?.phase == .exited
        if removed { throw HolosError.unavailable(exited ? exitedMessage : exitingMessage) }
        // Taken by the recorder: its last poll answers before exited is written; a leftover it deleted after exited
        // was never answered.
        if exited, status?.handledRequests.contains(where: { $0.id == request.id }) != true {
            throw HolosError.unavailable(exitedMessage)
        }
        return request
    }

    static let exitedMessage = "The recorder has already exited."
    static let exitingMessage = "The recorder is exiting and takes no more requests."

    /// Removes a published request that no recorder will read (it exited without acknowledging it). A request the
    /// recorder already took is gone already; that is not an error.
    public static func withdraw(_ request: ControlRequest, session: URL) {
        ControlInbox.removeRequest(id: request.id, session: session)
    }

    /// Polls status.json every 50 ms for the request's ack. Nil after `timeout`, or as soon as the recorder has
    /// exited without acknowledging it; the request is then withdrawn (`withdraw`), since nothing will read it.
    public static func waitForAck(_ request: ControlRequest, session: URL, timeout: Duration) async -> ControlAck? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let status = try? readStatus(session: session) {
                if let ack = status.handledRequests.last(where: { $0.id == request.id }) { return ack }
                if status.phase == .exited {
                    withdraw(request, session: session)
                    return nil
                }
            }
            guard clock.now < deadline, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// "Fresh" means updatedAt less than 10 s before `now` and kill(pid, 0) == 0.
    public static func liveness(session: URL, now: Date = Date()) -> RecorderLiveness {
        let status = try? readStatus(session: session)
        let fresh = status.map { isFresh($0, now: now) } ?? false
        // An unreadable lock counts as held: never call a recorder dead on an error.
        let writer = (try? SessionArchive.isActive(at: session)) ?? true
        if writer {
            guard let status else { return .capturing }
            return fresh && (status.phase.isMeetingActive || status.phase == .transcribing) ? .capturing : .maintenance
        }
        let lease = (try? SessionArchive.isProcessing(at: session)) ?? true
        if lease {
            // Between taking the lease and finishing the archive the recorder still says `transcribing`.
            if let status, fresh, status.phase == .postprocessing || status.phase == .transcribing { return .processing }
            return .maintenance
        }
        if status?.phase == .exited { return .exited }
        // A recorder writes exited before it releases its last lock: one that did so since the first read exited.
        if let again = try? readStatus(session: session), again.phase == .exited { return .exited }
        return .dead
    }

    /// Liveness is `maintenance` and no recorder process is behind the session: status.json is missing or exited, or
    /// names a process that is gone. Then recovery, a rebuild, `session diarize`, or a deletion holds the locks and
    /// nothing polls `control/`. False for a recorder that is alive but has not rewritten status.json for 10 s: it
    /// still answers requests.
    public static func maintenanceOnly(session: URL, now: Date = Date()) -> Bool {
        guard liveness(session: session, now: now) == .maintenance else { return false }
        let status: RecorderStatus?
        do { status = try readStatus(session: session) } catch {
            // An unreadable status is not proof that no recorder is running.
            return false
        }
        guard let status, status.phase != .exited else { return true }
        return !processExists(status.pid)
    }

    /// For maintenance commands: when liveness is dead and status.json is not exited, rewrites it as exited
    /// (reason `interrupted`, archiveStatus from the manifest). Returns true if it rewrote.
    ///
    /// A maintenance command calls this while holding the processing lease, so the lease is not part of the check:
    /// the recorder counts as dead when no writer lock is held and its status is not fresh (a live recorder rewrites
    /// it every second, including while a child it handed the lease to labels speakers).
    @discardableResult
    public static func markDeadRecorderExited(session: URL, now: Date = Date()) throws -> Bool {
        guard var status = try readStatus(session: session), status.phase != .exited else { return false }
        guard try !SessionArchive.isActive(at: session), !isFresh(status, now: now) else { return false }
        let archiveStatus = (try? SessionArchive.readManifest(at: session).status) ?? ArchiveStatus.interrupted
        status.phase = .exited
        status.sequence += 1
        status.updatedAt = now
        status.progress = nil
        status.exit = RecorderExit(archiveStatus: archiveStatus, reason: .interrupted,
                                   message: "The recorder stopped unexpectedly.")
        try AtomicFile.writeJSON(status, to: SessionPaths.status(session))
        log.notice("Session \(status.sessionID, privacy: .public): a dead recorder's status was marked exited")
        return true
    }

    // MARK: - Helpers

    static func isFresh(_ status: RecorderStatus, now: Date) -> Bool {
        let age = now.timeIntervalSince(status.updatedAt)
        return age < freshSeconds && processExists(status.pid)
    }

    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // Another user's process exists too.
        return errno == EPERM
    }

    /// `mach_continuous_time` in nanoseconds, comparable across processes on one Mac.
    static func continuousNanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        guard info.denom != 0 else { return ticks }
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(info.numer))
        let (quotient, _) = UInt64(info.denom).dividingFullWidth((high, low))
        return quotient
    }
}
