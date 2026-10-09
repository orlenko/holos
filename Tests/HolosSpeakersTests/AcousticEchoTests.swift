import Accelerate
import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// Acoustic microphone echo in calls (docs/meeting-design.md §5.11): EchoAnalysis on synthetic signals only, the mask's
// word rule and playback intervals, and the projection that hides the echo (stored runs never hold it).

// MARK: - Synthetic call

/// A deterministic generator (SplitMix64).
private struct Noise {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [−1, 1).
    mutating func uniform() -> Float { Float(Double(next() >> 11) / Double(1 << 52)) - 1 }

    /// Roughly Gaussian (sum of four uniforms).
    mutating func gaussian() -> Float { (uniform() + uniform() + uniform() + uniform()) * 0.866 }
}

private let rate = 16_000

/// Speech-like noise: band-limited noise, modulated at a syllable rate of 4 Hz, inside `intervals` (seconds) only,
/// scaled to `rms` while it speaks.
private func speech(seconds: Double, intervals: [(Double, Double)], rms: Float, seed: UInt64) -> [Float] {
    var noise = Noise(state: seed)
    let count = Int(seconds * Double(rate))
    var out = [Float](repeating: 0, count: count)
    var low: Float = 0
    var previous: Float = 0
    for (start, end) in intervals {
        let phase = Double(noise.uniform()) * Double.pi
        for index in Int(start * Double(rate))..<min(count, Int(end * Double(rate))) {
            let white = noise.gaussian()
            // High-pass (remove DC rumble), then low-pass around 3 kHz.
            let high = white - previous
            previous = white
            low += 0.6 * (high - low)
            let time = Double(index) / Double(rate)
            let envelope = Float(0.55 + 0.45 * sin(2 * Double.pi * 4 * time + phase))
            out[index] = low * envelope
        }
    }
    scale(&out, intervals: intervals, to: rms)
    return out
}

/// Scales `signal` so its RMS over `intervals` is `rms`.
private func scale(_ signal: inout [Float], intervals: [(Double, Double)], to rms: Float) {
    let current = level(signal, intervals)
    guard current > 0 else { return }
    let factor = rms / current
    for index in signal.indices { signal[index] *= factor }
}

private func level(_ signal: [Float], _ intervals: [(Double, Double)]) -> Float {
    var sum = 0.0
    var count = 0
    for (start, end) in intervals {
        for index in Int(start * Double(rate))..<min(signal.count, Int(end * Double(rate))) {
            sum += Double(signal[index] * signal[index])
            count += 1
        }
    }
    return count == 0 ? 0 : Float((sum / Double(count)).squareRoot())
}

/// The room's echo path: `delay` seconds to the direct sound, then 30 ms of decaying random reflections.
private func echoPath(of system: [Float], delay: Double, gain: Float, seed: UInt64) -> [Float] {
    var noise = Noise(state: seed)
    let shift = Int((delay * Double(rate)).rounded())
    let response = (0..<480).map { $0 == 0 ? 1 : 0.4 * Float(exp(-Double($0) / 80)) * noise.uniform() }
    // out[i] = Σ response[lag] · system[i − shift − lag], with vDSP_conv over a zero-padded input.
    let padding = shift + response.count - 1
    let input = [Float](repeating: 0, count: padding) + system
    var out = [Float](repeating: 0, count: system.count)
    response.withUnsafeBufferPointer { filter in
        vDSP_conv(input, 1, filter.baseAddress! + response.count - 1, -1, &out, 1, vDSP_Length(system.count),
                  vDSP_Length(response.count))
    }
    var factor = gain
    vDSP_vsmul(out, 1, &factor, &out, 1, vDSP_Length(out.count))
    return out
}

private func add(_ signals: [Float]...) -> [Float] {
    var out = [Float](repeating: 0, count: signals.map(\.count).max() ?? 0)
    for signal in signals { for (index, value) in signal.enumerated() { out[index] += value } }
    return out
}

/// One minute of a call on laptop speakers. The far end talks in `systemTalks`; the microphone hears it again 46 ms
/// later through the room. The user talks while the call is quiet (`localTalks`, about 10 dB below the echo) and once
/// over the call at the echo's level (`doubleTalk`).
private struct SyntheticCall {
    static let seconds = 60.0
    static let delay = 0.046
    static let systemTalks = [(1.0, 7.0), (10.0, 16.0), (22.0, 28.0), (40.0, 46.0), (49.0, 57.0)]
    static let localTalks = [(7.8, 9.2), (17.0, 20.5), (30.0, 34.0)]
    static let doubleTalk = (51.0, 55.0)

    let system: [Float]
    let echo: [Float]
    let microphone: [Float]

    init(echoGain: Float = 0.5, doubleTalkLevel: Float = 1) {
        system = speech(seconds: Self.seconds, intervals: Self.systemTalks, rms: 0.05, seed: 1)
        echo = echoPath(of: system, delay: Self.delay, gain: echoGain, seed: 2)
        let echoLevel = level(echo, Self.systemTalks)
        let own = speech(seconds: Self.seconds, intervals: Self.localTalks, rms: echoLevel * 0.3, seed: 3)
        let overlapEcho = level(echo, [Self.doubleTalk])
        let over = speech(seconds: Self.seconds, intervals: [Self.doubleTalk], rms: overlapEcho * doubleTalkLevel,
                          seed: 4)
        var floor = Noise(state: 5)
        let hiss = (0..<echo.count).map { _ in floor.gaussian() * 1e-4 }
        microphone = add(echo, own, over, hiss)
    }
}

/// Frames whose centre lies inside `interval`, shrunk by `margin` seconds at both ends.
private func frames(in interval: (Double, Double), margin: Double = 0.15, of mask: AcousticEchoMask) -> [Int] {
    (0..<mask.frameCount).filter { frame in
        let centre = AcousticEchoMask.centre(ofFrame: frame)
        return centre >= interval.0 + margin && centre < interval.1 - margin
    }
}

private func share(_ frames: [Int], _ wanted: AcousticEchoMask.FrameClass, of mask: AcousticEchoMask) -> Double {
    let active = frames.filter { mask.frameClass($0) != .silence }
    guard !active.isEmpty else { return 0 }
    return Double(active.filter { mask.frameClass($0) == wanted }.count) / Double(active.count)
}

/// 0.3 s words every 0.4 s inside `interval`.
private func wordTimes(in interval: (Double, Double)) -> [(Double, Double)] {
    stride(from: interval.0 + 0.1, to: interval.1 - 0.35, by: 0.4).map { ($0, $0 + 0.3) }
}

/// The analysis of the default call, computed once (it is deterministic).
private let analysedCall: (call: SyntheticCall, result: EchoAnalysis.Result) = {
    let call = SyntheticCall()
    let result = try! EchoAnalysis.analyze(microphone: InMemoryEchoAudio(call.microphone),
                                           system: InMemoryEchoAudio(call.system))
    return (call, result)
}()

/// System talk stretches with no local speech in them: the microphone hears only echo there.
private let echoOnly = SyntheticCall.systemTalks.filter { $0.0 != 49.0 } + [(49.0, 50.8), (55.2, 57.0)]

// MARK: - Analysis

@Test(.timeLimit(.minutes(2)))
func echoDelayIsRecoveredWithinOneMillisecond() throws {
    let result = analysedCall.result
    #expect(result.verdict == .echo)
    let delay = try #require(result.delay)
    let measured = try #require(delay.milliseconds(at: 30))
    #expect(abs(measured - SyntheticCall.delay * 1_000) < 1, "measured \(measured) ms")
    #expect(delay.agreeingWindows >= 3)
    #expect(abs(try #require(delay.driftMillisecondsPerHour)) < 60)
}

@Test(.timeLimit(.minutes(2)))
func echoOnlyFramesAreEcho() throws {
    let mask = try #require(analysedCall.result.mask)
    for interval in echoOnly {
        let echo = share(frames(in: interval, of: mask), .echo, of: mask)
        #expect(echo >= 0.9, "echo share \(echo) in \(interval)")
    }
    // Their words are dropped.
    let words = echoOnly.flatMap(wordTimes)
    let dropped = words.filter { mask.isEcho(start: $0.0, end: $0.1) == true }.count
    #expect(Double(dropped) >= 0.95 * Double(words.count), "\(dropped) of \(words.count) echo words dropped")
}

@Test(.timeLimit(.minutes(2)))
func localSpeechIsLocalWhileTheCallIsQuiet() throws {
    let mask = try #require(analysedCall.result.mask)
    for interval in SyntheticCall.localTalks {
        let local = share(frames(in: interval, of: mask), .local, of: mask)
        #expect(local >= 0.9, "local share \(local) in \(interval)")
    }
    let words = SyntheticCall.localTalks.flatMap(wordTimes)
    #expect(words.allSatisfy { mask.isEcho(start: $0.0, end: $0.1) == false })
}

@Test(.timeLimit(.minutes(2)))
func localSpeechOverTheCallAtEchoLevelIsKept() throws {
    let mask = try #require(analysedCall.result.mask)
    let local = share(frames(in: SyntheticCall.doubleTalk, of: mask), .local, of: mask)
    #expect(local >= 0.6, "local share \(local) during double-talk")
    let words = wordTimes(in: SyntheticCall.doubleTalk)
    let kept = words.filter { mask.isEcho(start: $0.0, end: $0.1) == false }.count
    #expect(Double(kept) >= 0.85 * Double(words.count), "\(kept) of \(words.count) double-talk words kept")
}

