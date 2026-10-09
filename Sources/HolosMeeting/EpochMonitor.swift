import HolosAudio
import Synchronization

/// What the frame consumer tells the loop, shared off the main actor.
final class EpochMonitor: Sendable {
    struct TrackInfo: Sendable, Equatable {
        /// Session time at which the consumer last received a frame (watchdog time).
        var lastFrameAt: Double
        /// Session time of the end of the last frame.
        var lastFrameEnd: Double
        /// Seconds of audio received.
        var seconds: Double
        var sampleRate: Double
        var channels: Int
    }

    private struct State {
        var epoch = 0
        var sawFrame = false
        var stopRequested: Set<Int> = []
        /// Epochs (the current one, or later) whose stream has already ended.
        var ended: Set<Int> = []
        var events: [RecorderInput] = []
        var tracks: [String: TrackInfo] = [:]
        var dropped = false
    }

    private let state = Mutex(State())

    func begin(epoch: Int) {
        state.withLock { state in
            state.epoch = epoch
            state.sawFrame = false
            // A stop requested after its epoch's stream had already ended is never matched; an older epoch's end
            // is stale for the machine anyway.
            state.stopRequested = state.stopRequested.filter { $0 >= epoch }
            state.ended = state.ended.filter { $0 >= epoch }
        }
    }

    /// The loop is about to stop `epoch`'s capture. Returns true when that epoch's stream had already ended by itself
    /// (the user stopped sharing, or capture failed): the stop is only cleanup then, and nothing waits for its end.
    @discardableResult
    func requestStop(epoch: Int) -> Bool {
        state.withLock { state in
            if state.ended.contains(epoch) { return true }
            state.stopRequested.insert(epoch)
            return false
        }
    }

    /// Tests only: stop requests not yet matched with their epoch's end.
    var pendingStopRequests: Int { state.withLock { $0.stopRequested.count } }

    func received(epoch: Int, audio: CapturedAudio, at: Double) {
        state.withLock { state in
            if epoch == state.epoch, !state.sawFrame {
                state.sawFrame = true
                state.events.append(.captureRunning(epoch: epoch, at: at))
            }
            let frame = audio.frame
            var info = state.tracks[audio.track] ?? TrackInfo(lastFrameAt: at, lastFrameEnd: 0, seconds: 0,
                                                             sampleRate: frame.sampleRate, channels: frame.channels)
            info.lastFrameAt = at
            info.lastFrameEnd = max(info.lastFrameEnd, frame.startTime + frame.duration)
            info.seconds += frame.duration
            info.sampleRate = frame.sampleRate
            info.channels = frame.channels
            state.tracks[audio.track] = info
        }
    }

    /// The frame stream of `epoch` ended, with `error` or normally.
    func ended(epoch: Int, error: Error?, at: Double) {
        state.withLock { state in
            let end: CaptureEnd
            state.ended.insert(epoch)
            // An epoch's stream ends once: its entry goes, so restarts over a long recording do not pile up.
            if state.stopRequested.remove(epoch) != nil {
                end = .requested
            } else if let interruption = error as? CaptureInterruption {
                end = interruption == .userStoppedSharing ? .userStoppedSharing : .configurationChanged
            } else if let error {
                end = .failed(message: error.localizedDescription)
            } else {
                end = .failed(message: "Audio capture ended unexpectedly.")
            }
            state.events.append(.captureEnded(epoch: epoch, end, at: at))
        }
    }

    func drain() -> [RecorderInput] {
        state.withLock { state in
            defer { state.events.removeAll() }
            return state.events
        }
    }

    func noteDrop() { state.withLock { $0.dropped = true } }

    /// True once after audio was dropped.
    func takeDropped() -> Bool {
        state.withLock { state in
            defer { state.dropped = false }
            return state.dropped
        }
    }

    /// The largest frame end on any track; nil before any audio.
    func lastFrameEnd() -> Double? { state.withLock { $0.tracks.values.map(\.lastFrameEnd).max() } }

    func lastFrameAt() -> [String: Double] { state.withLock { $0.tracks.mapValues(\.lastFrameAt) } }

    func trackInfo() -> [String: TrackInfo] { state.withLock { $0.tracks } }
}
