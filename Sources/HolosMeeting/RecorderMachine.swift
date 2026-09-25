import Foundation
import HolosAudio
import HolosCore

/// How a capture epoch's frame stream ended.
public enum CaptureEnd: Sendable, Equatable {
    /// The stream finished after stopCapture.
    case requested
    /// AVAudioEngineConfigurationChange.
    case configurationChanged
    /// Any other error, including ScreenCaptureKit stopping by itself.
    case failed(message: String)
    case startFailed(message: String)
    /// SCStreamError.Code.userStopped only.
    case userStoppedSharing
}

/// Everything the recorder loop tells the state machine (docs/meeting-design.md §4.2).
public enum RecorderInput: Sendable, Equatable {
    /// The capture of `epoch` started (its `start` returned) at session time `at`, recording `tracks`. The stall
    /// timers start here (PR2b). A call epoch whose `tracks` lack "mic" records without the microphone (no input
    /// device, §4.12); `lidClosed`: because that microphone is the built-in one and the lid is closed.
    case captureStarted(epoch: Int, tracks: [String], at: Double, lidClosed: Bool = false)
    /// The first frame of `epoch` arrived at session time `at`.
    case captureRunning(epoch: Int, at: Double)
    /// Ends from any epoch other than the current one are ignored (logged).
    case captureEnded(epoch: Int, CaptureEnd, at: Double)
    case control(ControlRequest, at: Double)
    case signal(at: Double)
    case durationElapsed(at: Double)
    case willSleep(at: Double)
    case didWake(at: Double, lidOpen: Bool)
    /// Lid opened, screen unlocked (`com.apple.screenIsUnlocked`), or the CoreAudio device list changed.
    case retryNow(reason: String, at: Double)
    /// Every 1 s. `lastFrameAt`: per track, the session time at which the consumer last received a frame.
    case tick(at: Double, lidOpen: Bool, freeBytes: Int64?, lastFrameAt: [String: Double])
}

/// What the recorder loop does, in order, for one input.
public enum RecorderEffect: Sendable, Equatable {
    /// Stop capture (≤ 5 s), drain, close every open chunk with `reason` pending, send a boundary to each LiveTrack.
    case stopCapture(reason: GapReason)
    /// Start epoch `epoch` at timelineOffset max(clock.now(), lastFrameEnd + 0.01) (§2.3).
    case startCapture(epoch: Int)
    case recordEvent(kind: String, details: [String: String])
    /// `handledAt` is stamped by the loop when it applies the acknowledgement.
    case acknowledge(ControlAck)
    /// `since` is stamped by the loop when it first shows the warning.
    case warn(RecorderWarning)
    case clearWarning(RecorderWarningCode)
    /// IOAllowPowerChange for the pending willSleep, after chunks are closed.
    case allowSleep
    /// Take or release the idle-sleep assertion (released while paused).
    case holdPowerAssertion(Bool)
    /// Leave the loop; the stop path (§4.6) runs next.
    case finish(StopReason)
}

/// The recorder's pure state machine (docs/meeting-design.md §4.2): the `@MainActor` loop feeds it inputs and executes
/// the effects it returns, in order. Capture restarts, the `waiting` phase with backoff, pause, control requests, the
/// runtime disk check, the pause limit, sleep and wake (§4.4), the stall watchdog, and the microphone rules of a call
/// (§4.12) live here.
public struct RecorderMachine: Sendable, Equatable {
    /// Seconds without audio after which `waiting` gives up (`finish(captureFailed)`).
    static let unavailableLimit = 600.0
    /// Seconds a meeting may stay paused (`finish(pauseTimeout)`).
    static let pauseLimit = 21_600.0
    /// Seconds of sleep after which the recording ends at the sleep point (`finish(sleepTimeout)`).
    static let sleepLimit = 900.0
    /// Seconds of audio after which an epoch counts as healthy and the restart attempts reset.
    static let healthyEpochSeconds = 10.0
    /// The longest wait between retries in `waiting`.
    static let maxRetryDelay = 30.0
    /// The placeholder date of acknowledgements and warnings; the loop stamps the real time.
    public static let placeholderDate = Date(timeIntervalSinceReferenceDate: 0)
    /// Why an in-person epoch could not start: the built-in microphone is gone (lid closed with an external display).
    /// It is also the `waiting` warning then (§4.12).
    public static let builtInMicrophoneOff = "The built-in microphone is off. Open the lid to continue recording."
    /// The warning of a call epoch that records without the microphone for want of an input device.
    public static let callMicrophoneMissing = "Microphone unavailable; recording call audio only."
    /// The warning of a call epoch that records without the built-in microphone because the lid is closed.
    public static let builtInMicrophoneOffInCall =
        "The built-in microphone is off while the lid is closed; recording the computer's audio only. Open the lid to include the microphone."
    /// The `deviceChanged` reason journaled when a call epoch starts without the built-in microphone (lid closed).
    static let lidClosedReason = "builtInMicrophoneLidClosed"
    /// The `retryNow` reason when the loop sees the lid open again.
    public static let lidOpened = "lidOpened"
    /// The `retryNow` reason when the loop sees the lid close while the current epoch records the built-in
    /// microphone: Core Audio may keep the device listed and deliver silence, so no stall or device change shows it.
    public static let lidClosed = "lidClosed"

