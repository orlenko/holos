import Foundation
import HolosAudio
import HolosCore
import HolosMeeting
import HolosStorage
import Testing

// Table-driven: every await point of `RecordingWorkflow.run`, with a fake that, at that point, (a) cancels the
// run and throws `CancellationError`, (b) throws `CancellationError` without the run being cancelled, or (c)
// fails with an ordinary error. (a) and (b) must follow the cancellation contract; (c) the failure statuses.
// One exception since PR2a (docs/meeting-design.md §4.2): a frame stream that ends with an error of its own,
// `CancellationError` included, is a capture failure, and capture restarts in a new epoch.

// MARK: - Table

private enum AwaitPoint: String, Sendable {
    case captureStart, captureStop, frames, speechAppend, speechFinish, replay, lease, hook
}

private enum FaultMode: String, Sendable {
    /// The run is cancelled at the await point, and the dependency throws `CancellationError`.
    case cancelled
    /// The dependency throws `CancellationError`; the run itself is not cancelled.
    case cancellationError
    /// The dependency fails with an ordinary error.
    case failure
}

private struct PointCase: Sendable, CustomTestStringConvertible {
    var point: AwaitPoint
    var mode: FaultMode
    var recordOnly: Bool

    var testDescription: String { "\(point.rawValue), \(mode.rawValue)\(recordOnly ? ", record-only" : "")" }

    static let all: [PointCase] = {
        var cases: [PointCase] = []
        for point in [AwaitPoint.captureStart, .captureStop, .frames] {
            for mode in [FaultMode.cancelled, .cancellationError, .failure] {
                for recordOnly in [false, true] { cases.append(PointCase(point: point, mode: mode, recordOnly: recordOnly)) }
            }
        }
        // Speech needs a transcribed recording.
        for point in [AwaitPoint.speechAppend, .speechFinish, .replay] {
            for mode in [FaultMode.cancelled, .cancellationError, .failure] {
                cases.append(PointCase(point: point, mode: mode, recordOnly: false))
            }
        }
        // Neither the lease nor the hook can throw into the run: only a cancellation during them, or their failure.
        for point in [AwaitPoint.lease, .hook] {
            for mode in [FaultMode.cancelled, .failure] {
                for recordOnly in [false, true] { cases.append(PointCase(point: point, mode: mode, recordOnly: recordOnly)) }
            }
        }
        return cases
    }()
}

// MARK: - Fakes

/// Raises the scripted fault. `run` is set right after the run's task is created, before it starts.
private final class Fault: Sendable {
    let mode: FaultMode
    let run = SharedValue<Task<RecordingOutcome, Error>?>(nil)

    init(_ mode: FaultMode) { self.mode = mode }

    func error() -> Error {
        switch mode {
        case .cancelled:
            run.value?.cancel()
            return CancellationError()
        case .cancellationError:
            return CancellationError()
        case .failure:
            return HolosError.io("Injected failure.")
        }
    }
}

private enum FrameStep: Sendable {
    case end, wait, fail
    case deliver(Int)
}

/// Three mic frames, delivered as the consumer asks for them once capture starts. With `fault`, the stream
/// throws its error when asked for a fourth frame.
private final class FaultyFrames: Sendable {
    private struct State: Sendable {
        var started = false
        var stopped = false
        var delivered = 0
        var consumed = 0
        var faulted = false
    }

    static let frames = FakeFrame.run(count: 3)
    private let state = SharedValue(State())
    private let fault: Fault?

    init(fault: Fault?) { self.fault = fault }

    /// Frames the consumer has finished with.
    var consumed: Int { state.value.consumed }

    func start() { state.update { $0.started = true } }
    func stop() { state.update { $0.stopped = true } }

