import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Synchronization
import Testing

// Live transcription of one track (docs/meeting-design.md §2.3, §4.6).

/// Events a live track journals, and a way to hold the journal back like a stalled disk.
private final class LiveEventLog: Sendable {
    private struct State {
        var events: [(kind: String, details: [String: String])] = []
        var calls = 0
        var held = false
        /// Writes of each kind still to fail, like a full disk.
        var failures: [String: Int] = [:]
    }

    private let state = Mutex(State())

    var sink: LiveEventSink {
        { kind, details in
            self.state.withLock { $0.calls += 1 }
            while self.state.withLock({ $0.held }) { try await Task.sleep(for: .milliseconds(2)) }
            let fails = self.state.withLock { state -> Bool in
                guard let left = state.failures[kind], left > 0 else { return false }
                state.failures[kind] = left - 1
                return true
            }
            if fails { throw HolosError.io("The disk is full.") }
            self.state.withLock { $0.events.append((kind, details)) }
        }
    }

    func hold(_ held: Bool) { state.withLock { $0.held = held } }
    /// The next `times` writes of `kind` fail.
    func fail(_ kind: String, times: Int) { state.withLock { $0.failures[kind] = times } }
    var calls: Int { state.withLock { $0.calls } }
    func events(_ kind: String) -> [[String: String]] {
        state.withLock { $0.events.filter { $0.kind == kind }.map(\.details) }
    }
    var kinds: [String] { state.withLock { $0.events.map(\.kind) } }
}

private func liveFrame(_ start: Double, seconds: Double = 0.1) throws -> PCMFrame {
    try PCMFrame(samples: [Float](repeating: 0.1, count: Int((seconds * 16_000).rounded())), sampleRate: 16_000,
                 channels: 1, startTime: start)
}

private func liveTrack(_ speech: @escaping LiveSpeechFactory, log: LiveEventLog, reporter: CollectingReporter = CollectingReporter(),
                       journalCapacity: Int = LiveTrack.journalCapacity,
                       timeouts: StopTimeouts = .standard) -> LiveTrack {
    LiveTrack(track: "mic", locale: "en-CA", backend: .speech, contextualStrings: ["Strata"], makeSpeech: speech,
              events: log.sink, reporter: reporter, timeouts: timeouts, journalCapacity: journalCapacity)
}

@Test(.timeLimit(.minutes(1))) func liveTrackRestartsSpeechAtBoundary() async throws {
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 0.1, text: "Call to order")]),
        FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 0.1, text: "Minutes adopted")]),
    ])
    let log = LiveEventLog()
    let track = liveTrack(speech.factory, log: log)
    try await track.prepareSession(epoch: 0, epochStart: 0)
    track.push(try liveFrame(0), epoch: 0)
    track.push(try liveFrame(0.1), epoch: 0)
    track.boundary()
    try await track.prepareSession(epoch: 1, epochStart: 5)
    track.push(try liveFrame(5), epoch: 1)
    track.push(try liveFrame(5.1), epoch: 1)
    let result = await track.finish()
    #expect(result.behindFrom == nil)
    #expect(result.segments.map(\.text) == ["Call to order", "Minutes adopted"])
    #expect(result.segments.map(\.start) == [0, 5])
    #expect(result.segments.allSatisfy { $0.track == "mic" })
    #expect(speech.sessions.count == 2, "One speech session per epoch.")
    #expect(speech.calls.allSatisfy { $0.contextualStrings == ["Strata"] })
}