@Test(.timeLimit(.minutes(2)))
func quietMicrophoneStretchesAreSilence() throws {
    let mask = try #require(analysedCall.result.mask)
    let quiet = frames(in: (35.0, 39.5), of: mask)
    #expect(!quiet.isEmpty)
    #expect(quiet.allSatisfy { mask.frameClass($0) == .silence })
}

@Test(.timeLimit(.minutes(2)))
func headphonesLeaveNothingToMask() throws {
    // The far end plays into headphones: the microphone hears only the user and its own hiss.
    let system = speech(seconds: SyntheticCall.seconds, intervals: SyntheticCall.systemTalks, rms: 0.05, seed: 1)
    let own = speech(seconds: SyntheticCall.seconds, intervals: SyntheticCall.localTalks + [SyntheticCall.doubleTalk],
                     rms: 0.02, seed: 3)
    var floor = Noise(state: 5)
    let microphone = add(own, (0..<own.count).map { _ in floor.gaussian() * 1e-4 })
    let result = try EchoAnalysis.analyze(microphone: InMemoryEchoAudio(microphone),
                                          system: InMemoryEchoAudio(system))
    #expect(result.verdict == .noEcho)
    #expect(result.mask == nil)
    let delay = try #require(result.delay)
    #expect(delay.windows > 0)
    #expect(delay.agreeingWindows < 3 || Double(delay.agreeingWindows) < 0.3 * Double(delay.windows))
}

@Test(.timeLimit(.minutes(2)))
func anInvertedMicrophoneStillFindsTheEcho() throws {
    // A microphone of inverted polarity records the echo upside down: its correlation peak is negative.
    let call = SyntheticCall(echoGain: -0.5)
    let result = try EchoAnalysis.analyze(microphone: InMemoryEchoAudio(call.microphone),
                                          system: InMemoryEchoAudio(call.system))
    #expect(result.verdict == .echo)
    let measured = try #require(result.delay?.milliseconds(at: 30))
    #expect(abs(measured - SyntheticCall.delay * 1_000) < 1, "measured \(measured) ms")
    let mask = try #require(result.mask)
    for interval in echoOnly {
        #expect(share(frames(in: interval, of: mask), .echo, of: mask) >= 0.9)
    }
    for interval in SyntheticCall.localTalks {
        #expect(share(frames(in: interval, of: mask), .local, of: mask) >= 0.9)
    }
}

@Test(.timeLimit(.minutes(2)))
func aCallOfExactlyThirtySecondsHasThreeDelayWindows() throws {
    // The last 10 s window ends exactly at the last sample; without it there would be two, fewer than the gate needs.
    let seconds = 30
    let call = SyntheticCall()
    let microphone = Array(call.microphone.prefix(seconds * rate))
    let system = Array(call.system.prefix(seconds * rate))
    let result = try EchoAnalysis.analyze(microphone: InMemoryEchoAudio(microphone),
                                          system: InMemoryEchoAudio(system))
    #expect(result.delay?.windows == 3)
    #expect(result.verdict == .echo)
    let measured = try #require(result.delay?.milliseconds(at: 15))
    #expect(abs(measured - SyntheticCall.delay * 1_000) < 1)
}

@Test func oneOutlyingDelayWindowDoesNotDefeatTheFit() throws {
    // Seven confident windows at 5…65 s, one 200 ms off: a least-squares start (74.6 ms) agrees with none of them.
    let delays = [46.0, 46, 46, 246, 46, 46, 46]
    let windows = delays.enumerated().map {
        EchoAnalysis.DelayWindow(centre: 5 + Double($0.offset) * 10, milliseconds: $0.element, peakRatio: 100)
    }
    let fit = EchoAnalysis.fitDelay(windows)
    #expect(fit.agreeingWindows == 6)
    #expect(abs(try #require(fit.milliseconds(at: 35)) - 46) < 0.01)
    #expect(EchoAnalysis.isPresent(fit, duration: 70))

    // An hour with drift (+5 ms/h) and two far-off windows (a Bluetooth hiccup, a loud echo of something else).
    var drifting = (0..<120).map { index -> EchoAnalysis.DelayWindow in
        let centre = 15 + Double(index) * 30
        return EchoAnalysis.DelayWindow(centre: centre, milliseconds: 46 + 5 * centre / 3_600, peakRatio: 100)
    }
    drifting[10].milliseconds = 300
    drifting[90].milliseconds = 12
    let line = EchoAnalysis.fitDelay(drifting)
    #expect(line.agreeingWindows == 118)
    #expect(abs(try #require(line.startMilliseconds) - 46) < 0.01)
    #expect(abs(try #require(line.driftMillisecondsPerHour) - 5) < 0.01)
}

@Test func theRobustFitOfTheLongestCallUsesABoundedNumberOfPairs() throws {
    // 12 hours (the longest call analysed) of windows every 30 s, drifting +5 ms/h, every 7th window far off: the
    // slopes come from 512 windows (130,816 pairs instead of about a million), and the line is still found.
    let count = 12 * 3_600 / 30
    var windows = (0..<count).map { index -> EchoAnalysis.DelayWindow in
        let centre = 15 + Double(index) * 30
        return EchoAnalysis.DelayWindow(centre: centre, milliseconds: 46 + 5 * centre / 3_600, peakRatio: 100)
    }
    for index in stride(from: 3, to: count, by: 7) { windows[index].milliseconds = 400 }
    let sampled = EchoAnalysis.slopeWindows(windows)
    #expect(sampled.count == EchoAnalysis.maximumSlopeWindows)
    #expect(sampled.count * (sampled.count - 1) / 2 == 130_816)
    #expect(sampled.first == windows.first && sampled.last == windows.last)
    let line = try #require(EchoAnalysis.robustLine(windows))
    #expect(abs(line.slope * 3_600 - 5) < 0.01)
    // Up to the cap, every window is used: real calls (a few hundred windows) fit exactly as before.
    let hourly = Array(windows.prefix(EchoAnalysis.maximumSlopeWindows))
    #expect(EchoAnalysis.slopeWindows(hourly) == hourly)
}

@Test func aShortMeetingWithAnOutlyingEndWindowStillFindsTheDelay() throws {
    // Four windows, the last 200 ms off: the Theil–Sen slope (3.3 ms/s) agrees with none of them; the constant start
    // agrees with three.
    let windows = zip([5.0, 15, 25, 35], [46.0, 46, 46, 246]).map {
        EchoAnalysis.DelayWindow(centre: $0.0, milliseconds: $0.1, peakRatio: 100)
    }
    let fit = EchoAnalysis.fitDelay(windows)
    #expect(fit.agreeingWindows == 3)
    #expect(abs(try #require(fit.milliseconds(at: 20)) - 46) < 0.01)
    #expect(EchoAnalysis.isPresent(fit, duration: 40))
}

@Test(.timeLimit(.minutes(2)))
func aGapInTheRecordingIsNoEvidenceOfEcho() throws {
    // Both tracks are silent (zeros, no hiss) from 36 to 39.5 s, as when a recording stops and starts again: a word
    // timed there is kept, not taken for echo the empty frames would "explain".
    let call = SyntheticCall()
    var microphone = call.microphone
    var system = call.system
    for index in (36 * rate)..<(Int(39.5 * Double(rate))) {
        microphone[index] = 0
        system[index] = 0
    }
    let result = try EchoAnalysis.analyze(microphone: InMemoryEchoAudio(microphone), system: InMemoryEchoAudio(system))
    let mask = try #require(result.mask)
    #expect(mask.isEcho(start: 37.0, end: 37.3) == false)
    #expect(mask.isEcho(start: 38.0, end: 38.6) == false)
}

@Test func untimedMicrophoneWordsAreKept() {
    // A microphone segment without word timing over echo (10–12 s) and local speech (12–14 s): its words get
    // estimated times, which say nothing about the sound, so none is dropped. A timed word in the echo is.
    let untimed = TranscriptSegment(id: "U", start: 10, end: 14, text: "one two three four five six", track: "mic")
    let timed = segment("T", words: 1, track: "mic", start: 10.5)
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                                backend: .speech, segments: [untimed, timed])
    let mask = timedMask(seconds: 20, echo: [(10, 12)])
    #expect(EchoFilter.acousticEchoSpans(transcript: transcript, mask: mask)
        == [WordSpan(segmentID: "T", first: 0, end: 1)])
}

@Test func missingOrSilentSystemAudioLeavesNothingToMask() throws {
    let call = SyntheticCall()
    let missing = try EchoAnalysis.analyze(microphone: InMemoryEchoAudio(call.microphone), system: nil)
    #expect(missing.verdict == .noSystemAudio)
    #expect(missing.mask == nil)
    let silent = try EchoAnalysis.analyze(microphone: InMemoryEchoAudio(call.microphone),
                                          system: InMemoryEchoAudio([Float](repeating: 0, count: call.system.count)))
    #expect(silent.verdict == .noSystemAudio)
    #expect(silent.mask == nil)
}

@Test(.timeLimit(.minutes(2)))
func theSameSignalOnBothTracksIsNotEcho() throws {
    // A zero lag is one signal recorded twice (a loopback device, a test tone), never the room.
    let call = SyntheticCall()
    let result = try EchoAnalysis.analyze(microphone: InMemoryEchoAudio(call.system),
                                          system: InMemoryEchoAudio(call.system))
    #expect(result.verdict == .noEcho)
    #expect(result.mask == nil)
}

// MARK: - Mask

/// A mask from per-frame classes, with the predicted echo at −20 dB (unexplained) unless `levels` says otherwise.
private func mask(_ classes: [AcousticEchoMask.FrameClass], levels: [Int8]? = nil) -> AcousticEchoMask {
    AcousticEchoMask(classes: classes.map(\.rawValue),
                     echoLevels: levels ?? [Int8](repeating: -40, count: classes.count))!
}

