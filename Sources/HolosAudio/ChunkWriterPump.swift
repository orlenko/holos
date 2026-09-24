import Foundation
import HolosCore
import os
import Synchronization

/// Takes disk latency out of the capture path (docs/meeting-design.md §4.3): the frame consumer pushes captured audio
/// here without ever waiting, and one writer task (`run()`) writes it to an `AudioChunkWriter` in order.
///
/// Each track may queue up to `capacitySeconds` of audio. When a track's queue is full the frame is dropped (`push`
/// returns false) and the writer closes the chunk at that point, so the lost interval is recorded as an
/// `audioDiscontinuity` with reason `overflow` instead of being written over. Gap notes and `closeAll` markers are
/// queued with the frames, so they apply at exactly the position they were made.
public final class ChunkWriterPump: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "capture")

    private enum Item: Sendable {
        case frame(CapturedAudio)
        case gap(track: String, reason: GapReason)
        case closeAll(reason: GapReason, marker: UInt64)
    }

    private enum Next {
        case item(Item)
        case wait
        case done
    }

    private struct State {
        var queue: [Item] = []
        var head = 0
        var queuedSeconds: [String: Double] = [:]
        /// Tracks whose last push was dropped: a run of drops queues one overflow note.
        var dropping: Set<String> = []
        var finished = false
        /// Set when the writer failed; later pushes are dropped.
        var failure: String?
        var nextMarker: UInt64 = 0
        /// The last `closeAll` marker the writer finished (markers are processed in order).
        var completedMarker: UInt64 = 0
        /// `closeAll` callers waiting for their marker, by marker number.
        var waiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
    }

    private let writer: AudioChunkWriter
    private let capacitySeconds: Double
    private let state = Mutex(State())
    private let wake: AsyncStream<Void>.Continuation
    private let wakeups: AsyncStream<Void>

    public init(writer: AudioChunkWriter, capacitySeconds: Double = 60) {
        self.writer = writer
        self.capacitySeconds = capacitySeconds.isFinite && capacitySeconds > 0 ? capacitySeconds : 60
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeups = stream
        wake = continuation
    }

    /// Never blocks. Returns false when the frame was dropped because the track's queue is full (or the writer
    /// failed or was finished).
    public func push(_ audio: CapturedAudio) -> Bool {
        let seconds = audio.frame.duration
        let accepted = state.withLock { state -> Bool in
            guard state.failure == nil, !state.finished else { return false }
            let queued = state.queuedSeconds[audio.track, default: 0]
            // An empty queue always takes a frame, so one frame longer than the capacity is never lost.
            if queued > 0, queued + seconds > capacitySeconds {
                if state.dropping.insert(audio.track).inserted {
                    state.queue.append(.gap(track: audio.track, reason: .overflow))
                }
                return false
            }
            state.dropping.remove(audio.track)
            state.queuedSeconds[audio.track] = queued + seconds
            state.queue.append(.frame(audio))
            return true
        }
        wake.yield()
        return accepted
    }

    /// The track's next discontinuity carries `reason`, and its next frame starts a new chunk at its own time.
    public func noteGap(track: String, reason: GapReason) {
        let queued = state.withLock { state -> Bool in
            guard state.failure == nil else { return false }
            state.queue.append(.gap(track: track, reason: reason))
            return true
        }
        if queued { wake.yield() }
    }

    /// Seconds of audio queued per track, waiting to be written.
    public func backlogSeconds() -> [String: Double] {
        state.withLock { $0.queuedSeconds.filter { $0.value > 0 } }
    }

    /// Closes every open chunk once the frames queued before this call are written; the next discontinuity on each
    /// track carries `reason`. Returns when the chunks are closed. Frames pushed afterwards go into new chunks even if
    /// the caller stops waiting.
    public func closeAll(expectingGap reason: GapReason) async throws {
        let marker = state.withLock { state -> UInt64? in
            guard state.failure == nil else { return nil }
            state.nextMarker &+= 1
            state.queue.append(.closeAll(reason: reason, marker: state.nextMarker))
            return state.nextMarker
        }
        guard let marker else { throw HolosError.io("The audio writer has stopped.") }
        wake.yield()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let outcome = state.withLock { state -> Result<Void, Error>? in
                if let failure = state.failure { return .failure(HolosError.io(failure)) }
                // Markers complete in order; the writer may already have passed this one.
                if state.completedMarker >= marker { return .success(()) }
                state.waiters[marker] = continuation
                return nil
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    /// Writes queued frames in order until `finish()` is called and the queue is empty. Throws the writer's first
    /// error; the pump then drops every later push.
    public func run() async throws {
        var iterator = wakeups.makeAsyncIterator()
        while true {
            switch next() {
            case .item(let item):
                do {
                    try await process(item)
                } catch {
                    fail(error)
                    throw error
                }
            case .done:
                return
            case .wait:
                if await iterator.next() == nil {
                    // The wake stream only ends when the waiting task is cancelled.
                    let error = CancellationError()
                    fail(error)
                    throw error
                }
            }
        }
    }

    /// No more frames will be pushed; `run()` returns once the queue is written.
    public func finish() {
        state.withLock { $0.finished = true }
        wake.yield()
    }

    // MARK: - Private

    private func next() -> Next {
        state.withLock { state in
            guard state.head < state.queue.count else {
                state.queue.removeAll(keepingCapacity: true)
                state.head = 0
                return state.finished ? .done : .wait
            }
            let item = state.queue[state.head]
            state.head += 1
            if state.head > 1_024, state.head * 2 > state.queue.count {
                state.queue.removeFirst(state.head)
                state.head = 0
            }
            return .item(item)
        }
    }

    private func process(_ item: Item) async throws {
        switch item {
        case .frame(let audio):
            // Counted as queued until written, so the backlog includes a frame the disk is still taking.
            defer {
                state.withLock { state in
                    let remaining = state.queuedSeconds[audio.track, default: 0] - audio.frame.duration
                    state.queuedSeconds[audio.track] = remaining > 1e-9 ? remaining : 0
                }
            }
            try await writer.append(audio)
        case .gap(let track, let reason):
            await writer.noteGap(track: track, reason: reason)
        case .closeAll(let reason, let marker):
            // A failure reaches the waiter through `fail`.
            try await writer.closeAll(expectingGap: reason)
            let waiter = state.withLock { state in
                state.completedMarker = marker
                return state.waiters.removeValue(forKey: marker)
            }
            waiter?.resume()
        }
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            if state.failure == nil { state.failure = message }
            let waiting = Array(state.waiters.values)
            state.waiters.removeAll()
            state.queue.removeAll()
            state.head = 0
            state.queuedSeconds.removeAll()
            return waiting
        }
        for waiter in waiters { waiter.resume(throwing: HolosError.io(message)) }
        Self.log.error("The audio writer failed: \(message, privacy: .public)")
    }
}
