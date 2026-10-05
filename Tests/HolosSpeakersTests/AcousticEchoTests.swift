import Accelerate
import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// Acoustic microphone echo in calls (docs/meeting-design.md §5.11): EchoAnalysis on synthetic signals only, the mask's
// word rule and playback intervals, and the run builder with a mask.

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

@Test func rebuildKeepsTheWordOwnershipTheRunHas() {
    // A system segment without word timing, split between two speakers. Its run's turns were carried across a word
    // fix by provenance: words 0–1 are S1's, 2–5 S2's, although aligning the fixed segment's estimated times again
    // would give word 2 to S1. A timed microphone segment has echo at word 1.
    let system = TranscriptSegment(id: "S", start: 10, end: 16, text: "a b c d e f", track: "system")
    let mic = segment("M", words: 4, track: "mic", start: 20)
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                                backend: .speech, segments: [system, mic])
    let output = DiarizerOutput(segments: [RawDiarizationSegment(speaker: "S1", start: 10, end: 13),
                                           RawDiarizationSegment(speaker: "S2", start: 13, end: 16)],
                                centroids: [:], windows: [], processingSeconds: 0)
    var parameters = callParameters
    parameters.offsetSearchSeconds = 0
    var run = SpeakerRunBuilder.build(
        sessionID: session, transcript: transcript,
        tracks: [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
                 SpeakerRunBuilder.TrackInput(track: "system", policy: .diarized, output: output)],
        engine: .fake, parameters: parameters).run
    let first = run.turns.firstIndex { $0.clusterID == "system:S1" }!
    let second = run.turns.firstIndex { $0.clusterID == "system:S2" }!
    #expect(run.turns[first].spans == [WordSpan(segmentID: "S", first: 0, end: 3)])
    run.turns[first].spans = [WordSpan(segmentID: "S", first: 0, end: 2)]
    run.turns[second].spans = [WordSpan(segmentID: "S", first: 2, end: 6)]

    let echoAtWord1 = timedMask(seconds: 30, echo: [(20.4, 20.7)])
    let rebuilt = SpeakerRunBuilder.rebuild(run, transcript: transcript, acousticEcho: echoAtWord1)
    #expect(rebuilt.turns.filter { $0.track == "system" }.map(\.spans)
        == [[WordSpan(segmentID: "S", first: 0, end: 2)], [WordSpan(segmentID: "S", first: 2, end: 6)]])
    #expect(rebuilt.turns.filter { $0.track == "mic" }.map(\.spans)
        == [[WordSpan(segmentID: "M", first: 0, end: 1)], [WordSpan(segmentID: "M", first: 2, end: 4)]])
    #expect(rebuilt.droppedWords == [DroppedWords(spans: [WordSpan(segmentID: "M", first: 1, end: 2)],
                                                  reason: EchoFilter.acousticReason)])

    // No echo found, or a mask that flags no word: the run as it is.
    for mask in [nil, timedMask(seconds: 30, echo: [])] {
        var same = SpeakerRunBuilder.rebuild(run, transcript: transcript, acousticEcho: mask, id: run.id,
                                             createdAt: run.createdAt)
        #expect(same == run)
        same = SpeakerRunBuilder.rebuild(rebuilt, transcript: transcript, acousticEcho: echoAtWord1, id: rebuilt.id,
                                         createdAt: rebuilt.createdAt)
        #expect(same == rebuilt, "Applying the same mask again changes nothing.")
    }
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
    // Frame k is centred at 0.032 + 0.016 k: frames 0..<10 cover [0.032, 0.176].
    let classes: [AcousticEchoMask.FrameClass] = [.local, .local, .echo, .echo, .echo, .echo, .echo, .silence,
                                                  .silence, .silence]
    let twoOfSix = mask(classes)
    // Frames 0...9: 2 local of 7 active (29 %) → echo.
    #expect(twoOfSix.isEcho(start: 0, end: 0.2) == true)
    // Frames 0...3: 2 local of 4 → kept.
    #expect(twoOfSix.isEcho(start: 0.03, end: 0.09) == false)
    // A word between centres still gets the next frame.
    #expect(twoOfSix.isEcho(start: 0.033, end: 0.034) == false)
    // After the last frame, or with times that are not numbers: not judged.
    #expect(twoOfSix.isEcho(start: 5, end: 6) == nil)
    #expect(twoOfSix.isEcho(start: .nan, end: 1) == nil)
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
    early[0] = .local
    #expect(mask(early).localSpeechIntervals().first?.start == 0)
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

