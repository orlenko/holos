import Darwin
import Foundation
import HolosAudio
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// MARK: - Helpers

/// Starts the workflow with a `ManualStopSource`, waits until the first capture's consumer has finished with
/// `frames` frames, then requests the stop and returns the outcome.
@MainActor
private func record(_ options: RecordingOptions, captures: FakeCaptureFactory,
                    speech: FakeSpeechFactory = FakeSpeechFactory(), postProcess: PostProcessHook? = nil,
                    reporter: CollectingReporter = CollectingReporter(),
                    stopAfterConsuming frames: Int) async throws -> RecordingOutcome {
    let stop = ManualStopSource()
    let dependencies = RecordingDependencies.testing(captures: captures, speech: speech, postProcess: postProcess,
                                                     stop: stop, reporter: reporter)
    let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
    let consumed = await eventually { (captures.captures.first?.consumedFrames ?? 0) >= frames }
    #expect(consumed, "The consumer should take every scripted frame.")
    stop.requestStop()
    return try await run.value
}

@MainActor
private func threeMicFrames() -> FakeCaptureFactory {
    FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
}

private func transcript(_ outcome: RecordingOutcome) throws -> Transcript {
    let id = try #require(outcome.transcriptID)
    return try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(id, in: outcome.directory))
}

private func eventKinds(_ directory: URL) throws -> [String] {
    try SessionArchive.readEvents(at: directory).events.map(\.kind)
}

/// Every path inside `folder`, relative to it.
private func contents(of folder: URL) -> Set<String> {
    let prefix = folder.standardizedFileURL.path + "/"
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    var paths: Set<String> = []
    while let url = enumerator?.nextObject() as? URL {
        paths.insert(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
    }
    return paths
}

private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

private func fakeRecord(_ session: URL, state: PostProcessingState = .succeeded,
                        message: String? = "Labelled 3 speakers.") -> PostProcessingRecord {
    PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: state, pid: 1,
                         startedAt: fixedDate, updatedAt: fixedDate, message: message)
}

