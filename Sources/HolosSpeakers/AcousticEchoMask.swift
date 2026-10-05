import Foundation
import HolosCore

/// What the acoustic echo analysis (`EchoAnalysis`, docs/meeting-design.md §5.11) found in each 16 ms frame of a
/// call's microphone track: silence, echo of the system audio, or local speech (the user, or someone in the room).
/// Frame k is the 1,024-sample window starting at session sample 256·k (16 kHz), so its centre is at
/// `firstCentreSeconds + k · hopSeconds`.
///
/// Speaker labelling asks it about words (`isEcho(start:end:)`); review playback can ask it where the microphone has
/// speech of its own (`localSpeechIntervals()`).
public struct AcousticEchoMask: Sendable, Equatable {
    public enum FrameClass: UInt8, Sendable {
        /// The microphone is within `EchoAnalysis` `activeAboveFloorDB` of its noise floor.
        case silence = 0
        /// Active, and the echo predicted from the system audio explains it.
        case echo = 1
        /// Active, and much of it is left after the predicted echo is taken away.
        case local = 2
    }

    /// Seconds between frame centres: 256 samples at 16 kHz.
    public static let hopSeconds = 0.016
    /// Session time of frame 0's centre: half of the 1,024-sample window.
    public static let firstCentreSeconds = 0.032
    /// A word is echo when fewer than this share of its active frames are local.
    public static let localWordShare = 0.3
    /// A word without active frames is echo when the predicted echo is at least this many decibels relative to the
    /// microphone over the word (median of its frames).
    public static let explainedEchoDB = -5.0
    /// Levels are stored in steps of this many decibels.
    static let levelStepDB = 0.5

    /// Review playback (`localSpeechIntervals`): local stretches closer than this are one interval,
    public static let playbackMergeGapSeconds = 0.3
    /// padded by this much before,
    public static let playbackLeadSeconds = 0.064
    /// and by this much after.
    public static let playbackTailSeconds = 0.2

    /// `FrameClass` raw values, one per frame.
    public let classes: [UInt8]
    /// The predicted echo level relative to the microphone (dB(echo) − dB(mic)), in `levelStepDB` steps, clamped to
    /// the Int8 range; only words without active frames use it.
    public let echoLevels: [Int8]

    /// Nil when the counts differ or a class is not a `FrameClass`.
    public init?(classes: [UInt8], echoLevels: [Int8]) {
        guard classes.count == echoLevels.count, classes.allSatisfy({ FrameClass(rawValue: $0) != nil }) else {
            return nil
        }
        self.classes = classes
        self.echoLevels = echoLevels
    }

    public var frameCount: Int { classes.count }

    public func frameClass(_ frame: Int) -> FrameClass { FrameClass(rawValue: classes[frame]) ?? .silence }

    /// Session time of frame `frame`'s centre.
    public static func centre(ofFrame frame: Int) -> Double { firstCentreSeconds + Double(frame) * hopSeconds }

    /// A level in decibels as stored: rounded to `levelStepDB`, clamped to the Int8 range.
    static func storedLevel(_ decibels: Double) -> Int8 {
        guard decibels.isFinite else { return decibels > 0 ? .max : .min }
        let steps = (decibels / levelStepDB).rounded()
        return Int8(max(Double(Int8.min), min(Double(Int8.max), steps)))
    }

    // MARK: - Words