// MARK: - Run builder

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
    return parameters
}()

@Test func acousticEchoWordsLeaveTheTurnsWithTheirOwnReason() {
    // Mic words at 10.0, 10.4, …, 12.8 (8 words); the mask calls 10.8–11.9 echo: words 2, 3, 4.
    let mic = segment("M", words: 8, track: "mic", start: 10)
    let system = segment("S", words: 4, track: "system", start: 2)
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                                backend: .speech, segments: [system, mic])
    let tracks = [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
                  SpeakerRunBuilder.TrackInput(track: "system", policy: .channel(speakerID: "system:all",
                                                                                 displayName: "Others"))]
    let plain = SpeakerRunBuilder.build(sessionID: session, transcript: transcript, tracks: tracks, engine: nil,
                                        parameters: callParameters, id: "R", createdAt: Date(timeIntervalSince1970: 0))
    let masked = SpeakerRunBuilder.build(sessionID: session, transcript: transcript, tracks: tracks, engine: nil,
                                         parameters: callParameters,
                                         acousticEcho: timedMask(seconds: 20, echo: [(10.8, 11.9)]),
                                         id: "R", createdAt: Date(timeIntervalSince1970: 0))
    #expect(plain.run.droppedWords.isEmpty)
    #expect(masked.run.droppedWords == [DroppedWords(spans: [WordSpan(segmentID: "M", first: 2, end: 5)],
                                                     reason: EchoFilter.acousticReason)])
    // The microphone turn is cut where the echo was taken out.
    let micTurns = masked.run.turns.filter { $0.track == "mic" }
    #expect(micTurns.map(\.spans) == [[WordSpan(segmentID: "M", first: 0, end: 2)],
                                      [WordSpan(segmentID: "M", first: 5, end: 8)]])
}

@Test func wordsBothFiltersFlagAreListedOnceAsTextEcho() {
    // The mic repeats the system's words 0.3 s later; the mask calls all of it echo, plus one word after.
    let system = TranscriptSegment(id: "S", start: 10, end: 11.2, text: "we should vote now", words: [
        TimedWord(text: "we", start: 10.0, end: 10.3, utf16Offset: 0, utf16Length: 2),
        TimedWord(text: "should", start: 10.3, end: 10.6, utf16Offset: 3, utf16Length: 6),
        TimedWord(text: "vote", start: 10.6, end: 10.9, utf16Offset: 10, utf16Length: 4),
        TimedWord(text: "now", start: 10.9, end: 11.2, utf16Offset: 15, utf16Length: 3),
    ], track: "system")
    let mic = TranscriptSegment(id: "M", start: 10.3, end: 11.8, text: "we should vote now ok", words: [
        TimedWord(text: "we", start: 10.3, end: 10.6, utf16Offset: 0, utf16Length: 2),
        TimedWord(text: "should", start: 10.6, end: 10.9, utf16Offset: 3, utf16Length: 6),
        TimedWord(text: "vote", start: 10.9, end: 11.2, utf16Offset: 10, utf16Length: 4),
        TimedWord(text: "now", start: 11.2, end: 11.5, utf16Offset: 15, utf16Length: 3),
        TimedWord(text: "ok", start: 11.5, end: 11.8, utf16Offset: 19, utf16Length: 2),
    ], track: "mic")
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                                backend: .speech, segments: [system, mic])
    let tracks = [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
                  SpeakerRunBuilder.TrackInput(track: "system", policy: .channel(speakerID: "system:all",
                                                                                 displayName: "Others"))]
    let built = SpeakerRunBuilder.build(sessionID: session, transcript: transcript, tracks: tracks, engine: nil,
                                        parameters: callParameters,
                                        acousticEcho: timedMask(seconds: 20, echo: [(10.0, 12.0)]))
    #expect(built.run.droppedWords == [
        DroppedWords(spans: [WordSpan(segmentID: "M", first: 0, end: 4)], reason: EchoFilter.reason),
        DroppedWords(spans: [WordSpan(segmentID: "M", first: 4, end: 5)], reason: EchoFilter.acousticReason),
    ])
    #expect(!built.run.turns.contains { $0.track == "mic" })
}

