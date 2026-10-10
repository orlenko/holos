import AVFoundation
import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// The microphone's volume through a meeting's review playback (docs/meeting/review-window.md §5.10): full where the
/// microphone has speech of its own, silent where it only picked up the call from the speakers (the echo), with short
/// linear ramps between. Pure.
public struct ReviewMicVolume: Sendable, Equatable {
    /// A linear change of volume from `start` to `end` (session seconds).
    public struct Ramp: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var from: Float
        public var to: Float

        public init(start: Double, end: Double, from: Float, to: Float) {
            self.start = start; self.end = end; self.from = from; self.to = to
        }
    }

    /// The volume from 0 until the first ramp.
    public var initial: Float
    /// In time order, apart; between two ramps the volume stays where the first one ended.
    public var ramps: [Ramp]

    public init(initial: Float, ramps: [Ramp]) { self.initial = initial; self.ramps = ramps }

    /// How long a fade in or out takes: short enough to keep a word's first sound, long enough not to click.
    public static let rampSeconds = 0.025

    /// The volume for a playback `duration` seconds long that keeps the microphone in `intervals` (session time, in
    /// start order; `AcousticEchoMask.localSpeechIntervals`) and silences it elsewhere.
    ///
    /// Intervals are sorted, clipped to the playback; empty ones are dropped. Two closer than two ramps are joined (a dip
    /// there would only be a click). A fade in ends where its interval starts (inside the mask's lead padding), and
    /// a fade out starts where it ends; both are shortened at the playback's start and end. An interval from 0 starts
    /// at full volume, and one that reaches the end never fades out. No interval: silent throughout.
    public static func keeping(_ intervals: [AcousticEchoMask.Interval], duration: Double,
                               ramp: Double = rampSeconds) -> ReviewMicVolume {
        guard duration.isFinite, duration > 0 else { return ReviewMicVolume(initial: 0, ramps: []) }
        var kept: [(start: Double, end: Double)] = []
        for interval in intervals.sorted(by: { $0.start < $1.start })
            where interval.start.isFinite && interval.end.isFinite {
            let start = max(0, interval.start)
            let end = min(duration, interval.end)
            guard start < end else { continue }
            if let last = kept.last, start - last.end < 2 * ramp {
                kept[kept.count - 1].end = max(last.end, end)
            } else {
                kept.append((start, end))
            }
        }
        var initial: Float = 0
        var ramps: [Ramp] = []
        ramps.reserveCapacity(kept.count * 2)
        for interval in kept {
            if interval.start <= 0 {
                initial = 1
            } else {
                ramps.append(Ramp(start: max(0, interval.start - ramp), end: interval.start, from: 0, to: 1))
            }
            if interval.end < duration {
                ramps.append(Ramp(start: interval.end, end: min(duration, interval.end + ramp), from: 1, to: 0))
            }
        }
        return ReviewMicVolume(initial: initial, ramps: ramps)
    }

    /// The audio mix that plays composition track `track` at this volume (the other tracks as they are).
    public func audioMix(track: CMPersistentTrackID) -> AVMutableAudioMix {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = track
        parameters.setVolume(initial, at: .zero)
        // Last ramp first: AVFoundation keeps the ramps sorted, and adding each before the ones it has is linear in
        // all, where adding in time order costs a pass over them each time (12,000 ramps, more than a 2-hour call
        // has: about 13 ms against 13 s in a debug build). The ramps read back the same either way.
        for ramp in ramps.reversed() {
            let range = CMTimeRange(start: SessionAudioComposition.sessionTime(ramp.start),
                                    end: SessionAudioComposition.sessionTime(ramp.end))
            parameters.setVolumeRamp(fromStartVolume: ramp.from, toEndVolume: ramp.to, timeRange: range)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

/// Echo-free review playback: the microphone volume a session's current echo mask calls for.
public enum ReviewEchoMute {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "review")

    /// The microphone's volume for a playback `duration` seconds long, or nil (the microphone as recorded) unless the
    /// session's current echo analysis (`EchoMaskStore.current`) found echo: no analysis, one out of date or damaged,
    /// one by a newer Voice is Local, or a verdict other than `echo` (headphones, no system audio, too long) all play
    /// the microphone as recorded. It is kept at full volume where the playback has no system audio (`systemPlaced`,
    /// session time, as `SessionAudioComposition.makePlayback` placed it): the echo is muted only where the call is
    /// heard from the system track. Reads files; call it off the main actor.
    public static func micVolume(session: URL, manifest: SessionManifest, duration: Double,
                                 systemPlaced: [Range<Double>]) -> ReviewMicVolume? {
        let stored: EchoMaskStore.Stored?
        do {
            stored = try EchoMaskStore.current(session: session, manifest: manifest)
        } catch {
            log.error("Session \(manifest.id, privacy: .public): echo mask not used for playback: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return nil
        }
        guard let mask = stored?.mask else { return nil }
        return ReviewMicVolume.keeping(mask.localSpeechIntervals() + uncovered(by: systemPlaced, duration: duration),
                                       duration: duration)
    }

    /// The parts of [0, `duration`) that `covered` (any order, may overlap) leaves out. Pure.
    static func uncovered(by covered: [Range<Double>], duration: Double) -> [AcousticEchoMask.Interval] {
        guard duration.isFinite, duration > 0 else { return [] }
        var gaps: [AcousticEchoMask.Interval] = []
        var reached = 0.0
        for range in covered.sorted(by: { $0.lowerBound < $1.lowerBound })
            where range.lowerBound.isFinite && range.upperBound.isFinite {
            if range.lowerBound > reached { gaps.append(.init(start: reached, end: min(range.lowerBound, duration))) }
            reached = max(reached, range.upperBound)
            if reached >= duration { break }
        }
        if reached < duration { gaps.append(.init(start: reached, end: duration)) }
        return gaps.filter { $0.start < $0.end }
    }
}

/// Which echo mask the review's microphone volume was last read for: the labels' mask
/// (`SpeakerSessionSnapshot.echoMaskIdentity`, nil without one). The window reads the volume again when the labels it
/// adopts come with another mask, however they came (a relabel in the window, a reload, `session echo-analyze`).
/// Pure.
public struct ReviewEchoMaskFollow: Sendable, Equatable {
    private var identity: String?

    public init(identity: String? = nil) { self.identity = identity }

    /// A player became ready (its playback read the mask while it was built, possibly an older one): the volume is
    /// read once more against the labels' mask now, `identity`. Always true.
    public mutating func playerBecameReady(labels identity: String?) -> Bool {
        self.identity = identity
        return true
    }

    /// The labels now show `identity`: true when it is another mask than the last one read for and the player is
    /// ready (the volume must be read again). While the player is not ready nothing is taken as read: its becoming
    /// ready reads the volume then. The same mask, or none again, is false.
    public mutating func update(_ identity: String?, playerReady: Bool) -> Bool {
        guard playerReady, identity != self.identity else { return false }
        self.identity = identity
        return true
    }
}
