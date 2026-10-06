import AVFoundation
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import Testing

// Echo-free review playback (docs/meeting-design.md §5.10): the microphone's volume from the echo mask's local-speech
// intervals. Pure, synthetic intervals; nothing is played. The composition and the mask on disk are in
// AudioCompositionTests.

private func echoInterval(_ start: Double, _ end: Double) -> AcousticEchoMask.Interval {
    AcousticEchoMask.Interval(start: start, end: end)
}

private let echoRamp = ReviewMicVolume.rampSeconds

@Test func theMicrophoneFadesInBeforeLocalSpeechAndOutAfterIt() {
    let volume = ReviewMicVolume.keeping([echoInterval(2, 3), echoInterval(10, 12)], duration: 60)
    #expect(volume.initial == 0)
    #expect(volume.ramps == [
        .init(start: 2 - echoRamp, end: 2, from: 0, to: 1), .init(start: 3, end: 3 + echoRamp, from: 1, to: 0),
        .init(start: 10 - echoRamp, end: 10, from: 0, to: 1), .init(start: 12, end: 12 + echoRamp, from: 1, to: 0),
    ])
}

@Test func noLocalSpeechKeepsTheMicrophoneSilent() {
    #expect(ReviewMicVolume.keeping([], duration: 60) == ReviewMicVolume(initial: 0, ramps: []))
    // Intervals outside the playback, or empty, count as none.
    #expect(ReviewMicVolume.keeping([echoInterval(70, 80), echoInterval(5, 5), echoInterval(-3, -1)], duration: 60)
        == ReviewMicVolume(initial: 0, ramps: []))
    // No playback length: nothing to schedule.
    #expect(ReviewMicVolume.keeping([echoInterval(1, 2)], duration: 0) == ReviewMicVolume(initial: 0, ramps: []))
}

@Test func speechFromTheStartBeginsAtFullVolume() {
    let volume = ReviewMicVolume.keeping([echoInterval(0, 1.5)], duration: 60)
    #expect(volume.initial == 1)
    #expect(volume.ramps == [.init(start: 1.5, end: 1.5 + echoRamp, from: 1, to: 0)])
    // An interval before 0 is clipped to it.
    #expect(ReviewMicVolume.keeping([echoInterval(-0.2, 1.5)], duration: 60) == volume)
}

@Test func aFadeInNearTheStartIsShortened() {
    let volume = ReviewMicVolume.keeping([echoInterval(0.01, 1)], duration: 60)
    #expect(volume.initial == 0)
    #expect(volume.ramps.first == .init(start: 0, end: 0.01, from: 0, to: 1))
}

@Test func speechToTheEndNeverFadesOut() {
    let volume = ReviewMicVolume.keeping([echoInterval(58, 75)], duration: 60)
    #expect(volume.ramps == [.init(start: 58 - echoRamp, end: 58, from: 0, to: 1)])
    // A fade out cut short by the end of the playback.
    let short = ReviewMicVolume.keeping([echoInterval(58, 59.99)], duration: 60)
    #expect(short.ramps.last == .init(start: 59.99, end: 60, from: 1, to: 0))
}

@Test func intervalsCloserThanTwoRampsAreJoined() {
    let joined = ReviewMicVolume.keeping([echoInterval(1, 2), echoInterval(2 + 2 * echoRamp - 0.001, 3)], duration: 60)
    #expect(joined.ramps == [.init(start: 1 - echoRamp, end: 1, from: 0, to: 1),
                             .init(start: 3, end: 3 + echoRamp, from: 1, to: 0)])
    // Just over two ramps apart: a fade out, then a fade in that starts after it ends.
    let apart = ReviewMicVolume.keeping([echoInterval(1, 2), echoInterval(2 + 2 * echoRamp + 0.001, 3)], duration: 60)
    #expect(apart.ramps.count == 4)
    if apart.ramps.count == 4 { #expect(apart.ramps[1].end <= apart.ramps[2].start) }
    // Overlapping intervals are one.
    #expect(ReviewMicVolume.keeping([echoInterval(1, 3), echoInterval(2, 2.5)], duration: 60).ramps.count == 2)
}

@Test func rampsNeverOverlapAndAlternate() {
    // Intervals of every spacing, from the mask's padding and merging.
    var intervals: [AcousticEchoMask.Interval] = []
    var time = 0.0
    for index in 0..<500 {
        let gap = [0.0, 0.01, 0.049, 0.05, 0.3, 2][index % 6]
        time += gap
        intervals.append(echoInterval(time, time + 0.2))
        time += 0.2
    }
    let volume = ReviewMicVolume.keeping(intervals, duration: time - 0.1)
    var previousEnd = 0.0
    var level = volume.initial
    for ramp in volume.ramps {
        #expect(ramp.start >= previousEnd - 1e-12 && ramp.end > ramp.start)
        #expect(ramp.from == level && ramp.to == 1 - level)
        previousEnd = ramp.end
        level = ramp.to
    }
}

// MARK: - The audio mix

