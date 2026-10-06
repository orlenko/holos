import Accelerate
import Dispatch
import Foundation
import HolosCore

/// One track's audio on the session timeline at `EchoAnalysis.sampleRate`: sample n is session time n / 16,000 s.
public protocol EchoAudioSource: Sendable {
    /// One past the last session sample with audio.
    var sampleCount: Int { get }
    /// Writes `count` samples from session sample `start` (which may be negative) to `destination`. Samples without
    /// audio (before 0, from `sampleCount` on, in a gap) are 0.
    func read(from start: Int, count: Int, into destination: UnsafeMutablePointer<Float>) throws
}

/// Samples held in memory (tests and short clips).
public struct InMemoryEchoAudio: EchoAudioSource {
    public let samples: [Float]

    public init(_ samples: [Float]) { self.samples = samples }

    public var sampleCount: Int { samples.count }

    public func read(from start: Int, count: Int, into destination: UnsafeMutablePointer<Float>) {
        guard count > 0 else { return }
        destination.update(repeating: 0, count: count)
        let lower = max(start, 0)
        let upper = min(start + count, samples.count)
        guard lower < upper else { return }
        samples.withUnsafeBufferPointer { buffer in
            (destination + (lower - start)).update(from: buffer.baseAddress! + lower, count: upper - lower)
        }
    }
}

/// Acoustic detection of microphone echo in calls (docs/meeting-design.md §5.11): when the laptop speakers play a
/// call, the microphone records it again a moment later. The analysis measures that delay, predicts the microphone
/// from the system audio with a short filter per frequency, and calls each 16 ms microphone frame silence, echo
/// (the prediction explains it), or local speech (much of it is left after the prediction is taken away), so speech
/// in the room survives even while the call plays (double-talk). Pure: the caller reads the audio and stores the mask.
///
/// Steps (parameters from the 2026-10-05 research on real calls):
/// 1. Delay: GCC-PHAT between 10 s windows of both tracks every 30 s (every 10 s in meetings under 5 min) where the
///    system plays, lags −0.3…1.5 s. A window is confident when its largest correlation magnitude (either sign, for
///    a microphone of inverted polarity) is more than 20 times the median magnitude; a robust (Theil–Sen) line is
///    fitted through the confident windows, then refitted by least squares three times on those within 3 ms of it
///    (an outlying window cannot drag the first line away from the rest; the delay drifts by a few milliseconds an
///    hour: the two tracks' clocks differ).
/// 2. Gate: echo is present only when at least 3 windows, and at least 30 % of the windows where the system plays,
///    are confident and on the line, and the delay is at least 1 ms all meeting long (echo cannot reach the microphone
///    before the system audio; a zero lag is the same signal on both tracks, not the room). Otherwise nothing is
///    masked: headphones, or no system audio.
/// 3. Model: STFT of both tracks (1,024-sample Hann window, 256 hop, 150–4,000 Hz). Per 5 s block and per bin, the
///    microphone is predicted from the delayed system spectrum by an 8-tap complex filter (one frame ahead to six
///    behind), fitted by ridge-regularized least squares on the frames where the system plays, then refitted twice
///    without the frames whose residual keeps over a quarter of the microphone power.
/// 4. Frame rule: noise floors are the 15 s minimum of the 31-frame mean power. A frame is active 10 dB above the
///    microphone floor; an active frame is local when its residual is within the threshold of the microphone level and
///    10 dB above the floor. The threshold is −8 dB, raised toward −3 dB in 30 s stretches where the echo is poorly
///    cancelled (the 90th percentile of the residual ratio of echo-dominated frames, plus 1 dB). Local decisions are
///    smoothed over 5 frames (80 ms). Every other active frame is echo.
/// 5. Word rule: `AcousticEchoMask.isEcho(start:end:)`.
public enum EchoAnalysis {
    /// Bumped whenever the mask for the same audio changes; a stored mask of another version is computed again.
    public static let version = 1
    public static let sampleRate = 16_000

    // MARK: - Parameters

    static let windowLength = 1_024
    static let hop = 256
    /// Bins 10..<257 of the 1,024-point FFT: 156–4,000 Hz in 15.625 Hz bins.
    static let firstBin = 10
    static let endBin = 257
    static var binCount: Int { endBin - firstBin }
    static let taps = 8
    /// Taps reach this many frames past the delayed system frame (the echo path's spread around the fitted delay).
    static let lead = 1
    static let blockSeconds = 5.0
    /// A first fit and two refits.
    static let fits = 3
    static let ridge = 1e-3
    static let minimumFitFrames = 50
    static let systemOnPercentile = 20.0
    static let systemOnFactor: Float = 3
    static let systemOnMinimum: Float = 1e-10
    static let refitResidualShare: Float = 0.25
    /// Blocks analysed in parallel between two reads of the audio.
    static let batchBlocks = 24

    static let delayWindowSeconds = 10.0
    static let delayHopSeconds = 30.0
    static let shortMeetingSeconds = 300.0
    static let shortMeetingDelayHopSeconds = 10.0
    static let earliestLagSeconds = -0.3
    static let latestLagSeconds = 1.5
    static let systemPlaysRMS = 1e-4
    static let confidentPeakRatio = 20.0
    static let agreementMilliseconds = 3.0
    static let lineRefits = 3
    static let minimumAgreeingWindows = 3
    static let echoPresentShare = 0.3
    static let minimumDelayMilliseconds = 1.0

