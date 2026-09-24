import Foundation

/// Notices a capture track that stops delivering audio (docs/meeting-design.md §4.2). Held by `RecorderMachine`.
///
/// Times are session-clock times at which the frame consumer received a frame (§2.3), never frame media times. A
/// track's stall timer starts when its epoch's capture has started and is reset by every newer arrival, so a slow
/// startup or a permission prompt never looks like a stall. A track with no arrival for `stallSeconds` is stalled until
/// it delivers again. The microphone track ("mic") stalled for `restartSeconds` is due for a restart, at most once per
/// epoch; the system track never is (ScreenCaptureKit may deliver nothing while nothing plays, open question Q4).
///
/// A microphone that stays silent after a restart is restarted again after twice as long each time (10, 20, 40 s, …, at
/// most 5 minutes) until it delivers, so a dead microphone does not interrupt system audio every 10 seconds.
public struct TrackWatchdog: Sendable, Equatable {
    public let stallSeconds: Double
    public let restartSeconds: Double
    /// The longest wait between restarts of a microphone that stays silent.
    static let maxRestartSeconds = 300.0
    private var tracks: [String: TrackState] = [:]

    private struct TrackState: Sendable, Equatable {
        /// When the track's epoch started.
        var epochStart: Double
        /// The later of the epoch start and the last arrival in this epoch.
        var lastActivity: Double
        /// The latest arrival time seen in `lastFrameAt`, from any epoch.
        var seenArrival: Double?
        var stalled = false
        /// A restart was reported in this epoch.
        var restartReported = false
        /// Restarts since the track last delivered.
        var restarts = 0
    }

    public init(stallSeconds: Double = 3, restartSeconds: Double = 10) {
        self.stallSeconds = stallSeconds; self.restartSeconds = restartSeconds
    }

    /// Starts the stall timers of `tracks` at `at`, when the epoch's capture has started. A track that was stalled
    /// stays stalled until it delivers a frame; tracks not listed are no longer watched (a call epoch without the
    /// microphone).
    public mutating func startEpoch(at: Double, tracks watched: [String]) {
        var next: [String: TrackState] = [:]
        for track in watched {
            let previous = tracks[track]
            next[track] = TrackState(epochStart: at, lastActivity: at, seenArrival: previous?.seenArrival,
                                     stalled: previous?.stalled ?? false, restarts: previous?.restarts ?? 0)
        }
        tracks = next
    }

    /// Tracks that became stalled, tracks that recovered, and microphone tracks due for a restart, each sorted.
    /// `lastFrameAt`: per track, the session time at which the consumer last received a frame. Only an arrival newer
    /// than any seen before, and not before the epoch started, counts. A track that delivers again is reported as
    /// resumed and judged afresh at the next evaluation.
    public mutating func evaluate(lastFrameAt: [String: Double], now: Double)
        -> (stalled: [String], resumed: [String], restart: [String]) {
        var stalled: [String] = []
        var resumed: [String] = []
        var restart: [String] = []
        for track in tracks.keys.sorted() {
            guard var state = tracks[track] else { continue }
            defer { tracks[track] = state }
            if let arrival = lastFrameAt[track], arrival > (state.seenArrival ?? -.infinity) {
                state.seenArrival = arrival
                if arrival >= state.epochStart {
                    state.lastActivity = max(state.lastActivity, arrival)
                    state.restarts = 0
                    if state.stalled {
                        state.stalled = false
                        resumed.append(track)
                        continue
                    }
                }
            }
            let silent = now - state.lastActivity
            if !state.stalled, silent >= stallSeconds {
                state.stalled = true
                stalled.append(track)
            }
            let restartAfter = min(max(restartSeconds, Self.maxRestartSeconds),
                                   restartSeconds * pow(2, Double(min(state.restarts, 16))))
            if state.stalled, track == Self.microphoneTrack, !state.restartReported, silent >= restartAfter {
                state.restartReported = true
                state.restarts += 1
                restart.append(track)
            }
        }
        return (stalled, resumed, restart)
    }

    /// The watched tracks that are stalled, sorted.
    public var stalledTracks: [String] { tracks.filter(\.value.stalled).keys.sorted() }

    /// Seconds since `track` last delivered audio (or since its epoch started) at `now`; nil when it is not watched.
    public func silentSeconds(_ track: String, now: Double) -> Double? {
        tracks[track].map { now - $0.lastActivity }
    }

    /// Stops watching every track and forgets stalls (capture stopped: paused, asleep, or waiting).
    public mutating func stop() { tracks = [:] }

    static let microphoneTrack = "mic"
}