    /// starting, recording, paused, waiting, sleeping, stopping.
    public private(set) var phase: RecorderPhase = .starting
    public private(set) var epoch = 0
    public private(set) var markers = 0
    /// Why the recording ended; nil until `finish`.
    public private(set) var stopReason: StopReason?
    /// The meeting's tracks ("mic", "system"). A started epoch that lacks "mic" records without the microphone.
    public let tracks: [String]
    /// The current call epoch records without the microphone because the Mac has no input device, or because it is
    /// the built-in microphone and the lid is closed (§4.12).
    public private(set) var microphoneMissing = false
    /// `microphoneMissing` because the lid is closed: opening the lid or unlocking the screen restarts capture with
    /// the microphone, not only a device-list change.
    public private(set) var microphoneOffWithLidClosed = false

    /// Restarts since the last healthy epoch.
    private(set) var attempt = 0
    /// When audio became unavailable (first failure); kept across attempts.
    private(set) var unavailableSince: Double?
    /// When `waiting` retries next.
    private(set) var retryAt: Double?
    /// When the current epoch's first frame arrived; nil while its start is in flight.
    private(set) var epochRunningSince: Double?
    private(set) var pausedSince: Double?
    /// The runtime low-disk warning was shown and not re-armed.
    private(set) var diskWarned = false
    /// Control request IDs already handled; a repeated ID is acknowledged `ignored`.
    private var handledRequests: Set<String> = []
    /// Stall timers of the current epoch's tracks.
    private(set) var watchdog: TrackWatchdog
    /// The current epoch's capture has started (`captureStarted`), so its stall timers run.
    private(set) var watching = false
    /// When the current sleep began. Set only on the transition into `sleeping`, so a dark wake keeps it.
    private(set) var sleepStart: Double?
    /// recording, paused, or waiting: the phase the meeting was in when it went to sleep.
    private(set) var phaseBeforeSleep: RecorderPhase?
    /// The Mac woke with the lid closed: a tick that sees the lid open resumes the recording.
    private(set) var wokeWithLidClosed = false

    /// `tracks`: the meeting's tracks. With none, the stall watchdog and the microphone rules do nothing.
    public init(tracks: [String] = [], watchdog: TrackWatchdog = TrackWatchdog()) {
        self.tracks = tracks
        self.watchdog = watchdog
    }

    /// The tracks that delivered no audio for longer than the stall limit.
    public var stalledTracks: [String] { watchdog.stalledTracks }

    public mutating func handle(_ input: RecorderInput) -> [RecorderEffect] {
        guard stopReason == nil else {
            // After finish every input is ignored, except that requests are still acknowledged.
            if case .control(let request, _) = input {
                return [Self.acknowledge(request, .ignored, Self.alreadyStopping)]
            }
            return []
        }
        switch input {
        case .captureStarted(let epoch, let tracks, let at, let lidClosed):
            return captureStarted(epoch: epoch, tracks: tracks, at: at, lidClosed: lidClosed)
        case .captureRunning(let epoch, let at):
            return captureRunning(epoch: epoch, at: at)
        case .captureEnded(let epoch, let end, let at):
            return captureEnded(epoch: epoch, end: end, at: at)
        case .control(let request, let at):
            return control(request, at: at)
        case .signal:
            return finish(.signal)
        case .durationElapsed:
            return finish(.duration)
        case .willSleep(let at):
            return willSleep(at: at)
        case .didWake(let at, let lidOpen):
            return didWake(at: at, lidOpen: lidOpen)
        case .retryNow(let reason, let at):
            return retryNow(reason: reason, at: at)
        case .tick(let at, let lidOpen, let freeBytes, let lastFrameAt):
            return tick(at: at, lidOpen: lidOpen, freeBytes: freeBytes, lastFrameAt: lastFrameAt)
        }
    }

