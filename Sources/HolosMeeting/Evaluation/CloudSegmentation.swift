import Foundation

/// One upload of a track: render frames [startFrame, endFrame) of its 16 kHz render.
public struct CloudSegmentPlan: Codable, Sendable, Equatable {
    public var index: Int
    public var startFrame: Int
    public var endFrame: Int
    /// Seconds at the start that the previous segment also sent (when no pause was found near the cut).
    public var overlapSeconds: Double
    /// Every energy window is below the silence level: nothing is uploaded and the text is empty.
    public var silent: Bool

    public init(index: Int, startFrame: Int, endFrame: Int, overlapSeconds: Double = 0, silent: Bool = false) {
        self.index = index; self.startFrame = startFrame; self.endFrame = endFrame
        self.overlapSeconds = overlapSeconds; self.silent = silent
    }

    public func seconds(sampleRate: Double) -> Double { Double(endFrame - startFrame) / sampleRate }
}

/// Where to cut a track for upload (docs/reference-evaluation.md, "Cloud reference").
public enum CloudSegmentation {
    public struct Settings: Sendable, Equatable {
        /// Longest segment. OpenAI takes files up to 25 MB; the older models refuse audio over 1,400–1,500 s and cut
        /// their output at about 2,000 tokens (8–11 minutes), so segments stay well below both.
        public var maxSeconds: Double = 300
        /// How far before `maxSeconds` a cut may move to reach a pause.
        public var searchSeconds: Double = 45
        /// Energy window length.
        public var windowSeconds: Double = 0.1
        /// A pause is at least this long.
        public var pauseSeconds: Double = 0.4
        /// RMS level (full scale 1) under which a window is silence (about −46 dBFS).
        public var silenceRMS: Float = 0.005
        /// Audio the next segment repeats when the cut falls inside speech.
        public var overlapSeconds: Double = 1.0
        /// A last segment shorter than this is merged into the one before when that stays under `maxSeconds` +
        /// `searchSeconds`; one shorter than 0.1 s (below the API's minimum) is dropped.
        public var minimumSeconds: Double = 2.0

        public init() {}
    }

    /// Cuts `frameCount` frames into segments of at most `maxSeconds` (except the merge above). Each cut is placed
    /// at the quietest `pauseSeconds` stretch within the last `searchSeconds` before the limit (the latest one on a
    /// tie); when that stretch is not silence, the next segment starts `overlapSeconds` earlier. A segment whose
    /// every window is silence is marked `silent`. `rms` holds one value per `windowSeconds` window.
    public static func plan(frameCount: Int, sampleRate: Double, rms: [Float], settings: Settings = Settings())
        -> [CloudSegmentPlan] {
        guard frameCount > 0, sampleRate > 0 else { return [] }
        let windowFrames = max(1, Int((settings.windowSeconds * sampleRate).rounded()))
        let maxFrames = max(windowFrames, Int(settings.maxSeconds * sampleRate))
        let searchFrames = min(maxFrames / 2, Int(settings.searchSeconds * sampleRate))
        let pauseWindows = max(1, Int((settings.pauseSeconds / settings.windowSeconds).rounded()))
        let overlapFrames = Int(settings.overlapSeconds * sampleRate)
        var cuts: [(start: Int, end: Int, overlap: Int)] = []
        var start = 0
        var overlap = 0
        while frameCount - start > maxFrames {
            let latest = start + maxFrames
            let earliest = latest - searchFrames
            // Candidate pause stretches: pauseWindows consecutive windows starting at w, fully inside the search.
            var best: (level: Float, cut: Int)?
            let firstWindow = (earliest + windowFrames - 1) / windowFrames
            let lastWindow = latest / windowFrames - pauseWindows
            if lastWindow >= firstWindow {
                for window in firstWindow...lastWindow {
                    var level: Float = 0
                    for k in window..<(window + pauseWindows) { level = max(level, k < rms.count ? rms[k] : 0) }
                    if best == nil || level <= best!.level {
                        best = (level, (window + pauseWindows / 2) * windowFrames)
                    }
                }
            }
            let cut = best?.cut ?? latest
            let quiet = (best?.level ?? .infinity) < settings.silenceRMS
            cuts.append((start, cut, overlap))
            overlap = quiet ? 0 : min(overlapFrames, cut - start)
            start = cut - overlap
        }
        cuts.append((start, frameCount, overlap))
        // A very short tail joins the segment before when it fits.
        if cuts.count > 1, let tail = cuts.last {
            let tailFrames = tail.end - tail.start - tail.overlap
            let previous = cuts[cuts.count - 2]
            if Double(tailFrames) < settings.minimumSeconds * sampleRate,
               tail.end - previous.start <= maxFrames + searchFrames {
                cuts.removeLast()
                cuts[cuts.count - 1].end = tail.end
            } else if Double(tail.end - tail.start) < 0.1 * sampleRate {
                cuts.removeLast()
            }
        }
        return cuts.enumerated().map { index, cut in
            let firstWindow = cut.start / windowFrames
            let lastWindow = min(rms.count, (cut.end + windowFrames - 1) / windowFrames)
            let silent = lastWindow <= firstWindow
                || rms[firstWindow..<lastWindow].allSatisfy { $0 < settings.silenceRMS }
            return CloudSegmentPlan(index: index, startFrame: cut.start, endFrame: cut.end,
                                    overlapSeconds: Double(cut.overlap) / sampleRate, silent: silent)
        }
    }

    /// Words a second of overlap can hold (fast speech is about four words a second).
    static let wordsPerOverlapSecond = 4.0

    /// The words of each segment's text with the words a segment repeats from the one before removed: with an
    /// overlap, the longest run that ends the previous segment's words and starts this one's, compared by key, is
    /// dropped from this one — at most as many words as the overlap can hold (`wordsPerOverlapSecond`), so a
    /// phrase said again after the overlap stays. Segments without overlap are kept whole.
    public static func stitch(_ texts: [(text: String, overlapSeconds: Double)]) -> [[String]] {
        var result: [[String]] = []
        for (text, overlapSeconds) in texts {
            var words = EvalText.tokens(text)
            if overlapSeconds > 0, let previous = result.last(where: { !$0.isEmpty }) {
                let maxRepeat = max(1, Int((overlapSeconds * wordsPerOverlapSecond).rounded(.up)))
                let limit = min(maxRepeat, previous.count, words.count)
                var drop = 0
                if limit > 0 {
                    for length in stride(from: limit, through: 1, by: -1) {
                        let tail = previous.suffix(length).map(EvalText.key)
                        let head = words.prefix(length).map(EvalText.key)
                        if tail == head { drop = length; break }
                    }
                }
                words.removeFirst(drop)
            }
            result.append(words)
        }
        return result
    }
}