    func next() async throws -> CapturedAudio? {
        state.update { $0.consumed = $0.delivered }
        let hasFault = fault != nil
        while true {
            let step: FrameStep = state.update { state in
                if state.stopped { return .end }
                guard state.started else { return .wait }
                if state.delivered < Self.frames.count {
                    state.delivered += 1
                    return .deliver(state.delivered - 1)
                }
                if hasFault, !state.faulted {
                    state.faulted = true
                    return .fail
                }
                return .wait
            }
            switch step {
            case .end: return nil
            case .fail: throw fault?.error() ?? CancellationError()
            case .deliver(let index): return try Self.frames[index].captured(offset: 0)
            case .wait:
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}

@MainActor
private final class FaultyCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    private let source: FaultyFrames
    private let point: AwaitPoint
    private let fault: Fault

    init(source: FaultyFrames, point: AwaitPoint, fault: Fault) {
        self.source = source; self.point = point; self.fault = fault
        frames = AsyncThrowingStream(unfolding: { try await source.next() })
    }

    var hostTimeOrigin: Double { 1_000 }

    func start(_ request: CaptureRequest) async throws {
        if point == .captureStart { throw fault.error() }
        source.start()
    }

    /// Ends the stream first, like a platform stop that fails after stopping, so the consumer can drain.
    func stop() async throws {
        source.stop()
        if point == .captureStop { throw fault.error() }
    }
}

private actor FaultySpeech: LiveSpeechSession {
    private let point: AwaitPoint
    private let fault: Fault
    private var cancelled = false

    init(point: AwaitPoint, fault: Fault) { self.point = point; self.fault = fault }

    func append(_ frame: PCMFrame) async throws {
        if cancelled { throw CancellationError() }
        if point == .speechAppend { throw fault.error() }
    }

    func finish() async throws -> [TranscriptSegment] {
        if cancelled { throw CancellationError() }
        if point == .speechFinish { throw fault.error() }
        return []
    }

    func cancel() async { cancelled = true }
}

/// Stops once the consumer has finished with every frame, `enabled` holds, and `gate` is open.
private final class AfterFramesStop: RecorderStopSource {
    let source: FaultyFrames
    let enabled: @Sendable () -> Bool
    let gate: SharedValue<Bool>

    init(source: FaultyFrames, enabled: @escaping @Sendable () -> Bool, gate: SharedValue<Bool>) {
        self.source = source; self.enabled = enabled; self.gate = gate
    }

    var shouldStop: Bool { enabled() && gate.value && source.consumed >= FaultyFrames.frames.count }
    func restoreDefaultHandlers() {}
}

private func isIncomplete(_ error: Error) -> Bool {
    if case .incomplete? = error as? HolosError { return true }
    return false
}

// MARK: - Test

@Test(.timeLimit(.minutes(1)), arguments: PointCase.all) @MainActor
private func cancellationAtEachAwaitPoint(_ c: PointCase) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let point = c.point
    let fault = Fault(c.mode)
    let frames = FaultyFrames(fault: point == .frames ? fault : nil)
    let speechCalls = SharedValue(0)
    let speech: LiveSpeechFactory = { _, _, _, _ in
        let call = speechCalls.update { count -> Int in count += 1; return count }
        if point == .replay {
            // Live speech is unavailable, so the track is replayed; the replay's session cannot be created.
            if call == 1 { throw HolosError.unavailable("Live speech is unavailable.") }
            throw fault.error()
        }
        return FaultySpeech(point: point, fault: fault)
    }
    let hookCalls = SharedValue(0)
    let mode = c.mode
    let hook: PostProcessHook = { session, _, _ in
        hookCalls.update { $0 += 1 }
        var state = PostProcessingState.succeeded
        if point == .hook {
            if mode == .failure { state = .failed } else { _ = fault.error() }
        }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: state,
                                    pid: 1, startedAt: date, updatedAt: date, message: nil)
    }
    let usesHook = point == .lease || point == .hook
    // The lease rows open the gate once another holder has the processing lease.
    let gate = SharedValue(point != .lease)
    let captures = SharedValue(0)
    // A failed frame stream restarts capture: those rows stop once the next epoch's capture exists. A cancelled
    // run needs no stop.
    let stop = AfterFramesStop(source: frames, enabled: {
        point != .frames || (mode != .cancelled && captures.value >= 2)
    }, gate: gate)
    let dependencies = RecordingDependencies(
        makeCapture: {
            captures.update { $0 += 1 }
            return FaultyCapture(source: frames, point: point, fault: fault)
        }, makeSpeech: speech,
        stop: stop, reporter: CollectingReporter(), postProcess: usesHook ? hook : nil)
    let options = RecordingOptions.testing(root: temp.url, recordOnly: c.recordOnly)
    let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
    fault.run.set(run)

    var other: ProcessingLease?
    if point == .lease {
        #expect(await eventually { frames.consumed >= 1 })
        let folder = try #require(sessionFolders(in: temp.url).first)
        other = try SessionArchive.acquireProcessingLease(at: folder)
        gate.set(true)
        if c.mode == .cancelled {
            // The run records captureStopped, then waits for the lease (1 s): cancel it there.
            let waiting = await eventually {
                let events = (try? SessionArchive.readEvents(at: folder).events) ?? []
                return events.contains { $0.kind == MeetingEventKind.captureStopped }
            }
            #expect(waiting)
            run.cancel()
            other?.release()
        }
    }
    let result = await run.result
    other?.release()

