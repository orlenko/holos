import AVFoundation
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import Synchronization
import Testing

// Opt-in (HOLOS_SPEECH_FIXTURE=1): installed speech assets, no microphone. Checks with real speech that rebased
// speech sessions give absolute word times (docs/meeting-design.md §2.3, review finding C6), whether SpeechAnalyzer
// reports times from the AVAudioTime it is given or from its first buffer.

private let speechFixtureEnabled = ProcessInfo.processInfo.environment["HOLOS_SPEECH_FIXTURE"] == "1"

/// A phrase rendered by the system speech synthesizer (`say`, the voices NativeSpeechRenderer uses) as mono frames of
/// 0.1 s, and the time the speech starts in it.
private func renderedPhrase(_ text: String, in folder: URL) throws -> (frames: [PCMFrame], onset: Double) {
    let url = folder.appendingPathComponent("phrase.aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, text]
    try say.run()
    say.waitUntilExit()
    guard say.terminationStatus == 0 else { throw HolosError.unavailable("say could not render the phrase.") }
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    let step = AVAudioFrameCount((rate / 10).rounded())
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step) else {
        throw HolosError.io("Cannot allocate a buffer.")
    }
    var frames: [PCMFrame] = []
    var onset: Double?
    var position = 0
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: step)
        guard buffer.frameLength > 0 else { break }
        let frame = try PCMConversion.copy(buffer, startTime: Double(position) / rate)
        if onset == nil, let first = frame.samples.firstIndex(where: { abs($0) > 0.02 }) {
            onset = (Double(position) + Double(first / frame.channels)) / rate
        }
        frames.append(frame)
        position += Int(buffer.frameLength)
    }
    return (frames, onset ?? 0)
}

@Test(.enabled(if: speechFixtureEnabled), .timeLimit(.minutes(2)))
func speechFixtureTimesAreAbsolute() async throws {
    let temp = try TemporaryDirectory("speech")
    defer { temp.remove() }
    let (frames, onset) = try renderedPhrase(
        "The council meeting is called to order, and the minutes of the last meeting are adopted.", in: temp.url)
    let length = frames.reduce(0) { $0 + $1.duration }
    let reporter = CollectingReporter()
    let locale = ProcessInfo.processInfo.environment["HOLOS_SPEECH_TEST_LOCALE"] ?? "en-CA"
    // Fails here, with the reason, when the speech assets are not installed (`holos setup --locale <locale>`).
    let probe = try await appleSpeechFactory(locale, .speech, []) { _ in }
    await probe.cancel()
    let track = LiveTrack(track: "mic", locale: locale, backend: .speech, contextualStrings: [],
                          makeSpeech: appleSpeechFactory, events: { _, _ in }, reporter: reporter)
    // An epoch an hour in, then the same audio again after a 5 s gap (a new epoch and speech session). Frames wait in
    // the live queue until the recognizer takes them, so they need not be fed in real time.
    let firstStart = 3_600.0
    let secondStart = firstStart + length + 5
    for (epoch, start) in [firstStart, secondStart].enumerated() {
        try await track.prepareSession(epoch: epoch + 1, epochStart: start)
        for frame in frames {
            track.push(try PCMFrame(samples: frame.samples, sampleRate: frame.sampleRate, channels: frame.channels,
                                    startTime: start + frame.startTime), epoch: epoch + 1)
        }
        track.boundary()
    }
    let result = await track.finish()
    #expect(result.behindFrom == nil, "Live transcription stopped: \(reporter.messages)")
    let words = result.segments.flatMap(\.words)
    let first = words.filter { $0.start < secondStart - 2.5 }
    let second = words.filter { $0.start >= secondStart - 2.5 }
    try #require(!first.isEmpty && !second.isEmpty, "Both passes were transcribed.")
    // Counts and times only; no transcript text is printed.
    print("speech fixture: \(first.count) and \(second.count) words; onset \(onset) s; first word at \(first[0].start - firstStart) s and \(second[0].start - secondStart) s into each pass")
    #expect(abs(first[0].start - (firstStart + onset)) <= 0.3, "Pass 1 starts where its speech starts.")
    #expect(abs(second[0].start - (secondStart + onset)) <= 0.3, "Pass 2 starts where its speech starts.")
    for (a, b) in zip(first, second) {
        #expect(abs((a.start - firstStart) - (b.start - secondStart)) <= 0.3, "The same word at the same point of each pass.")
    }
}