private func finishedArchive(in root: URL) async throws -> SessionArchive {
    let archive = try SessionArchive.create(root: root, name: "Finished", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    return archive
}

// MARK: - RecordingWorkflow

@Test(.timeLimit(.minutes(1))) @MainActor
func recordOnlySavesAudioAndFinishesAudioOnly() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = threeMicFrames()
    let speech = FakeSpeechFactory()
    let outcome = try await record(.testing(root: temp.url, recordOnly: true), captures: captures, speech: speech,
                                   stopAfterConsuming: 3)
    #expect(outcome.archiveStatus == ArchiveStatus.audioOnly)
    #expect(outcome.stopReason == .requested, "A ManualStopSource stop is a stop request, not a signal.")
    #expect(outcome.transcriptID == nil)
    #expect(outcome.transcriptErrors.isEmpty)
    #expect(outcome.postProcessing == nil)
    let manifest = try SessionArchive.readManifest(at: outcome.directory)
    #expect(manifest.id == outcome.sessionID)
    #expect(manifest.status == ArchiveStatus.audioOnly)
    #expect(manifest.chunks.count == 1)
    #expect(manifest.chunks.first?.track == "mic")
    #expect(manifest.chunks.first?.frameCount == 14_400)
    let kinds = try eventKinds(outcome.directory)
    #expect(kinds.contains(MeetingEventKind.captureStarted))
    #expect(kinds.contains(MeetingEventKind.captureStopped))
    #expect(speech.calls.isEmpty)
    #expect(captures.requests == [CaptureRequest(source: .microphone)])
    #expect(captures.captures.first?.stopCalls == 1)
    #expect(try SessionArchive.currentTranscriptID(at: outcome.directory) == nil)
    #expect(try !SessionArchive.isActive(at: outcome.directory))
    #expect(!FileManager.default.fileExists(atPath: outcome.directory.appendingPathComponent("control.json").path))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func captureFailureMarksArchiveIncompleteAndThrows() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 1), failAfterFrames: 1,
                                                         failure: .io("The microphone disappeared."))])
    do {
        _ = try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: .testing(captures: captures))
        Issue.record("A capture failure must throw.")
    } catch let HolosError.incomplete(message) {
        #expect(message.contains("The microphone disappeared."))
    }
    let directory = try #require(sessionFolders(in: temp.url).first)
    let manifest = try SessionArchive.readManifest(at: directory)
    #expect(manifest.status == ArchiveStatus.incomplete)
    #expect(manifest.chunks.count == 1, "Audio captured before the failure is kept.")
    let events = try SessionArchive.readEvents(at: directory).events
    let failure = try #require(events.first { $0.kind == MeetingEventKind.captureFailed })
    #expect(failure.details["error"] == "The microphone disappeared.")
    #expect(!events.contains { $0.kind == MeetingEventKind.captureStopped })
    #expect(try !SessionArchive.isActive(at: directory))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func noFramesIsIncomplete() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let stop = ManualStopSource()
    stop.requestStop()
    do {
        _ = try await RecordingWorkflow.run(.testing(root: temp.url),
                                            dependencies: .testing(captures: FakeCaptureFactory(), stop: stop))
        Issue.record("A recording without audio must throw.")
    } catch let HolosError.incomplete(message) {
        #expect(message.contains("No audio buffers"))
    }
    let directory = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.incomplete)
    #expect(try eventKinds(directory).contains(MeetingEventKind.captureFailed))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func liveSegmentsBecomeTranscriptWithTrack() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let segments = [TranscriptSegment(start: 0, end: 0.1, text: "Good evening"),
                    TranscriptSegment(start: 0.12, end: 0.28, text: "everyone")]
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: segments)])
    let reporter = CollectingReporter()
    let outcome = try await record(.testing(root: temp.url), captures: threeMicFrames(), speech: speech,
                                   reporter: reporter, stopAfterConsuming: 3)
    #expect(outcome.archiveStatus == ArchiveStatus.complete)
    #expect(try SessionArchive.readManifest(at: outcome.directory).status == ArchiveStatus.complete)
    #expect(outcome.transcriptErrors.isEmpty)
    let saved = try transcript(outcome)
    #expect(saved.segments.map(\.text) == ["Good evening", "everyone"])
    #expect(saved.segments.allSatisfy { $0.track == "mic" })
    #expect(try SessionArchive.currentTranscriptID(at: outcome.directory) == outcome.transcriptID)
    #expect(reporter.phrases.map(\.track) == ["mic", "mic"])
    #expect(reporter.phrases.map(\.segment.text) == ["Good evening", "everyone"])
    let finalized = try SessionArchive.readEvents(at: outcome.directory).events
        .filter { $0.kind == MeetingEventKind.transcriptFinalized }
    #expect(finalized.map { $0.details["text"] } == ["Good evening", "everyone"])
    #expect(finalized.allSatisfy { $0.details["track"] == "mic" })
    #expect(speech.calls == [FakeSpeechFactory.Call(locale: "en-CA", backend: .speech, contextualStrings: [])])
    let session = try #require(speech.sessions.first)
    let starts = await session.frameStarts
    #expect(starts.count == 3)
    for (start, expected) in zip(starts, [0.0, 0.1, 0.2]) { #expect(abs(start - expected) < 1e-9) }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func liveSpeechFailureFallsBackToReplay() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let replayed = TranscriptSegment(start: 0.05, end: 0.25, text: "Read back from disk")
    let speech = FakeSpeechFactory([FakeSpeechScript(makeError: .unavailable("Speech assets are missing.")),
                                    FakeSpeechScript(segments: [replayed])])
    let reporter = CollectingReporter()
    let outcome = try await record(.testing(root: temp.url), captures: threeMicFrames(), speech: speech,
                                   reporter: reporter, stopAfterConsuming: 3)
    #expect(outcome.archiveStatus == ArchiveStatus.complete)
    let saved = try transcript(outcome)
    #expect(saved.segments.map(\.text) == ["Read back from disk"])
    #expect(saved.segments.first?.track == "mic")
    #expect(speech.calls.count == 2)
    #expect(speech.sessions.count == 1)
    let replay = try #require(speech.sessions.first)
    #expect(await abs(replay.fedSeconds - 0.3) < 1e-6, "The replay reads every saved frame.")
    #expect(await replay.frameStarts.first == 0)
    #expect(reporter.messages.contains { $0.hasPrefix("Live mic transcription unavailable: Speech assets are missing.") })
    #expect(reporter.messages.contains("Processing saved mic audio…"))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func durationStopsRecording() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(continuous: FakeFrame(start: 0))])
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = try await RecordingWorkflow.run(.testing(root: temp.url, duration: 0.3),
                                                  dependencies: .testing(captures: captures))
    #expect(started.duration(to: clock.now) < .seconds(2))
    #expect(outcome.stopReason == .duration)
    #expect(outcome.archiveStatus == ArchiveStatus.complete)
    let manifest = try SessionArchive.readManifest(at: outcome.directory)
    #expect(!manifest.chunks.isEmpty)
    #expect(manifest.chunks.allSatisfy { $0.track == "mic" })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func stopRequestFileStopsRecording() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
                                        dependencies: .testing(captures: captures))
    }
    var directory: URL?
    #expect(await eventually {
        directory = sessionFolders(in: temp.url).first
        guard let directory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.json").path)
    })
    let session = try #require(directory)
    struct Control: Decodable { var schemaVersion: Int; var sessionID: String; var pid: Int32 }
    let control = try AtomicFile.readJSON(Control.self, from: session.appendingPathComponent("control.json"))
    #expect(control.schemaVersion == 1)
    #expect(control.pid == getpid())
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    try Data("stop\n".utf8).write(to: session.appendingPathComponent("stop.request"))
    let outcome = try await run.value
    #expect(control.sessionID == outcome.sessionID)
    #expect(outcome.stopReason == .requested)
    #expect(outcome.archiveStatus == ArchiveStatus.audioOnly)
    #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("control.json").path))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func startFailureMarksArchiveFailed() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(startError: .permissionDenied("Microphone access is required."))])
    do {
        _ = try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: .testing(captures: captures))
        Issue.record("A capture that cannot start must throw.")
    } catch let HolosError.permissionDenied(message) {
        #expect(message == "Microphone access is required.")
    }
    let directory = try #require(sessionFolders(in: temp.url).first)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.failed)
    let events = try SessionArchive.readEvents(at: directory).events
    #expect(events.first { $0.kind == MeetingEventKind.startFailed }?.details["error"] == "Microphone access is required.")
    #expect(try !SessionArchive.isActive(at: directory))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".processing.lock").path))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func invalidDurationIsRefusedBeforeCreatingASession() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    for duration in [0, -1, Double.nan, .infinity] {
        await #expect(throws: HolosError.self) {
            try await RecordingWorkflow.run(.testing(root: temp.url, duration: duration),
                                            dependencies: .testing(captures: FakeCaptureFactory()))
        }
    }
    #expect(sessionFolders(in: temp.url).isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func callCaptureRequestCarriesSourceAndApplication() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = threeMicFrames()
    let speech = FakeSpeechFactory()
    let reporter = CollectingReporter()
    let options = RecordingOptions.testing(root: temp.url, source: .microphoneAndSystem,
                                           applicationBundleID: "com.example.Call")
    let outcome = try await record(options, captures: captures, speech: speech, reporter: reporter,
                                   stopAfterConsuming: 3)
    #expect(captures.requests == [CaptureRequest(source: .microphoneAndSystem, applicationBundleID: "com.example.Call",
                                                 timelineOffset: 0)])
    #expect(speech.calls.count == 2, "One live speech session per track.")
    #expect(reporter.messages.contains("No system audio buffers arrived; that source track is empty."))
    #expect(outcome.archiveStatus == ArchiveStatus.complete)
}