@Test(.timeLimit(.minutes(1))) func speechSessionsAreRebased() async throws {
    let word = TimedWord(text: "Adjourned", start: 1.0, end: 1.4, utf16Offset: 0, utf16Length: 9)
    let speech = FakeSpeechFactory([
        FakeSpeechScript(),
        FakeSpeechScript(segments: [TranscriptSegment(start: 1.0, end: 1.4, text: "Adjourned", words: [word])]),
    ])
    let log = LiveEventLog()
    let reporter = CollectingReporter()
    let track = liveTrack(speech.factory, log: log, reporter: reporter)
    try await track.prepareSession(epoch: 0, epochStart: 0)
    track.push(try liveFrame(0), epoch: 0)
    track.boundary()
    // Epoch 1 starts an hour in.
    try await track.prepareSession(epoch: 1, epochStart: 3_605)
    for index in 0..<20 { track.push(try liveFrame(3_605 + Double(index) / 10), epoch: 1) }
    let result = await track.finish()
    let segment = try #require(result.segments.first { $0.text == "Adjourned" })
    #expect(abs(segment.start - 3_606.0) < 1e-9)
    #expect(abs(segment.words[0].start - 3_606.0) < 1e-9)
    #expect(abs(segment.words[0].end - 3_606.4) < 1e-9)
    let second = try #require(speech.sessions.last)
    #expect(await second.frameStarts.first == 0, "The speech session sees times from 0.")
    #expect(reporter.phrases.first?.segment.start == segment.start, "Phrases are reported on the session timeline.")
}

@Test(.timeLimit(.minutes(1))) func gapOverOneSecondStartsANewSession() async throws {
    let speech = FakeSpeechFactory()
    let track = liveTrack(speech.factory, log: LiveEventLog())
    try await track.prepareSession(epoch: 0, epochStart: 0)
    track.push(try liveFrame(0), epoch: 0)
    track.push(try liveFrame(0.5), epoch: 0)
    track.push(try liveFrame(2), epoch: 0)
    _ = await track.finish()
    #expect(speech.sessions.count == 2)
    let first = await speech.sessions[0].frameStarts
    let second = await speech.sessions[1].frameStarts
    #expect(first.count == 2 && abs(first[1] - 0.5) < 1e-9, "A gap under a second stays in one session.")
    #expect(second == [0])
}

@Test(.timeLimit(.minutes(1))) func finalizedEventCarriesWords() async throws {
    let words = [TimedWord(text: "Second", start: 0.1, end: 0.4, utf16Offset: 0, utf16Length: 6, confidence: 0.9),
                 TimedWord(text: "reading", start: 0.45, end: 0.9, utf16Offset: 7, utf16Length: 7)]
    let segment = TranscriptSegment(id: "SEG-1", start: 0.1, end: 0.9, text: "Second reading", words: words)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [segment])])
    let log = LiveEventLog()
    let track = liveTrack(speech.factory, log: log)
    try await track.prepareSession(epoch: 0, epochStart: 0)
    for index in 0..<10 { track.push(try liveFrame(Double(index) / 10), epoch: 0) }
    _ = await track.finish()
    let event = try #require(log.events(MeetingEventKind.transcriptFinalized).first)
    #expect(event["segmentID"] == "SEG-1")
    #expect(event["text"] == "Second reading")
    #expect(event["track"] == "mic")
    let decoded = try HolosJSON.decoder().decode([TimedWord].self, from: Data(try #require(event["words"]).utf8))
    #expect(decoded == words)
    #expect(try #require(event["words"]).contains("\n") == false, "Compact JSON.")
}

@Test(.timeLimit(.minutes(1))) func journalDropRecordsBehind() async throws {
    let segments = (0..<5).map { TranscriptSegment(start: Double($0) / 10, end: Double($0 + 1) / 10, text: "s\($0)") }
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: segments)])
    let log = LiveEventLog()
    let reporter = CollectingReporter()
    let track = liveTrack(speech.factory, log: log, reporter: reporter, journalCapacity: 2)
    log.hold(true)
    try await track.prepareSession(epoch: 0, epochStart: 0)
    track.push(try liveFrame(0), epoch: 0)
    // The first final is being written while the archive stalls.
    #expect(await eventuallyAsync { log.calls == 1 })
    for index in 1..<5 { track.push(try liveFrame(Double(index) / 10), epoch: 0) }
    #expect(await eventuallyAsync { reporter.phrases.count == 5 })
    log.hold(false)
    let result = await track.finish()
    #expect(result.segments.map(\.text) == ["s0", "s1", "s2", "s3", "s4"], "Live text itself is complete.")
    #expect(result.behindFrom == nil, "A journal hole does not stop live transcription.")
    #expect(log.events(MeetingEventKind.transcriptFinalized).map { $0["text"] } == ["s0", "s1", "s2"])
    let behind = try #require(log.events(MeetingEventKind.transcriptionBehind).first)
    #expect(behind["from"] == "0.3", "From the start of the first dropped segment.")
    #expect(behind["reason"] == "journalFull")
    #expect(log.kinds.last == MeetingEventKind.transcriptionBehind, "Recorded once the queue drained.")
}

