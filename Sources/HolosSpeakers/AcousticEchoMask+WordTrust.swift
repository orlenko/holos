import Foundation

/// Which local frames the word rule (`AcousticEchoMask.isEcho`, docs/meeting-design.md §5.11) counts as the
/// microphone's own speech: each local frame is judged by the frames within a fixed reach of it, never through runs or
/// stretches that can grow without bound. Review playback keeps #108's local stretches with evidence
/// (`localSpeechIntervals`) and none of this.
extension AcousticEchoMask {
    /// (a) A local frame whose predicted echo is at least this many decibels below the microphone (1 % of its power),
    /// or absent, has no echo to explain: trusted on its own. The 5-frame smoothing can leave a single local frame of a
    /// quiet sound; the echo cancelled poorly predicts within a few decibels of the microphone.
    public static let negligibleEchoDB = -20.0
    /// (b) A local frame with at least `evidenceFrames` local frames 6 dB clear of the echo (`evidenceDB`) within this
    /// many frames either side (288 ms, under the 300 ms across which #108 joins runs) is trusted: speech over the call
    /// keeps its quieter syllables. Only evidence frames give support, so it reaches no further from them.
    public static let supportFrames = 18
    /// (c) A local frame is trusted when, in the window of this many frames centred on it (496 ms, a few syllables),
    public static let sustainedWindowFrames = 31
    /// at least this share of the frames are local (sustained speech with brief gaps between syllables; the echo
    /// cancelled poorly leaves runs of 3–5 frames scattered through the call's speech)
    public static let sustainedDensity = 0.5
    /// and most of those local frames have the predicted echo below this many decibels relative to the microphone.
    /// Speech in the room adds to the echo, so the microphone is louder than the echo alone: by 3 dB at equal
    /// loudness (−3 dB here), by 1 dB for speech about 6 dB quieter than the echo; the echo cancelled poorly predicts
    /// 0 to +3.5 dB.
    public static let sustainedLevelDB = -1.0

    /// The frames whose local frames the word rule trusts (rules (a)–(c) above), in order, consecutive frames joined.
    /// One pass with running counts: linear in the frames.
    static func trustedWordFrames(classes: [UInt8], echoLevels: [Int8]) -> [Range<Int>] {
        let count = classes.count
        let local = FrameClass.local.rawValue
        // Running counts: local frames, local frames of evidence, local frames below `sustainedLevelDB`.
        var locals = [Int32](repeating: 0, count: count + 1)
        var evidence = [Int32](repeating: 0, count: count + 1)
        var below = [Int32](repeating: 0, count: count + 1)
        for frame in 0..<count {
            let isLocal = classes[frame] == local
            let level = Double(echoLevels[frame]) * levelStepDB
            locals[frame + 1] = locals[frame] + (isLocal ? 1 : 0)
            evidence[frame + 1] = evidence[frame] + (isLocal && level < evidenceDB ? 1 : 0)
            below[frame + 1] = below[frame] + (isLocal && level < sustainedLevelDB ? 1 : 0)
        }
        func sum(_ counts: [Int32], _ first: Int, _ end: Int) -> Int {
            Int(counts[min(count, max(0, end))] - counts[min(count, max(0, first))])
        }
        let reach = sustainedWindowFrames / 2
        var trusted: [Range<Int>] = []
        for frame in 0..<count where classes[frame] == local {
            let negligible = Double(echoLevels[frame]) * levelStepDB <= negligibleEchoDB
            let supported = sum(evidence, frame - supportFrames, frame + supportFrames + 1) >= evidenceFrames
            var sustained = false
            if !negligible && !supported {
                let first = max(0, frame - reach)
                let end = min(count, frame + reach + 1)
                let windowLocals = sum(locals, first, end)
                sustained = Double(windowLocals) >= sustainedDensity * Double(end - first)
                    && 2 * sum(below, first, end) > windowLocals
            }
            guard negligible || supported || sustained else { continue }
            if let last = trusted.last, last.upperBound == frame {
                trusted[trusted.count - 1] = last.lowerBound..<(frame + 1)
            } else {
                trusted.append(frame..<(frame + 1))
            }
        }
        return trusted
    }
}