    static let floorSmoothingFrames = 31
    /// 15 s of frames.
    static let floorWindowFrames = 937
    static let floorMinimum = 1e-11
    static let activeAboveFloorDB = 10.0
    static let localAboveFloorDB = 10.0
    /// 30 s of frames.
    static let thresholdBlockFrames = 1_875
    static let thresholdPercentile = 90.0
    static let thresholdMarginDB = 1.0
    static let lowestThresholdDB = -8.0
    static let highestThresholdDB = -3.0
    static let echoDominatedDB = -3.0
    static let minimumThresholdFrames = 50
    static let smoothingFrames = 5

    // MARK: - Results

    public enum Verdict: String, Codable, Sendable {
        /// Echo is present; the mask says where.
        case echo
        /// The system audio played but did not reach the microphone confidently (headphones), or the meeting is too
        /// short to tell.
        case noEcho
        /// The system track is missing or silent.
        case noSystemAudio
    }

    /// The measured echo delay of the microphone behind the system audio.
    public struct DelayFit: Codable, Sendable, Equatable {
        /// Delay windows in which the system audio played.
        public var windows: Int
        /// Of those, the windows whose correlation peak stood out.
        public var confidentWindows: Int
        /// Of those, the windows within 3 ms of the fitted line (0 without a line).
        public var agreeingWindows: Int
        /// The fitted line: the delay at session time 0, and its change per hour. Nil with fewer than three confident
        /// windows.
        public var startMilliseconds: Double?
        public var driftMillisecondsPerHour: Double?

        public init(windows: Int, confidentWindows: Int, agreeingWindows: Int, startMilliseconds: Double? = nil,
                    driftMillisecondsPerHour: Double? = nil) {
            self.windows = windows; self.confidentWindows = confidentWindows; self.agreeingWindows = agreeingWindows
            self.startMilliseconds = startMilliseconds; self.driftMillisecondsPerHour = driftMillisecondsPerHour
        }

        /// The fitted delay at session time `seconds`, in milliseconds.
        public func milliseconds(at seconds: Double) -> Double? {
            guard let startMilliseconds, let driftMillisecondsPerHour else { return nil }
            return startMilliseconds + driftMillisecondsPerHour * seconds / 3_600
        }
    }

    public struct Result: Sendable {
        public var verdict: Verdict
        public var delay: DelayFit?
        /// Only with `.echo`.
        public var mask: AcousticEchoMask?

        public init(verdict: Verdict, delay: DelayFit? = nil, mask: AcousticEchoMask? = nil) {
            self.verdict = verdict; self.delay = delay; self.mask = mask
        }
    }

    /// Analyses a call's microphone against its system audio (nil: the meeting has none). `progress` gets 0…1.
    /// Checks cancellation between windows and blocks. The mask covers every whole frame of the microphone track.
    public static func analyze(microphone: any EchoAudioSource, system: (any EchoAudioSource)?,
                               progress: (@Sendable (Double) -> Void)? = nil) throws -> Result {
        guard let system, system.sampleCount > 0 else { return Result(verdict: .noSystemAudio) }
        let found = try delayWindows(microphone: microphone, system: system)
        progress?(0.1)
        if found.total > 0, found.windows.isEmpty { return Result(verdict: .noSystemAudio) }
        let duration = Double(microphone.sampleCount) / Double(sampleRate)
        let fit = fitDelay(found.windows)
        guard isPresent(fit, duration: duration) else { return Result(verdict: .noEcho, delay: fit) }
        let powers = try framePowers(microphone: microphone, system: system,
                                     delayMilliseconds: { fit.milliseconds(at: $0) ?? 0 }) { fraction in
            progress?(0.1 + 0.85 * fraction)
        }
        let mask = classify(powers)
        progress?(1)
        return Result(verdict: .echo, delay: fit, mask: mask)
    }

    // MARK: - Delay

    struct DelayWindow: Equatable {
        /// Session time of the window's middle.
        var centre: Double
        var milliseconds: Double
        var peakRatio: Double
    }

    /// The delay windows where the system plays, and how many windows there were in all.
    static func delayWindows(microphone: any EchoAudioSource, system: any EchoAudioSource) throws
        -> (windows: [DelayWindow], total: Int) {
        let length = Int(delayWindowSeconds) * sampleRate
        let samples = microphone.sampleCount
        let step = Double(samples) / Double(sampleRate) < shortMeetingSeconds
            ? shortMeetingDelayHopSeconds : delayHopSeconds
        let correlator = PhaseCorrelator(length: length,
                                         earliestLag: Int(earliestLagSeconds * Double(sampleRate)),
                                         latestLag: Int(latestLagSeconds * Double(sampleRate)))
        var mic = [Float](repeating: 0, count: length)
        var sys = [Float](repeating: 0, count: length)
        var windows: [DelayWindow] = []
        var total = 0
        var start = 0.0
        // A window may end exactly at the last sample: a 30 s call has windows at 0, 10 and 20 s.
        while Int(((start + delayWindowSeconds) * Double(sampleRate)).rounded()) <= samples {
            try Task.checkCancellation()
            let first = Int((start * Double(sampleRate)).rounded())
            try system.read(from: first, count: length, into: &sys)
            total += 1
            var power: Float = 0
            vDSP_measqv(sys, 1, &power, vDSP_Length(length))
            if Double(power).squareRoot() > systemPlaysRMS {
                try microphone.read(from: first, count: length, into: &mic)
                let peak = correlator.peak(microphone: mic, system: sys)
                windows.append(DelayWindow(centre: start + delayWindowSeconds / 2,
                                           milliseconds: Double(peak.lag) * 1_000 / Double(sampleRate),
                                           peakRatio: peak.ratio))
            }
            start += step
        }
        return (windows, total)
    }

