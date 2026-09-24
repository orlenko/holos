import Foundation

/// How a captured frame continues its track (docs/meeting-design.md §2.3). Used by `AudioChunkWriter` and the live
/// transcription feed, so audio is never written or recognized twice and no chunk starts before the previous one
/// ends.
///
/// Within a capture epoch, per track, with `expected` = the end of the previous frame:
/// - `|start − expected| < 0.05 s`: contiguous. The samples follow directly; the frame's own time is ignored.
/// - `start ≥ expected + 0.05 s`: a gap.
/// - `start ≤ expected − 0.05 s`: an overlap. The leading samples before `expected` are dropped.
public enum FrameContinuity {
    /// Seconds of timestamp jitter treated as contiguous audio.
    public static let tolerance = 0.05

    public enum Decision: Sendable, Equatable {
        /// The frame follows the previous one; `driftSeconds` is `start − expected` (0 for a track's first frame).
        case contiguous(driftSeconds: Double)
        /// The frame starts `seconds` after the previous one ended.
        case gap(seconds: Double)
        /// Leading frames to drop; `dropFrames ≥ frameCount` means the whole frame lies before `expected`.
        case overlap(dropFrames: Int)
    }

    /// §2.3 rules with the 0.05 s tolerance. `expected` nil means the first frame of the track.
    public static func classify(frameStart: Double, frameCount: Int, sampleRate: Double,
                                expected: Double?) -> Decision {
        guard let expected else { return .contiguous(driftSeconds: 0) }
        let drift = frameStart - expected
        if drift >= tolerance { return .gap(seconds: drift) }
        if drift > -tolerance { return .contiguous(driftSeconds: drift) }
        // The samples that start before `expected`: sample i starts at frameStart + i / sampleRate. A millionth of
        // a sample absorbs floating-point error at an exact boundary.
        let exact = (expected - frameStart) * sampleRate
        let drop = exact.isFinite ? max(0, (exact - 1e-6).rounded(.up)) : Double(frameCount)
        return .overlap(dropFrames: drop >= Double(Int.max) ? Int.max : Int(drop))
    }
}