@Test func wordRuleCountsLocalShareOfActiveFrames() {
    // Frame k is centred at 0.032 + 0.016 k: frames 0..<12 cover [0.032, 0.208]. The local run (3 frames, the
    // shortest the analysis leaves) has the predicted echo 20 dB below the microphone: a stretch with evidence.
    let classes: [AcousticEchoMask.FrameClass] = [.local, .local, .local] + Array(repeating: .echo, count: 8)
        + [.silence]
    let threeOfEleven = mask(classes)
    // Frames 0...10: 3 local of 11 active (27 %) → echo.
    #expect(threeOfEleven.isEcho(start: 0, end: 0.2) == true)
    // Frames 0...3: 3 local of 4 → kept.
    #expect(threeOfEleven.isEcho(start: 0.03, end: 0.09) == false)
    // A word between centres still gets the next frame.
    #expect(threeOfEleven.isEcho(start: 0.033, end: 0.034) == false)
    // After the last frame, or with times that are not numbers: not judged.
    #expect(threeOfEleven.isEcho(start: 5, end: 6) == nil)
    #expect(threeOfEleven.isEcho(start: .nan, end: 1) == nil)
}

@Test func quietWordIsEchoOnlyWhenThePredictionExplainsIt() {
    let silent = [AcousticEchoMask.FrameClass](repeating: .silence, count: 10)
    // Predicted echo −3 dB relative to the microphone (stored in half-dB steps): explained.
    #expect(mask(silent, levels: [Int8](repeating: -6, count: 10)).isEcho(start: 0, end: 0.2) == true)
    // −8 dB: not explained, kept.
    #expect(mask(silent, levels: [Int8](repeating: -16, count: 10)).isEcho(start: 0, end: 0.2) == false)
    // Median of −4 and −6 dB is −5 dB: exactly the limit, echo.
    #expect(mask(Array(silent.prefix(2)), levels: [-8, -12]).isEcho(start: 0, end: 0.1) == true)
}

@Test func localSpeechIntervalsMergeShortGapsAndPad() {
    // Local frames 10..<20 and 30..<40 (gap of 10 frames = 0.16 s < 0.3 s) and 80..<85 (gap 0.64 s).
    var classes = [AcousticEchoMask.FrameClass](repeating: .echo, count: 100)
    for frame in Array(10..<20) + Array(30..<40) + Array(80..<85) { classes[frame] = .local }
    let intervals = mask(classes).localSpeechIntervals()
    #expect(intervals.count == 2)
    let first = AcousticEchoMask.centre(ofFrame: 10) - 0.008 - 0.064
    let firstEnd = AcousticEchoMask.centre(ofFrame: 39) + 0.008 + 0.2
    #expect(abs(intervals[0].start - first) < 1e-9)
    #expect(abs(intervals[0].end - firstEnd) < 1e-9)
    #expect(abs(intervals[1].start - (AcousticEchoMask.centre(ofFrame: 80) - 0.008 - 0.064)) < 1e-9)
    // Padding never goes below 0.
    var early = [AcousticEchoMask.FrameClass](repeating: .silence, count: 10)
    for frame in 0..<3 { early[frame] = .local }
    #expect(mask(early).localSpeechIntervals().first?.start == 0)
}

/// Echo frames throughout `count` frames, with `local` frames at the given predicted echo level (stored half-dB steps)
/// and every other frame at 0 dB (the echo explains the microphone).
private func echoMask(count: Int, local: [(frames: Range<Int>, level: Int8)]) -> AcousticEchoMask {
    var classes = [AcousticEchoMask.FrameClass](repeating: .echo, count: count)
    var levels = [Int8](repeating: 0, count: count)
    for run in local {
        for frame in run.frames { classes[frame] = .local; levels[frame] = run.level }
    }
    return mask(classes, levels: levels)
}

@Test func scatteredLocalFramesInTheCallStayMuted() {
    // Short local runs through the call's speech, the predicted echo at or above the microphone's level (0 to +3 dB)
    // or a steady 3.5–4 dB below it (once as two runs 80 ms apart: one stretch), no frame 6 dB below: echo cancelled
    // poorly, not speech in the room. A 12-frame run at +1 dB too.
    let scattered = echoMask(count: 500, local: [
        (20..<23, 2), (50..<53, 6), (80..<85, -8), (120..<124, 0), (200..<212, 2), (300..<305, -8), (310..<314, -7),
    ])
    #expect(scattered.localSpeechIntervals().isEmpty)
    // Exactly 6 dB below is not below: two stretches, one of three such frames, one with two frames past it.
    let limit = echoMask(count: 200, local: [(20..<23, -12), (100..<105, -8), (102..<104, -13)])
    #expect(limit.localSpeechIntervals().isEmpty)
}

@Test func sustainedLocalSpeechIsKeptWithItsLeadPadding() {
    // 0.64 s of speech in the room, the call quiet (predicted echo 20 dB below the microphone), between echo.
    let speech = echoMask(count: 300, local: [(100..<140, -40)])
    let intervals = speech.localSpeechIntervals()
    #expect(intervals.count == 1)
    let start = AcousticEchoMask.centre(ofFrame: 100) - AcousticEchoMask.hopSeconds / 2
        - AcousticEchoMask.playbackLeadSeconds
    let end = AcousticEchoMask.centre(ofFrame: 139) + AcousticEchoMask.hopSeconds / 2
        + AcousticEchoMask.playbackTailSeconds
    #expect(abs((intervals.first?.start ?? 0) - start) < 1e-9)
    #expect(abs((intervals.first?.end ?? 0) - end) < 1e-9)
    // No predicted echo at all (stored as the lowest level) is evidence too: three frames are enough.
    let burst = echoMask(count: 100, local: [(40..<43, .min)])
    #expect(burst.localSpeechIntervals().count == 1)
}

@Test func speechOverTheCallKeepsItsWeakFirstSyllable() {
    // Double-talk: the user starts quietly over the call (a first run near the echo's level, no evidence of its
    // own), then speaks up: frames 8 dB above the prediction among others 1.5–2 dB above it, in runs under 0.2 s
    // apart. The whole stretch is kept from the first run, lead included.
    let doubleTalk = echoMask(count: 400, local: [
        (100..<104, -4), (110..<120, -4), (113..<116, -16), (130..<150, -3), (135..<137, -16), (160..<170, -4),
    ])
    let intervals = doubleTalk.localSpeechIntervals()
    #expect(intervals.count == 1)
    let start = AcousticEchoMask.centre(ofFrame: 100) - AcousticEchoMask.hopSeconds / 2
        - AcousticEchoMask.playbackLeadSeconds
    let end = AcousticEchoMask.centre(ofFrame: 169) + AcousticEchoMask.hopSeconds / 2
        + AcousticEchoMask.playbackTailSeconds
    #expect(abs((intervals.first?.start ?? 0) - start) < 1e-9)
    #expect(abs((intervals.first?.end ?? 0) - end) < 1e-9)
    // Evidence adds up across the runs of one stretch (2 + 1 frames), not across stretches (0.7 s apart).
    let spread = echoMask(count: 400, local: [(100..<104, -4), (100..<102, -16), (110..<114, -4), (112..<113, -16)])
    #expect(spread.localSpeechIntervals().count == 1)
    let apart = echoMask(count: 400, local: [(100..<104, -4), (100..<102, -16), (150..<154, -4), (150..<151, -16)])
    #expect(apart.localSpeechIntervals().isEmpty)
}

@Test func mutedEchoBurstsLeaveTheSpeechIntervalsAsTheyWere() {
    // Scattered echo bursts between two kept stretches change nothing about those stretches: the same intervals as
    // the mask without the bursts.
    let speech: [(frames: Range<Int>, level: Int8)] = [(100..<140, -40), (400..<430, -30)]
    let clean = echoMask(count: 600, local: speech)
    let noisy = echoMask(count: 600, local: speech + [(200..<204, 2), (250..<253, 4), (520..<532, 0)])
    #expect(noisy.localSpeechIntervals() == clean.localSpeechIntervals())
    #expect(clean.localSpeechIntervals().count == 2)
}

@Test func maskBytesRoundTrip() throws {
    let original = mask([.silence, .echo, .local, .echo], levels: [-128, -3, 0, 127])
    let decoded = try #require(AcousticEchoMask(bytes: original.bytes, frameCount: 4))
    #expect(decoded == original)
    #expect(AcousticEchoMask(bytes: original.bytes, frameCount: 3) == nil)
    #expect(AcousticEchoMask(bytes: Data([7, 0]), frameCount: 1) == nil)
    // A count from a damaged mask.json must not overflow (2 × Int.max would trap).
    #expect(AcousticEchoMask(bytes: original.bytes, frameCount: .max) == nil)
    #expect(AcousticEchoMask(bytes: original.bytes, frameCount: -1) == nil)
    #expect(AcousticEchoMask(bytes: Data([0, 0, 0]), frameCount: 1) == nil)
}

// MARK: - Projection

private let session = "SESSION"

/// A segment of 0.3 s words starting every 0.4 s.
private func segment(_ id: String, words: Int, track: String, start: Double) -> TranscriptSegment {
    var text = ""
    var timed: [TimedWord] = []
    for index in 0..<words {
        let word = "\(id)w\(index)"
        if !text.isEmpty { text += " " }
        let wordStart = start + Double(index) * 0.4
        timed.append(TimedWord(text: word, start: wordStart, end: wordStart + 0.3, utf16Offset: text.utf16.count,
                               utf16Length: word.utf16.count))
        text += word
    }
    return TranscriptSegment(id: id, start: start, end: start + Double(words) * 0.4, text: text, words: timed,
                             track: track)
}