/// The journal-hole marker cannot be written when the queue first drains: the hole stays noted and is recorded by a
/// later attempt, so recovery still knows where replay must begin.
@Test(.timeLimit(.minutes(1))) func journalHoleIsKeptUntilItsMarkerIsWritten() async throws {
    let segments = (0..<5).map { TranscriptSegment(start: Double($0) / 10, end: Double($0 + 1) / 10, text: "s\($0)") }
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: segments)])
    let log = LiveEventLog()
    let reporter = CollectingReporter()
    let track = liveTrack(speech.factory, log: log, reporter: reporter, journalCapacity: 2)
    log.fail(MeetingEventKind.transcriptionBehind, times: 1)
    log.hold(true)
    try await track.prepareSession(epoch: 0, epochStart: 0)
    track.push(try liveFrame(0), epoch: 0)
    #expect(await eventuallyAsync { log.calls == 1 })
    for index in 1..<5 { track.push(try liveFrame(Double(index) / 10), epoch: 0) }
    #expect(await eventuallyAsync { reporter.phrases.count == 5 })
    log.hold(false)
    // The queue drains and the marker's first write fails.
    #expect(await eventuallyAsync { log.calls == 4 })
    #expect(log.events(MeetingEventKind.transcriptionBehind).isEmpty)
    _ = await track.finish()
    let behind = log.events(MeetingEventKind.transcriptionBehind)
    #expect(behind.count == 1)
    #expect(behind.first?["from"] == "0.3", "From the start of the first dropped segment.")
    #expect(behind.first?["reason"] == "journalFull")
    #expect(reporter.messages.contains { $0.contains("Could not persist live text") })
}

/// A finalized segment whose journal write fails leaves a hole like a dropped one: it is recorded as
/// `transcriptionBehind` from that segment's start.
@Test(.timeLimit(.minutes(1))) func failedFinalizedWriteRecordsAHole() async throws {
    let segments = (0..<3).map { TranscriptSegment(start: Double($0) / 10, end: Double($0 + 1) / 10, text: "s\($0)") }
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: segments)])
    let log = LiveEventLog()
    let track = liveTrack(speech.factory, log: log)
    log.fail(MeetingEventKind.transcriptFinalized, times: 1)
    try await track.prepareSession(epoch: 0, epochStart: 0)
    for index in 0..<3 { track.push(try liveFrame(Double(index) / 10), epoch: 0) }
    let result = await track.finish()
    #expect(result.segments.map(\.text) == ["s0", "s1", "s2"], "Live text itself is complete.")
    #expect(log.events(MeetingEventKind.transcriptFinalized).map { $0["text"] } == ["s1", "s2"])
    let behind = try #require(log.events(MeetingEventKind.transcriptionBehind).first)
    #expect(behind["from"] == "0.0")
    #expect(behind["reason"] == "journalWriteFailed")
}