    /// The line through the confident windows, refitted on those that agree with it.
    ///
    /// Two starts are refined and the one more windows agree with wins (the robust one on a tie): a robust (Theil–Sen)
    /// line, since one far-off window would pull a least-squares line so far that no window agrees with it; and a
    /// constant delay at the median, since with few windows one outlier at an end still tilts the Theil–Sen slope
    /// (four windows, one 200 ms off, give a slope no window agrees with).
    static func fitDelay(_ windows: [DelayWindow]) -> DelayFit {
        let confident = windows.filter { $0.peakRatio > confidentPeakRatio }
        var result = DelayFit(windows: windows.count, confidentWindows: confident.count, agreeingWindows: 0)
        guard confident.count >= minimumAgreeingWindows, let robust = robustLine(confident) else { return result }
        func agrees(_ window: DelayWindow, _ line: (intercept: Double, slope: Double)) -> Bool {
            abs(window.milliseconds - (line.intercept + line.slope * window.centre)) < agreementMilliseconds
        }
        func refined(_ start: (intercept: Double, slope: Double)) -> (line: (intercept: Double, slope: Double), agreeing: Int) {
            var line = start
            for _ in 0..<lineRefits {
                let kept = confident.filter { agrees($0, line) }
                guard kept.count >= 2, let refit = fitLine(kept) else { break }
                line = refit
            }
            return (line, confident.filter { agrees($0, line) }.count)
        }
        var best = refined(robust)
        let constant = refined((median(confident.map(\.milliseconds)), 0))
        if constant.agreeing > best.agreeing { best = constant }
        result.agreeingWindows = best.agreeing
        result.startMilliseconds = best.line.intercept
        result.driftMillisecondsPerHour = best.line.slope * 3_600
        return result
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.isEmpty ? 0 : sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Least-squares line of delay (ms) against window centre (s); a flat line when every centre is the same.
    static func fitLine(_ windows: [DelayWindow]) -> (intercept: Double, slope: Double)? {
        guard !windows.isEmpty else { return nil }
        let count = Double(windows.count)
        let meanT = windows.map(\.centre).reduce(0, +) / count
        let meanD = windows.map(\.milliseconds).reduce(0, +) / count
        var sxx = 0.0
        var sxy = 0.0
        for window in windows {
            sxx += (window.centre - meanT) * (window.centre - meanT)
            sxy += (window.centre - meanT) * (window.milliseconds - meanD)
        }
        guard sxx > 0 else { return (meanD, 0) }
        let slope = sxy / sxx
        return (meanD - slope * meanT, slope)
    }

    /// The Theil–Sen line: the median slope over every pair of windows with different centres (0 when there is no
    /// such pair), and the median intercept for it. Up to about 29 % of the windows can be anywhere.
    static func robustLine(_ windows: [DelayWindow]) -> (intercept: Double, slope: Double)? {
        guard !windows.isEmpty else { return nil }
        var slopes: [Double] = []
        for first in windows.indices {
            for second in windows.indices where second > first && windows[second].centre != windows[first].centre {
                slopes.append((windows[second].milliseconds - windows[first].milliseconds)
                              / (windows[second].centre - windows[first].centre))
            }
        }
        let slope = slopes.isEmpty ? 0 : median(slopes)
        return (median(windows.map { $0.milliseconds - slope * $0.centre }), slope)
    }

    /// The gate (step 2).
    static func isPresent(_ fit: DelayFit, duration: Double) -> Bool {
        guard let first = fit.milliseconds(at: 0), let last = fit.milliseconds(at: max(0, duration)) else {
            return false
        }
        return fit.agreeingWindows >= minimumAgreeingWindows
            && Double(fit.agreeingWindows) >= echoPresentShare * Double(fit.windows)
            && min(first, last) >= minimumDelayMilliseconds
            && max(first, last) <= latestLagSeconds * 1_000
    }

    /// GCC-PHAT over one pair of windows, zero-padded to a power of two at least twice their length.
    final class PhaseCorrelator {
        let length: Int
        let size: Int
        let log2n: vDSP_Length
        let setup: FFTSetupD
        let earliestLag: Int
        let latestLag: Int
        private var micRe: [Double]
        private var micIm: [Double]
        private var sysRe: [Double]
        private var sysIm: [Double]
        private var padded: [Double]
        private var lags: [Double]

        init(length: Int, earliestLag: Int, latestLag: Int) {
            var exponent = 0
            while (1 << exponent) < 2 * length { exponent += 1 }
            self.length = length
            size = 1 << exponent
            log2n = vDSP_Length(exponent)
            setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
            self.earliestLag = earliestLag
            self.latestLag = latestLag
            micRe = [Double](repeating: 0, count: size / 2)
            micIm = micRe
            sysRe = micRe
            sysIm = micRe
            padded = [Double](repeating: 0, count: size)
            lags = [Double](repeating: 0, count: latestLag - earliestLag + 1)
        }

        deinit { vDSP_destroy_fftsetupD(setup) }

        /// The lag (samples, microphone behind system positive) with the largest correlation magnitude, and that peak
        /// over the median magnitude of every lag in range.
        func peak(microphone: [Float], system: [Float]) -> (lag: Int, ratio: Double) {
            transform(microphone, re: &micRe, im: &micIm)
            transform(system, re: &sysRe, im: &sysIm)
            let half = size / 2
            func whitened(_ value: Double) -> Double { value / (abs(value) + 1e-12) }
            // Packed DC and Nyquist bins are real.
            micRe[0] = whitened(micRe[0] * sysRe[0])
            micIm[0] = whitened(micIm[0] * sysIm[0])
            for bin in 1..<half {
                let real = micRe[bin] * sysRe[bin] + micIm[bin] * sysIm[bin]
                let imaginary = micIm[bin] * sysRe[bin] - micRe[bin] * sysIm[bin]
                let magnitude = (real * real + imaginary * imaginary).squareRoot() + 1e-12
                micRe[bin] = real / magnitude
                micIm[bin] = imaginary / magnitude
            }
            micRe.withUnsafeMutableBufferPointer { re in
                micIm.withUnsafeMutableBufferPointer { im in
                    var split = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    padded.withUnsafeMutableBytes { raw in
                        vDSP_ztocD(&split, 1, raw.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2,
                                   vDSP_Length(half))
                    }
                }
            }
            // The peak is the largest magnitude, either sign: a microphone wired or mounted with inverted polarity
            // records the echo upside down, and its correlation peak is negative.
            var best = 0
            for index in lags.indices {
                let lag = earliestLag + index
                lags[index] = abs(padded[lag >= 0 ? lag : size + lag])
                if lags[index] > lags[best] { best = index }
            }
            let peak = lags[best]
            let magnitudes = lags.sorted()
            let middle = magnitudes.count / 2
            let median = magnitudes.count % 2 == 1 ? magnitudes[middle]
                : (magnitudes[middle - 1] + magnitudes[middle]) / 2
            return (earliestLag + best, peak / (median + 1e-12))
        }

        private func transform(_ samples: [Float], re: inout [Double], im: inout [Double]) {
            for index in 0..<size { padded[index] = index < samples.count ? Double(samples[index]) : 0 }
            re.withUnsafeMutableBufferPointer { re in
                im.withUnsafeMutableBufferPointer { im in
                    var split = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    padded.withUnsafeBytes { raw in
                        vDSP_ctozD(raw.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &split, 1,
                                   vDSP_Length(size / 2))
                    }
                    vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }
    }

    // MARK: - Model

    /// Mean power over the analysed bins per frame: the microphone, the predicted echo, the residual (microphone minus
    /// prediction), and the delay-aligned system audio.
    struct FramePowers {
        var microphone: [Float]
        var echo: [Float]
        var residual: [Float]
        var system: [Float]

        var count: Int { microphone.count }
    }

    /// Whole frames in `samples` samples.
    static func frameCount(samples: Int) -> Int {
        samples < windowLength ? 0 : (samples - windowLength) / hop + 1
    }

    /// The first frame of each 5 s block (frames by centre time), and `frames` last.
    static func blockStarts(frames: Int) -> [Int] {
        var starts = [0]
        let blockSamples = Int(blockSeconds) * sampleRate
        var block = 1
        while true {
            let first = (block * blockSamples - windowLength / 2 + hop - 1) / hop
            guard first < frames else { break }
            starts.append(first)
            block += 1
        }
        starts.append(frames)
        return starts
    }

    /// Step 3 over the whole microphone track. `delayMilliseconds` gives the echo delay at a session time.
    static func framePowers(microphone: any EchoAudioSource, system: any EchoAudioSource,
                            delayMilliseconds: (Double) -> Double,
                            progress: (Double) -> Void) throws -> FramePowers {
        let frames = frameCount(samples: microphone.sampleCount)
        guard frames > 0 else { return FramePowers(microphone: [], echo: [], residual: [], system: []) }
        let output = UnsafeMutablePointer<Float>.allocate(capacity: max(1, 4 * frames))
        defer { output.deallocate() }
        output.update(repeating: 0, count: max(1, 4 * frames))
        let starts = blockStarts(frames: frames)
        let blocks = starts.count - 1
        let duration = Double(microphone.sampleCount) / Double(sampleRate)
        let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: windowLength)
        for index in 0..<windowLength {
            window[index] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(windowLength)))
        }

        var batch = 0
        while batch < blocks {
            try Task.checkCancellation()
            let end = min(blocks, batch + batchBlocks)
            let firstFrame = starts[batch]
            let endFrame = starts[end]
            let delays = (batch..<end).map { block -> Int in
                let blockStart = Double(block) * blockSeconds
                let middle = (blockStart + min(blockStart + blockSeconds, duration)) / 2
                return Int((delayMilliseconds(middle) / 1_000 * Double(sampleRate)).rounded())
            }
            let micStart = firstFrame * hop
            let micCount = (endFrame - 1 - firstFrame) * hop + windowLength
            let sysStart = (firstFrame + lead - (taps - 1)) * hop - (delays.max() ?? 0)
            let sysCount = (endFrame - 1 + lead) * hop - (delays.min() ?? 0) + windowLength - sysStart
            var micSamples = [Float](repeating: 0, count: micCount)
            var sysSamples = [Float](repeating: 0, count: sysCount)
            try microphone.read(from: micStart, count: micCount, into: &micSamples)
            try system.read(from: sysStart, count: sysCount, into: &sysSamples)
            let shared = SharedPointers(output: output, frames: frames)
            let firstBlock = batch
            micSamples.withUnsafeBufferPointer { micBuffer in
                sysSamples.withUnsafeBufferPointer { sysBuffer in
                    window.withUnsafeBufferPointer { windowBuffer in
                        let inputs = BatchInputs(microphone: micBuffer.baseAddress!, system: sysBuffer.baseAddress!,
                                                 window: windowBuffer.baseAddress!, setup: setup)
                        DispatchQueue.concurrentPerform(iterations: end - firstBlock) { offset in
                            let block = firstBlock + offset
                            let first = starts[block]
                            let count = starts[block + 1] - first
                            let systemFirst = (first + lead - (taps - 1)) * hop - delays[offset]
                            fitBlock(microphone: inputs.microphone + (first * hop - micStart),
                                     system: inputs.system + (systemFirst - sysStart), frames: count,
                                     setup: inputs.setup, window: inputs.window, output: shared, firstFrame: first)
                        }
                    }
                }
            }
            progress(Double(end) / Double(max(1, blocks)))
            batch = end
        }
        func column(_ index: Int) -> [Float] { Array(UnsafeBufferPointer(start: output + index * frames, count: frames)) }
        return FramePowers(microphone: column(0), echo: column(1), residual: column(2), system: column(3))
    }