/// A mask of `seconds` whose frames inside `echo` (seconds) are echo and the rest local.
private func timedMask(seconds: Double, echo: [(Double, Double)]) -> AcousticEchoMask {
    let count = Int(seconds / AcousticEchoMask.hopSeconds)
    let classes: [AcousticEchoMask.FrameClass] = (0..<count).map { frame in
        let centre = AcousticEchoMask.centre(ofFrame: frame)
        return echo.contains { centre >= $0.0 && centre < $0.1 } ? .echo : .local
    }
    return mask(classes)
}

private let callParameters: AlignmentParameters = {
    var parameters = AlignmentParameters.v1
    parameters.echoWindowSeconds = 1.0
    parameters.offsetSearchSeconds = 0
    return parameters
}()

private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
    Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
               backend: .speech, segments: segments)
}

/// A call whose microphone is "Me" (M: ten words from 10 s) and whose system track is one channel speaker (S).
private func channelCall() -> (transcript: Transcript, run: DiarizationRun) {
    let words = transcript([segment("M", words: 10, track: "mic", start: 10), segment("S", words: 4, track: "system",
                                                                                     start: 20)])
    let tracks = [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
                  SpeakerRunBuilder.TrackInput(track: "system", policy: .channel(speakerID: "system:all",
                                                                                 displayName: "Others"))]
    let run = SpeakerRunBuilder.build(sessionID: session, transcript: words, tracks: tracks, engine: nil,
                                      parameters: callParameters, id: "RUN").run
    return (words, run)
}

private func view(_ run: DiarizationRun, _ transcript: Transcript, edits: [SpeakerEdit] = [],
                  mask: AcousticEchoMask? = nil) -> SpeakerProjection {
    SpeakerProjection.make(run: run, transcript: transcript, edits: edits, recognition: nil, profileNames: [:],
                           acousticEcho: mask)
}

/// Words 2–3 of M (10.8–11.5 s) are echo.
private let echoInTheMiddle = timedMask(seconds: 30, echo: [(10.8, 11.5)])

/// The word indexes of M a turn shows.
private func shownWords(_ turn: ProjectedTurn?) -> [Int] {
    (turn?.spans ?? []).flatMap { Array($0.first..<$0.end) }
}

@Test func echoWordsLeaveTheTurnWhichKeepsItsIDAndSpeaker() throws {
    let (words, run) = channelCall()
    let plain = view(run, words)
    let micTurn = try #require(plain.turns.first { $0.track == "mic" })
    #expect(shownWords(micTurn) == Array(0..<10))
    #expect(!micTurn.cutByEcho)

    let masked = view(run, words, mask: echoInTheMiddle)
    let shown = masked.turns.filter { $0.track == "mic" }
    #expect(shown.count == 1)
    #expect(shown.first?.id == micTurn.id)
    #expect(shown.first?.speakerID == "mic:me")
    #expect(shown.first?.spans == [WordSpan(segmentID: "M", first: 0, end: 2), WordSpan(segmentID: "M", first: 4, end: 10)])
    #expect(shown.first?.cutByEcho == true)
    #expect(shown.first?.start == micTurn.start)
    // The system turn is untouched, and nothing about the stored run says echo.
    #expect(masked.turns.filter { $0.track == "system" } == plain.turns.filter { $0.track == "system" })
    #expect(run.droppedWords.isEmpty)
    // Voice learning never uses a turn whose voice covers echo.
    #expect(VoiceEnrollment.candidateTurns(for: ["mic:me"], projection: plain).count == 1)
    #expect(VoiceEnrollment.candidateTurns(for: ["mic:me"], projection: masked).isEmpty)
    // Echo at the start: the turn starts at its first word shown.
    let leading = view(run, words, mask: timedMask(seconds: 30, echo: [(10, 10.8)]))
    #expect(abs((leading.turns.first { $0.track == "mic" }?.start ?? 0) - 10.8) < 1e-9)
    // A turn that is all echo is not shown at all, nor its speaker.
    let allEcho = view(run, words, mask: timedMask(seconds: 30, echo: [(10, 14)]))
    #expect(!allEcho.turns.contains { $0.track == "mic" })
    #expect(!allEcho.speakers.contains { $0.id == "mic:me" })
}

@Test func hiddenEchoInsideATurnDoesNotCountAsTalkTime() throws {
    // M's words are 0.3 s long every 0.4 s from 10 s. Plain: 10.0–13.9 s. With words 2–3 hidden: 10.0–10.7 s and
    // 11.6–13.9 s, so 3.0 s, while the turn still runs from 10.0 to 13.9 s.
    let (words, run) = channelCall()
    let plain = view(run, words)
    #expect(abs((plain.speakers.first { $0.id == "mic:me" }?.talkSeconds ?? 0) - 3.9) < 1e-9)
    let masked = view(run, words, mask: echoInTheMiddle)
    let turn = try #require(masked.turns.first { $0.track == "mic" })
    #expect(abs(turn.end - turn.start - 3.9) < 1e-9)
    // The sidebar and the Markdown and JSON exports read this.
    #expect(abs((masked.speakers.first { $0.id == "mic:me" }?.talkSeconds ?? 0) - 3.0) < 1e-9)
}

@Test func editsOnATurnWithHiddenWordsWorkAsOnItsStoredWords() throws {
    let (words, run) = channelCall()
    let masked = view(run, words, mask: echoInTheMiddle)
    let micTurn = try #require(masked.turns.first { $0.track == "mic" }).id
    // Reassigning moves the turn, echo words and all (hidden either way).
    let moved = masked.applying(.reassignTurns(turnIDs: [micTurn], to: "system:all"), editID: "E1")
    #expect(moved.turns.first { $0.id == micTurn }?.speakerID == "system:all")
    // The words a split is chosen from are those shown; the third shown word is word 4 of the segment, the first
    // after the hidden echo. Splitting there splits the stored turn at that word.
    let shown = try #require(masked.turns.first { $0.id == micTurn })
    let third = shown.spans.flatMap { span in (span.first..<span.end).map { WordRef(segmentID: span.segmentID, word: $0) } }[2]
    #expect(third == WordRef(segmentID: "M", word: 4))
    let parted = masked.applying(.splitTurn(turnID: micTurn, at: third), editID: "E2")
    #expect(parted.staleEdits.isEmpty)
    #expect(shownWords(parted.turns.first { $0.id == micTurn }) == [0, 1])
    let part = try #require(parted.turns.first { $0.id == "\(micTurn)/E2" })
    #expect(shownWords(part) == Array(4..<10))
    #expect(!part.cutByEcho)
    // The stored journal names the same turn and word whatever is shown: without the mask, the echo words are in the
    // first part.
    let journal = [SpeakerEdit(id: "E2", baseRunID: run.id, source: "app",
                               action: .splitTurn(turnID: micTurn, at: third))]
    let plain = view(run, words, edits: journal)
    #expect(plain.turns.filter { $0.track == "mic" }.map(shownWords) == [[0, 1, 2, 3], Array(4..<10)])
    // The first word shown is still the turn's first: a split there is refused, as on a turn without echo.
    let first = masked.applying(.splitTurn(turnID: micTurn, at: WordRef(segmentID: "M", word: 0)), editID: "E3")
    #expect(first.staleEdits.map(\.editID) == ["E3"])
    // Undo takes a split back.
    let undone = parted.applying(.revert(editID: "E2"), editID: "E4")
    #expect(undone.turns.filter { $0.track == "mic" }.map(shownWords) == [[0, 1, 4, 5, 6, 7, 8, 9]])
}

/// A diarized microphone: S1 holds E (seven words from 10 s, of which the first five are echo), S2 holds U; the
/// system track is one channel speaker.
private func diarizedCall() -> (transcript: Transcript, run: DiarizationRun) {
    let words = transcript([segment("E", words: 7, track: "mic", start: 10), segment("U", words: 4, track: "mic",
                                                                                    start: 20),
                            segment("S", words: 4, track: "system", start: 30)])
    let output = DiarizerOutput(segments: [RawDiarizationSegment(speaker: "S1", start: 9.9, end: 12.8),
                                           RawDiarizationSegment(speaker: "S2", start: 19.9, end: 21.8)],
                                centroids: [:], windows: [], processingSeconds: 0)
    let tracks = [SpeakerRunBuilder.TrackInput(track: "mic", policy: .diarized, output: output),
                  SpeakerRunBuilder.TrackInput(track: "system", policy: .channel(speakerID: "system:all",
                                                                                 displayName: "Others"))]
    let run = SpeakerRunBuilder.build(sessionID: session, transcript: words, tracks: tracks, engine: .fake,
                                      parameters: callParameters, id: "RUN").run
    return (words, run)
}

/// E's words 0–4 (10.0–11.9 s) are echo: 5 of S1's 7 words.
private let mostlyEcho = timedMask(seconds: 40, echo: [(10, 11.95)])

@Test func aMicrophoneClusterMostlyEchoShowsAsUnknownUnlessTheUserNamedIt() throws {
    let (words, run) = diarizedCall()
    #expect(view(run, words).speakers.map(\.id) == ["mic:S1", "mic:S2", "system:all"])
    let masked = view(run, words, mask: mostlyEcho)
    #expect(masked.speakers.map(\.id) == ["mic:S2", "system:all"])
    let rest = try #require(masked.turns.first { $0.spans == [WordSpan(segmentID: "E", first: 5, end: 7)] })
    #expect(rest.speakerID == nil)
    #expect(masked.turns.first { $0.spans.first?.segmentID == "U" }?.speakerID == "mic:S2")
    // Named by the user, the speaker stays: their decision stands.
    let named = view(run, words, edits: [SpeakerEdit(id: "E1", baseRunID: run.id, source: "app",
                                                     action: .rename(speakerID: "mic:S1", name: "Person C"))],
                     mask: mostlyEcho)
    #expect(named.turns.first { $0.spans == [WordSpan(segmentID: "E", first: 5, end: 7)] }?.speakerID == "mic:S1")
}

