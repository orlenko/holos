import AVFoundation
import Darwin
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// The stop path: timeouts, coverage-based replay, and the hand-off to post-processing (docs/meeting-design.md §4.6).

private func stopRecord(_ session: URL, state: PostProcessingState, message: String? = nil) -> PostProcessingRecord {
    PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: state, pid: getpid(),
                         startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                         updatedAt: Date(timeIntervalSince1970: 1_790_000_000), message: message)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func hungCaptureStopTimesOut() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3), stopDelay: .seconds(30))])
    let stop = ManualStopSource()
    let timeouts = StopTimeouts(captureStop: .milliseconds(200))
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: recorderDependencies(captures: captures, stop: stop, timeouts: timeouts))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    let clock = ContinuousClock()
    let stopped = clock.now
    stop.requestStop()
    let outcome = try await run.value
    #expect(stopped.duration(to: clock.now) < .seconds(10), "The stop path does not wait for the hung stop.")
    #expect(outcome.archiveStatus == ArchiveStatus.audioOnly, "The archive is finished with the audio saved.")
    #expect(try SessionArchive.readManifest(at: outcome.directory).chunks.first?.frameCount == 14_400)
    let failure = try #require(try recorderEvents(outcome.directory, MeetingEventKind.captureFailed).first)
    #expect(failure.details["error"]?.hasPrefix("Capture did not stop within") == true)
    #expect(failure.details["epoch"] == "0")
    #expect(try !SessionArchive.isActive(at: outcome.directory))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func hungSpeechFinishTimesOut() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    // Live: "Opening" is final once its audio is fed; "Unfinished" never is, and finish() hangs.
    let speech = FakeSpeechFactory([
        FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 0.1, text: "Opening"),
                                    TranscriptSegment(start: 0.25, end: 0.5, text: "Unfinished")],
                         finishHangs: true),
        FakeSpeechScript(segments: [TranscriptSegment(start: 0.2, end: 0.3, text: "Replayed rest")]),
    ])
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    let stop = ManualStopSource()
    let timeouts = StopTimeouts(speechFinishBase: .milliseconds(300), speechFinishPerAudioSecond: 0)
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url),
            dependencies: recorderDependencies(captures: captures, speech: speech.factory, stop: stop,
                                               timeouts: timeouts))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    let outcome = try await run.value
    let live = try #require(speech.sessions.first)
    #expect(await live.cancelled, "The hung session is cancelled after its timeout.")
    #expect(speech.sessions.count == 2, "The rest is replayed from disk.")
    let transcript = try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(
        try #require(outcome.transcriptID), in: outcome.directory))
    #expect(transcript.segments.map(\.text) == ["Opening", "Replayed rest"],
            "Its finalized segment is kept; the replay covers only what follows it.")
    #expect(outcome.archiveStatus == ArchiveStatus.complete)
}