    // MARK: - Capture

    /// The epoch's capture started: its stall timers start now, and a call epoch without the microphone warns (and
    /// one with it again clears the warning). Without the built-in microphone because the lid is closed, the warning
    /// says so and the reason is journaled (`deviceChanged` on the microphone track), so the gap on the microphone
    /// track is explained.
    private mutating func captureStarted(epoch started: Int, tracks recorded: [String], at: Double,
                                         lidClosed: Bool) -> [RecorderEffect] {
        guard started == epoch, phase == .starting || phase == .recording else { return [] }
        let stalledBefore = watchdog.stalledTracks
        watchdog.startEpoch(at: at, tracks: recorded)
        watching = true
        var effects = stallWarning(previously: stalledBefore)
        let microphone = TrackWatchdog.microphoneTrack
        let missing = tracks.contains(microphone) && !recorded.contains(microphone)
        let offWithLid = missing && lidClosed
        if missing, !microphoneMissing || offWithLid != microphoneOffWithLidClosed {
            if offWithLid {
                effects.append(.recordEvent(kind: MeetingEventKind.deviceChanged, details: [
                    "track": microphone, "at": String(at), "reason": Self.lidClosedReason,
                ]))
            }
            let message = offWithLid ? Self.builtInMicrophoneOffInCall : Self.callMicrophoneMissing
            effects.append(.warn(Self.warning(.microphoneUnavailable, message)))
        } else if !missing, microphoneMissing {
            effects.append(.clearWarning(.microphoneUnavailable))
        }
        microphoneMissing = missing
        microphoneOffWithLidClosed = offWithLid
        return effects
    }

    private mutating func captureRunning(epoch running: Int, at: Double) -> [RecorderEffect] {
        guard running == epoch else { return [] }
        switch phase {
        case .starting:
            phase = .recording
            epochRunningSince = at
        case .recording:
            if epochRunningSince == nil { epochRunningSince = at }
        default:
            break
        }
        return []
    }

    private mutating func captureEnded(epoch ended: Int, end: CaptureEnd, at: Double) -> [RecorderEffect] {
        guard ended == epoch, end != .requested else { return [] }
        if end == .userStoppedSharing { return finish(.requested) }
        switch phase {
        case .starting where end != .configurationChanged:
            // Epoch 0 ended before its first frame: capture never started.
            return [.recordEvent(kind: MeetingEventKind.startFailed, details: ["error": Self.describe(end)])]
                + finish(.startFailed)
        case .starting, .recording:
            // A device change right after the start (pinning the built-in microphone, a headset connecting) restarts
            // like one later on: capture did start. A frameless epoch counts as unavailable audio, though: the first
            // restarts at once, and another frameless end before an epoch delivers backs off into `waiting` like a
            // failure, so the 10-minute limit applies and a change posted on every start cannot loop forever.
            if end == .configurationChanged {
                if epochRunningSince == nil {
                    if attempt > 0 { return failure(Self.describe(end), at: at) }
                    attempt = 1
                    if unavailableSince == nil { unavailableSince = at }
                }
                return [
                    .recordEvent(kind: MeetingEventKind.deviceChanged, details: [
                        "track": "mic", "at": String(at), "reason": "configurationChanged",
                    ]),
                    .warn(Self.warning(.deviceChanged, "Audio restarted after a device change; the gap is marked.")),
                    .stopCapture(reason: .deviceChanged),
                    startNextEpoch(),
                ]
            }
            return failure(Self.describe(end), at: at)
        default:
            // Capture is not running while paused, waiting, or sleeping: a late end changes nothing.
            return []
        }
    }