@Test func aSpeakerWhoseTurnsAreAllEchoKeepsItsNameAndAssignments() throws {
    // The user named S1 and gave it the system turn; the mask then calls every word of S1 echo.
    let (words, run) = diarizedCall()
    let systemTurn = try #require(run.turns.first { $0.track == "system" }?.id)
    let edits = [
        SpeakerEdit(id: "E1", baseRunID: run.id, source: "app", action: .rename(speakerID: "mic:S1", name: "Person C")),
        SpeakerEdit(id: "E2", baseRunID: run.id, source: "app",
                    action: .reassignTurns(turnIDs: [systemTurn], to: "mic:S1")),
    ]
    let masked = view(run, words, edits: edits, mask: timedMask(seconds: 40, echo: [(10, 13)]))
    #expect(masked.staleEdits.isEmpty)
    #expect(masked.appliedEditIDs == ["E1", "E2"])
    #expect(!masked.turns.contains { $0.track == "mic" && $0.speakerID == "mic:S1" })
    #expect(masked.turns.first { $0.track == "system" }?.speakerID == "mic:S1")
    #expect(masked.speakers.first { $0.id == "mic:S1" }?.name == "Person C")
}

@Test func aNewMaskChangesOnlyTheView() {
    // The same stored run and journal under three masks: no echo, a narrow one, a wide one.
    let (words, run) = channelCall()
    let stored = run
    let counts = [nil, timedMask(seconds: 30, echo: [(10.8, 11.1)]), echoInTheMiddle].map { mask in
        view(run, words, mask: mask).turns.filter { $0.track == "mic" }.flatMap(\.spans)
            .reduce(0) { $0 + $1.end - $1.first }
    }
    #expect(counts == [10, 9, 8])
    #expect(run == stored)
}

@Test func aCorrectedWordAcrossAnEchoBoundaryIsJudgedOnce() {
    // A word fix joined an echo word and a kept word into one ("data base" → "database", 10.4–11.0 s): the mask
    // judges the word by its frames, half echo and half local, and keeps it once.
    let mic = TranscriptSegment(id: "M", start: 10, end: 11.4, text: "so database here", words: [
        TimedWord(text: "so", start: 10.0, end: 10.3, utf16Offset: 0, utf16Length: 2),
        TimedWord(text: "database", start: 10.4, end: 11.0, utf16Offset: 3, utf16Length: 8),
        TimedWord(text: "here", start: 11.1, end: 11.4, utf16Offset: 12, utf16Length: 4),
    ], track: "mic")
    let words = transcript([mic])
    let run = SpeakerRunBuilder.build(
        sessionID: session, transcript: words,
        tracks: [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me"))],
        engine: nil, parameters: callParameters, id: "RUN").run
    let masked = view(run, words, mask: timedMask(seconds: 20, echo: [(10.4, 10.7)]))
    let shown = masked.turns.flatMap(\.spans).flatMap { Array($0.first..<$0.end) }
    #expect(shown == [0, 1, 2])
    // Fully inside the echo, it is hidden.
    let hidden = view(run, words, mask: timedMask(seconds: 20, echo: [(10.4, 11.05)]))
    #expect(hidden.turns.flatMap(\.spans).flatMap { Array($0.first..<$0.end) } == [0, 2])
}

@Test func damagedDroppedSpansAreReadOnlyWithinTheirSegment() {
    // A run file whose dropped spans run to Int.max or name a segment that is not there: the view is still made.
    let (words, original) = channelCall()
    var run = original
    run.droppedWords = [DroppedWords(spans: [WordSpan(segmentID: "M", first: 0, end: .max),
                                             WordSpan(segmentID: "X", first: .min, end: 9)], reason: "echo")]
    let masked = view(run, words, mask: echoInTheMiddle)
    // Every word of M counts as dropped already, so the mask hides nothing more.
    #expect(masked.turns.filter { $0.track == "mic" }.count == 1)
}


// MARK: - Word rule: local frames need evidence

/// Session times of a word over frames `frames`: from just before the first frame's centre to just after the last's.
private func word(_ frames: Range<Int>) -> (start: Double, end: Double) {
    (AcousticEchoMask.centre(ofFrame: frames.lowerBound) - 0.004,
     AcousticEchoMask.centre(ofFrame: frames.upperBound - 1) + 0.004)
}

private func isEcho(_ mask: AcousticEchoMask, _ frames: Range<Int>) -> Bool? {
    let times = word(frames)
    return mask.isEcho(start: times.start, end: times.end)
}

@Test func echoWordsWithScatteredLocalFramesAreEcho() {
    // A word of the call's echo, cancelled poorly: short local runs with the predicted echo at the microphone's level
    // (0 dB), 3.5 dB above it, and 5.5 dB below it, half of the word's frames. Before, the microphone's; now echo,
    // as review playback leaves it muted.
    let scattered = echoMask(count: 300, local: [(100..<103, 0), (106..<109, -11), (112..<115, 7)])
    #expect(isEcho(scattered.countingEveryLocalFrame(), 100..<118) == false)
    #expect(isEcho(scattered, 100..<118) == true)
    #expect(scattered.localSpeechIntervals().isEmpty)
    #expect(scattered.localStretches() == [AcousticEchoMask.LocalStretch(frames: 100..<115, evidence: 0)])
    // Exactly 6 dB below is no evidence, so #108 keeps it muted; but a run that far under the echo is an utterance of
    // the user's.
    let limit = echoMask(count: 300, local: [(100..<106, -12)])
    #expect(limit.localSpeechIntervals().isEmpty)
    #expect(isEcho(limit, 100..<110) == false)
}

@Test func doubleTalkWordsStayTheUsers() {
    // The user over the call (as in `speechOverTheCallKeepsItsWeakFirstSyllable`): a quiet first word whose own local
    // frames are 2 dB below the prediction, then louder speech with frames 8 dB below it, all one stretch.
    let doubleTalk = echoMask(count: 400, local: [
        (100..<104, -4), (110..<120, -4), (113..<116, -16), (130..<150, -3), (135..<137, -16), (160..<170, -4),
    ])
    #expect(isEcho(doubleTalk, 98..<106) == false, "The quiet first word, 0.24 s before louder frames.")
    #expect(isEcho(doubleTalk, 108..<122) == false)
    #expect(isEcho(doubleTalk, 128..<152) == false)
    #expect(isEcho(doubleTalk, 300..<320) == true, "The call's echo after it.")
    // The last quiet run, 0.4 s after the louder frames and alone in its half second, is an utterance of its own 2 dB
    // under the echo: the user's.
    #expect(isEcho(doubleTalk, 158..<172) == false)
    // Every word the rule before kept, it keeps.
    for frames in [98..<106, 108..<122, 128..<152, 158..<172, 300..<320] {
        #expect(isEcho(doubleTalk, frames) == isEcho(doubleTalk.countingEveryLocalFrame(), frames))
    }
}

@Test func quietSpeechWithoutPredictedEchoStaysTheUsers() {
    // The call is quiet (no predicted echo: the lowest stored level) and the microphone hears the user softly, between
    // silences: a long word, and a short sound of three local frames.
    var classes = [AcousticEchoMask.FrameClass](repeating: .silence, count: 200)
    for frame in Array(50..<80) + Array(150..<153) { classes[frame] = .local }
    let quiet = mask(classes, levels: [Int8](repeating: .min, count: 200))
    #expect(isEcho(quiet, 50..<80) == false)
    #expect(isEcho(quiet, 148..<156) == false)
    #expect(quiet.localStretches().map(\.hasEvidence) == [true, true])
}

@Test func aWordPartlyInAStretchWithEvidenceCountsOnlyItsFramesThere() {
    // The user's speech (20 dB above the prediction) ends at frame 146; 19 frames of echo later (0.304 s: another
    // stretch), a short local run at +2 dB with no evidence.
    let mixed = echoMask(count: 400, local: [(100..<146, -40), (165..<170, 4)])
    #expect(mixed.localStretches() == [
        AcousticEchoMask.LocalStretch(frames: 100..<146, evidence: 46),
        AcousticEchoMask.LocalStretch(frames: 165..<170, evidence: 0),
    ])
    // Over the end of the speech and the echo after it: 6 of its 18 frames local in the stretch (33 %), kept.
    #expect(isEcho(mixed, 140..<158) == false)
    // Reaching the other run too: before, 11 local of 30 (37 %); now only the 6 in the stretch count (20 %), echo.
    #expect(isEcho(mixed.countingEveryLocalFrame(), 140..<170) == false)
    #expect(isEcho(mixed, 140..<170) == true)
    // A word over the other run alone: 5 of 12 local before, none now.
    #expect(isEcho(mixed.countingEveryLocalFrame(), 160..<172) == false)
    #expect(isEcho(mixed, 160..<172) == true)
}