@Test func micClusterMostlyAcousticEchoIsHidden() {
    // A diarized microphone: S1 holds 5 words the mask calls echo and 2 more; S2 is the user. With the mask, S1 is
    // at 5/7 ≥ 60 % echo and disappears; its other words become unknown speaker.
    let echoWords = segment("E", words: 7, track: "mic", start: 10)
    let own = segment("U", words: 5, track: "mic", start: 20)
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                                backend: .speech, segments: [echoWords, own])
    let output = DiarizerOutput(segments: [
        RawDiarizationSegment(speaker: "S1", start: 9.9, end: 12.9),
        RawDiarizationSegment(speaker: "S2", start: 19.9, end: 22.0),
    ], centroids: [:], windows: [], processingSeconds: 0)
    var parameters = callParameters
    parameters.offsetSearchSeconds = 0
    let tracks = [SpeakerRunBuilder.TrackInput(track: "mic", policy: .diarized, output: output)]
    let plain = SpeakerRunBuilder.build(sessionID: session, transcript: transcript, tracks: tracks, engine: nil,
                                        parameters: parameters)
    #expect(plain.run.speakers.map(\.id) == ["mic:S1", "mic:S2"])
    let masked = SpeakerRunBuilder.build(sessionID: session, transcript: transcript, tracks: tracks, engine: nil,
                                         parameters: parameters,
                                         acousticEcho: timedMask(seconds: 30, echo: [(10.0, 11.9)]))
    #expect(masked.run.speakers.map(\.id) == ["mic:S2"])
    let unknown = masked.run.turns.filter { $0.speakerID == nil }
    #expect(unknown.flatMap(\.spans) == [WordSpan(segmentID: "E", first: 5, end: 7)])
}

@Test func rebuildingARunOnItsOwnDiarizationReproducesIt() {
    let system = SessionFixturesLite.alternatingSegments(track: "system")
    let mic = segment("M", words: 6, track: "mic", start: 3)
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                                backend: .speech, segments: (system + [mic]).sorted { $0.start < $1.start })
    let output = FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds: 5, duration: 20)
    let tracks = [SpeakerRunBuilder.TrackInput(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
                  SpeakerRunBuilder.TrackInput(track: "system", policy: .diarized, output: output)]
    let built = SpeakerRunBuilder.build(sessionID: session, transcript: transcript, tracks: tracks, engine: .fake,
                                        parameters: callParameters).run
    let rebuilt = SpeakerRunBuilder.rebuild(built, transcript: transcript, acousticEcho: nil, id: "NEW")
    #expect(rebuilt.id == "NEW")
    #expect(rebuilt.turns == built.turns)
    #expect(rebuilt.speakers == built.speakers)
    #expect(rebuilt.tracks == built.tracks)
    #expect(rebuilt.droppedWords == built.droppedWords)
    #expect(rebuilt.alignment == built.alignment)
    // With a mask that calls the mic words 1–2 echo, only the mic turns change.
    let masked = SpeakerRunBuilder.rebuild(built, transcript: transcript,
                                           acousticEcho: timedMask(seconds: 30, echo: [(3.4, 4.1)]))
    #expect(masked.turns.filter { $0.track == "system" }.map(\.spans)
        == built.turns.filter { $0.track == "system" }.map(\.spans))
    #expect(masked.droppedWords == [DroppedWords(spans: [WordSpan(segmentID: "M", first: 1, end: 3)],
                                                 reason: EchoFilter.acousticReason)])
}

/// Transcript helpers matching `FakeDiarizer.alternating`, as the meeting tests' fixtures lay them out.
private enum SessionFixturesLite {
    static func alternatingSegments(track: String) -> [TranscriptSegment] {
        (0..<4).map { turn in segment("\(track)\(turn)", words: 6, track: track, start: Double(turn) * 5 + 0.5) }
    }
}

// MARK: - Edit replay