@Test(.timeLimit(.minutes(1))) func failedSessionCreationFallsBehindFromTheEpochStart() async throws {
    let speech = FakeSpeechFactory([FakeSpeechScript(), FakeSpeechScript(makeError: .unavailable("No assets."))])
    let log = LiveEventLog()
    let reporter = CollectingReporter()
    let track = liveTrack(speech.factory, log: log, reporter: reporter)
    try await track.prepareSession(epoch: 0, epochStart: 0)
    track.push(try liveFrame(0), epoch: 0)
    track.boundary()
    try await track.prepareSession(epoch: 1, epochStart: 42)
    #expect(track.transcription == .behind)
    track.push(try liveFrame(42), epoch: 1)
    let result = await track.finish()
    #expect(result.behindFrom == 42)
    #expect(log.events(MeetingEventKind.transcriptionBehind).first?["from"] == "42.0")
    #expect(reporter.messages.contains { $0.hasPrefix("Live mic transcription could not restart: No assets.") })
}

/// A session whose finish began before the stop (its epoch ended first) still ends by the stop budget of `finish()`,
/// not by its own, longer timeout.
@Test(.timeLimit(.minutes(1))) func stopBudgetCutsShortASessionFinishThatBeganEarlier() async throws {
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 0.1, text: "Opening")], finishHangs: true),
    ])
    // The session's own limit for 1 s of audio: 0.3 s + 30 s = 30.3 s. The stop budget with no session open: 0.3 s.
    let timeouts = StopTimeouts(speechFinishBase: .milliseconds(300), speechFinishPerAudioSecond: 30)
    let track = liveTrack(speech.factory, log: LiveEventLog(), timeouts: timeouts)
    try await track.prepareSession(epoch: 0, epochStart: 0)
    for index in 0..<10 { track.push(try liveFrame(Double(index) / 10), epoch: 0) }
    track.boundary()
    let session = try #require(speech.sessions.first)
    var finishing = false
    for _ in 0..<2_000 where !finishing {
        finishing = await session.finishCalls == 1
        if !finishing { try await Task.sleep(for: .milliseconds(5)) }
    }
    #expect(finishing, "The session's finish began before the stop.")
    let clock = ContinuousClock()
    let stopped = clock.now
    let result = await track.finish()
    let elapsed = stopped.duration(to: clock.now)
    #expect(elapsed < .seconds(5), "finish() waited \(elapsed) for a finish that began before it.")
    #expect(await session.cancelled, "The hung session is cancelled at the stop deadline.")
    #expect(result.segments.map(\.text) == ["Opening"], "Its finalized text is kept.")
    #expect(result.behindFrom == 0.1, "The rest of its audio is replayed.")
}

@Test(.timeLimit(.minutes(1))) func appendFailureKeepsFinalizedText() async throws {
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 0.1, text: "Roll call"),
                                    TranscriptSegment(start: 0.4, end: 0.5, text: "Never reached")],
                         appendError: .io("The speech service stopped."), appendErrorAfter: 0.3),
    ])
    let track = liveTrack(speech.factory, log: LiveEventLog())
    try await track.prepareSession(epoch: 0, epochStart: 0)
    for index in 0..<5 { track.push(try liveFrame(Double(index) / 10), epoch: 0) }
    let result = await track.finish()
    #expect(result.segments.map(\.text) == ["Roll call"])
    let from = try #require(result.behindFrom)
    #expect(abs(from - 0.3) < 1e-9, "Behind from the frame that failed (\(from)).")
}

@Test(.timeLimit(.minutes(1))) func finishFailureKeepsFinalizedText() async throws {
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 0.1, text: "Roll call"),
                                    TranscriptSegment(start: 0.25, end: 0.5, text: "Carried")],
                         finishError: .io("Recognition failed.")),
    ])
    let track = liveTrack(speech.factory, log: LiveEventLog())
    try await track.prepareSession(epoch: 0, epochStart: 0)
    for index in 0..<3 { track.push(try liveFrame(Double(index) / 10), epoch: 0) }
    let result = await track.finish()
    #expect(result.segments.map(\.text) == ["Roll call"])
    #expect(result.behindFrom == 0.1, "Behind from the end of its last finalized segment.")
}