@Test func playbackAndTheWordRuleReadTheSameStretches() {
    // The masks of the playback tests: review plays exactly the stretches with evidence, padded, whichever word rule.
    let masks = [
        echoMask(count: 500, local: [(20..<23, 2), (50..<53, 6), (80..<85, -8), (120..<124, 0), (200..<212, 2),
                                     (300..<305, -8), (310..<314, -7)]),
        echoMask(count: 300, local: [(100..<140, -40)]),
        echoMask(count: 400, local: [(100..<104, -4), (110..<120, -4), (113..<116, -16), (130..<150, -3),
                                     (135..<137, -16), (160..<170, -4)]),
        echoMask(count: 400, local: [(100..<104, -4), (100..<102, -16), (110..<114, -4), (112..<113, -16)]),
        echoMask(count: 400, local: [(100..<104, -4), (100..<102, -16), (150..<154, -4), (150..<151, -16)]),
        echoMask(count: 600, local: [(100..<140, -40), (400..<430, -30), (200..<204, 2), (250..<253, 4),
                                     (520..<532, 0)]),
    ]
    for mask in masks {
        var padded: [AcousticEchoMask.Interval] = []
        for stretch in mask.localStretches() where stretch.hasEvidence {
            let interval = AcousticEchoMask.Interval(
                start: max(0, stretch.start - AcousticEchoMask.playbackLeadSeconds),
                end: stretch.end + AcousticEchoMask.playbackTailSeconds)
            if let last = padded.last, interval.start <= last.end {
                padded[padded.count - 1].end = max(last.end, interval.end)
            } else {
                padded.append(interval)
            }
        }
        #expect(mask.localSpeechIntervals() == padded)
        #expect(mask.countingEveryLocalFrame().localSpeechIntervals() == mask.localSpeechIntervals())
    }
    // Evidence adds up across the runs of one stretch, not across stretches.
    #expect(masks[3].localStretches() == [AcousticEchoMask.LocalStretch(frames: 100..<114, evidence: 3)])
    #expect(masks[4].localStretches().map(\.evidence) == [2, 1])
}

// MARK: - Labels and stats under the evidence rule

/// Echo throughout `seconds` (the prediction explains the microphone, 0 dB), with local frames whose centre lies in
/// each interval at its predicted echo level (stored half-dB steps).
private func levelledMask(seconds: Double, local: [(start: Double, end: Double, level: Int8)]) -> AcousticEchoMask {
    let count = Int(seconds / AcousticEchoMask.hopSeconds)
    var classes = [AcousticEchoMask.FrameClass](repeating: .echo, count: count)
    var levels = [Int8](repeating: 0, count: count)
    for frame in 0..<count {
        let centre = AcousticEchoMask.centre(ofFrame: frame)
        for run in local where centre >= run.start && centre < run.end {
            classes[frame] = .local
            levels[frame] = run.level
        }
    }
    return mask(classes, levels: levels)
}

/// M (`channelCall`, words every 0.4 s from 10 s): words 0–1 the user's (20 dB above the prediction), word 6 the
/// call's echo with false local frames at +2 dB and +3.5 dB (6 of its 19 frames), word 9 the user's while the call
/// is quiet (no prediction); every other frame echo.
private let falseLocalInWordSix = levelledMask(seconds: 30, local: [
    (10.0, 10.3, -40), (10.4, 10.7, -40), (12.4, 12.45, 4), (12.6, 12.65, 7), (13.6, 13.9, .min),
])

@Test func echoWithFalseLocalFramesLeavesTheUsersTurn() throws {
    let (words, run) = channelCall()
    let before = view(run, words, mask: falseLocalInWordSix.countingEveryLocalFrame())
    #expect(shownWords(before.turns.first { $0.track == "mic" }) == [0, 1, 6, 9])
    let after = view(run, words, mask: falseLocalInWordSix)
    #expect(shownWords(after.turns.first { $0.track == "mic" }) == [0, 1, 9])

    let stats = EchoLabelStats.compare(transcript: words, mask: falseLocalInWordSix, run: run)
    #expect(stats.microphoneWords == 10)
    #expect(stats.judgedWords == 10)
    #expect((stats.localBefore, stats.localAfter, stats.localToEcho, stats.echoToLocal) == (4, 3, 1, 0))
    #expect((stats.localToEchoInEcho, stats.localToEchoElsewhere) == (1, 0))
    // Word 6's local frames: the echo predicted 2 and 3.5 dB over the microphone, 6 or 7 of its 19 frames.
    #expect(stats.localToEchoLevels.atLeast0 == 1)
    #expect(stats.localToEchoShares.from30To50 == 1)
    #expect(stats.localToEchoElsewhereLevels == EchoLabelStats.LevelBuckets())
    // Word 6 is surrounded by echo; the user's words are not.
    #expect((stats.localInEchoBefore, stats.localInEchoAfter) == (1, 0))
    #expect((stats.microphoneRowsBefore, stats.microphoneRowsAfter) == (1, 1))
    #expect(stats.rowsChanged == 1)
    // Without labels: words only.
    let wordsOnly = EchoLabelStats.compare(transcript: words, mask: falseLocalInWordSix)
    #expect(wordsOnly.localToEcho == 1)
    #expect(wordsOnly.microphoneRowsBefore == nil && wordsOnly.rowsChanged == nil)
}

@Test func anEchoClusterWithFalseLocalFramesNowShowsUnknown() throws {
    // `diarizedCall`: S1 holds E (seven words from 10 s). E's words 0–4 are the call's echo with false local frames
    // (6 of each word's 19 frames, +2 dB); words 5–6 end with the user's own speech, 20 dB above the prediction (0.35
    // s after the last false run, so another stretch). S2 holds U, the user's.
    let (words, run) = diarizedCall()
    var local: [(start: Double, end: Double, level: Int8)] = (0..<5).flatMap { index -> [(Double, Double, Int8)] in
        let start = 10 + 0.4 * Double(index)
        return [(start, start + 0.05, 4), (start + 0.15, start + 0.2, 4)]
    }
    local += [(12.15, 12.3, -40), (12.45, 12.7, -40), (20, 21.5, -40)]
    let mask = levelledMask(seconds: 40, local: local)
    let before = view(run, words, mask: mask.countingEveryLocalFrame())
    #expect(before.speakers.map(\.id) == ["mic:S1", "mic:S2", "system:all"])
    let after = view(run, words, mask: mask)
    #expect(after.speakers.map(\.id) == ["mic:S2", "system:all"])
    #expect(after.turns.first { $0.spans.first?.segmentID == "E" }?.speakerID == nil)

    let stats = EchoLabelStats.compare(transcript: words, mask: mask, run: run)
    #expect(stats.localToEcho == 5)
    #expect((stats.unknownRowsBefore, stats.unknownRowsAfter) == (0, 1))
    #expect((stats.microphoneRowsBefore, stats.microphoneRowsAfter) == (2, 2))
}

@Test func echoLabelStatsAddUpAndPrintCountsOnly() {
    var first = EchoLabelStats()
    first.microphoneWords = 100
    first.judgedWords = 90
    first.localBefore = 40
    first.localAfter = 30
    first.localToEcho = 10
    first.localToEchoInEcho = 7
    first.localToEchoElsewhere = 3
    for level in [0.5, -2, -2, -4, -10, -10, -10] { first.localToEchoLevels.add(level: level) }
    for level: Double in [-2, -4, -10] { first.localToEchoElsewhereLevels.add(level: level) }
    for share in [0.3, 0.6, 0.9] { first.localToEchoShares.add(share: share) }
    first.localToEchoElsewhereShares.add(share: 0.9)
    first.localInEchoBefore = 12
    first.localInEchoAfter = 3
    first.microphoneRowsBefore = 20
    first.microphoneRowsAfter = 17
    first.unknownRowsBefore = 6
    first.unknownRowsAfter = 2
    first.rowsChanged = 5
    var second = EchoLabelStats()
    second.microphoneWords = 10
    second.judgedWords = 10
    second.localBefore = 4
    second.localAfter = 4
    var total = EchoLabelStats()
    total.add(first)
    total.add(second)
    #expect(total.line == "mic words 110, judged 100; user's 44 -> 34 (local->echo 10 [in echo 7, elsewhere 3], "
        + "echo->local 0); in echo 12 -> 3; mic rows 20 -> 17, unknown 6 -> 2; rows changed 5; levels ≥0:1 −1..0:0 "
        + "−3..−1:2 −6..−3:1 <−6:3 (elsewhere ≥0:0 −1..0:0 −3..−1:1 −6..−3:1 <−6:1); shares 30-50%:1 50-80%:1 ≥80%:1 "
        + "(elsewhere 30-50%:0 50-80%:0 ≥80%:1)")
    #expect(second.line == "mic words 10, judged 10; user's 4 -> 4 (local->echo 0 [in echo 0, elsewhere 0], "
        + "echo->local 0); in echo 0 -> 0")
}

@Test func echoDominatesAWordWhenItsFramesAreThreeTimesTheLocalOnes() {
    // ±0.5 s around the word's middle: about 62 frames.
    let mostlyEcho = echoMask(count: 300, local: [(140..<150, -40)])
    let middle = AcousticEchoMask.centre(ofFrame: 145)
    #expect(EchoLabelStats.echoDominated(mostlyEcho, start: middle - 0.1, end: middle + 0.1))
    let muchLocal = echoMask(count: 300, local: [(130..<160, -40)])
    #expect(!EchoLabelStats.echoDominated(muchLocal, start: middle - 0.1, end: middle + 0.1))
    let silent = mask([AcousticEchoMask.FrameClass](repeating: .silence, count: 300))
    #expect(!EchoLabelStats.echoDominated(silent, start: middle - 0.1, end: middle + 0.1))
}

