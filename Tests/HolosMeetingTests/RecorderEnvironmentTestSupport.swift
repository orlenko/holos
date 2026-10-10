import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import Synchronization
import Testing

// Helpers for the sleep, power and input-device tests. Shared test helpers (Fakes.swift) live elsewhere
// (docs/conventions.md §1.8), so every name here starts with `recorder`.

/// The PR2b tests that run a whole recorder loop (SleepPolicyTests, WatchdogTests, MicrophoneSelectionTests), one at a
/// time: each loop runs on the main actor, and running them all at once with the rest of the suite would slow the
/// other timing-sensitive tests.
@Suite(.serialized) @MainActor struct RecorderEnvironmentLoopTests {}

/// A scripted `SystemPowerEvents`: the test posts events and moves the lid; the loop's acknowledgements are kept.
/// Like `SystemPowerMonitor`, it drops events posted while neither observing nor attached.
final class RecorderFakePower: SystemPowerEvents {
    private struct State {
        var events: [TimedPowerEvent] = []
        var attached = false
        var observing = false
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

    func post(_ event: PowerEvent) { post([TimedPowerEvent(event)]) }

    /// Posts `events` at once, so the loop drains them together, each as old as it says.
    func post(_ events: [TimedPowerEvent]) {
        state.withLock { state in
            if state.attached || state.observing { state.events += events }
        }
    }

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

    /// Observing or attached: events are queued.
    var listening: Bool { state.withLock { $0.attached || $0.observing } }

    func pendingEvents() -> [PowerEvent] { pendingTimedEvents().map(\.event) }

    func pendingTimedEvents() -> [TimedPowerEvent] {
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

    func observe() { state.withLock { $0.observing = true } }

    func attach() { state.withLock { $0.attached = true } }

    func detach() {
        state.withLock { state in
            state.attached = false
            state.observing = false
            state.events.removeAll()
        }
    }
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

/// Opens once. `wait()` returns once it is open, and cancelling the waiting task does not end the wait: a platform
/// call that hangs whatever its caller does.
final class RecorderStopHold: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    var isOpen: Bool { state.withLock { $0.open } }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withLock { state in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if open { continuation.resume() }
        }
    }
}

/// The `FakeCapture` it wraps, but `stop()` hangs until `hold` opens, even once the recorder has given up on it.
@MainActor
final class RecorderHangingStopCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    let inner: FakeCapture
    private let hold: RecorderStopHold
    private(set) var stopCalls = 0

    init(_ inner: FakeCapture, hold: RecorderStopHold) {
        self.inner = inner; self.hold = hold
        frames = inner.frames
    }

    var hostTimeOrigin: Double { inner.hostTimeOrigin }

    func start(_ request: CaptureRequest) async throws { try await inner.start(request) }

    func stop() async throws {
        stopCalls += 1
        await hold.wait()
        try await inner.stop()
    }
}