    /// Whether the microphone word spoken from `start` to `end` (session seconds) is echo; nil when the mask cannot
    /// say (times that are not numbers, or a word after the last frame), and the word is kept.
    ///
    /// The word's frames are those whose centre lies in [start, end), at least the first frame centred at or after
    /// `start`. With active frames, it is echo when fewer than `localWordShare` of them are local. Without any, it is
    /// echo only when the predicted echo explains its energy: the median stored level is at least `explainedEchoDB`.
    public func isEcho(start: Double, end: Double) -> Bool? {
        guard start.isFinite, end.isFinite else { return nil }
        let first = firstFrame(centredAtOrAfter: start)
        guard first < frameCount else { return nil }
        let last = min(frameCount, max(first + 1, firstFrame(centredAtOrAfter: end)))
        var active = 0
        var local = 0
        for frame in first..<last {
            switch frameClass(frame) {
            case .silence: continue
            case .echo: active += 1
            case .local: active += 1; local += 1
            }
        }
        if active > 0 { return Double(local) < Self.localWordShare * Double(active) }
        let levels = echoLevels[first..<last].map { Double($0) * Self.levelStepDB }.sorted()
        let middle = levels.count / 2
        let median = levels.count % 2 == 1 ? levels[middle] : (levels[middle - 1] + levels[middle]) / 2
        return median >= Self.explainedEchoDB
    }

    /// The first frame whose centre is at or after `time`.
    func firstFrame(centredAtOrAfter time: Double) -> Int {
        let position = (time - Self.firstCentreSeconds) / Self.hopSeconds
        guard position > 0 else { return 0 }
        guard position < Double(frameCount) + 1 else { return frameCount }
        var frame = Int(position.rounded(.up))
        // Floating-point rounding near an exact centre: settle on the first frame whose centre qualifies.
        while frame > 0, Self.centre(ofFrame: frame - 1) >= time { frame -= 1 }
        while frame < frameCount, Self.centre(ofFrame: frame) < time { frame += 1 }
        return min(frame, frameCount)
    }

    // MARK: - Playback

    public struct Interval: Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// Session-time intervals where the microphone has speech of its own, for review playback: runs of local frames
    /// (each frame covering one hop around its centre), joined across gaps shorter than `playbackMergeGapSeconds`,
    /// then widened by `playbackLeadSeconds` before (not below 0) and `playbackTailSeconds` after, and joined again
    /// where they meet. In start order, disjoint.
    public func localSpeechIntervals() -> [Interval] {
        var runs: [Interval] = []
        var frame = 0
        while frame < frameCount {
            guard frameClass(frame) == .local else { frame += 1; continue }
            let first = frame
            while frame < frameCount, frameClass(frame) == .local { frame += 1 }
            let start = Self.centre(ofFrame: first) - Self.hopSeconds / 2
            let end = Self.centre(ofFrame: frame - 1) + Self.hopSeconds / 2
            if let last = runs.last, start - last.end < Self.playbackMergeGapSeconds {
                runs[runs.count - 1].end = end
            } else {
                runs.append(Interval(start: start, end: end))
            }
        }
        var padded: [Interval] = []
        for run in runs {
            let interval = Interval(start: max(0, run.start - Self.playbackLeadSeconds),
                                    end: run.end + Self.playbackTailSeconds)
            if let last = padded.last, interval.start <= last.end {
                padded[padded.count - 1].end = max(last.end, interval.end)
            } else {
                padded.append(interval)
            }
        }
        return padded
    }

    // MARK: - Storage

    /// The classes, then the levels: two bytes per frame.
    public var bytes: Data {
        var data = Data(classes)
        data.append(contentsOf: echoLevels.map { UInt8(bitPattern: $0) })
        return data
    }

    /// Reads `bytes` as written for `frameCount` frames; nil when the length or a class does not fit.
    public init?(bytes: Data, frameCount: Int) {
        guard frameCount >= 0, bytes.count == 2 * frameCount else { return nil }
        let all = [UInt8](bytes)
        self.init(classes: Array(all[0..<frameCount]),
                  echoLevels: all[frameCount...].map { Int8(bitPattern: $0) })
    }
}

/// The mask holds per-frame audio classes only (no speech content), yet a 3 h meeting has 675,000 of them: printing
/// shows counts.
extension AcousticEchoMask: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let echo = classes.filter { $0 == FrameClass.echo.rawValue }.count
        let local = classes.filter { $0 == FrameClass.local.rawValue }.count
        return "AcousticEchoMask(frames: \(frameCount), echo: \(echo), local: \(local))"
    }

    public var debugDescription: String { description }
}
