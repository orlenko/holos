import HolosAudio
import HolosCore
import os

extension Recorder {
    /// Stops the current capture (≤ the capture-stop timeout), drains its consumer, closes every open chunk with
    /// `reason` pending once the frames before it are written, and sends a boundary to each live track.
    ///
    /// Before a sleep (§4.4) all of it fits in the capture-stop limit plus `tuning.sleepMargin` (7 s): the Mac is
    /// allowed to sleep next, even if the platform stop has not returned or the disk is still behind.
    func stopCapture(reason: GapReason) async {
        lastGapReason = reason
        let deadline = reason == .sleep ? sleepDeadline ?? ContinuousClock.now.advanced(by: sleepBudget) : nil
        await stopCurrentCapture(deadline: deadline)
        let pump = self.pump
        if case .timedOut = await awaitWithTimeout(Self.limit(dependencies.timeouts.captureStop, by: deadline), {
            try await pump.closeAll(expectingGap: reason)
        }) {
            // Still queued behind a slow disk; the frames after it go into new chunks all the same.
            Self.log.notice("Session \(self.archive.id, privacy: .public): chunks close after the disk catches up")
        }
        for feed in live.values { feed.boundary() }
    }

    /// `limit`, shortened to what is left before `deadline`.
    static func limit(_ limit: Duration, by deadline: ContinuousClock.Instant?) -> Duration {
        guard let deadline else { return limit }
        return max(.zero, min(limit, ContinuousClock.now.duration(to: deadline)))
    }

    /// Asks the current capture to stop (at most the capture-stop timeout), then waits for its consumer. A cancelled run
    /// waits too: the microphone and system audio are released before it returns. A `CancellationError` from the stop
    /// (or any error once the run is cancelled) marks the run cancelled; another error is returned for the stop path
    /// to report, and only logged when capture restarts. When the stream had already ended by itself (the user
    /// stopped sharing, or capture failed), the stop is only cleanup: an error from it (ScreenCaptureKit refuses to
    /// stop a stream that has stopped) is logged and never returned, so it cannot turn a finished recording into a
    /// capture failure. Every wait also ends at `deadline`.
    @discardableResult
    func stopCurrentCapture(deadline: ContinuousClock.Instant? = nil) async -> Error? {
        holdDisplay(false)
        guard let capture, !captureStopped else { return nil }
        let stopAt = clock.now()
        // Also runs for pause/sleep/restart, when final Stop may have no live capture left. Queue after draining
        // so the writer uses the last saved sample, not a potentially stale status snapshot.
        defer { pump.noteUnavailableTails(tracks: capture.unavailableTailTracks, at: stopAt) }
        captureStopped = true
        let alreadyEnded = monitor.requestStop(epoch: captureEpoch)
        let limit = dependencies.timeouts.captureStop
        let outcome = await awaitWithTimeout(Self.limit(limit, by: deadline), cancellable: false) {
            try await capture.stop()
        }
        var abandon = false
        var failure: Error?
        switch outcome {
        case .finished(.success):
            break
        case .finished(.failure(let error)):
            if error is CancellationError || Task.isCancelled {
                cancelled = true
            } else if alreadyEnded {
                Self.log.notice("Session \(self.archive.id, privacy: .public): stopping capture after its stream ended: \(error.localizedDescription, privacy: .public)")
            } else {
                failure = error
                Self.log.error("Session \(self.archive.id, privacy: .public): capture stop failed: \(error.localizedDescription, privacy: .public)")
            }
        case .timedOut:
            abandon = true
            let seconds = Self.seconds(limit)
            Self.log.error("Session \(self.archive.id, privacy: .public): capture did not stop within \(seconds, privacy: .public) s; abandoned")
            await recordEvent(MeetingEventKind.captureFailed, [
                "epoch": String(captureEpoch), "error": "Capture did not stop within \(seconds) s",
            ])
        case .cancelled:
            abandon = true
        }
        guard let consumer else { return failure }
        self.consumer = nil
        if abandon { consumer.cancel() }
        // A stopped stream ends at once; one that never ends is abandoned.
        if case .finished = await awaitWithTimeout(Self.limit(limit, by: deadline), cancellable: false, {
            await consumer.value
        }) { return failure }
        consumer.cancel()
        _ = await awaitWithTimeout(Self.limit(.seconds(1), by: deadline), cancellable: false) { await consumer.value }
        return failure
    }

