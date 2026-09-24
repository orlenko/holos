import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import Synchronization
import Testing

// Helpers for the PR2b tests (sleep, power, input devices). Shared test helpers (Fakes.swift) belong to another PR in
// this wave (docs/meeting-design.md §1.8), so every name here starts with `recorder`.

/// The PR2b tests that run a whole recorder loop (SleepPolicyTests, WatchdogTests, MicrophoneSelectionTests), one at a
/// time: each loop runs on the main actor, and running them all at once with the rest of the suite would slow the
/// other timing-sensitive tests.
@Suite(.serialized) @MainActor struct RecorderEnvironmentLoopTests {}

/// A scripted `SystemPowerEvents`: the test posts events and moves the lid; the loop's acknowledgements are kept.
final class RecorderFakePower: SystemPowerEvents {
    private struct State {
        var events: [PowerEvent] = []
        var attached = false
        var lidOpen: Bool
        /// Lid reads since the lid last moved.
        var lidReads = 0
        var allowed: [Int] = []
    }

    private let state: Mutex<State>
    private let onAllow: (@Sendable (Int) -> Void)?

    /// `onAllow` runs inside `allowPowerChange`, before the token is recorded.
    init(lidOpen: Bool = true, onAllow: (@Sendable (Int) -> Void)? = nil) {
        state = Mutex(State(lidOpen: lidOpen))
        self.onAllow = onAllow
    }

    func post(_ event: PowerEvent) { state.withLock { $0.events.append(event) } }

    func setLid(open: Bool) {
        state.withLock { state in
            state.lidOpen = open
            state.lidReads = 0
        }
    }

    /// The loop has read the lid since it last moved.
    var lidSeen: Bool { state.withLock { $0.lidReads > 0 } }

    /// Tokens the loop acknowledged, in order.
    var allowed: [Int] { state.withLock { $0.allowed } }

    var attached: Bool { state.withLock { $0.attached } }

    func pendingEvents() -> [PowerEvent] {
        state.withLock { state in
            defer { state.events.removeAll() }
            return state.events
        }
    }

    func allowPowerChange(token: Int) {
        onAllow?(token)
        state.withLock { $0.allowed.append(token) }
    }

    func isLidOpen() -> Bool {
        state.withLock { state in
            state.lidReads += 1
            return state.lidOpen
        }
    }

    func attach() { state.withLock { $0.attached = true } }

    func detach() { state.withLock { $0.attached = false } }
}

/// The built-in microphone of the PR2b tests.
let recorderBuiltIn = InputDevice(id: 71, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
/// A headset that is the system default input.
let recorderAirPods = InputDevice(id: 92, uid: "AirPodsProUID", name: "AirPods Pro")

/// Input devices a test can change while a recording runs.
final class RecorderDevices: Sendable {
    private let devices: Mutex<InputDevices>

    init(builtIn: InputDevice? = recorderBuiltIn, systemDefault: InputDevice? = recorderAirPods) {
        devices = Mutex(InputDevices(builtIn: builtIn, systemDefault: systemDefault))
    }

    func set(builtIn: InputDevice?, systemDefault: InputDevice?) {
        devices.withLock { $0 = InputDevices(builtIn: builtIn, systemDefault: systemDefault) }
    }

    var lookup: @Sendable () -> InputDevices { { self.devices.withLock { $0 } } }
}

/// The current status.json of `session`, or nil.
func recorderStatus(_ session: URL) -> RecorderStatus? { try? RecorderChannel.readStatus(session: session) }

/// Frames on both tracks of a call, `count` of each, 0.1 s long from `from`.
func recorderCallFrames(from start: Double = 0, count: Int) -> [FakeFrame] {
    let mic = FakeFrame.run(track: "mic", from: start, count: count)
    let system = FakeFrame.run(track: "system", from: start, count: count)
    return zip(mic, system).flatMap { [$0, $1] }
}

/// Runs a record-only recording of `source` into `root`.
@MainActor
func recorderRecordOnly(_ root: URL, source: AudioSource = .microphone,
                        _ dependencies: RecordingDependencies) -> Task<RecordingOutcome, Error> {
    Task {
        try await RecordingWorkflow.run(.testing(root: root, source: source, recordOnly: true),
                                        dependencies: dependencies)
    }
}