    /// `failed` or `startFailed` for the current epoch while recording.
    private mutating func failure(_ message: String, at: Double) -> [RecorderEffect] {
        var effects: [RecorderEffect] = [
            .recordEvent(kind: MeetingEventKind.captureFailed, details: ["epoch": String(epoch), "error": message]),
        ]
        if unavailableSince == nil { unavailableSince = at }
        if attempt == 0 {
            attempt = 1
            effects += [.stopCapture(reason: .captureRestarted), startNextEpoch()]
            return effects
        }
        let delay = min(Self.maxRetryDelay, 0.5 * pow(2, Double(min(attempt - 1, 16))))
        retryAt = at + delay
        phase = .waiting
        // The built-in microphone being off is something the user can fix; say how.
        let text = message == Self.builtInMicrophoneOff ? message : "Audio is unavailable; retrying. The gap is marked."
        effects += [
            // Chunks are already closed; this sets the gap's reason.
            .stopCapture(reason: .audioUnavailable),
            .recordEvent(kind: MeetingEventKind.captureWaiting, details: [
                "at": String(at), "reason": message, "attempt": String(attempt), "retryInSeconds": String(delay),
            ]),
            .warn(Self.warning(.audioUnavailable, text)),
        ]
        return effects + stopWatching()
    }

    /// Leaves `waiting` with the next start attempt.
    private mutating func retry(at: Double) -> RecorderEffect {
        retryAt = nil
        attempt += 1
        return startNextEpoch()
    }

    /// The phase is `recording` while a start is in flight; a start failure comes back as `startFailed`. The stall
    /// timers wait for the new epoch's `captureStarted`; a track stalled before stays stalled until it delivers.
    private mutating func startNextEpoch() -> RecorderEffect {
        epoch += 1
        epochRunningSince = nil
        watching = false
        phase = .recording
        return .startCapture(epoch: epoch)
    }

    /// `retryNow` (lid opened, screen unlocked, device list changed): a waiting recorder retries at once; a call
    /// recording without the microphone restarts with it when the device list changes, and one without the built-in
    /// microphone because the lid was closed also when the lid opens or the screen is unlocked. The loop sends these
    /// only when the next epoch would record the microphone.
    ///
    /// `lidClosed` (the loop sends it only when the next epoch would lack the built-in microphone): an epoch that
    /// records the microphone restarts once, so a call goes on with the computer's audio alone and a microphone-only
    /// recording waits for the lid. Nothing happens while a restart is in flight, while the microphone is already
    /// missing, or in any other phase.
    private mutating func retryNow(reason: String, at: Double) -> [RecorderEffect] {
        switch phase {
        case .waiting:
            // A waiting recorder already starts its next epoch with the lid as it is.
            guard reason != Self.lidClosed else { return [] }
            return [retry(at: at)]
        case .starting, .recording:
            if reason == Self.lidClosed {
                let microphone = TrackWatchdog.microphoneTrack
                guard watching, tracks.contains(microphone), !microphoneMissing else { return [] }
                return [
                    .recordEvent(kind: MeetingEventKind.deviceChanged, details: [
                        "track": microphone, "at": String(at), "reason": reason,
                    ]),
                    .stopCapture(reason: .deviceChanged),
                    startNextEpoch(),
                ]
            }
            // `starting` too: a call epoch 0 without the microphone may deliver nothing while nothing plays.
            guard microphoneMissing, watching else { return [] }
            let lidReasons = [Self.lidOpened, AudioEnvironmentEvents.screenUnlocked]
            guard reason == AudioEnvironmentEvents.audioDevicesChanged
                || microphoneOffWithLidClosed && lidReasons.contains(reason) else { return [] }
            return [
                .recordEvent(kind: MeetingEventKind.deviceChanged, details: [
                    "track": TrackWatchdog.microphoneTrack, "at": String(at), "reason": reason,
                ]),
                .stopCapture(reason: .deviceChanged),
                startNextEpoch(),
            ]
        default:
            return []
        }
    }

    // MARK: - Ticks