// MARK: - Post-processing hand-off

@Test(.timeLimit(.minutes(1))) @MainActor
func postProcessHookRunsUnderLeaseAfterFinish() async throws {
    struct Observation: Sendable {
        var isActive: Bool
        var isProcessing: Bool
        var leaseSession: URL
        var archiveStatus: String?
    }
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let seen = SharedValue<Observation?>(nil)
    let hook: PostProcessHook = { session, lease, _ in
        seen.set(Observation(isActive: (try? SessionArchive.isActive(at: session)) ?? true,
                             isProcessing: (try? SessionArchive.isProcessing(at: session)) ?? false,
                             leaseSession: lease.session,
                             archiveStatus: try? SessionArchive.readManifest(at: session).status))
        return fakeRecord(session)
    }
    let outcome = try await record(.testing(root: temp.url), captures: threeMicFrames(), postProcess: hook,
                                   stopAfterConsuming: 3)
    let observed = try #require(seen.value)
    #expect(!observed.isActive, "The writer lock is released before the hook runs.")
    #expect(observed.isProcessing, "The hook runs under the processing lease.")
    #expect(observed.leaseSession == outcome.directory)
    #expect(observed.archiveStatus == ArchiveStatus.complete, "The archive is finished before the hook runs.")
    #expect(outcome.postProcessing == fakeRecord(outcome.directory))
    #expect(try !SessionArchive.isProcessing(at: outcome.directory), "The lease is released afterwards.")
}