    /// Read-only inputs shared by the blocks of one batch. `@unchecked Sendable`: the buffers outlive
    /// `concurrentPerform`, are only read, and an FFT setup may be shared by concurrent transforms.
    private struct BatchInputs: @unchecked Sendable {
        let microphone: UnsafePointer<Float>
        let system: UnsafePointer<Float>
        let window: UnsafePointer<Float>
        let setup: FFTSetup
    }

    /// The four power columns. `@unchecked Sendable`: each block writes only its own frames.
    struct SharedPointers: @unchecked Sendable {
        let output: UnsafeMutablePointer<Float>
        let frames: Int

        func column(_ index: Int, at frame: Int) -> UnsafeMutablePointer<Float> { output + index * frames + frame }
    }

    /// One 5 s block: spectra, the per-bin echo filter (`fits` fits), and the block's frame powers.
    /// `microphone` points at the block's first frame; `system` at the system frame `taps - 1 - lead` frames before
    /// the delay-aligned frame of the block's first frame.
    static func fitBlock(microphone: UnsafePointer<Float>, system: UnsafePointer<Float>, frames: Int,
                         setup: FFTSetup, window: UnsafePointer<Float>, output: SharedPointers, firstFrame: Int) {
        guard frames > 0 else { return }
        let space = BlockWorkspace(frames: frames)
        let bins = binCount
        let systemFrames = frames + taps - 1
        for frame in 0..<frames {
            space.spectrum(of: microphone + frame * hop, column: frame, rows: frames, re: space.micRe,
                           im: space.micIm, setup: setup, window: window)
        }
        for frame in 0..<systemFrames {
            space.spectrum(of: system + frame * hop, column: frame, rows: systemFrames, re: space.sysRe,
                           im: space.sysIm, setup: setup, window: window)
        }
        let pm = output.column(0, at: firstFrame)
        let pe = output.column(1, at: firstFrame)
        let pr = output.column(2, at: firstFrame)
        let ps = output.column(3, at: firstFrame)
        let scale = 1 / Float(bins)
        vDSP_vclr(pm, 1, vDSP_Length(frames))
        vDSP_vclr(ps, 1, vDSP_Length(frames))
        for bin in 0..<bins {
            var mic = DSPSplitComplex(realp: space.micRe + bin * frames, imagp: space.micIm + bin * frames)
            vDSP_zvmags(&mic, 1, space.scratch, 1, vDSP_Length(frames))
            vDSP_vadd(space.scratch, 1, pm, 1, pm, 1, vDSP_Length(frames))
            let aligned = bin * systemFrames + taps - 1 - lead
            var sys = DSPSplitComplex(realp: space.sysRe + aligned, imagp: space.sysIm + aligned)
            vDSP_zvmags(&sys, 1, space.scratch, 1, vDSP_Length(frames))
            vDSP_vadd(space.scratch, 1, ps, 1, ps, 1, vDSP_Length(frames))
        }
        var factor = scale
        vDSP_vsmul(pm, 1, &factor, pm, 1, vDSP_Length(frames))
        vDSP_vsmul(ps, 1, &factor, ps, 1, vDSP_Length(frames))

        // Frames where the system plays.
        let sorted = Array(UnsafeBufferPointer(start: ps, count: frames)).sorted()
        let threshold = max(systemOnMinimum, Float(percentile(sorted, systemOnPercentile)) * systemOnFactor)
        let systemOn = (0..<frames).map { ps[$0] > threshold }
        guard systemOn.filter({ $0 }).count > minimumFitFrames else {
            vDSP_vclr(pe, 1, vDSP_Length(frames))
            pr.update(from: pm, count: frames)
            return
        }
        for frame in 0..<frames { space.weights[frame] = systemOn[frame] ? 1 : 0 }

        for fit in 0..<fits {
            vDSP_vclr(pe, 1, vDSP_Length(frames))
            vDSP_vclr(pr, 1, vDSP_Length(frames))
            for bin in 0..<bins {
                space.fitBin(bin, frames: frames, systemFrames: systemFrames, residual: pr, echo: pe)
            }
            vDSP_vsmul(pe, 1, &factor, pe, 1, vDSP_Length(frames))
            vDSP_vsmul(pr, 1, &factor, pr, 1, vDSP_Length(frames))
            guard fit < fits - 1 else { break }
            var kept = 0
            for frame in 0..<frames {
                let keep = systemOn[frame] && pr[frame] < refitResidualShare * pm[frame]
                space.weights[frame] = keep ? 1 : 0
                if keep { kept += 1 }
            }
            if kept < minimumFitFrames {
                for frame in 0..<frames { space.weights[frame] = systemOn[frame] ? 1 : 0 }
            }
        }
    }