    /// Capture runs (or is starting) in `starting` and `recording`: the disk check and the stall watchdog run there,
    /// so an epoch 0 that never delivers its first frame is flagged and restarted like any other stall. `waiting`
    /// checks the disk before it retries.
    private mutating func tick(at: Double, lidOpen: Bool, freeBytes: Int64?,
                               lastFrameAt: [String: Double]) -> [RecorderEffect] {
        switch phase {
        case .starting, .recording:
            // In `starting`, no epoch has run and nothing has failed yet, so the restart rules below do nothing.
            var effects: [RecorderEffect] = []
            if let since = epochRunningSince {
                // A healthy epoch stops a start-then-fail loop from retrying at full speed.
                if at - since >= Self.healthyEpochSeconds, attempt > 0 || unavailableSince != nil {
                    attempt = 0
                    unavailableSince = nil
                    effects.append(.clearWarning(.audioUnavailable))
                }
            } else if let since = unavailableSince, at - since >= Self.unavailableLimit {
                // A restarted epoch that never delivered audio.
                return effects + finish(.captureFailed)
            }
            effects += diskCheck(freeBytes)
            if stopReason != nil { return effects }
            return effects + watchdogCheck(at: at, lastFrameAt: lastFrameAt)
        case .waiting:
            if let since = unavailableSince, at - since >= Self.unavailableLimit { return finish(.captureFailed) }
            var effects = diskCheck(freeBytes)
            if stopReason != nil { return effects }
            if let retryAt, at >= retryAt { effects.append(retry(at: at)) }
            return effects
        case .paused:
            if let since = pausedSince, at - since >= Self.pauseLimit { return finish(.pauseTimeout) }
            return []
        case .sleeping:
            return sleepingTick(at: at, lidOpen: lidOpen)
        default:
            return []
        }
    }

    // MARK: - Watchdog

    /// No frame on a track for 3 s: `trackStalled` and a warning; frames again: `trackResumed`, and the warning is
    /// cleared once no track is stalled. The microphone stalled for 10 s restarts capture in a new epoch.
    private mutating func watchdogCheck(at: Double, lastFrameAt: [String: Double]) -> [RecorderEffect] {
        guard watching else { return [] }
        let stalledBefore = watchdog.stalledTracks
        let (stalled, resumed, restart) = watchdog.evaluate(lastFrameAt: lastFrameAt, now: at)
        var effects: [RecorderEffect] = resumed.map {
            .recordEvent(kind: MeetingEventKind.trackResumed, details: ["track": $0])
        }
        effects += stalled.map { track in
            .recordEvent(kind: MeetingEventKind.trackStalled, details: [
                "track": track, "silentSeconds": String(watchdog.silentSeconds(track, now: at) ?? 0),
            ])
        }
        effects += stallWarning(previously: stalledBefore)
        if !restart.isEmpty {
            // An epoch that delivered nothing on any track (epoch 0 before its first frame, too) means audio is
            // unavailable: the 10-minute limit then ends a recording whose restarts never bring audio back.
            if epochRunningSince == nil, unavailableSince == nil { unavailableSince = at }
            effects += [.stopCapture(reason: .captureRestarted), startNextEpoch()]
        }
        return effects
    }

    /// The stall warning after the stalled tracks changed from `previously`: updated while any track is stalled,
    /// cleared when none is.
    private func stallWarning(previously: [String]) -> [RecorderEffect] {
        let stalled = watchdog.stalledTracks
        guard stalled != previously else { return [] }
        if stalled.isEmpty { return [.clearWarning(.trackStalled)] }
        return [.warn(Self.warning(.trackStalled, Self.stallMessage(stalled, seconds: watchdog.stallSeconds)))]
    }

    /// Capture stopped on purpose (paused, asleep, waiting): nothing is watched, and a stall warning goes away.
    private mutating func stopWatching() -> [RecorderEffect] {
        watching = false
        let wasStalled = !watchdog.stalledTracks.isEmpty
        watchdog.stop()
        return wasStalled ? [.clearWarning(.trackStalled)] : []
    }

    // MARK: - Sleep (§4.4)

    /// From recording (or starting), waiting, or paused: capture stops, the sleep point is remembered, and the sleep is
    /// allowed once the chunks are closed. Asleep already (a dark wake going back to sleep): allowed, nothing else.
    private mutating func willSleep(at: Double) -> [RecorderEffect] {
        switch phase {
        case .starting, .recording, .waiting, .paused:
            let before: RecorderPhase = phase == .starting ? .recording : phase
            var effects: [RecorderEffect] = []
            if before == .recording { effects.append(.stopCapture(reason: .sleep)) }
            effects.append(.recordEvent(kind: MeetingEventKind.systemWillSleep, details: [
                "at": String(at), "phaseBeforeSleep": before.rawValue,
            ]))
            effects += stopWatching()
            phase = .sleeping
            sleepStart = at
            phaseBeforeSleep = before
            wokeWithLidClosed = false
            retryAt = nil
            epochRunningSince = nil
            return effects + [.allowSleep]
        case .sleeping:
            wokeWithLidClosed = false
            return [.allowSleep]
        default:
            return []
        }
    }

