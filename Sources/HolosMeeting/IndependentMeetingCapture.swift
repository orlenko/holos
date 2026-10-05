import Foundation
import HolosAudio
import HolosCore
import Synchronization

/// Meeting-only isolation: microphone uses AVAudioEngine, system audio uses its own ScreenCaptureKit stream.
/// Only system-audio failures retry locally. Mic failures and deliberate Stop Sharing still reach the recorder's
/// existing lifecycle. Pause/sleep/stop cancel both tracks. Optional screen capture belongs to the microphone
/// capture (or the system-only capture) and already fails independently of audio.
@MainActor public final class IndependentMeetingCapture: MeetingCapture {
    public nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    private let relay: IndependentCaptureRelay
    private let makeCapture: @MainActor @Sendable () -> any MeetingCapture
    private var microphone: (any MeetingCapture)?
    private var system: (any MeetingCapture)?
    private var microphoneTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var stopped = false
    private var started = false
    private var systemReading = false
    private var retiredDrops = 0
    public private(set) var hostTimeOrigin = 0.0
    // Tests shorten these; production awaits are bounded and retries back off to 30 s.
    var retryDelay: Duration = .milliseconds(500)
    var startLimit: Duration = .seconds(10)
    var stopLimit: Duration = .seconds(5)

    public init(bufferCapacity: Int = 4096) {
        let pair = AsyncThrowingStream<CapturedAudio, Error>.makeStream(bufferingPolicy: .bufferingOldest(bufferCapacity))
        frames = pair.stream
        relay = IndependentCaptureRelay(pair.continuation)
        makeCapture = { LiveMeetingCapture(bufferCapacity: bufferCapacity) }
    }

    /// No native capture is created in tests.
    init(bufferCapacity: Int = 4096, makeCapture: @escaping @MainActor @Sendable () -> any MeetingCapture) {
        let pair = AsyncThrowingStream<CapturedAudio, Error>.makeStream(bufferingPolicy: .bufferingOldest(bufferCapacity))
        frames = pair.stream
        relay = IndependentCaptureRelay(pair.continuation)
        self.makeCapture = makeCapture
    }

    public var unavailableTracks: Set<String> { relay.unavailableTracks }
    public var droppedBuffers: Int {
        relay.droppedBuffers + retiredDrops + (microphone?.droppedBuffers ?? 0) + (system?.droppedBuffers ?? 0)
    }

    public func start(_ request: CaptureRequest) async throws {
        guard !started, !stopped else { throw HolosError.invalidInput("Capture is already running or stopped.") }
        started = true
        let primary = makeCapture()
        microphone = primary
        var primaryRequest = request
        if request.source == .microphoneAndSystem {
            primaryRequest.source = .microphone
            primaryRequest.applicationBundleID = nil
        }
        try await primary.start(primaryRequest)
        guard !stopped, !Task.isCancelled else {
            try? await primary.stop()
            throw CancellationError()
        }
        hostTimeOrigin = primary.hostTimeOrigin
        let relay = self.relay
        microphoneTask = Task.detached(priority: .userInitiated) {
            do {
                for try await frame in primary.frames { relay.push(frame) }
                await self.primaryEnded()
            } catch { await self.primaryEnded(error: error) }
        }
        guard request.source == .microphoneAndSystem else { return }
        // A slow content query / locked display must not hold up microphone frames or the recorder loop.
        var systemRequest = request
        systemRequest.source = .system
        systemRequest.screen = nil
        systemRequest.sessionDirectory = nil
        // Both native streams use one host origin, including every later retry's setup time.
        systemRequest.timelineOffset = 0
        systemRequest.offsetHostTime = hostTimeOrigin
        systemTask = Task { await retrySystem(systemRequest) }
    }

    private func primaryEnded(error: Error? = nil) {
        // A requested stop drains both native queues before ending the merged stream.
        if !stopped { relay.finish(error: error) }
    }

