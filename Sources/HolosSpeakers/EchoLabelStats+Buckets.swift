import Foundation

/// What the words the evidence rule moves from the microphone to echo look like (`EchoLabelStats`): how far below the
/// microphone the call's predicted echo is over each word's local frames, and how much of the word is local. Counts
/// only.
extension EchoLabelStats {
    /// Words by the median predicted echo relative to the microphone over their local frames, in decibels (a frame
    /// with no predicted echo is the lowest level, so in `below6`).
    public struct LevelBuckets: Sendable, Equatable, Encodable {
        /// 0 dB or more: the echo explains the microphone.
        public var atLeast0 = 0
        /// −1 dB or more, under 0.
        public var from1To0 = 0
        /// −3 dB or more, under −1.
        public var from3To1 = 0
        /// −6 dB or more, under −3.
        public var from6To3 = 0
        /// Under −6 dB.
        public var below6 = 0

        public init() {}

        mutating func add(level: Double) {
            switch level {
            case 0...: atLeast0 += 1
            case -1..<0: from1To0 += 1
            case -3 ..< -1: from3To1 += 1
            case -6 ..< -3: from6To3 += 1
            default: below6 += 1
            }
        }

        mutating func add(_ other: LevelBuckets) {
            atLeast0 += other.atLeast0; from1To0 += other.from1To0; from3To1 += other.from3To1
            from6To3 += other.from6To3; below6 += other.below6
        }

        /// "≥0:a −1..0:b −3..−1:c −6..−3:d <−6:e".
        public var text: String {
            "≥0:\(atLeast0) −1..0:\(from1To0) −3..−1:\(from3To1) −6..−3:\(from6To3) <−6:\(below6)"
        }
    }

    /// Words by the share of their active frames that are local (all of them, as the rule before counted: a word moved
    /// to echo had 30 % or more).
    public struct ShareBuckets: Sendable, Equatable, Encodable {
        /// Under 50 %.
        public var from30To50 = 0
        /// 50 % or more, under 80 %.
        public var from50To80 = 0
        /// 80 % or more.
        public var atLeast80 = 0

        public init() {}

        mutating func add(share: Double) {
            if share < 0.5 { from30To50 += 1 } else if share < 0.8 { from50To80 += 1 } else { atLeast80 += 1 }
        }

        mutating func add(_ other: ShareBuckets) {
            from30To50 += other.from30To50; from50To80 += other.from50To80; atLeast80 += other.atLeast80
        }

        /// "30-50%:a 50-80%:b ≥80%:c".
        public var text: String { "30-50%:\(from30To50) 50-80%:\(from50To80) ≥80%:\(atLeast80)" }
    }

    /// The word from `start` to `end` as `AcousticEchoMask.isEcho` reads it: the median stored level of its local
    /// frames in decibels, and the share of its active frames that are local; nil without a local frame.
    static func localFrames(_ mask: AcousticEchoMask, start: Double, end: Double) -> (level: Double, share: Double)? {
        guard start.isFinite, end.isFinite else { return nil }
        let first = mask.firstFrame(centredAtOrAfter: start)
        guard first < mask.frameCount else { return nil }
        let last = min(mask.frameCount, max(first + 1, mask.firstFrame(centredAtOrAfter: end)))
        var active = 0
        var levels: [Double] = []
        for frame in first..<last {
            switch mask.frameClass(frame) {
            case .silence: continue
            case .echo: active += 1
            case .local:
                active += 1
                levels.append(Double(mask.echoLevels[frame]) * AcousticEchoMask.levelStepDB)
            }
        }
        guard !levels.isEmpty else { return nil }
        levels.sort()
        let middle = levels.count / 2
        let median = levels.count % 2 == 1 ? levels[middle] : (levels[middle - 1] + levels[middle]) / 2
        return (median, Double(levels.count) / Double(active))
    }

    /// Counts one word moved from the microphone to echo, `elsewhere` when its surroundings are not echo.
    mutating func countMoved(_ mask: AcousticEchoMask, start: Double, end: Double, elsewhere: Bool) {
        guard let word = Self.localFrames(mask, start: start, end: end) else { return }
        localToEchoLevels.add(level: word.level)
        localToEchoShares.add(share: word.share)
        if elsewhere {
            localToEchoElsewhereLevels.add(level: word.level)
            localToEchoElsewhereShares.add(share: word.share)
        }
    }

    /// "levels ≥0:a … (elsewhere ≥0:…); shares 30-50%:a … (elsewhere 30-50%:…)".
    var bucketsText: String {
        "levels \(localToEchoLevels.text) (elsewhere \(localToEchoElsewhereLevels.text)); shares "
            + "\(localToEchoShares.text) (elsewhere \(localToEchoElsewhereShares.text))"
    }
}