    let directory = try #require(sessionFolders(in: temp.url).first)
    let manifest = try SessionArchive.readManifest(at: directory)
    let events = try SessionArchive.readEvents(at: directory).events
    let stopped = events.first { $0.kind == MeetingEventKind.captureStopped }
    let captureFailed = events.contains { $0.kind == MeetingEventKind.captureFailed }
    let untranscribed = c.recordOnly ? ArchiveStatus.audioOnly : ArchiveStatus.transcriptionIncomplete
    let finished = c.recordOnly ? ArchiveStatus.audioOnly : ArchiveStatus.complete

    switch (point, c.mode) {
    case (.captureStart, .failure):
        #expect(throws: HolosError.self) { try result.get() }
        #expect(manifest.status == ArchiveStatus.failed)
        let started = events.first { $0.kind == MeetingEventKind.startFailed }
        #expect(started != nil && started?.details["cancelled"] == nil)
    case (.captureStart, _):
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(manifest.status == ArchiveStatus.failed)
        #expect(events.first { $0.kind == MeetingEventKind.startFailed }?.details["cancelled"] == "true")
        #expect(!events.contains { $0.kind == MeetingEventKind.captureStarted })
    case (.frames, .failure), (.frames, .cancellationError):
        // §4.2: the failed stream is a capture failure; capture restarts in epoch 1 and the recording goes on.
        let outcome = try result.get()
        #expect(outcome.archiveStatus == finished)
        #expect(manifest.status == finished)
        #expect(captureFailed)
        #expect(events.contains { $0.kind == MeetingEventKind.captureStarted && $0.details["epoch"] == "1" })
        #expect(!manifest.chunks.isEmpty, "Audio saved before the failure is kept.")
        #expect(stopped != nil && stopped?.details["cancelled"] == nil)
    case (.captureStop, .failure):
        do {
            _ = try result.get()
            Issue.record("A capture failure must throw.")
        } catch {
            #expect(isIncomplete(error), "Expected HolosError.incomplete, got \(error).")
        }
        #expect(manifest.status == ArchiveStatus.incomplete)
        #expect(captureFailed)
        #expect(!manifest.chunks.isEmpty, "Audio saved before the failure is kept.")
    case (.lease, .failure), (.hook, .failure):
        let outcome = try result.get()
        #expect(outcome.archiveStatus == finished)
        #expect(manifest.status == finished)
        if point == .lease {
            #expect(outcome.postProcessing == nil, "A lease held elsewhere skips post-processing.")
            #expect(hookCalls.value == 0)
        } else {
            #expect(outcome.postProcessing?.state == .failed)
            #expect(hookCalls.value == 1)
        }
    case (.lease, _), (.hook, _):
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(manifest.status == finished, "The archive was finished before post-processing.")
        #expect(hookCalls.value == (point == .lease ? 0 : 1))
        #expect(!captureFailed)
        #expect(stopped != nil && stopped?.details["cancelled"] == nil)
        #expect(try (SessionArchive.currentTranscriptID(at: directory) != nil) == !c.recordOnly)
    case (_, .failure):
        // Speech: the live track and its replay both fail; the audio is kept and the run returns.
        let outcome = try result.get()
        #expect(outcome.archiveStatus == ArchiveStatus.transcriptionIncomplete)
        #expect(manifest.status == ArchiveStatus.transcriptionIncomplete)
        #expect(!outcome.transcriptErrors.isEmpty)
        let transcriptionErrors = stopped?.details["transcriptionErrors"] ?? ""
        #expect(!transcriptionErrors.isEmpty)
        #expect(stopped?.details["cancelled"] == nil)
        #expect(!captureFailed)
    default:
        // Cancelled once capture started: the audio is kept, no partial transcript, no capture failure.
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(manifest.status == untranscribed)
        #expect(!manifest.chunks.isEmpty, "The saved audio is kept.")
        #expect(!captureFailed, "A cancellation is not a capture failure.")
        #expect(stopped?.details["cancelled"] == "true")
        #expect(try SessionArchive.currentTranscriptID(at: directory) == nil)
    }
    #expect(try !SessionArchive.isActive(at: directory))
    #expect(try !SessionArchive.isProcessing(at: directory))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.json").path))
}