/// Counts the speech sessions still in memory: made and not yet deallocated.
private final class SessionCensus: Sendable {
    private let alive = Mutex(0)
    private let made = Mutex(0)
    var count: Int { alive.withLock { $0 } }
    var total: Int { made.withLock { $0 } }
    func born() { alive.withLock { $0 += 1 }; made.withLock { $0 += 1 } }
    func died() { alive.withLock { $0 -= 1 } }

    var factory: LiveSpeechFactory {
        { _, _, _, _ in CensusSpeech(census: self) }
    }
}

/// A speech session that finishes at once with one segment and reports its own deallocation.
private final class CensusSpeech: LiveSpeechSession {
    let census: SessionCensus
    init(census: SessionCensus) { self.census = census; census.born() }
    deinit { census.died() }
    func append(_ frame: PCMFrame) async throws {}
    func finish() async throws -> [TranscriptSegment] { [TranscriptSegment(start: 0, end: 0.1, text: "Item")] }
    func cancel() async {}
}

@Test(.timeLimit(.minutes(1))) func finishedSpeechSessionsAreReleased() async throws {
    // A long recording: 40 epochs, each with a gap over 1 s inside, so 80 speech sessions. Each keeps an analyzer,
    // a converter, and tasks while it lives; only its segments may outlast it.
    let census = SessionCensus()
    let track = liveTrack(census.factory, log: LiveEventLog())
    for epoch in 0..<40 {
        let start = Double(epoch) * 10
        try await track.prepareSession(epoch: epoch, epochStart: start)
        track.push(try liveFrame(start), epoch: epoch)
        track.push(try liveFrame(start + 3), epoch: epoch)
        track.boundary()
    }
    let fed = await eventuallyAsync { census.total >= 80 && census.count <= 2 }
    #expect(fed, "\(census.count) of \(census.total) speech sessions are still in memory after they finished.")
    let result = await track.finish()
    #expect(census.total == 80)
    #expect(result.segments.count == 80, "Every session's segments are kept.")
    #expect(result.segments.first?.start == 0)
    #expect(result.segments.last?.start == 393)
    #expect(census.count == 0)
}

/// Polls `condition` every 5 ms on a 30 s `PollBudget` (outside the main actor).
private func eventuallyAsync(_ condition: @Sendable () -> Bool) async -> Bool {
    var budget = PollBudget(timeout: .seconds(30))
    while !budget.isSpent {
        if condition() { return true }
        await budget.poll()
    }
    return condition()
}

// MARK: - In a recording

@Test(.timeLimit(.minutes(1))) @MainActor
func nextSpeechSessionIsReadyBeforeCaptureRestarts() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let timeline = SharedValue<[String]>([])
    let fake = FakeSpeechFactory()
    let speech: LiveSpeechFactory = { locale, backend, strings, onUpdate in
        let call = fake.calls.count
        if call > 0 { try await Task.sleep(for: .milliseconds(500)) }
        let session = try await fake.factory(locale, backend, strings, onUpdate)
        timeline.update { $0.append("speech \(call) ready") }
        return session
    }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2)),
                                       FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let stop = ManualStopSource()
    let dependencies = recorderDependencies(captures: captures, speech: speech, stop: stop, makeCapture: {
        timeline.update { $0.append("capture \(captures.captures.count)") }
        return captures.make()
    })
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    let session = try #require(await recorderSession(in: temp.url))
    #expect(try await recorderSend(.pause, to: session)?.result == .applied)
    #expect(try await recorderSend(.resume, to: session)?.result == .applied)
    #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 2 })
    stop.requestStop()
    _ = try await run.value
    #expect(timeline.value == ["speech 0 ready", "capture 0", "speech 1 ready", "capture 1"],
            "The next epoch's speech session is ready before its capture is made and started.")
}