@Test func editsCarryToARunRebuiltWithoutEcho() throws {
    // A diarized microphone whose first cluster's words are partly echo, and a system track.
    let mic = segment("M", words: 10, track: "mic", start: 10)
    let other = segment("N", words: 4, track: "mic", start: 20)
    let transcript = Transcript(id: "T", createdAt: Date(timeIntervalSince1970: 0), source: "fixture", locale: "en-CA",
                                backend: .speech, segments: [mic, other])
    let output = DiarizerOutput(segments: [
        RawDiarizationSegment(speaker: "S1", start: 9.9, end: 14.0),
        RawDiarizationSegment(speaker: "S2", start: 19.9, end: 21.6),
    ], centroids: [:], windows: [], processingSeconds: 0)
    var parameters = callParameters
    parameters.offsetSearchSeconds = 0
    let old = SpeakerRunBuilder.build(sessionID: session, transcript: transcript,
                                      tracks: [SpeakerRunBuilder.TrackInput(track: "mic", policy: .diarized,
                                                                            output: output)],
                                      engine: .fake, parameters: parameters, id: "OLD").run
    #expect(old.turns.map(\.id) == ["T1", "T2"])
    // The user named S2, moved T1 to S2 ... then undid that, split T1 at word 6, and kept T2 out of voice learning.
    let edits = [
        SpeakerEdit(id: "E1", baseRunID: "OLD", source: "app", action: .rename(speakerID: "mic:S2", name: "Person")),
        SpeakerEdit(id: "E2", baseRunID: "OLD", source: "app", action: .reassignTurns(turnIDs: ["T1"], to: "mic:S2")),
        SpeakerEdit(id: "E3", baseRunID: "OLD", source: "app", action: .revert(editID: "E2")),
        SpeakerEdit(id: "E4", baseRunID: "OLD", source: "app",
                    action: .splitTurn(turnID: "T1", at: WordRef(segmentID: "M", word: 6))),
        SpeakerEdit(id: "E5", baseRunID: "OLD", source: "app",
                    action: .reassignTurns(turnIDs: ["T1/E4"], to: "mic:S2")),
        SpeakerEdit(id: "E6", baseRunID: "OLD", source: "app", action: .excludeFromEnrollment(turnIDs: ["T2"])),
    ]
    let projection = SpeakerProjection.make(run: old, transcript: transcript, edits: edits, recognition: nil,
                                            profileNames: [:])
    #expect(projection.appliedEditIDs == ["E1", "E4", "E5", "E6"])

    // Words 1–2 of M are echo (10.4–11.0): T1 now starts after them, at word 3, as a separate turn.
    let rebuilt = SpeakerRunBuilder.rebuild(old, transcript: transcript,
                                            acousticEcho: timedMask(seconds: 30, echo: [(10.4, 11.1)]), id: "NEW")
    let carried = SpeakerEditReplay.carry(edits: edits, effective: projection.appliedEditIDs, from: old, to: rebuilt,
                                          transcript: transcript)
    #expect(carried.droppedEditIDs.isEmpty)
    #expect(carried.edits.map(\.id) == ["E1", "E4", "E5", "E6"])
    #expect(carried.edits.allSatisfy { $0.baseRunID == "NEW" && $0.source == "carry" })
    let view = SpeakerProjection.make(run: rebuilt, transcript: transcript, edits: carried.edits, recognition: nil,
                                      profileNames: [:])
    #expect(view.appliedEditIDs == ["E1", "E4", "E5", "E6"])
    #expect(view.speakers.first { $0.id == "mic:S2" }?.name == "Person")
    // Words 6–9 of M belong to the named speaker; words 0 and 3–5 stay with S1; 1–2 are gone.
    func speaker(of word: Int) -> String? {
        view.turns.first { turn in turn.spans.contains { $0.segmentID == "M" && $0.first <= word && word < $0.end } }?
            .speakerID
    }
    #expect((6..<10).allSatisfy { speaker(of: $0) == "mic:S2" })
    #expect([0, 3, 4, 5].allSatisfy { speaker(of: $0) == "mic:S1" })
    #expect(speaker(of: 1) == nil && speaker(of: 2) == nil)
    #expect(view.turns.filter(\.excludedFromEnrollment).flatMap(\.spans) == [WordSpan(segmentID: "N", first: 0, end: 4)])
}
