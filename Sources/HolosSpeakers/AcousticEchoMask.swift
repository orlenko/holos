import Foundation
import HolosCore

/// What the acoustic echo analysis (`EchoAnalysis`, docs/meeting-design.md §5.11) found in each 16 ms frame of a
/// call's microphone track: silence, echo of the system audio, or local speech (the user, or someone in the room).
/// Frame k is the 1,024-sample window starting at session sample 256·k (16 kHz), so its centre is at
/// `firstCentreSeconds + k · hopSeconds`.
///
/// Speaker labelling asks it about words (`isEcho(start:end:)`); review playback can ask it where the microphone has
/// speech of its own (`localSpeechIntervals()`). Neither trusts every local frame: the call cancelled poorly also
/// leaves frames the frame rule calls local. Playback keeps the local stretches with evidence (`localStretches()`);
/// the word rule trusts those and a little more (`trustedWordFrames`).
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
    /// A word is echo when fewer than this share of its active frames are local frames the word rule trusts
    /// (`trustedWordFrames`).
    public static let localWordShare = 0.3
    /// The version of the word rule (`isEcho`), part of the mask's identity (`EchoMaskStore.identity`), so transcript
    /// files written under an earlier rule are out of date. 1: every local frame counted; 2 (2026-10-08): only the
    /// local frames `trustedWordFrames` trusts.
    public static let wordRuleVersion = 2
    /// A word without active frames is echo when the predicted echo is at least this many decibels relative to the
    /// microphone over the word (median of its frames).
    public static let explainedEchoDB = -5.0
    /// Levels are stored in steps of this many decibels.
    static let levelStepDB = 0.5

    /// Local stretches (`localStretches()`): runs of local frames closer than this are one stretch.
    public static let stretchGapSeconds = 0.3
    /// A stretch has evidence of the microphone's own speech when at least this many of its local frames (48 ms: the
    /// shortest local run the analysis's 5-frame smoothing leaves)
    public static let evidenceFrames = 3
    /// have the predicted echo more than this many decibels below the microphone (three quarters of the sound or
    /// more is not the call; no predicted echo at all is the lowest level, so speech while the call is quiet has it).
    /// Local frames where the prediction is near the microphone's level, or above it, are the echo cancelled poorly:
    /// on real calls they come scattered through the call's speech in runs of a few frames, and alone they would open
    /// the microphone onto the echo in review and give echo words to the microphone's speakers.
    public static let evidenceDB = -6.0
    /// Review playback (`localSpeechIntervals`): stretches with evidence are padded by this much before,
    public static let playbackLeadSeconds = 0.064
    /// and by this much after.
    public static let playbackTailSeconds = 0.2

    /// `FrameClass` raw values, one per frame.
    public let classes: [UInt8]
    /// The predicted echo level relative to the microphone (dB(echo) − dB(mic)), in `levelStepDB` steps, clamped to
    /// the Int8 range (no predicted echo or no microphone sound: the lowest). Words without active frames use it, and
    /// the evidence of local stretches (`localStretches()`).
    public let echoLevels: [Int8]
    /// The frames whose local frames count for the word rule (`isEcho`), in order and disjoint (`trustedWordFrames`),
    /// worked out once (a call has hundreds of thousands of frames and thousands of words). Every stretch whole in
    /// `countingEveryLocalFrame()`.
    let wordStretches: [Range<Int>]

    /// Nil when the counts differ or a class is not a `FrameClass`.
    public init?(classes: [UInt8], echoLevels: [Int8]) {
        guard classes.count == echoLevels.count, classes.allSatisfy({ FrameClass(rawValue: $0) != nil }) else {
            return nil
        }
        self.classes = classes
        self.echoLevels = echoLevels
        wordStretches = Self.trustedWordFrames(classes: classes, echoLevels: echoLevels)
    }

    private init(classes: [UInt8], echoLevels: [Int8], wordStretches: [Range<Int>]) {
        self.classes = classes
        self.echoLevels = echoLevels
        self.wordStretches = wordStretches
    }

    /// The same frames under the word rule before 2026-10-08 (`wordRuleVersion` 1), where every local frame counted
    /// for its word, evidence or not; review playback is unchanged. For measuring the rule
    /// (`EchoLabelStats`), never for showing labels.
    public func countingEveryLocalFrame() -> AcousticEchoMask {
        AcousticEchoMask(classes: classes, echoLevels: echoLevels,
                         wordStretches: localStretches().map(\.frames))
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
    /// `start`. With active frames, it is echo when fewer than `localWordShare` of them are local frames the word rule
    /// trusts (`trustedWordFrames`: a stretch with evidence whole, sustained speech over the call, frames with
    /// negligible predicted echo): any other local frame (the call cancelled poorly) counts as echo. A stretch is
    /// judged whole, beyond the word, so a word spoken quietly over the call is the microphone's when the stretch it is
    /// in has louder frames elsewhere, and a word only partly on trusted frames counts just those. Without
    /// active frames, it is echo only when the predicted echo explains its energy: the median stored level is at least
    /// `explainedEchoDB`.
    public func isEcho(start: Double, end: Double) -> Bool? {
        guard start.isFinite, end.isFinite else { return nil }
        let first = firstFrame(centredAtOrAfter: start)
        guard first < frameCount else { return nil }
        let last = min(frameCount, max(first + 1, firstFrame(centredAtOrAfter: end)))
        var active = 0
        var local = 0
        // The first stretch that does not end before the word.
        var lower = 0
        var upper = wordStretches.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if wordStretches[middle].upperBound <= first { lower = middle + 1 } else { upper = middle }
        }
        var stretch = lower
        for frame in first..<last {
            switch frameClass(frame) {
            case .silence: continue
            case .echo: active += 1
            case .local:
                active += 1
                while stretch < wordStretches.count, wordStretches[stretch].upperBound <= frame { stretch += 1 }
                if stretch < wordStretches.count, wordStretches[stretch].contains(frame) { local += 1 }
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

    // MARK: - Local stretches

    /// Runs of local frames joined across gaps shorter than `stretchGapSeconds`, with how many of their local frames
    /// are evidence of the microphone's own speech.
    public struct LocalStretch: Sendable, Equatable {
        /// From the stretch's first local frame to after its last (the frames between its runs included).
        public var frames: Range<Int>
        /// Its local frames with the predicted echo below `evidenceDB`.
        public var evidence: Int

        public init(frames: Range<Int>, evidence: Int) { self.frames = frames; self.evidence = evidence }

        /// At least `evidenceFrames` frames of evidence: speech of the microphone's own (the user, or someone in the
        /// room), whose every local frame counts, also the quieter ones over the call. Review playback plays it whole
        /// (#108), and the word rule trusts it.
        public var hasEvidence: Bool { evidence >= AcousticEchoMask.evidenceFrames }
        /// Session time from its first frame to its last, each frame covering one hop around its centre.
        public var start: Double {
            AcousticEchoMask.centre(ofFrame: frames.lowerBound) - AcousticEchoMask.hopSeconds / 2
        }
        public var end: Double {
            AcousticEchoMask.centre(ofFrame: frames.upperBound - 1) + AcousticEchoMask.hopSeconds / 2
        }
    }

    /// Every local stretch, with evidence or not, in frame order: what review playback (`localSpeechIntervals`)
    /// plays, and the first thing the word rule trusts (`trustedWordFrames`).
    public func localStretches() -> [LocalStretch] {
        Self.localStretches(classes: classes, echoLevels: echoLevels)
    }

    static func localStretches(classes: [UInt8], echoLevels: [Int8]) -> [LocalStretch] {
        let local = FrameClass.local.rawValue
        var stretches: [LocalStretch] = []
        var frame = 0
        while frame < classes.count {
            guard classes[frame] == local else { frame += 1; continue }
            let first = frame
            var evidence = 0
            while frame < classes.count, classes[frame] == local {
                if Double(echoLevels[frame]) * levelStepDB < evidenceDB { evidence += 1 }
                frame += 1
            }
            let run = LocalStretch(frames: first..<frame, evidence: evidence)
            if let last = stretches.last, run.start - last.end < stretchGapSeconds {
                stretches[stretches.count - 1].frames = last.frames.lowerBound..<frame
                stretches[stretches.count - 1].evidence += evidence
            } else {
                stretches.append(run)
            }
        }
        return stretches
    }

    // MARK: - Playback

    public struct Interval: Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// Session-time intervals where the microphone has speech of its own, for review playback: the local stretches
    /// with evidence (`localStretches()`; a stretch keeps all its runs, so speech over the call keeps its quieter
    /// syllables and its first one), widened by `playbackLeadSeconds` before (not below 0) and `playbackTailSeconds`
    /// after, and joined again where they meet. In start order, disjoint. Only these (#108): the word rule's other
    /// trusted frames (`trustedWordFrames`) hold the echo as loud as the user, or lie beside echo the padding would
    /// open onto.
    public func localSpeechIntervals() -> [Interval] {
        var padded: [Interval] = []
        for stretch in localStretches() where stretch.hasEvidence {
            let interval = Interval(start: max(0, stretch.start - Self.playbackLeadSeconds),
                                    end: stretch.end + Self.playbackTailSeconds)
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

    /// Reads `bytes` as written for `frameCount` frames; nil when the length or a class does not fit. The count comes
    /// from a file, so it is checked against the bytes before any arithmetic (a huge count must not overflow).
    public init?(bytes: Data, frameCount: Int) {
        guard frameCount >= 0, bytes.count % 2 == 0, frameCount == bytes.count / 2 else { return nil }
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