@Test func aQuietSoundSmoothedToOneLocalFrameWhileTheCallIsSilentStaysTheUsers() throws {
    // Through the analysis's own frame rule: the microphone has a quiet sound 40 dB over its floor at frames 100, 102
    // and 104, nothing between. The 5-frame smoothing leaves only frame 102 local; 100 and 104 stay active, as echo.
    // One local frame of three: the rule before kept the word, and so does the rule now when the call predicts no
    // echo there, or a negligible one (40 dB below the microphone).
    for echo: Float in [0, 1e-8] {
        let mask = EchoAnalysis.classify(framePowers([
            (100..<101, 1e-4, echo, 1e-4, 1e-8), (102..<103, 1e-4, echo, 1e-4, 1e-8),
            (104..<105, 1e-4, echo, 1e-4, 1e-8),
        ]))
        #expect((99...105).map(mask.frameClass) == [.silence, .echo, .silence, .local, .silence, .echo, .silence])
        #expect(mask.localStretches() == [AcousticEchoMask.LocalStretch(frames: 102..<103, evidence: 1)])
        #expect(isEcho(mask.countingEveryLocalFrame(), 100..<105) == false)
        #expect(isEcho(mask, 100..<105) == false)
        // Review playback is #108's: one frame is not evidence enough to open the microphone.
        #expect(mask.localSpeechIntervals().isEmpty)
        // The same single frame with the echo 10 dB below the microphone: not negligible, and alone.
        var levels = mask.echoLevels
        levels[102] = -20
        let predicted = try #require(AcousticEchoMask(classes: mask.classes, echoLevels: levels))
        #expect(isEcho(predicted, 100..<105) == true)
    }
}