    /// Paused before sleep: paused again, whatever the sleep length (the pause limit still applies). Otherwise: asleep
    /// for 15 minutes or more ends the recording at the sleep point; less, with the lid open, resumes in a new epoch;
    /// less with the lid closed (a dark wake, or clamshell) waits for a tick that sees the lid open.
    private mutating func didWake(at: Double, lidOpen: Bool) -> [RecorderEffect] {
        guard phase == .sleeping, let sleepStart, let before = phaseBeforeSleep else { return [] }
        let slept = max(0, at - sleepStart)
        if before == .paused {
            phase = .paused
            clearSleep()
            return [Self.wakeEvent(at: at, slept: slept, action: "wait")]
        }
        if slept >= Self.sleepLimit { return finalizeAfterSleep(at: at, slept: slept) }
        if lidOpen { return resumeAfterSleep(at: at, slept: slept) }
        wokeWithLidClosed = true
        return [Self.wakeEvent(at: at, slept: slept, action: "wait")]
    }

    /// While asleep, each tick re-checks: 15 minutes reached ends the recording; the lid open after a wake resumes it.
    /// A sleep that began paused only honours the pause limit.
    private mutating func sleepingTick(at: Double, lidOpen: Bool) -> [RecorderEffect] {
        guard let sleepStart, let before = phaseBeforeSleep else { return [] }
        let slept = max(0, at - sleepStart)
        if before == .paused {
            if let since = pausedSince, at - since >= Self.pauseLimit { return finish(.pauseTimeout) }
            return []
        }
        if slept >= Self.sleepLimit { return finalizeAfterSleep(at: at, slept: slept) }
        if wokeWithLidClosed, lidOpen { return resumeAfterSleep(at: at, slept: slept) }
        return []
    }

    /// Asleep for 15 minutes or more: the recording ends at the sleep point (capture stopped when the sleep began).
    private mutating func finalizeAfterSleep(at: Double, slept: Double) -> [RecorderEffect] {
        [Self.wakeEvent(at: at, slept: slept, action: "finalize")] + finish(.sleepTimeout)
    }

    /// Capture restarts in a new epoch with the restart attempts reset, so a failed start is retried at once and then
    /// with backoff. Audio that was unavailable before the sleep counts its 10 minutes from the wake.
    private mutating func resumeAfterSleep(at: Double, slept: Double) -> [RecorderEffect] {
        clearSleep()
        attempt = 0
        retryAt = nil
        if unavailableSince != nil { unavailableSince = at }
        let start = startNextEpoch()
        let message = "Resumed after \(Self.sleepLength(slept)) of sleep; the gap is marked."
        return [start, .warn(Self.warning(.resumedAfterSleep, message)), Self.wakeEvent(at: at, slept: slept, action: "resume")]
    }

    private mutating func clearSleep() {
        sleepStart = nil
        phaseBeforeSleep = nil
        wokeWithLidClosed = false
    }

    private mutating func diskCheck(_ freeBytes: Int64?) -> [RecorderEffect] {
        guard let freeBytes else { return [] }
        let (verdict, warned) = DiskPolicy.runtimeCheck(freeBytes: freeBytes, warned: diskWarned)
        var effects: [RecorderEffect] = []
        if diskWarned, !warned { effects.append(.clearWarning(.diskLow)) }
        diskWarned = warned
        switch verdict {
        case .warn(let message):
            effects += [
                .recordEvent(kind: MeetingEventKind.diskLow, details: ["freeBytes": String(freeBytes), "action": "warn"]),
                .warn(Self.warning(.diskLow, message)),
            ]
        case .stop(let message):
            effects += [
                .recordEvent(kind: MeetingEventKind.diskLow, details: ["freeBytes": String(freeBytes), "action": "stop"]),
                .warn(Self.warning(.diskLow, message)),
            ] + finish(.diskLow)
        case .ok, .refuse:
            break
        }
        return effects
    }

    // MARK: - Control requests