/// A capture of `count` 0.1 s frames at 16 kHz that never runs more than half a second ahead of what live speech has
/// taken, until `speech` reports that speech is blocked on the frame it stops at. Pacing the capture until that frame
/// has been taken, rather than until a frame time, is what makes the overflow's point deterministic: live speech
/// always has exactly the audio before its block, however slowly the machine runs, and only the frames behind it
/// overflow the live queue.
@MainActor
private final class PacedCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    let hostTimeOrigin = 0.0
    let droppedBuffers = 0
    private let stopped = SharedValue(false)
    let delivered: SharedValue<Int>

    init(count: Int, delivered: SharedValue<Int> = SharedValue(0),
         speech: @escaping @Sendable () async -> (fed: Double, blocked: Bool)) {
        self.delivered = delivered
        let stopped = stopped
        frames = AsyncThrowingStream(unfolding: {
            let index = delivered.value
            guard index < count, !stopped.value, !Task.isCancelled else { return nil }
            let start = Double(index) / 10
            while !stopped.value, !Task.isCancelled {
                let live = await speech()
                if live.blocked || live.fed >= start - 0.5 { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            guard !stopped.value, !Task.isCancelled else { return nil }
            delivered.update { $0 += 1 }
            return try FakeFrame(start: start, sampleRate: 16_000).captured(offset: 0)
        })
    }

    func start(_ request: CaptureRequest) async throws {}
    func stop() async throws { stopped.set(true) }
}

/// Live speech blocks at 40 s of a 60 s recording with a 1 s live queue, until capture has delivered all 60 s: the
/// words before the point where live transcription fell behind are kept, and only the rest is transcribed from disk.
/// The block ends on that signal, not after a fixed time, so the overflow happens however slowly the machine runs.
/// The capture is paced until speech is blocked, so live always covers whole seconds 0..<40 before it falls behind.
@Test(.timeLimit(.minutes(6))) @MainActor
func liveOverflowKeepsLiveWordsAndReplaysOnlyTheRest() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let delivered = SharedValue(0)
    let speech = RecorderSpeechFactory { call, onUpdate in
        call == 0 ? RecorderWordSpeech(prefix: "live", blockAt: 40, blockUntil: { delivered.value >= 600 },
                                       onUpdate: onUpdate)
            : RecorderWordSpeech(prefix: "replay", onUpdate: onUpdate)
    }
    let capture = PacedCapture(count: 600, delivered: delivered) {
        guard let live = speech.made.first as? RecorderWordSpeech else { return (0, false) }
        return await live.progress
    }
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: recorderDependencies(
            captures: FakeCaptureFactory(), speech: speech.factory, stop: stop,
            tuning: recorderFastTuning(liveQueueSeconds: 1), makeCapture: { capture }))
    }
    #expect(await eventually(timeout: .seconds(300)) { capture.delivered.value >= 600 })
    // The consumer finishes with the frame it holds before the stream ends, so nothing is lost by stopping now.
    stop.requestStop()
    let outcome = try await run.value
    let behind = try #require(try recorderEvents(outcome.directory, MeetingEventKind.transcriptionBehind).first)
    let from = try #require(behind.details["from"].flatMap(Double.init))
    #expect(from >= 40 && from <= 42, "Behind from about 40 s (\(from)).")
    let made = speech.made.compactMap { $0 as? RecorderWordSpeech }
    #expect(made.count == 2, "One live session, then one replay.")
    let replay = try #require(made.last)
    let replayed = await replay.fedSeconds
    #expect(abs(replayed - 22) < 0.5, "The replay starts about 2 s before the live coverage ends (\(replayed) s fed).")
    let transcript = try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(
        try #require(outcome.transcriptID), in: outcome.directory))
    let words = transcript.segments.flatMap(\.words)
    #expect(words.map(\.start) == (0..<60).map(Double.init), "Every second once: merged with no duplicates.")
    #expect(words.filter { $0.start < 40 }.allSatisfy { $0.text.hasPrefix("live") }, "Live words before 40 s are kept.")
    #expect(words.filter { $0.start >= 40 }.allSatisfy { $0.text.hasPrefix("replay") })
    #expect(try RecorderChannel.readStatus(session: outcome.directory)?.warnings
        .contains { $0.code == .transcriptionBehind } == true)
}