@Test func aHiddenInterjectionWhoseWordsChangeIsNoChangedRow() throws {
    // The microphone: an unknown speaker's "mm" (the user's, 20 dB over the prediction) and, 0.7 s later, "okay", the
    // call's echo with false local frames; then the user's sentence. "mm okay" is a filler turn Review hides under
    // both rules, though the new rule drops "okay" from it: no row changes. The sentence's row does not change either.
    let filler = TranscriptSegment(id: "F", start: 10, end: 11.3, text: "mm okay", words: [
        TimedWord(text: "mm", start: 10.0, end: 10.3, utf16Offset: 0, utf16Length: 2),
        TimedWord(text: "okay", start: 11.0, end: 11.3, utf16Offset: 3, utf16Length: 4),
    ], track: "mic")
    let words = transcript([filler, segment("M", words: 5, track: "mic", start: 20)])
    var run = SpeakerRunBuilder.build(
        sessionID: session, transcript: words,
        tracks: [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me"))],
        engine: nil, parameters: callParameters, id: "RUN").run
    let fillerTurn = try #require(run.turns.firstIndex { $0.spans.first?.segmentID == "F" })
    #expect(run.turns.count == 2)
    run.turns[fillerTurn].speakerID = nil
    let mask = levelledMask(seconds: 30, local: [
        (10.0, 10.3, -40), (11.0, 11.05, 4), (11.2, 11.25, 4), (20, 22, -40),
    ])
    let before = view(run, words, mask: mask.countingEveryLocalFrame())
    let after = view(run, words, mask: mask)
    let id = run.turns[fillerTurn].id
    #expect(shownWords(before.turns.first { $0.id == id }) == [0, 1])
    #expect(shownWords(after.turns.first { $0.id == id }) == [0])
    #expect(!before.shownTurns(includingHidden: false).contains { $0.id == id })
    #expect(!after.shownTurns(includingHidden: false).contains { $0.id == id })
    let stats = EchoLabelStats.compare(transcript: words, mask: mask, run: run)
    #expect(stats.localToEcho == 1)
    #expect(stats.rowsChanged == 0)
    #expect((stats.microphoneRowsBefore, stats.microphoneRowsAfter) == (1, 1))
}

/// Frame powers for `EchoAnalysis.classify`: `count` frames of a quiet microphone (1e-8, its noise floor) and silent
/// system audio, with `set` giving frames their microphone, predicted echo, residual and system powers.
private func framePowers(count: Int = 3_000,
                         _ set: [(frames: Range<Int>, mic: Float, echo: Float, residual: Float, system: Float)])
    -> EchoAnalysis.FramePowers {
    var powers = EchoAnalysis.FramePowers(microphone: [Float](repeating: 1e-8, count: count),
                                          echo: [Float](repeating: 0, count: count),
                                          residual: [Float](repeating: 1e-8, count: count),
                                          system: [Float](repeating: 1e-8, count: count))
    for entry in set {
        for frame in entry.frames {
            powers.microphone[frame] = entry.mic
            powers.echo[frame] = entry.echo
            powers.residual[frame] = entry.residual
            powers.system[frame] = entry.system
        }
    }
    return powers
}

@Test func sustainedDoubleTalkAtTheEchosLoudnessStaysTheUsers() {
    // The far end talks (well cancelled echo, frames 1300–1500), then the user talks over it as loud as the echo for
    // 1.6 s: microphone 2e-4, predicted echo 1e-4, residual 1e-4. The frame rule calls it local all through, but the
    // predicted echo is only 3 dB below the microphone, so no frame is 6 dB clear of it.
    let mask = EchoAnalysis.classify(framePowers([
        (1300..<1500, 1e-4, 1e-4, 1e-6, 1e-2),
        (1500..<1600, 2e-4, 1e-4, 1e-4, 1e-2),
    ]))
    #expect((1502..<1598).allSatisfy { mask.frameClass($0) == .local })
    #expect(mask.frameClass(1400) == .echo)
    let stretch = mask.localStretches().first { $0.frames.contains(1550) }
    #expect(stretch?.evidence == 0)
    #expect(mask.wordStretches.contains { $0.contains(1502) && $0.contains(1597) })
    // Every word of it is the user's, as before the evidence rule; the echo before it is echo.
    for start in stride(from: 1500, to: 1580, by: 20) {
        #expect(isEcho(mask, start..<(start + 18)) == false)
        #expect(isEcho(mask.countingEveryLocalFrame(), start..<(start + 18)) == false)
    }
    #expect(isEcho(mask, 1400..<1418) == true)
    // Review playback is unchanged (#108): the echo is as loud as the user there, so it stays muted.
    #expect(mask.localSpeechIntervals().isEmpty)
}

@Test func scatteredFalseLocalRunsThroughTheFrameRuleStayEcho() {
    // The far end talks (frames 600–1200), cancelled poorly in places: ten 5-frame runs 10 frames apart, and one of
    // 20 frames, where the residual keeps the microphone's level and the prediction is 2 dB above it. They are local
    // frames, but neither 6 dB clear of the echo nor quieter than it: the words over them are echo.
    var set: [(frames: Range<Int>, mic: Float, echo: Float, residual: Float, system: Float)] = [
        (600..<1200, 1e-4, 1e-4, 1e-6, 1e-2),
    ]
    for run in 0..<10 { set.append(((700 + 15 * run)..<(705 + 15 * run), 1e-4, 1.6e-4, 1e-4, 1e-2)) }
    set.append((1000..<1020, 1e-4, 1.6e-4, 1e-4, 1e-2))
    let mask = EchoAnalysis.classify(framePowers(set))
    #expect((700..<705).allSatisfy { mask.frameClass($0) == .local })
    #expect((1000..<1020).allSatisfy { mask.frameClass($0) == .local })
    #expect(mask.localStretches().allSatisfy { !$0.hasEvidence })
    #expect(mask.wordStretches.isEmpty)
    for frames in [700..<715, 760..<775, 1000..<1020] {
        #expect(isEcho(mask.countingEveryLocalFrame(), frames) == false)
        #expect(isEcho(mask, frames) == true)
    }
    #expect(mask.localSpeechIntervals().isEmpty)
}

@Test func aQuietSoundKeepsItsExemptionBesideAFalseLocalRun() throws {
    // The quiet sound smoothed to one local frame (102) while the call is silent, and 0.16 s later a short local run
    // of the call's echo predicted at the microphone's level (113–115): one stretch. The quiet frame keeps its own
    // exemption; the echo run does not share it.
    let mask = EchoAnalysis.classify(framePowers([
        (100..<101, 1e-4, 0, 1e-4, 1e-8), (102..<103, 1e-4, 0, 1e-4, 1e-8), (104..<105, 1e-4, 0, 1e-4, 1e-8),
        (113..<116, 1e-4, 1e-4, 1e-4, 1e-2),
    ]))
    #expect((99...105).map(mask.frameClass) == [.silence, .echo, .silence, .local, .silence, .echo, .silence])
    #expect((113..<116).allSatisfy { mask.frameClass($0) == .local })
    #expect(mask.localStretches() == [AcousticEchoMask.LocalStretch(frames: 102..<116, evidence: 1)])
    #expect(isEcho(mask, 100..<105) == false)
    #expect(isEcho(mask, 112..<117) == true)
    // Playback stays #108's: the quiet frame does not open the microphone, whose padding would reach the echo.
    #expect(mask.localSpeechIntervals().isEmpty)
}

/// Review playback exactly as #108 made it: runs of local frames joined across gaps under 0.3 s, a stretch kept with
/// at least 3 local frames 6 dB clear of the predicted echo, padded 64 ms before and 200 ms after.
private func playback108(_ mask: AcousticEchoMask) -> [AcousticEchoMask.Interval] {
    var stretches: [(interval: AcousticEchoMask.Interval, evidence: Int)] = []
    var frame = 0
    while frame < mask.frameCount {
        guard mask.frameClass(frame) == .local else { frame += 1; continue }
        let first = frame
        var evidence = 0
        while frame < mask.frameCount, mask.frameClass(frame) == .local {
            if Double(mask.echoLevels[frame]) * 0.5 < -6 { evidence += 1 }
            frame += 1
        }
        let start = AcousticEchoMask.centre(ofFrame: first) - 0.008
        let end = AcousticEchoMask.centre(ofFrame: frame - 1) + 0.008
        if let last = stretches.last, start - last.interval.end < 0.3 {
            stretches[stretches.count - 1].interval.end = end
            stretches[stretches.count - 1].evidence += evidence
        } else {
            stretches.append((AcousticEchoMask.Interval(start: start, end: end), evidence))
        }
    }
    var padded: [AcousticEchoMask.Interval] = []
    for (run, evidence) in stretches where evidence >= 3 {
        let interval = AcousticEchoMask.Interval(start: max(0, run.start - 0.064), end: run.end + 0.2)
        if let last = padded.last, interval.start <= last.end {
            padded[padded.count - 1].end = max(last.end, interval.end)
        } else {
            padded.append(interval)
        }
    }
    return padded
}

@Test func theWordRulesExemptionsLeavePlaybackAsItWas() {
    // Sustained double-talk at the echo's loudness, a quiet frame beside echo, a run that turns from double-talk into
    // false local frames, negligible predictions, and a quiet sound touching a false local run: the words keep their
    // frames, and review plays exactly what #108 played.
    let masks = [
        EchoAnalysis.classify(framePowers([
            (1300..<1500, 1e-4, 1e-4, 1e-6, 1e-2), (1500..<1600, 2e-4, 1e-4, 1e-4, 1e-2),
        ])),
        EchoAnalysis.classify(framePowers([
            (100..<101, 1e-4, 0, 1e-4, 1e-8), (102..<103, 1e-4, 0, 1e-4, 1e-8), (104..<105, 1e-4, 0, 1e-4, 1e-8),
            (113..<116, 1e-4, 1e-4, 1e-4, 1e-2),
        ])),
        echoMask(count: 400, local: [(100..<140, 4), (140..<165, -6)]),
        echoMask(count: 400, local: [(100..<102, -80), (102..<106, 4), (200..<230, -40), (300..<301, .min)]),
        echoMask(count: 300, local: [(200..<202, .min), (202..<206, 4)]),
    ]
    for mask in masks {
        #expect(mask.localSpeechIntervals() == playback108(mask))
        #expect(mask.countingEveryLocalFrame().localSpeechIntervals() == playback108(mask))
    }
    #expect(playback108(masks[1]).isEmpty, "The echo beside the quiet frame stays muted.")
}

@Test func sustainedDoubleTalkInARunThatBeganAsFalseLocalFramesIsKept() {
    // One unbroken local run: 40 frames of the call cancelled poorly (+2 dB), then 25 frames of the user over the
    // call at its loudness (−3 dB). Over the whole run the median is +2 dB; frame by frame, the double-talk
    // qualifies.
    let mask = echoMask(count: 400, local: [(100..<140, 4), (140..<165, -6)])
    #expect(mask.localStretches().map(\.evidence) == [0])
    #expect(isEcho(mask, 145..<163) == false)
    #expect(isEcho(mask, 140..<165) == false)
    #expect(isEcho(mask, 105..<125) == true)
    #expect(isEcho(mask.countingEveryLocalFrame(), 105..<125) == false)
    // Frames are trusted only where most local frames of their half second are below −1 dB.
    #expect(mask.wordStretches == [140..<165])
}

@Test func aQuietSoundTouchingAFalseLocalRunStaysTheUsers() {
    // While the call is silent the user makes a short sound (two local frames, nothing predicted), and the call
    // resumes at once with local frames it cancels poorly (+2 dB): one run. The quiet frames stay trusted on their own.
    let mask = echoMask(count: 300, local: [(200..<202, .min), (202..<206, 4)])
    #expect(mask.wordStretches == [200..<202])
    #expect(isEcho(mask, 199..<203) == false)
    #expect(isEcho(mask, 202..<210) == true)
    // A negligible prediction (40 dB below the microphone) is the same.
    let tiny = echoMask(count: 300, local: [(200..<202, -80), (202..<206, 4)])
    #expect(isEcho(tiny, 199..<203) == false)
}

@Test func syllabicDoubleTalkWithBriefGapsStaysTheUsers() {
    // The user talks over the call in syllables: 10 local frames (microphone 3e-4, predicted echo 1e-4, residual
    // 2e-4: the echo 4.8 dB below) then 4 frames of echo alone, again and again. No run is long, no frame is 6 dB
    // clear.
    var set: [(frames: Range<Int>, mic: Float, echo: Float, residual: Float, system: Float)] = [
        (1300..<1700, 1e-4, 1e-4, 1e-6, 1e-2),
    ]
    for start in stride(from: 1400, to: 1600, by: 14) { set.append((start..<(start + 10), 3e-4, 1e-4, 2e-4, 1e-2)) }
    let mask = EchoAnalysis.classify(framePowers(set))
    #expect((1400..<1410).allSatisfy { mask.frameClass($0) == .local })
    #expect((1410..<1414).allSatisfy { mask.frameClass($0) == .echo })
    #expect(mask.localStretches().allSatisfy { !$0.hasEvidence })
    // A word of 28 frames, 20 of them local: the user's.
    #expect(isEcho(mask, 1442..<1470) == false)
    #expect(isEcho(mask, 1500..<1528) == false)
    #expect(isEcho(mask, 1320..<1348) == true, "The echo before it.")
    #expect(mask.localSpeechIntervals().isEmpty, "Playback is #108's.")
}

@Test func evidenceSupportsOnlyFramesCloseToIt() {
    // One short burst of the user's (3 frames 10 dB clear of the echo), then 4 false local frames (+2 dB) every 10
    // frames for 5 s: one stretch, its gaps all under 0.3 s. The burst supports the frames within 18 of it, no more.
    var local: [(frames: Range<Int>, level: Int8)] = [(100..<103, -20)]
    for start in stride(from: 110, to: 410, by: 10) { local.append((start..<(start + 4), 4)) }
    let mask = echoMask(count: 500, local: local)
    #expect(mask.localStretches().count == 1)
    #expect(isEcho(mask, 98..<112) == false)
    #expect(isEcho(mask, 200..<220) == true)
    #expect(isEcho(mask, 380..<400) == true)
    #expect(isEcho(mask.countingEveryLocalFrame(), 380..<400) == false)
    #expect(mask.wordStretches == [100..<103, 110..<114])
}

@Test func syllablesFarApartOverTheCallStayTheUsers() {
    // The user over the call in syllables 160 ms long, 192 ms of echo alone between them: 10 local frames (microphone
    // 3e-4, predicted echo 1e-4, residual 2e-4) then 12 echo frames, again and again. No syllable has its half second
    // mostly local; each is an utterance 5 dB under the echo.
    var set: [(frames: Range<Int>, mic: Float, echo: Float, residual: Float, system: Float)] = [
        (1300..<1700, 1e-4, 1e-4, 1e-6, 1e-2),
    ]
    for start in stride(from: 1400, to: 1600, by: 22) { set.append((start..<(start + 10), 3e-4, 1e-4, 2e-4, 1e-2)) }
    let mask = EchoAnalysis.classify(framePowers(set))
    #expect((1400..<1410).allSatisfy { mask.frameClass($0) == .local })
    #expect((1410..<1422).allSatisfy { mask.frameClass($0) == .echo })
    #expect(isEcho(mask, 1400..<1428) == false)
    #expect(isEcho(mask, 1466..<1494) == false)
    #expect(isEcho(mask, 1320..<1348) == true, "The echo before it.")
    #expect(mask.localSpeechIntervals().isEmpty, "Playback is #108's.")
}

@Test func aShortUtteranceAloneAfterTheUsersSpeechStaysTheUsers() {
    // The user speaks (20 dB over the echo), the call goes on alone for 0.4 s, then the user says one short word 2 dB
    // under the echo, alone in its half second: no evidence near it and no sustained speech around it.
    let mask = echoMask(count: 400, local: [(100..<130, -40), (155..<165, -4)])
    #expect(isEcho(mask, 153..<167) == false)
    // The same short word 2 dB over the echo is the call cancelled poorly.
    let over = echoMask(count: 400, local: [(100..<130, -40), (155..<165, 4)])
    #expect(isEcho(over, 153..<167) == true)
    // An utterance ends at a gap of 4 frames: a short run of the call's after the user's word does not share its
    // level.
    let apart = echoMask(count: 400, local: [(200..<210, -4), (214..<217, 4)])
    #expect(isEcho(apart, 200..<210) == false)
    #expect(isEcho(apart, 214..<217) == true)
}

@Test func movedWordsAreBucketedByTheirLevelAndShare() {
    var levels = EchoLabelStats.LevelBuckets()
    for level in [0, -0.5, -1, -2.9, -3, -6, -6.5, -64] { levels.add(level: level) }
    #expect((levels.atLeast0, levels.from1To0, levels.from3To1, levels.from6To3, levels.below6) == (1, 2, 2, 1, 2))
    var shares = EchoLabelStats.ShareBuckets()
    for share in [0.3, 0.5, 0.79, 0.8, 1] { shares.add(share: share) }
    #expect((shares.from30To50, shares.from50To80, shares.atLeast80) == (1, 2, 2))
    // A word over frames 100..<110: 4 local at +2 dB, 2 local with no predicted echo, 4 echo. The median of its local
    // levels is the middle of +2 and +2 (the two lowest sort first), its share 60 %.
    let mask = echoMask(count: 300, local: [(100..<104, 4), (104..<106, .min)])
    let times = word(100..<110)
    let measured = EchoLabelStats.localFrames(mask, start: times.start, end: times.end)
    #expect(measured?.level == 2)
    #expect(measured?.share == 0.6)
    #expect(EchoLabelStats.localFrames(mask, start: word(200..<210).start, end: word(200..<210).end) == nil)
}