    private mutating func control(_ request: ControlRequest, at: Double) -> [RecorderEffect] {
        guard handledRequests.insert(request.id).inserted else {
            return [Self.acknowledge(request, .ignored, "This request was already handled.")]
        }
        switch request.command {
        case .stop:
            return [Self.acknowledge(request, .applied)] + finish(.requested)
        case .pause:
            switch phase {
            case .recording, .waiting:
                var effects: [RecorderEffect] = []
                if phase == .recording { effects.append(.stopCapture(reason: .paused)) }
                if phase == .waiting || unavailableSince != nil { effects.append(.clearWarning(.audioUnavailable)) }
                effects += stopWatching()
                phase = .paused
                pausedSince = at
                retryAt = nil
                attempt = 0
                unavailableSince = nil
                effects += [
                    .recordEvent(kind: MeetingEventKind.paused, details: ["at": String(at)]),
                    .holdPowerAssertion(false),
                    Self.acknowledge(request, .applied),
                ]
                return effects
            case .paused:
                return [Self.acknowledge(request, .ignored, "Already paused.")]
            case .sleeping:
                return [Self.acknowledge(request, .rejected, Self.asleep)]
            default:
                return [Self.acknowledge(request, .rejected, Self.stillStarting)]
            }
        case .resume:
            switch phase {
            case .paused:
                pausedSince = nil
                let start = startNextEpoch()
                return [
                    .recordEvent(kind: MeetingEventKind.resumed, details: ["at": String(at), "epoch": String(epoch)]),
                    .holdPowerAssertion(true),
                    start,
                    Self.acknowledge(request, .applied),
                ]
            case .recording:
                return [Self.acknowledge(request, .ignored, "Already recording.")]
            case .waiting:
                return [Self.acknowledge(request, .ignored, "Already restarting audio.")]
            case .sleeping:
                return [Self.acknowledge(request, .rejected, Self.asleep)]
            default:
                return [Self.acknowledge(request, .rejected, Self.stillStarting)]
            }
        case .marker:
            guard phase != .starting else { return [Self.acknowledge(request, .rejected, Self.stillStarting)] }
            markers += 1
            var details = ["at": String(at), "requestID": request.id]
            if let label = request.label { details["label"] = String(label.prefix(ControlInbox.maxLabelLength)) }
            return [.recordEvent(kind: MeetingEventKind.marker, details: details), Self.acknowledge(request, .applied)]
        }
    }

    private mutating func finish(_ reason: StopReason) -> [RecorderEffect] {
        stopReason = reason
        phase = .stopping
        retryAt = nil
        return [.finish(reason)]
    }

    // MARK: - Helpers

    static let alreadyStopping = "The recorder is already stopping."
    private static let asleep = "The computer is asleep."
    private static let stillStarting = "The recording is still starting."

    private static func acknowledge(_ request: ControlRequest, _ result: ControlResult,
                                    _ message: String? = nil) -> RecorderEffect {
        .acknowledge(ControlAck(id: request.id, command: request.command, result: result, message: message,
                                handledAt: placeholderDate))
    }

    private static func warning(_ code: RecorderWarningCode, _ message: String) -> RecorderWarning {
        RecorderWarning(code: code, message: message, since: placeholderDate)
    }

    /// `didWake {at, sleptSeconds, action}`: resume, wait, or finalize.
    private static func wakeEvent(at: Double, slept: Double, action: String) -> RecorderEffect {
        .recordEvent(kind: MeetingEventKind.didWake, details: [
            "at": String(at), "sleptSeconds": String(slept), "action": action,
        ])
    }

    /// "4 min", or "less than a minute".
    static func sleepLength(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "less than a minute" }
        return "\(Int((min(seconds, 1e9) / 60).rounded())) min"
    }

    /// The stall warning for the stalled `tracks`.
    static func stallMessage(_ tracks: [String], seconds: Double) -> String {
        let limit = seconds.rounded() == seconds && seconds.isFinite ? String(Int(min(seconds, 1e9))) : String(seconds)
        switch Set(tracks) {
        case [TrackWatchdog.microphoneTrack]:
            return "No audio from the microphone for more than \(limit) s."
        case ["system"]:
            return "No system audio for more than \(limit) s; nothing may be playing."
        default:
            return "No audio from the microphone or system audio for more than \(limit) s."
        }
    }

    private static func describe(_ end: CaptureEnd) -> String {
        switch end {
        case .requested: "Capture stopped."
        case .configurationChanged: "The audio device configuration changed."
        case .failed(let message), .startFailed(let message): message
        case .userStoppedSharing: "Sharing was stopped."
        }
    }
}
