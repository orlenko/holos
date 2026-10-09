import Foundation

/// Which local frames the word rule (`AcousticEchoMask.isEcho`, docs/meeting-design.md §5.11) counts as the
/// microphone's own speech. Review playback keeps only the stretches with evidence (#108); words also keep sustained
/// speech over the call and sounds the call predicts nothing for, which playback leaves muted (the echo is as loud as
/// the user there, or lies beside them within the playback padding).
extension AcousticEchoMask {
    /// A window of this many consecutive local frames (208 ms: a held syllable; over four times the 48 ms the 5-frame
    /// smoothing can leave, and over twice the 3–5-frame runs the call cancelled poorly leaves scattered through its
    /// speech)
    public static let sustainedRunFrames = 13
    /// whose median predicted echo is below this many decibels relative to the microphone is sustained speech of the
    /// microphone's own over the call. Speech in the room adds to the echo, so the microphone is louder than the echo
    /// alone: by 3 dB at equal loudness (−3 dB here), by 1 dB for speech about 6 dB quieter than the echo; the echo
    /// cancelled poorly predicts 0 to +3.5 dB.
    public static let sustainedLevelDB = -1.0
    /// A local frame whose predicted echo is at least this many decibels below the microphone (1 % of its power, or no
    /// prediction at all) has no echo to explain: the word rule trusts it on its own, at any length. The 5-frame
    /// smoothing can leave a single local frame of a quiet sound, too short for `evidenceFrames`; the echo cancelled
    /// poorly predicts within a few decibels of the microphone, and even evidence (`evidenceDB`) is a quarter of it.
    public static let negligibleEchoDB = -20.0

    /// The frames whose local frames the word rule trusts, in order, joined where they touch: every local stretch with
    /// evidence (`localStretches()`, whole); every frame of a run of local frames covered by a window of
    /// `sustainedRunFrames` of them whose median predicted echo is below `sustainedLevelDB` (only the windows that
    /// qualify, so a run's poorly cancelled part before or after the speech is not trusted with it); and every local
    /// frame whose predicted echo is at most `negligibleEchoDB` (each on its own, never its neighbours).
    static func trustedWordFrames(classes: [UInt8], echoLevels: [Int8]) -> [Range<Int>] {
        var trusted = localStretches(classes: classes, echoLevels: echoLevels).filter(\.hasEvidence).map(\.frames)
        let local = FrameClass.local.rawValue
        let window = sustainedRunFrames
        var frame = 0
        while frame < classes.count {
            guard classes[frame] == local else { frame += 1; continue }
            let first = frame
            while frame < classes.count, classes[frame] == local {
                if Double(echoLevels[frame]) * levelStepDB <= negligibleEchoDB { trusted.append(frame..<(frame + 1)) }
                frame += 1
            }
            guard frame - first >= window else { continue }
            for start in first...(frame - window) {
                // The median of an odd count is its middle value.
                let median = Double(echoLevels[start..<(start + window)].sorted()[window / 2]) * levelStepDB
                if median < sustainedLevelDB { trusted.append(start..<(start + window)) }
            }
        }
        return joined(trusted)
    }

    /// `ranges` in order, with ranges that overlap or touch joined.
    static func joined(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var joined: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = joined.last, range.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                joined.append(range)
            }
        }
        return joined
    }
}