/// §4.6 steps 5–6: the lease is taken before `archive.finish`, so from the stop until the hook runs the session
/// always holds the writer lock or the processing lease.
@Test(.timeLimit(.minutes(1))) @MainActor
func leaseHandOffLeavesNoUnlockedGap() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let hookStarted = SharedValue(false)
    let probeDone = SharedValue(false)
    let hook: PostProcessHook = { session, _, _ in
        hookStarted.set(true)
        // Hold the lease until the probe has stopped, so no sample can see its release.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !probeDone.value, clock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return fakeRecord(session)
    }
    let captures = threeMicFrames()
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
                                        dependencies: .testing(captures: captures, postProcess: hook, stop: stop))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    let directory = try #require(sessionFolders(in: temp.url).first)
    let probe = Task.detached { () -> (samples: Int, unlocked: Int) in
        var samples = 0
        var unlocked = 0
        while !hookStarted.value {
            // Writer lock first: once it is gone, the lease must already be held.
            let locked = ((try? SessionArchive.isActive(at: directory)) ?? true)
                || ((try? SessionArchive.isProcessing(at: directory)) ?? true)
            samples += 1
            if !locked { unlocked += 1 }
        }
        probeDone.set(true)
        return (samples, unlocked)
    }
    stop.requestStop()
    let outcome = try await run.value
    let result = await probe.value
    #expect(result.samples > 0)
    #expect(result.unlocked == 0, "The session was left without any lock between stop and the hook.")
    #expect(outcome.postProcessing == fakeRecord(outcome.directory))
    #expect(try !SessionArchive.isProcessing(at: outcome.directory))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cancellingTheRunKeepsAudioAndRethrowsCancellation() async throws {
    for recordOnly in [false, true] {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let hookCalls = SharedValue(0)
        let hook: PostProcessHook = { session, _, _ in
            hookCalls.update { $0 += 1 }
            return fakeRecord(session)
        }
        let captures = threeMicFrames()
        let run = Task {
            try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: recordOnly),
                                            dependencies: .testing(captures: captures, postProcess: hook))
        }
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
        run.cancel()
        do {
            _ = try await run.value
            Issue.record("A cancelled recording must throw.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        let directory = try #require(sessionFolders(in: temp.url).first)
        let manifest = try SessionArchive.readManifest(at: directory)
        #expect(manifest.status == (recordOnly ? ArchiveStatus.audioOnly : ArchiveStatus.transcriptionIncomplete))
        #expect(manifest.chunks.count == 1, "All captured audio is saved.")
        #expect(manifest.chunks.first?.frameCount == 14_400)
        let events = try SessionArchive.readEvents(at: directory).events
        #expect(!events.contains { $0.kind == MeetingEventKind.captureFailed })
        #expect(events.first { $0.kind == MeetingEventKind.captureStopped }?.details["cancelled"] == "true")
        #expect(try SessionArchive.currentTranscriptID(at: directory) == nil, "No partial transcript is published.")
        #expect(hookCalls.value == 0)
        #expect(captures.captures.first?.stopCalls == 1)
        #expect(try !SessionArchive.isActive(at: directory))
        #expect(try !SessionArchive.isProcessing(at: directory))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.json").path))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func noHookMeansNoLease() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let outcome = try await record(.testing(root: temp.url), captures: threeMicFrames(), postProcess: nil,
                                   stopAfterConsuming: 3)
    #expect(outcome.postProcessing == nil)
    #expect(!FileManager.default.fileExists(atPath: outcome.directory.appendingPathComponent(".processing.lock").path))
    #expect(try !SessionArchive.isProcessing(at: outcome.directory))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func leaseHeldElsewhereSkipsPostProcessing() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let calls = SharedValue(0)
    let hook: PostProcessHook = { session, _, _ in
        calls.update { $0 += 1 }
        return fakeRecord(session)
    }
    let captures = threeMicFrames()
    let stop = ManualStopSource()
    let reporter = CollectingReporter()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: .testing(captures: captures, postProcess: hook, stop: stop, reporter: reporter))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
    let directory = try #require(sessionFolders(in: temp.url).first)
    let other = try SessionArchive.acquireProcessingLease(at: directory)
    defer { other.release() }
    stop.requestStop()
    let outcome = try await run.value
    #expect(outcome.postProcessing == nil)
    #expect(calls.value == 0)
    #expect(reporter.messages.contains("Another Holos process is labelling this meeting."))
    #expect(outcome.archiveStatus == ArchiveStatus.audioOnly)
    #expect(try SessionArchive.readManifest(at: directory).status == ArchiveStatus.audioOnly)
    #expect(try !SessionArchive.isActive(at: directory))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func hookProgressMessagesReachTheReporterOnce() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let hook: PostProcessHook = { session, _, progress in
        progress(PostProcessingProgress(stage: .render, track: "mic", fraction: 0, message: "Preparing audio…"))
        progress(PostProcessingProgress(stage: .render, track: "mic", fraction: 0.5, message: "Preparing audio…"))
        progress(PostProcessingProgress(stage: .diarize, track: "mic", fraction: 0, message: "Labelling speakers…"))
        return fakeRecord(session)
    }
    let reporter = CollectingReporter()
    _ = try await record(.testing(root: temp.url, recordOnly: true), captures: threeMicFrames(), postProcess: hook,
                         reporter: reporter, stopAfterConsuming: 3)
    let progress = reporter.messages.filter { $0 == "Preparing audio…" || $0 == "Labelling speakers…" }
    #expect(progress == ["Preparing audio…", "Labelling speakers…"])
}