    /// Starts epoch `epoch` (§2.3): the next speech sessions are ready first, then capture starts at
    /// timelineOffset max(clock.now(), lastFrameEnd + 0.01), anchored at the host time the clock was read
    /// (`CaptureRequest.offsetHostTime`). Success comes back as `captureStarted` with the epoch's tracks, a start
    /// failure as `startFailed`; a `CancellationError` from the start, or any error once the run is cancelled, marks
    /// the run cancelled instead (the loop then takes the cancellation stop path).
    ///
    /// The input devices are looked up first (§4.12): in person without the built-in microphone the start fails at
    /// once (the recorder waits for the lid to open); a call without any input device, or whose microphone is the
    /// built-in one with the lid closed, records system audio alone.
    ///
    /// Neither step can hold up the loop: a speech session not ready within `tuning.restartLimit` is made later by
    /// its live track, and a capture that has not started by then is abandoned (stopped once its start returns) and
    /// reported as `startFailed`, so the waiting and backoff rules take over.
    func startCapture(epoch: Int) async -> RecorderInput? {
        if cancelled || Task.isCancelled { return nil }
        let devices = dependencies.findInputDevices()
        guard let plan = EpochPlan.make(options, devices: devices,
                                        lidOpen: dependencies.power?.isLidOpen() ?? true) else {
            Self.log.error("Session \(self.archive.id, privacy: .public): no microphone for epoch \(epoch, privacy: .public)")
            // A recording that follows the default input and has none asks for a microphone, not an open lid.
            let message = options.microphone == .systemDefault && devices.systemDefault == nil
                ? EpochPlan.noMicrophone : RecorderMachine.builtInMicrophoneOff
            return .captureEnded(epoch: epoch, .startFailed(message: message), at: clock.now())
        }
        let limit = dependencies.tuning.restartLimit
        let epochStart = clock.now()
        let feeds = Array(live.values)
        // The tracks' sessions are made concurrently; a creation that fails makes that track fall behind.
        if !feeds.isEmpty {
            _ = await awaitWithTimeout(limit) {
                await withTaskGroup(of: Void.self) { group in
                    for feed in feeds {
                        group.addTask { try? await feed.prepareSession(epoch: epoch, epochStart: epochStart) }
                    }
                }
            }
        }
        // The offset follows both the last frame received and the last sample written (contiguous frames are written
        // back to back, which can run past their timestamps).
        let lastEnd = [monitor.lastFrameEnd(), writer.lastFrameEnd > 0 ? writer.lastFrameEnd : nil].compactMap { $0 }.max()
        // The offset is anchored to the host time at which the session clock was read, so the capture's own setup
        // (ScreenCaptureKit's content query, the audio engine) stays on the timeline instead of vanishing from the gap.
        let now = clock.now()
        let offsetHostTime = dependencies.hostTime()
        let offset = max(now, lastEnd.map { $0 + 0.01 } ?? 0)
        let initialSystemUnavailable = plan.source != .microphone
            && (self.capture?.unavailableTracks.contains("system") == true
                || shownWarnings.contains(RecorderWarningCode("systemAudioUnavailable")))
        let capture = dependencies.makeCapture()
        self.capture = capture
        captureEpoch = epoch
        captureStopped = false
        lastCaptureDrops = 0
        monitor.begin(epoch: epoch)
        let request = CaptureRequest(source: plan.source, applicationBundleID: options.applicationBundleID,
                                     timelineOffset: offset, microphone: options.microphone,
                                     offsetHostTime: offsetHostTime, screen: options.screen,
                                     sessionDirectory: options.screen == nil ? nil : archive.directory,
                                     initialSystemUnavailable: initialSystemUnavailable,
                                     boundaryReason: lastGapReason ?? .captureRestarted)
        let starting = Task { @MainActor in try await capture.start(request) }
        let startedAt: Double
        switch await awaitWithTimeout(limit, { try await starting.value }) {
        case .finished(.success):
            startedAt = clock.now()
        case .finished(.failure(let error)):
            if error is CancellationError || Task.isCancelled {
                // A cancellation, not an audio outage: the run stops as cancelled and keeps the audio it saved. The
                // capture is released before the stop path runs.
                captureStopped = true
                _ = await awaitWithTimeout(dependencies.timeouts.captureStop, cancellable: false) {
                    try await capture.stop()
                }
                cancelled = true
                Self.log.notice("Session \(self.archive.id, privacy: .public): epoch \(epoch, privacy: .public) start was cancelled")
                return nil
            }
            Self.log.error("Session \(self.archive.id, privacy: .public): epoch \(epoch, privacy: .public) failed to start")
            // The capture's own lookup of the built-in microphone failed (the lid closed since the plan was made):
            // the recorder says how to continue.
            let message = error.localizedDescription == BuiltInMicrophone.unavailableMessage
                ? RecorderMachine.builtInMicrophoneOff : error.localizedDescription
            return .captureEnded(epoch: epoch, .startFailed(message: message), at: clock.now())
        case .timedOut, .cancelled:
            // Abandoned: whenever the start returns, the capture is stopped so nothing keeps recording unseen.
            starting.cancel()
            captureStopped = true
            Task { @MainActor in
                _ = await starting.result
                try? await capture.stop()
            }
            if Task.isCancelled {
                cancelled = true
                return nil
            }
            let seconds = Self.seconds(limit)
            Self.log.error("Session \(self.archive.id, privacy: .public): epoch \(epoch, privacy: .public) did not start within \(seconds, privacy: .public) s; abandoned")
            return .captureEnded(epoch: epoch, .startFailed(message: "Audio capture did not start within \(seconds) s."),
                                 at: clock.now())
        }
        await recordEvent(MeetingEventKind.captureStarted, [
            "hostTimeOrigin": String(capture.hostTimeOrigin), "epoch": String(epoch), "timelineOffset": String(offset),
        ])
        await recordEvent(MeetingEventKind.captureRestarted, [
            "epoch": String(epoch), "at": String(clock.now()), "reason": (lastGapReason ?? .captureRestarted).rawValue,
            "timelineOffset": String(offset),
        ])
        startConsumer(capture, epoch: epoch)
        holdDisplay(true)
        if plan.microphoneName != self.plan.microphoneName {
            let name = plan.microphoneName
            await updateStatus { $0.microphoneName = name }
        }
        self.plan = plan
        return .captureStarted(epoch: epoch, tracks: plan.tracks, at: startedAt,
                               lidClosed: plan.microphoneOffWithLidClosed)
    }
}