/// Replay runs when live speech failed, so its speech calls have time limits too (§1.3): a replay session whose
/// `finish()` hangs is cancelled, the segments of the replay session before it are kept, and the track is incomplete.
@Test(.timeLimit(.minutes(1))) @MainActor
func hungReplayFinishTimesOut() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let speech = FakeSpeechFactory([
        // Live speech is unavailable, so the whole track is replayed.
        FakeSpeechScript(makeError: .unavailable("Live speech is unavailable.")),
        // The replay's first session (before the 1.7 s gap) finishes; the second one hangs.
        FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 0.2, text: "Before the gap")]),
        FakeSpeechScript(finishHangs: true),
    ])
    let frames = FakeFrame.run(count: 3) + FakeFrame.run(from: 2, count: 3)
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: frames)])
    let stop = ManualStopSource()
    let timeouts = StopTimeouts(speechFinishBase: .milliseconds(300), speechFinishPerAudioSecond: 0)
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url),
            dependencies: recorderDependencies(captures: captures, speech: speech.factory, stop: stop,
                                               timeouts: timeouts))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 6 })
    let clock = ContinuousClock()
    let stopped = clock.now
    stop.requestStop()
    let outcome = try await run.value
    #expect(stopped.duration(to: clock.now) < .seconds(10), "The stop path does not wait for the hung replay.")
    #expect(speech.sessions.count == 2)
    // Cancelled without waiting for it, since it may be stuck.
    var cancelled = false
    for _ in 0..<200 where !cancelled {
        cancelled = await speech.sessions.last?.cancelled == true
        if !cancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(cancelled, "The hung replay session is cancelled.")
    #expect(outcome.archiveStatus == ArchiveStatus.transcriptionIncomplete)
    #expect(outcome.transcriptErrors.count == 1)
    #expect(outcome.transcriptErrors.first?.hasPrefix("mic: Speech did not respond within 0.3 s") == true)
    let transcript = try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(
        try #require(outcome.transcriptID), in: outcome.directory))
    #expect(transcript.segments.map(\.text) == ["Before the gap"], "Segments already returned are kept.")
    let status = try #require(try RecorderChannel.readStatus(session: outcome.directory))
    #expect(status.phase == .exited)
    #expect(try !SessionArchive.isActive(at: outcome.directory))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func leaseTakenBeforeFinish() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let hookStarted = SharedValue(false)
    let probeSawHook = SharedValue(false)
    let hook: PostProcessHook = { session, _, _ in
        hookStarted.set(true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !probeSawHook.value, clock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return stopRecord(session, state: .succeeded)
    }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: recorderDependencies(captures: captures, postProcess: hook, stop: stop))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    let session = try #require(await recorderSession(in: temp.url))
    // Probes from before the stop until status.json says exited: into the hook and out of it.
    let probe = Task.detached { () -> (samples: Int, afterHook: Int, dead: Int, unlocked: Int, seen: Set<RecorderLiveness>) in
        var samples = 0, afterHook = 0, dead = 0, unlocked = 0
        var seen: Set<RecorderLiveness> = []
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let hookRunning = hookStarted.value
            // Locks first, then the status: the recorder writes exited before it releases its last lock.
            let writer = (try? SessionArchive.isActive(at: session)) ?? true
            let lease = (try? SessionArchive.isProcessing(at: session)) ?? true
            let liveness = RecorderChannel.liveness(session: session)
            let exited = (try? RecorderChannel.readStatus(session: session))?.phase == .exited
            samples += 1
            if hookRunning { afterHook += 1 }
            seen.insert(liveness)
            if liveness == .dead { dead += 1 }
            if !writer && !lease && !exited { unlocked += 1 }
            if hookRunning { probeSawHook.set(true) }
            if exited { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return (samples, afterHook, dead, unlocked, seen)
    }
    stop.requestStop()
    let outcome = try await run.value
    let result = await probe.value
    #expect(result.samples > 0)
    #expect(result.afterHook > 0, "The probe ran while and after the hook ran.")
    #expect(result.dead == 0, "Liveness never reads dead during the hand-off or the exit (saw \(result.seen)).")
    #expect(result.unlocked == 0, "The lease is held before the writer lock is released, until status says exited.")
    #expect(outcome.postProcessing?.state == .succeeded)
    #expect(RecorderChannel.liveness(session: session) == .exited)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func statusEndsExitedAfterFakePostProcessor() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let phaseDuringHook = SharedValue<RecorderPhase?>(nil)
    let hook: PostProcessHook = { session, _, _ in
        phaseDuringHook.set(try? RecorderChannel.readStatus(session: session)?.phase)
        return stopRecord(session, state: .partial, message: "No speaker labels: speaker models are not installed.")
    }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url),
            dependencies: recorderDependencies(captures: captures, postProcess: hook, stop: stop))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    stop.requestStop()
    let outcome = try await run.value
    #expect(phaseDuringHook.value == .postprocessing)
    let status = try #require(try RecorderChannel.readStatus(session: outcome.directory))
    #expect(status.phase == .exited)
    #expect(status.exit?.postprocessing == .partial)
    #expect(status.exit?.postprocessingMessage == "No speaker labels: speaker models are not installed.")
    #expect(status.exit?.archiveStatus == ArchiveStatus.complete)
    #expect(status.exit?.reason == .requested)
    #expect(status.progress == nil)
    #expect(RecordingWorkflow.recordedStopReason(session: outcome.directory) == .requested)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func startFailureEndsTheStatusExited() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(startError: .permissionDenied("Microphone access is required."))])
    await #expect(throws: HolosError.self) {
        try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: recorderDependencies(captures: captures))
    }
    let session = try #require(sessionFolders(in: temp.url).first)
    let status = try #require(try RecorderChannel.readStatus(session: session))
    #expect(status.phase == .exited)
    #expect(status.exit?.reason == .startFailed)
    #expect(status.exit?.archiveStatus == ArchiveStatus.failed)
    #expect(RecorderChannel.liveness(session: session) == .exited)
    // meeting.json was written before capture was asked to start.
    let meeting = try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(session))
    #expect(meeting.mode == .inPerson)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func setupFilesAreWrittenOnce() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let id = UUID().uuidString.lowercased()
    let options = RecordingOptions(name: "Council", source: .microphoneAndSystem, locale: "en-CA", backend: .speech,
                                   root: temp.url, recordOnly: true, vocabulary: ["Maria Chen", "", "Strata"],
                                   sessionID: id, othersInRoom: true, expectedSpeakers: 7)
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(options, dependencies: recorderDependencies(captures: captures, stop: stop))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    stop.requestStop()
    let outcome = try await run.value
    #expect(outcome.sessionID == id.uppercased(), "The given ID names the session.")
    let meeting = try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(outcome.directory))
    #expect(meeting.sessionID == outcome.sessionID)
    #expect(meeting.mode == .call)
    #expect(meeting.othersInRoom)
    #expect(meeting.expectedSpeakers == 7)
    #expect(meeting.origin == .recorded)
    let vocabulary = try AtomicFile.readJSON(MeetingVocabulary.self, from: SessionPaths.vocabulary(outcome.directory))
    #expect(vocabulary.strings == ["Maria Chen", "Strata"])
    // Reusing the ID is refused.
    await #expect(throws: HolosError.self) {
        try await RecordingWorkflow.run(options, dependencies: recorderDependencies(captures: FakeCaptureFactory()))
    }
    for invalid in [RecordingOptions.testing(root: temp.url, source: .microphone)] {
        var othersInRoom = invalid
        othersInRoom.othersInRoom = true
        await #expect(throws: HolosError.self) {
            try await RecordingWorkflow.run(othersInRoom, dependencies: recorderDependencies(captures: FakeCaptureFactory()))
        }
        var speakers = invalid
        speakers.expectedSpeakers = 21
        await #expect(throws: HolosError.self) {
            try await RecordingWorkflow.run(speakers, dependencies: recorderDependencies(captures: FakeCaptureFactory()))
        }
    }
    #expect(sessionFolders(in: temp.url).count == 1)
}

@Test(.timeLimit(.minutes(1)))
func float32ChunksStillReplay() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Before Int16", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    // A chunk as builds before PR2a wrote it: Float32 CAF.
    let path = "audio/mic/000001.caf"
    let url = archive.directory.appendingPathComponent(path)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
    buffer.frameLength = 32_000
    for index in 0..<32_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.01)) * 0.3 }
    try file?.write(from: buffer)
    file = nil
    #expect(try AVAudioFile(forReading: url).fileFormat.commonFormat == .pcmFormatFloat32)
    try await archive.registerChunk(AudioChunkRecord(track: "mic", relativePath: path, start: 0, end: 2,
                                                     sampleRate: 16_000, channels: 1, frameCount: 32_000))
    try await archive.finish(status: ArchiveStatus.complete)
    let speech = FakeSpeechFactory()
    _ = try await TrackReplayer.replay(directory: archive.directory, track: "mic", locale: "en-CA", backend: .speech,
                                       makeSpeech: speech.factory)
    let session = try #require(speech.sessions.first)
    #expect(await abs(session.fedSeconds - 2) < 1e-9, "Every frame is read.")
}