// MARK: - Vocabulary and replay

@Test(.timeLimit(.minutes(1))) @MainActor
func vocabularyReachesSpeechFactory() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let replayed = TranscriptSegment(start: 0, end: 0.2, text: "Maria Chen moved the motion")
    let speech = FakeSpeechFactory([FakeSpeechScript(appendError: .unavailable("The recognizer stopped.")),
                                    FakeSpeechScript(segments: [replayed])])
    let outcome = try await record(.testing(root: temp.url, vocabulary: ["Maria Chen"]), captures: threeMicFrames(),
                                   speech: speech, stopAfterConsuming: 3)
    #expect(speech.calls.map(\.contextualStrings) == [["Maria Chen"], ["Maria Chen"]], "Live, then replay.")
    #expect(speech.sessions.map(\.contextualStrings) == [["Maria Chen"], ["Maria Chen"]])
    #expect(try transcript(outcome).segments.map(\.text) == ["Maria Chen moved the motion"])
}

@Test(.timeLimit(.minutes(1)))
func replayFromSkipsEarlierAudio() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let sampleRate = 8_000.0
    let archive = try SessionArchive.create(root: temp.url, name: "Replay", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    let writer = AudioChunkWriter(archive: archive, chunkDuration: 30)
    for second in 0..<60 {
        let frame = try PCMFrame(samples: [Float](repeating: 0.1, count: Int(sampleRate)), sampleRate: sampleRate,
                                 channels: 1, startTime: Double(second))
        try await writer.append(CapturedAudio(track: "mic", frame: frame))
    }
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let chunks = try SessionArchive.readManifest(at: archive.directory).chunks.sorted { $0.start < $1.start }
    #expect(chunks.map(\.start) == [0, 30])
    #expect(chunks.map(\.end) == [30, 60])

    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [TranscriptSegment(start: 0.5, end: 1, text: "Item four")])])
    let segments = try await TrackReplayer.replay(directory: archive.directory, track: "mic", locale: "en-CA",
                                                  backend: .speech, contextualStrings: ["Strata"], from: 40,
                                                  makeSpeech: speech.factory)
    #expect(segments.map(\.text) == ["Item four"])
    #expect(segments.map(\.track) == ["mic"])
    #expect(speech.calls == [FakeSpeechFactory.Call(locale: "en-CA", backend: .speech, contextualStrings: ["Strata"])])
    let session = try #require(speech.sessions.first)
    let starts = await session.frameStarts
    let buffer = Double(4096) / sampleRate
    let first = try #require(starts.first)
    #expect(abs(first - 40) <= buffer)
    #expect(starts.allSatisfy { $0 >= 40 - buffer }, "No audio before `from` is fed.")
    #expect(await abs(session.fedSeconds - 20) <= buffer)
}