    private func retrySystem(_ request: CaptureRequest) async {
        var attempt = 0
        while !stopped, !Task.isCancelled {
            let child = makeCapture()
            system = child
            let recoveries = relay.recoveries
            let starting = Task { try await child.start(request) }
            switch await awaitWithTimeout(startLimit, { try await starting.value }) {
            case .finished(.success):
                if stopped || Task.isCancelled {
                    try? await child.stop()
                    return
                }
                systemReading = true
                let end = await Self.consumeSystem(child, relay: relay)
                systemReading = false
                if end == .userStoppedSharing {
                    relay.finish(error: CaptureInterruption.userStoppedSharing)
                    return
                }
            case .finished(.failure(let error)):
                if error as? CaptureInterruption == .userStoppedSharing {
                    relay.finish(error: CaptureInterruption.userStoppedSharing)
                    return
                }
            case .timedOut, .cancelled:
                // One abandoned start at a time: never accumulate new SCStreams behind a hung platform call.
                // If it eventually returns, release it and retry. Stop also releases it immediately and later.
                starting.cancel()
                relay.systemUnavailable()
                systemTask = Task {
                    _ = await starting.result
                    _ = await awaitWithTimeout(stopLimit, cancellable: false) { try await child.stop() }
                    guard !stopped, !Task.isCancelled else { return }
                    retiredDrops += child.droppedBuffers
                    system = nil
                    do { try await Task.sleep(for: retryDelay) } catch { return }
                    await retrySystem(request)
                }
                return
            }
            guard !stopped, !Task.isCancelled else { return }
            relay.systemUnavailable()
            _ = await awaitWithTimeout(stopLimit, cancellable: false) { try await child.stop() }
            retiredDrops += child.droppedBuffers
            system = nil
            if relay.recoveries > recoveries { attempt = 0 }
            let delay = min(.seconds(30), retryDelay * (1 << min(attempt, 6)))
            attempt = min(attempt + 1, 6)
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    /// Runs off the main actor, so the microphone and system stream do not compete with UI work.
    private nonisolated static func consumeSystem(_ capture: any MeetingCapture,
                                                  relay: IndependentCaptureRelay) async -> CaptureInterruption? {
        do {
            for try await frame in capture.frames {
                guard !Task.isCancelled else { return nil }
                relay.push(frame)
            }
        } catch {
            return error as? CaptureInterruption
        }
        return nil
    }

    public func stop() async throws {
        guard !stopped else { return }
        stopped = true
        let deadline = ContinuousClock.now.advanced(by: stopLimit)
        if !systemReading { systemTask?.cancel() }
        let children = [microphone, system].compactMap { $0 }
        // Concurrent stops keep the recorder's single stop budget, not two sequential native stop budgets.
        let limit = stopLimit
        let failure = await withTaskGroup(of: (any Error)?.self, returning: (any Error)?.self) { group in
            for child in children {
                group.addTask {
                    switch await awaitWithTimeout(limit, cancellable: false, { try await child.stop() }) {
                    case .finished(.failure(let error)): return error
                    case .timedOut: return HolosError.io("Audio capture stop timed out.")
                    default: return nil
                    }
                }
            }
            var first: (any Error)?
            for await error in group { if first == nil { first = error } }
            return first
        }
        // Native stop finished the streams: drain queued audio before finishing the merged output.
        if let microphoneTask {
            _ = await awaitWithTimeout(max(.zero, ContinuousClock.now.duration(to: deadline)), cancellable: false) {
                await microphoneTask.value
            }
        }
        if systemReading, let systemTask {
            _ = await awaitWithTimeout(max(.zero, ContinuousClock.now.duration(to: deadline)), cancellable: false) {
                await systemTask.value
            }
        }
        relay.finish()
        microphoneTask?.cancel()
        systemTask?.cancel()
        if let failure { throw failure }
    }
}

/// One bounded output queue, independent of main-actor scheduling. Only the first accepted resumed system frame
/// carries the boundary. If it is dropped, the boundary and drop flag are retained for the next accepted frame.
private final class IndependentCaptureRelay: Sendable {
    private struct State {
        var finished = false
        var systemMissing = false
        var systemHeard = false
        var systemBoundary = false
        var recoveries = 0
        var dropped = 0
        var pendingDrops: Set<String> = []
    }
    private let state = Mutex(State())
    private let output: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    init(_ output: AsyncThrowingStream<CapturedAudio, Error>.Continuation) { self.output = output }
    var unavailableTracks: Set<String> { state.withLock { $0.systemMissing ? ["system"] : [] } }
    var droppedBuffers: Int { state.withLock { $0.dropped } }
    var recoveries: Int { state.withLock { $0.recoveries } }

    func systemUnavailable() {
        state.withLock {
            guard !$0.finished else { return }
            $0.systemMissing = true
            $0.systemBoundary = true
        }
    }

    func push(_ audio: CapturedAudio) {
        state.withLock { state in
            guard !state.finished else { return }
            let system = audio.track == "system"
            let frame = CapturedAudio(track: audio.track, frame: audio.frame,
                                      followsDrop: audio.followsDrop || state.pendingDrops.contains(audio.track),
                                      discontinuity: system && state.systemBoundary
                                        ? (state.systemHeard ? .captureRestarted : .audioUnavailable) : audio.discontinuity)
            switch output.yield(frame) {
            case .enqueued:
                state.pendingDrops.remove(audio.track)
                if system {
                    if state.systemMissing { state.recoveries += 1 }
                    state.systemMissing = false
                    state.systemHeard = true
                    state.systemBoundary = false
                }
            case .dropped:
                state.dropped += 1
                state.pendingDrops.insert(audio.track)
            case .terminated: state.finished = true
            @unknown default: break
            }
        }
    }

    func finish(error: Error? = nil) {
        let end = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.finished = true
            return true
        }
        if end { output.finish(throwing: error) }
    }
}