@Test func theMixSetsOnlyTheMicrophoneTrack() throws {
    let volume = ReviewMicVolume.keeping([echoInterval(2, 3)], duration: 60)
    let mix = volume.audioMix(track: 7)
    let parameters = try #require(mix.inputParameters.first)
    #expect(mix.inputParameters.count == 1)
    #expect(parameters.trackID == 7)
    func ramp(at seconds: Double) -> (start: Float, end: Float, range: CMTimeRange)? {
        var start: Float = -1, end: Float = -1
        var range = CMTimeRange.zero
        let time = CMTime(seconds: seconds, preferredTimescale: 7_056_000)
        guard parameters.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range) else {
            return nil
        }
        return (start, end, range)
    }
    // Before the fade in, the volume set at 0 holds; the fade in and the fade out are where the schedule says.
    let silent = try #require(ramp(at: 1))
    #expect(silent.start == 0 && silent.end == 0)
    let fadeIn = try #require(ramp(at: 2 - echoRamp / 2))
    #expect(fadeIn.start == 0 && fadeIn.end == 1)
    #expect(abs(fadeIn.range.start.seconds - (2 - echoRamp)) < 1e-6 && abs(fadeIn.range.end.seconds - 2) < 1e-6)
    let fadeOut = try #require(ramp(at: 3 + echoRamp / 2))
    #expect(fadeOut.start == 1 && fadeOut.end == 0)
}

@Test func aMixOfManyRampsReadsBackAsScheduled() throws {
    // The mix adds its ramps last first (for speed): every ramp must still be where the schedule puts it.
    let intervals = (0..<400).map { echoInterval(0.5 + Double($0) * 1.1, 0.5 + Double($0) * 1.1 + 0.4) }
    let volume = ReviewMicVolume.keeping(intervals, duration: 500)
    let parameters = try #require(volume.audioMix(track: 3).inputParameters.first)
    #expect(volume.ramps.count == 800)
    for ramp in volume.ramps {
        var start: Float = -1, end: Float = -1
        var range = CMTimeRange.zero
        let middle = CMTime(seconds: (ramp.start + ramp.end) / 2, preferredTimescale: 7_056_000)
        #expect(parameters.getVolumeRamp(for: middle, startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == ramp.from && end == ramp.to)
        #expect(abs(range.start.seconds - ramp.start) < 1e-6 && abs(range.end.seconds - ramp.end) < 1e-6)
    }
}

/// Building the schedule and the mix for a 2-hour call's intervals: printed, never asserted (run with
/// HOLOS_ECHO_MIX_BENCHMARK=1).
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_ECHO_MIX_BENCHMARK"] == "1"))
func echoMixBenchmark() {
    // 6,000 intervals over 2 hours: one local stretch every 1.2 s on average, far more than real calls have.
    let intervals = (0..<6_000).map { echoInterval(Double($0) * 1.2, Double($0) * 1.2 + 0.5) }
    let clock = ContinuousClock()
    var volume = ReviewMicVolume(initial: 0, ramps: [])
    let schedule = clock.measure { volume = ReviewMicVolume.keeping(intervals, duration: 7_200) }
    var mix: AVMutableAudioMix?
    let build = clock.measure { mix = volume.audioMix(track: 1) }
    print("echo mix benchmark: \(volume.ramps.count) ramps; schedule \(schedule), mix \(build), "
          + "inputs \(mix?.inputParameters.count ?? 0)")
}

// MARK: - Where the system track plays

@Test func theGapsInTheSystemAudioAreFound() {
    #expect(ReviewEchoMute.uncovered(by: [], duration: 10) == [echoInterval(0, 10)])
    #expect(ReviewEchoMute.uncovered(by: [0..<10], duration: 10).isEmpty)
    // Unsorted and overlapping, with gaps at the start, between, and at the end; past the end is ignored.
    #expect(ReviewEchoMute.uncovered(by: [6..<8, 1..<3, 2..<4, 9.5..<12], duration: 10)
        == [echoInterval(0, 1), echoInterval(4, 6), echoInterval(8, 9.5)])
    #expect(ReviewEchoMute.uncovered(by: [0..<4], duration: 0).isEmpty)
}

@Test func intervalsInAnyOrderGiveTheSameVolume() {
    let sorted = [echoInterval(1, 2), echoInterval(5, 9)]
    #expect(ReviewMicVolume.keeping(sorted.reversed(), duration: 20) == ReviewMicVolume.keeping(sorted, duration: 20))
}

// MARK: - Following the labels' mask

@Test func anotherMaskInTheLabelsReadsTheVolumeAgain() {
    var follow = ReviewEchoMaskFollow()
    // A player became ready while the labels had no mask: read once.
    let firstReady = follow.playerBecameReady(labels: nil)
    let noneAgain = follow.update(nil, playerReady: true)
    #expect(firstReady)
    #expect(!noneAgain, "No mask again: nothing to read.")
    // A relabel in the window saved a mask, and the labels adopted it.
    let saved = follow.update("sha-a", playerReady: true)
    let same = follow.update("sha-a", playerReady: true)
    #expect(saved)
    #expect(!same, "The same mask: nothing to read.")
    // The analysis was run again (another mask), then dropped.
    let replaced = follow.update("sha-b", playerReady: true)
    let dropped = follow.update(nil, playerReady: true)
    #expect(replaced && dropped)
}

@Test func aMaskChangedWhilePlaybackLoadsIsReadOnceThePlayerIsReady() {
    var follow = ReviewEchoMaskFollow(identity: "sha-a")
    // Playback is being rebuilt (it may read "sha-a"); the labels adopt "sha-b" meanwhile: not taken as read.
    let whileLoading = follow.update("sha-b", playerReady: false)
    #expect(!whileLoading)
    // The player becomes ready: the volume is read against "sha-b" now, whatever the build read.
    let ready = follow.playerBecameReady(labels: "sha-b")
    let after = follow.update("sha-b", playerReady: true)
    #expect(ready)
    #expect(!after)
}