    /// Buffers of one block, allocated once per block and freed with it.
    final class BlockWorkspace {
        let frames: Int
        let systemFrames: Int
        let micRe: UnsafeMutablePointer<Float>
        let micIm: UnsafeMutablePointer<Float>
        let sysRe: UnsafeMutablePointer<Float>
        let sysIm: UnsafeMutablePointer<Float>
        let weights: UnsafeMutablePointer<Float>
        let scratch: UnsafeMutablePointer<Float>
        private let weightedMicRe: UnsafeMutablePointer<Float>
        private let weightedMicIm: UnsafeMutablePointer<Float>
        private let weightedSysRe: UnsafeMutablePointer<Float>
        private let weightedSysIm: UnsafeMutablePointer<Float>
        private let echoRe: UnsafeMutablePointer<Float>
        private let echoIm: UnsafeMutablePointer<Float>
        private let frame: UnsafeMutablePointer<Float>
        private let splitRe: UnsafeMutablePointer<Float>
        private let splitIm: UnsafeMutablePointer<Float>
        private let tapRe: UnsafeMutablePointer<Float>
        private let tapIm: UnsafeMutablePointer<Float>
        private let dotRe: UnsafeMutablePointer<Float>
        private let dotIm: UnsafeMutablePointer<Float>
        private var gramRe = [Double](repeating: 0, count: EchoAnalysis.taps * EchoAnalysis.taps)
        private var gramIm = [Double](repeating: 0, count: EchoAnalysis.taps * EchoAnalysis.taps)
        private var targetRe = [Double](repeating: 0, count: EchoAnalysis.taps)
        private var targetIm = [Double](repeating: 0, count: EchoAnalysis.taps)
        private var allocations: [UnsafeMutablePointer<Float>] = []