@Test(.timeLimit(.minutes(1)))
func replayFromEndOfAudioFeedsNothing() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Replay", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    let writer = AudioChunkWriter(archive: archive)
    let frame = try PCMFrame(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 8_000, channels: 1, startTime: 0)
    try await writer.append(CapturedAudio(track: "mic", frame: frame))
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let speech = FakeSpeechFactory()
    let segments = try await TrackReplayer.replay(directory: archive.directory, track: "mic", locale: "en-CA",
                                                  backend: .speech, from: 1, makeSpeech: speech.factory)
    #expect(segments.isEmpty)
    let session = try #require(speech.sessions.first)
    #expect(await session.frameStarts.isEmpty)
    #expect(await session.finishCalls == 1)
    await #expect(throws: HolosError.self) {
        try await TrackReplayer.replay(directory: archive.directory, track: "mic", locale: "en-CA",
                                       backend: .speech, from: .nan, makeSpeech: speech.factory)
    }
}

// MARK: - MeetingPostProcessor start checks

@Test(.timeLimit(.minutes(1)))
func postProcessorWithoutTranscriptIsSkipped() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try await finishedArchive(in: temp.url)
    let before = contents(of: archive.directory)
    let progressCalls = SharedValue(0)
    let record = try await MeetingPostProcessor().run(session: archive.directory, lease: nil) { _ in
        progressCalls.update { $0 += 1 }
    }
    #expect(record.state == .skipped)
    #expect(record.sessionID == archive.id)
    #expect(record.pid == getpid())
    #expect(record.stages.map(\.stage) == [.transcript])
    #expect(record.runID == nil)
    #expect(record.message != nil)
    // Only the lease's lock file and postprocess.json appear; nothing is exported without a transcript.
    #expect(contents(of: archive.directory).subtracting([".processing.lock", "postprocess.json"]) == before)
    #expect(try !SessionArchive.isProcessing(at: archive.directory), "A lease run acquired is released.")
    #expect(progressCalls.value >= 1)

    let withDiarizer = MeetingPostProcessor(diarizer: FakeDiarizer(outputs: [:]),
                                            options: PostProcessingOptions(speakers: SpeakerCountHint(minimum: 2)),
                                            freeSpace: FixedFreeSpace(.max))
    #expect(try await withDiarizer.run(session: archive.directory, lease: nil).state == .skipped)
    #expect(contents(of: archive.directory).subtracting([".processing.lock", "postprocess.json"]) == before)
}

@Test(.timeLimit(.minutes(1)))
func postProcessorKeepsTheCallersLease() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let archive = try await finishedArchive(in: temp.url)
    let lease = try SessionArchive.acquireProcessingLease(at: archive.directory)
    defer { lease.release() }
    let record = try await MeetingPostProcessor().run(session: archive.directory, lease: lease)
    #expect(record.state == .skipped)
    #expect(try SessionArchive.isProcessing(at: archive.directory), "The caller still owns its lease.")
    lease.release()
    #expect(try !SessionArchive.isProcessing(at: archive.directory))
}

@Test(.timeLimit(.minutes(1)))
func postProcessorRefusesWhenItCannotStart() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    // Still recording: the writer lock is held.
    let recording = try SessionArchive.create(root: temp.url, name: "Live", source: .microphone,
                                              locale: "en-CA", backend: .speech)
    await #expect(throws: HolosError.self) {
        try await MeetingPostProcessor().run(session: recording.directory, lease: nil)
    }
    try await recording.finish(status: ArchiveStatus.complete)

    // A lease for another session.
    let other = try await finishedArchive(in: temp.url)
    let foreign = try SessionArchive.acquireProcessingLease(at: other.directory)
    defer { foreign.release() }
    await #expect(throws: HolosError.self) {
        try await MeetingPostProcessor().run(session: recording.directory, lease: foreign)
    }

    // A lease that was already released.
    let released = try SessionArchive.acquireProcessingLease(at: recording.directory)
    released.release()
    await #expect(throws: HolosError.self) {
        try await MeetingPostProcessor().run(session: recording.directory, lease: released)
    }

    // The lease is held elsewhere (acquisition retries for 1 s, then gives up).
    let held = try SessionArchive.acquireProcessingLease(at: recording.directory)
    defer { held.release() }
    await #expect(throws: HolosError.self) {
        try await MeetingPostProcessor().run(session: recording.directory, lease: nil)
    }
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.postprocess(recording.directory).path))
}
