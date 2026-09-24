import Foundation
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
/// runtime disk check, and the pause limit live here. PR2b adds the sleep, watchdog, and device rules; until then
/// `willSleep` and `didWake` have no effect.
public struct RecorderMachine: Sendable, Equatable {
    /// Seconds without audio after which `waiting` gives up (`finish(captureFailed)`).
    static let unavailableLimit = 600.0
    /// Seconds a meeting may stay paused (`finish(pauseTimeout)`).
    static let pauseLimit = 21_600.0
    /// Seconds of audio after which an epoch counts as healthy and the restart attempts reset.
    static let healthyEpochSeconds = 10.0
    /// The longest wait between retries in `waiting`.
    static let maxRetryDelay = 30.0
    /// The placeholder date of acknowledgements and warnings; the loop stamps the real time.
    public static let placeholderDate = Date(timeIntervalSinceReferenceDate: 0)

    /// starting, recording, paused, waiting, sleeping, stopping.
    public private(set) var phase: RecorderPhase = .starting
    public private(set) var epoch = 0
    public private(set) var markers = 0
    /// Why the recording ended; nil until `finish`.
    public private(set) var stopReason: StopReason?

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

    public init() {}

    public mutating func handle(_ input: RecorderInput) -> [RecorderEffect] {
        guard stopReason == nil else {
            // After finish every input is ignored, except that requests are still acknowledged.
            if case .control(let request, _) = input {
                return [Self.acknowledge(request, .ignored, Self.alreadyStopping)]
            }
            return []
        }
        switch input {
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
        case .willSleep, .didWake:
            // Sleep rules arrive with PR2b.
            return []
        case .retryNow(_, let at):
            guard phase == .waiting else { return [] }
            return [retry(at: at)]
        case .tick(let at, _, let freeBytes, _):
            return tick(at: at, freeBytes: freeBytes)
        }
    }

    // MARK: - Capture

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
        case .starting:
            // Epoch 0 ended before its first frame: capture never started.
            return [.recordEvent(kind: MeetingEventKind.startFailed, details: ["error": Self.describe(end)])]
                + finish(.startFailed)
        case .recording:
            if end == .configurationChanged {
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
        effects += [
            // Chunks are already closed; this sets the gap's reason.
            .stopCapture(reason: .audioUnavailable),
            .recordEvent(kind: MeetingEventKind.captureWaiting, details: [
                "at": String(at), "reason": message, "attempt": String(attempt), "retryInSeconds": String(delay),
            ]),
            .warn(Self.warning(.audioUnavailable, "Audio is unavailable; retrying. The gap is marked.")),
        ]
        return effects
    }

    /// Leaves `waiting` with the next start attempt.
    private mutating func retry(at: Double) -> RecorderEffect {
        retryAt = nil
        attempt += 1
        return startNextEpoch()
    }

    /// The phase is `recording` while a start is in flight; a start failure comes back as `startFailed`.
    private mutating func startNextEpoch() -> RecorderEffect {
        epoch += 1
        epochRunningSince = nil
        phase = .recording
        return .startCapture(epoch: epoch)
    }

    // MARK: - Ticks

    private mutating func tick(at: Double, freeBytes: Int64?) -> [RecorderEffect] {
        switch phase {
        case .recording:
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
            return effects + diskCheck(freeBytes)
        case .waiting:
            if let since = unavailableSince, at - since >= Self.unavailableLimit { return finish(.captureFailed) }
            if let retryAt, at >= retryAt { return [retry(at: at)] }
            return []
        case .paused:
            if let since = pausedSince, at - since >= Self.pauseLimit { return finish(.pauseTimeout) }
            return []
        default:
            return []
        }
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

    private static func describe(_ end: CaptureEnd) -> String {
        switch end {
        case .requested: "Capture stopped."
        case .configurationChanged: "The audio device configuration changed."
        case .failed(let message), .startFailed(let message): message
        case .userStoppedSharing: "Sharing was stopped."
        }
    }
}