        init(frames: Int) {
            self.frames = frames
            systemFrames = frames + EchoAnalysis.taps - 1
            let bins = EchoAnalysis.binCount
            let taps = EchoAnalysis.taps
            var made: [UnsafeMutablePointer<Float>] = []
            func make(_ count: Int) -> UnsafeMutablePointer<Float> {
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
                pointer.update(repeating: 0, count: max(1, count))
                made.append(pointer)
                return pointer
            }
            micRe = make(bins * frames)
            micIm = make(bins * frames)
            sysRe = make(bins * systemFrames)
            sysIm = make(bins * systemFrames)
            weights = make(frames)
            scratch = make(frames)
            weightedMicRe = make(frames)
            weightedMicIm = make(frames)
            weightedSysRe = make(taps * frames)
            weightedSysIm = make(taps * frames)
            echoRe = make(frames)
            echoIm = make(frames)
            frame = make(EchoAnalysis.windowLength)
            splitRe = make(EchoAnalysis.windowLength / 2)
            splitIm = make(EchoAnalysis.windowLength / 2)
            tapRe = make(taps)
            tapIm = make(taps)
            dotRe = make(1)
            dotIm = make(1)
            allocations = made
        }

        deinit { for pointer in allocations { pointer.deallocate() } }

        /// The analysed bins of the windowed frame at `samples`, written to column `column` of bin-major
        /// `re`/`im` (`rows` frames per bin), scaled like a plain DFT.
        func spectrum(of samples: UnsafePointer<Float>, column: Int, rows: Int, re: UnsafeMutablePointer<Float>,
                      im: UnsafeMutablePointer<Float>, setup: FFTSetup, window: UnsafePointer<Float>) {
            let length = EchoAnalysis.windowLength
            vDSP_vmul(samples, 1, window, 1, frame, 1, vDSP_Length(length))
            var split = DSPSplitComplex(realp: splitRe, imagp: splitIm)
            frame.withMemoryRebound(to: DSPComplex.self, capacity: length / 2) { complex in
                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(length / 2))
            }
            vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
            // vDSP's real FFT is twice the DFT.
            var half: Float = 0.5
            let first = EchoAnalysis.firstBin
            vDSP_vsmul(splitRe + first, 1, &half, re + column, rows, vDSP_Length(EchoAnalysis.binCount))
            vDSP_vsmul(splitIm + first, 1, &half, im + column, rows, vDSP_Length(EchoAnalysis.binCount))
        }

