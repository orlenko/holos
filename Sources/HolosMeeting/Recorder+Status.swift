import Foundation
import HolosCore
import HolosStorage
import os

extension Recorder {
    // MARK: - Status

    func recordEvent(_ kind: String, _ details: [String: String]) async {
        let archive = self.archive
        if let error = await beforeSleepDeadline("the \(kind) event", {
            try await archive.recordEvent(kind: kind, details: details)
        }) {
            Self.log.error("Session \(self.archive.id, privacy: .public): cannot journal \(kind, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Journals the answer and adds it to status.json, with `phase` and `markers` when the loop is still running.
    func acknowledge(_ ack: ControlAck, phase: RecorderPhase? = nil, markers: Int? = nil) async {
        guard !internalRequests.contains(ack.id) else { return }
        var details = ["id": ack.id, "command": ack.command.rawValue, "result": ack.result.rawValue]
        if let message = ack.message { details["message"] = message }
        if archiveOpen { await recordEvent(MeetingEventKind.controlHandled, details) }
        if let phase { lastStatusPhase = phase }
        await updateStatus { status in
            if let phase { status.phase = phase }
            if let markers { status.markers = markers }
            status.handledRequests.append(ack)
            if status.handledRequests.count > 32 { status.handledRequests.removeFirst(status.handledRequests.count - 32) }
        }
    }

    func rejected(file: String, reason: String) async {
        Self.log.notice("Session \(self.archive.id, privacy: .public): rejected a control request: \(reason, privacy: .public)")
        if archiveOpen { await recordEvent(MeetingEventKind.controlRejected, ["file": file, "reason": reason]) }
    }

    func clearWarning(_ code: RecorderWarningCode) async {
        shownWarnings.remove(code)
        await updateStatus { $0.warnings.removeAll { $0.code == code } }
    }

    func warn(_ requested: RecorderWarning) async {
        var warning = requested
        if warning.code == .trackStalled, capture?.unavailableTracks.contains("system") == true {
            let stalled = machine.stalledTracks.filter { $0 != "system" }
            guard !stalled.isEmpty else { await clearWarning(.trackStalled); return }
            warning.message = RecorderMachine.stallMessage(stalled, seconds: machine.watchdog.stallSeconds)
        }
        let isNew = shownWarnings.insert(warning.code).inserted
        if isNew { reporter.message(warning.message) }
        let code = warning.code
        let message = warning.message
        await updateStatus { status in
            if let index = status.warnings.firstIndex(where: { $0.code == code }) {
                status.warnings[index].message = message
            } else {
                status.warnings.append(RecorderWarning(code: code, message: message, since: Date()))
            }
        }
    }

    func updateStatus(_ change: @escaping @Sendable (inout RecorderStatus) -> Void) async {
        let status = self.status
        if let error = await beforeSleepDeadline("a status.json write", { try await status.update(change) }) {
            Self.log.error("Session \(self.archive.id, privacy: .public): cannot write status.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs `write` (a journal or status.json write) and returns its error. While a sleep waits for the loop, the wait
    /// ends at the sleep deadline: the write goes on behind a slow disk, unreported, and the Mac is allowed to sleep
    /// on time (§4.4).
    private func beforeSleepDeadline(_ what: String,
                                     _ write: @escaping @Sendable () async throws -> Void) async -> Error? {
        guard let deadline = sleepDeadline, !pendingSleepTokens.isEmpty else {
            do { try await write() } catch { return error }
            return nil
        }
        switch await awaitWithTimeout(Self.limit(.seconds(3_600), by: deadline), cancellable: false, write) {
        case .finished(.failure(let error)):
            return error
        case .timedOut:
            Self.log.notice("Session \(self.archive.id, privacy: .public): \(what, privacy: .public) finishes after the sleep is allowed")
            return nil
        case .finished(.success), .cancelled:
            return nil
        }
    }

    func setPhase(_ phase: RecorderPhase) async {
        lastStatusPhase = phase
        await updateStatus { $0.phase = phase }
    }

    /// Rewrites the live fields of status.json (every tick, and when the phase changes).
    func refreshStatus() async {
        let systemUnavailable = capture?.unavailableTracks.contains("system") == true
        let systemWarning = RecorderWarningCode("systemAudioUnavailable")
        if systemUnavailable {
            // A system stall may predate the explicit failure. Replace its presentation before adding the outage
            // warning; watchdog journal events remain intact, and a concurrent microphone stall stays visible.
            if shownWarnings.contains(.trackStalled) {
                await warn(RecorderWarning(code: .trackStalled,
                    message: RecorderMachine.stallMessage(machine.stalledTracks, seconds: machine.watchdog.stallSeconds)))
            }
            if !shownWarnings.contains(systemWarning) {
                await recordEvent(MeetingEventKind.captureWaiting, ["track": "system", "at": String(clock.now())])
                await warn(RecorderWarning(code: systemWarning,
                    message: "System audio is unavailable; recovery is pending."))
            }
        } else if shownWarnings.remove(systemWarning) != nil {
            await recordEvent(MeetingEventKind.captureRestarted, ["track": "system", "at": String(clock.now())])
            await updateStatus { $0.warnings.removeAll { $0.code == systemWarning } }
        }
        // Drops with no frame after them yet (so no `followsDrop` frame) still warn.
        let captureDrops = capture?.droppedBuffers ?? 0
        let newCaptureDrops = captureDrops > lastCaptureDrops
        lastCaptureDrops = captureDrops
        if monitor.takeDropped() || newCaptureDrops {
            await warn(RecorderWarning(code: .audioDropped,
                                       message: "The disk could not keep up, so some audio was dropped; the gap is marked."))
        }
        if live.values.contains(where: { $0.transcription == .behind }), !shownWarnings.contains(.transcriptionBehind) {
            await warn(RecorderWarning(code: .transcriptionBehind,
                                       message: "Live transcription fell behind; the rest is transcribed from the saved audio after stop."))
        }
        let phase = machine.phase
        lastStatusPhase = phase
        let elapsed = clock.now()
        let seen = monitor.trackInfo()
        let backlog = pump.backlogSeconds()
        let bytes = writer.bytesWritten()
        let free = try? dependencies.freeSpace.availableBytes(at: archive.directory)
        let markers = machine.markers
        let recordOnly = options.recordOnly
        let stalled = Set(machine.stalledTracks)
        let trackStatuses = tracks.map { track -> TrackStatus in
            let info = seen[track]
            return TrackStatus(track: track, transcription: recordOnly ? .off : (live[track]?.transcription ?? .behind),
                               lastFrameSeconds: info?.lastFrameEnd,
                               lastFinalizedSeconds: live[track]?.lastFinalizedSeconds,
                               sampleRate: info?.sampleRate, channels: info?.channels,
                               stalled: stalled.contains(track) || track == "system" && systemUnavailable,
                               backlogSeconds: backlog[track] ?? 0)
        }
        let latest = live.values.max { ($0.lastFinalizedSeconds ?? -1) < ($1.lastFinalizedSeconds ?? -1) }
        let phrase = latest?.lastPhrase
        let recorded = seen.values.map(\.seconds).max() ?? 0
        let screenSnapshotStatus: String?
        if options.screen != nil {
            let session = archive.directory, id = archive.id
            let screen = await Task.detached(priority: .utility) {
                try? ScreenContextStore.read(session: session, sessionID: id)
            }.value
            if let failure = screen?.failure {
                screenSnapshotStatus = failure == "storageLimit" ? "Screen capture stopped: storage limit"
                    : "Screen capture unavailable; audio continues"
            } else if phase == .recording, screen?.captureID != nil {
                screenSnapshotStatus = "Capturing screen · \(screen?.frames.count ?? 0) saved · OCR after stop"
            } else if phase == .recording {
                screenSnapshotStatus = "Screen capture starting · \(screen?.frames.count ?? 0) saved"
            } else {
                screenSnapshotStatus = "Screen capture paused"
            }
        } else { screenSnapshotStatus = nil }
        await updateStatus { status in
            status.phase = phase
            status.elapsedSeconds = elapsed
            status.recordedSeconds = recorded
            status.bytesWritten = bytes
            status.freeBytes = free
            status.tracks = trackStatuses
            status.lastPhrase = phrase
            status.markers = markers
            status.screenSnapshotStatus = screenSnapshotStatus
        }
    }
}
