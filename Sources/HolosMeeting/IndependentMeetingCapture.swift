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
    /// Shared by recovery and Stop: a timeout does not launch a second native stop or abandon its cleanup.
    private var systemStopTask: Task<Void, Error>?
    private var stopped = false
    private var started = false
    private var systemReading = false
    private var retiredDrops = 0
    public private(set) var hostTimeOrigin = 0.0
    // Tests shorten these; production awaits are bounded and retries back off to 30 s.
    var retryDelay: Duration = .milliseconds(500)
    var startLimit: Duration = .seconds(10)
    var stopLimit: Duration = .seconds(5)
    private(set) var systemRetryAttempt = 0

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
    public var unavailableTailTracks: Set<String> { relay.unavailableTailTracks }
    public var droppedBuffers: Int {
        relay.droppedBuffers + retiredDrops + (microphone?.droppedBuffers ?? 0) + (system?.droppedBuffers ?? 0)
    }

    public func start(_ request: CaptureRequest) async throws {
        guard !started, !stopped else { throw HolosError.invalidInput("Capture is already running or stopped.") }
        started = true
        if request.source != .microphone {
            relay.configureSystemStart(unavailable: request.initialSystemUnavailable, boundary: request.boundaryReason)
        }
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

    private func retrySystem(_ request: CaptureRequest, attempt initialAttempt: Int = 0) async {
        var attempt = initialAttempt
        while !stopped, !Task.isCancelled {
            systemRetryAttempt = attempt
            let child = makeCapture()
            system = child
            let recoveries = relay.recoveries
            let starting = Task { try await child.start(request) }
            switch await awaitWithTimeout(startLimit, { try await starting.value }) {
            case .finished(.success):
                if stopped || Task.isCancelled {
                    _ = await settleSystemStop(child)
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
                let stopping = beginSystemStop(child)
                _ = await awaitWithTimeout(stopLimit, cancellable: false) { try await stopping.value }
                systemTask = Task {
                    _ = await starting.result
                    // Settle the in-flight stop first. The late start may have acquired a handle afterwards,
                    // so also settle a fresh stop before any retry. This worker may wait; the recorder never does.
                    _ = await settleSystemStop(child)
                    guard await settleSystemStop(child) else { return }
                    guard !stopped, !Task.isCancelled else { return }
                    retiredDrops += child.droppedBuffers
                    system = nil
                    let next = min(attempt + 1, 6)
                    do { try await Task.sleep(for: Self.retryWait(attempt: attempt, base: retryDelay)) }
                    catch { return }
                    await retrySystem(request, attempt: next)
                }
                return
            }
            guard !stopped, !Task.isCancelled else { return }
            relay.systemUnavailable()
            guard await settleSystemStop(child), !stopped, !Task.isCancelled else { return }
            retiredDrops += child.droppedBuffers
            system = nil
            if relay.recoveries > recoveries { attempt = 0 }
            let delay = Self.retryWait(attempt: attempt, base: retryDelay)
            attempt = min(attempt + 1, 6)
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    static func retryWait(attempt: Int, base: Duration) -> Duration {
        min(.seconds(30), base * (1 << min(max(0, attempt), 6)))
    }

    private func beginSystemStop(_ child: any MeetingCapture) -> Task<Void, Error> {
        if let systemStopTask { return systemStopTask }
        let stopping = Task { try await child.stop() }
        systemStopTask = stopping
        return stopping
    }

    /// Only the serial recovery worker clears this task. Stop can await the same task within its own budget.
    /// A failed cleanup retries the same handle with backoff; an unresolved cleanup waits. Neither creates streams.
    private func settleSystemStop(_ child: any MeetingCapture) async -> Bool {
        var attempt = 0
        while true {
            let stopping = beginSystemStop(child)
            let outcome = await stopping.result
            systemStopTask = nil
            if case .success = outcome { return true }
            guard !stopped, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: Self.retryWait(attempt: attempt, base: retryDelay)) }
            catch { return false }
            attempt = min(attempt + 1, 6)
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
        let primary = microphone
        let systemStopping = system.map { beginSystemStop($0) }
        // Concurrent stops keep the recorder's single stop budget, not two sequential native stop budgets.
        let limit = stopLimit
        let failure = await withTaskGroup(of: (any Error)?.self, returning: (any Error)?.self) { group in
            if let primary {
                group.addTask {
                    switch await awaitWithTimeout(limit, cancellable: false, { try await primary.stop() }) {
                    case .finished(.failure(let error)): return error
                    case .timedOut: return HolosError.io("Audio capture stop timed out.")
                    default: return nil
                    }
                }
            }
            if let systemStopping {
                group.addTask {
                    switch await awaitWithTimeout(limit, cancellable: false, { try await systemStopping.value }) {
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
        var initialSystemReason: GapReason = .audioUnavailable
        var recoveries = 0
        var dropped = 0
        var pendingDrops: Set<String> = []
    }
    private let state = Mutex(State())
    private let output: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    init(_ output: AsyncThrowingStream<CapturedAudio, Error>.Continuation) { self.output = output }
    var unavailableTracks: Set<String> { state.withLock { $0.systemMissing ? ["system"] : [] } }
    var unavailableTailTracks: Set<String> {
        state.withLock { $0.systemMissing || $0.systemBoundary && !$0.systemHeard ? ["system"] : [] }
    }
    var droppedBuffers: Int { state.withLock { $0.dropped } }
    var recoveries: Int { state.withLock { $0.recoveries } }

    func configureSystemStart(unavailable: Bool, boundary: GapReason?) {
        state.withLock {
            // A delayed successful first start still has a leading gap, without implying failure/silence.
            $0.systemBoundary = true
            $0.systemMissing = unavailable
            $0.initialSystemReason = boundary ?? .audioUnavailable
        }
    }

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
                                        ? (state.systemHeard ? .captureRestarted : state.initialSystemReason) : audio.discontinuity)
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