        /// Fits one bin's filter with the current weights and adds its residual and echo power per frame.
        func fitBin(_ bin: Int, frames: Int, systemFrames: Int, residual: UnsafeMutablePointer<Float>,
                    echo: UnsafeMutablePointer<Float>) {
            let taps = EchoAnalysis.taps
            let count = vDSP_Length(frames)
            let micRow = (re: micRe + bin * frames, im: micIm + bin * frames)
            let sysRow = (re: sysRe + bin * systemFrames, im: sysIm + bin * systemFrames)
            // Tap l of frame f is system frame f + taps − 1 − l of the row.
            func tap(_ l: Int) -> DSPSplitComplex {
                DSPSplitComplex(realp: sysRow.re + (taps - 1 - l), imagp: sysRow.im + (taps - 1 - l))
            }
            vDSP_vmul(micRow.re, 1, weights, 1, weightedMicRe, 1, count)
            vDSP_vmul(micRow.im, 1, weights, 1, weightedMicIm, 1, count)
            for m in 0..<taps {
                vDSP_vmul(sysRow.re + (taps - 1 - m), 1, weights, 1, weightedSysRe + m * frames, 1, count)
                vDSP_vmul(sysRow.im + (taps - 1 - m), 1, weights, 1, weightedSysIm + m * frames, 1, count)
            }
            var dot = DSPSplitComplex(realp: dotRe, imagp: dotIm)
            var weightedMic = DSPSplitComplex(realp: weightedMicRe, imagp: weightedMicIm)
            for l in 0..<taps {
                var a = tap(l)
                for m in l..<taps {
                    var b = DSPSplitComplex(realp: weightedSysRe + m * frames, imagp: weightedSysIm + m * frames)
                    // Σ conj(x_l) · w · x_m
                    vDSP_zidotpr(&a, 1, &b, 1, &dot, count)
                    gramRe[l * taps + m] = Double(dotRe.pointee)
                    gramIm[l * taps + m] = Double(dotIm.pointee)
                }
                vDSP_zidotpr(&a, 1, &weightedMic, 1, &dot, count)
                targetRe[l] = Double(dotRe.pointee)
                targetIm[l] = Double(dotIm.pointee)
            }
            var trace = 0.0
            for l in 0..<taps { trace += gramRe[l * taps + l] }
            let loading = EchoAnalysis.ridge * trace / Double(taps) + 1e-12
            for l in 0..<taps { gramRe[l * taps + l] += loading }
            if !EchoAnalysis.solveHermitian(re: &gramRe, im: &gramIm, rightRe: &targetRe, rightIm: &targetIm,
                                            size: taps) {
                for l in 0..<taps { targetRe[l] = 0; targetIm[l] = 0 }
            }
            for l in 0..<taps {
                tapRe[l] = Float(targetRe[l])
                tapIm[l] = Float(targetIm[l])
            }
            vDSP_vclr(echoRe, 1, count)
            vDSP_vclr(echoIm, 1, count)
            var predicted = DSPSplitComplex(realp: echoRe, imagp: echoIm)
            for l in 0..<taps {
                var a = tap(l)
                var coefficient = DSPSplitComplex(realp: tapRe + l, imagp: tapIm + l)
                vDSP_zvsma(&a, 1, &coefficient, &predicted, 1, &predicted, 1, count)
            }
            for frame in 0..<frames {
                let er = echoRe[frame]
                let ei = echoIm[frame]
                let dr = micRow.re[frame] - er
                let di = micRow.im[frame] - ei
                residual[frame] += dr * dr + di * di
                echo[frame] += er * er + ei * ei
            }
        }
    }

    /// Solves A·h = b in place (`rightRe`/`rightIm` become h) for a Hermitian positive definite A given by its upper
    /// triangle (row-major, `size`×`size`), by Cholesky factorization. False when A is not positive definite.
    static func solveHermitian(re: inout [Double], im: inout [Double], rightRe: inout [Double],
                               rightIm: inout [Double], size n: Int) -> Bool {
        // Lower factor L (A = L·Lᴴ) in the lower triangle; A[i][j] for i > j is conj(A[j][i]).
        var lowRe = [Double](repeating: 0, count: n * n)
        var lowIm = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            var diagonal = re[j * n + j]
            for k in 0..<j { diagonal -= lowRe[j * n + k] * lowRe[j * n + k] + lowIm[j * n + k] * lowIm[j * n + k] }
            guard diagonal > 0, diagonal.isFinite else { return false }
            let pivot = diagonal.squareRoot()
            lowRe[j * n + j] = pivot
            for i in (j + 1)..<max(j + 1, n) {
                // A[i][j] = conj(A[j][i])
                var sumRe = re[j * n + i]
                var sumIm = -im[j * n + i]
                for k in 0..<j {
                    // L[i][k] · conj(L[j][k])
                    let ar = lowRe[i * n + k], ai = lowIm[i * n + k]
                    let br = lowRe[j * n + k], bi = -lowIm[j * n + k]
                    sumRe -= ar * br - ai * bi
                    sumIm -= ar * bi + ai * br
                }
                lowRe[i * n + j] = sumRe / pivot
                lowIm[i * n + j] = sumIm / pivot
            }
        }
        // L·y = b
        for i in 0..<n {
            var sumRe = rightRe[i]
            var sumIm = rightIm[i]
            for k in 0..<i {
                let ar = lowRe[i * n + k], ai = lowIm[i * n + k]
                sumRe -= ar * rightRe[k] - ai * rightIm[k]
                sumIm -= ar * rightIm[k] + ai * rightRe[k]
            }
            rightRe[i] = sumRe / lowRe[i * n + i]
            rightIm[i] = sumIm / lowRe[i * n + i]
        }
        // Lᴴ·h = y
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sumRe = rightRe[i]
            var sumIm = rightIm[i]
            for k in (i + 1)..<max(i + 1, n) {
                // conj(L[k][i]) · h[k]
                let ar = lowRe[k * n + i], ai = -lowIm[k * n + i]
                sumRe -= ar * rightRe[k] - ai * rightIm[k]
                sumIm -= ar * rightIm[k] + ai * rightRe[k]
            }
            rightRe[i] = sumRe / lowRe[i * n + i]
            rightIm[i] = sumIm / lowRe[i * n + i]
        }
        return rightRe.allSatisfy(\.isFinite) && rightIm.allSatisfy(\.isFinite)
    }

    // MARK: - Frame rule

    /// Step 4.
    static func classify(_ powers: FramePowers) -> AcousticEchoMask {
        let count = powers.count
        func decibels(_ value: Double) -> Double { 10 * log10(value + 1e-12) }
        let micFloor = noiseFloor(powers.microphone).map(decibels)
        let systemFloor = noiseFloor(powers.system)
        var ratio = [Double](repeating: 0, count: count)
        var aboveFloor = [Double](repeating: 0, count: count)
        var residualAboveFloor = [Double](repeating: 0, count: count)
        var echoLevel = [Double](repeating: 0, count: count)
        var dominated = [Bool](repeating: false, count: count)
        for frame in 0..<count {
            let mic = decibels(Double(powers.microphone[frame]))
            let residual = decibels(Double(powers.residual[frame]))
            let echo = decibels(Double(powers.echo[frame]))
            ratio[frame] = residual - mic
            aboveFloor[frame] = mic - micFloor[frame]
            residualAboveFloor[frame] = residual - micFloor[frame]
            // No microphone sound at all (a gap in the recording) or no predicted echo is no evidence of echo: with
            // both zero the two levels would be equal and a quiet word there would read as explained.
            echoLevel[frame] = powers.microphone[frame] > 0 && powers.echo[frame] > 0 ? echo - mic : -.infinity
            let systemActive = Double(powers.system[frame]) > systemFloor[frame] * 10
            dominated[frame] = systemActive && aboveFloor[frame] > activeAboveFloorDB && echoLevel[frame] > echoDominatedDB
        }
        var threshold = [Double](repeating: lowestThresholdDB, count: count)
        var start = 0
        while start < count {
            let end = min(count, start + thresholdBlockFrames)
            let values = (start..<end).filter { dominated[$0] }.map { ratio[$0] }
            if values.count > minimumThresholdFrames {
                let value = percentile(values.sorted(), thresholdPercentile) + thresholdMarginDB
                for frame in start..<end { threshold[frame] = min(highestThresholdDB, max(lowestThresholdDB, value)) }
            }
            start = end
        }
        let active = aboveFloor.map { $0 > activeAboveFloorDB }
        let raw = (0..<count).map { frame in
            active[frame] && ratio[frame] > threshold[frame] && residualAboveFloor[frame] > localAboveFloorDB
        }
        let local = majority(raw, size: smoothingFrames)
        var classes = [UInt8](repeating: AcousticEchoMask.FrameClass.silence.rawValue, count: count)
        for frame in 0..<count where active[frame] {
            classes[frame] = (local[frame] ? AcousticEchoMask.FrameClass.local : .echo).rawValue
        }
        let levels = echoLevel.map(AcousticEchoMask.storedLevel)
        return AcousticEchoMask(classes: classes, echoLevels: levels)!
    }

    /// The 15 s running minimum of the 31-frame mean power (zero beyond the ends), at least `floorMinimum`.
    static func noiseFloor(_ power: [Float]) -> [Double] {
        let count = power.count
        guard count > 0 else { return [] }
        var prefix = [Double](repeating: 0, count: count + 1)
        for index in 0..<count { prefix[index + 1] = prefix[index] + Double(power[index]) }
        let reach = floorSmoothingFrames / 2
        let smoothed = (0..<count).map { index in
            (prefix[min(count, index + reach + 1)] - prefix[max(0, index - reach)]) / Double(floorSmoothingFrames)
        }
        return runningMinimum(smoothed, halfWidth: floorWindowFrames / 2).map { max($0, floorMinimum) }
    }

    /// The minimum of `values` over [i − halfWidth, i + halfWidth], clipped to the ends.
    static func runningMinimum(_ values: [Double], halfWidth: Int) -> [Double] {
        let count = values.count
        var result = [Double](repeating: 0, count: count)
        var queue = [Int]()
        queue.reserveCapacity(count)
        var head = 0
        var next = 0
        for index in 0..<count {
            let upper = min(count - 1, index + halfWidth)
            while next <= upper {
                while queue.count > head, values[queue[queue.count - 1]] >= values[next] { queue.removeLast() }
                queue.append(next)
                next += 1
            }
            while queue[head] < index - halfWidth { head += 1 }
            result[index] = values[queue[head]]
        }
        return result
    }

    /// The majority of each `size`-frame neighbourhood (a median filter on booleans), mirrored at the ends.
    static func majority(_ values: [Bool], size: Int) -> [Bool] {
        let count = values.count
        guard count > 0 else { return [] }
        let reach = size / 2
        func mirrored(_ index: Int) -> Int {
            var position = index
            while position < 0 || position >= count {
                position = position < 0 ? -position - 1 : 2 * count - position - 1
            }
            return position
        }
        return (0..<count).map { index in
            var on = 0
            for offset in -reach...reach where values[mirrored(index + offset)] { on += 1 }
            return on > reach
        }
    }

    /// The `percent`-th percentile of ascending `sorted`, interpolated linearly between ranks.
    static func percentile<T: BinaryFloatingPoint>(_ sorted: [T], _ percent: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = Double(sorted.count - 1) * percent / 100
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return Double(sorted[lower]) + fraction * (Double(sorted[upper]) - Double(sorted[lower]))
    }
}
