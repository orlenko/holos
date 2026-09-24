import Foundation
import HolosAudio
import HolosCore
import HolosMeeting
import Synchronization

// Shared test helpers for HolosMeetingTests. Only the first-merged PR of each wave edits this file
// (docs/meeting-design.md §1.8); other PRs declare their helpers `fileprivate`, or in
// `<Component>TestSupport.swift` with names prefixed by the component.

// MARK: - General helpers

/// A value shared between a test and the closures or tasks it hands to the code under test.
final class SharedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    var value: Value { mutex.withLock { $0 } }

    func set(_ newValue: Value) { mutex.withLock { $0 = newValue } }

    @discardableResult
    func update<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

/// A private folder `FileManager.default.temporaryDirectory/holos-<area>-<UUID>`. Remove it with
/// `defer { temp.remove() }`.
struct TemporaryDirectory: Sendable {
    let url: URL

    init(_ area: String = "meeting") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-\(area)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Polls `condition` every 5 ms until it holds or `timeout` passes, and returns its last value. The default is
/// generous so a heavily loaded machine (many test runs in parallel) still passes; a condition that holds returns at
/// once, so only a failing test waits that long.
@MainActor
func eventually(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// The `.holos` session folders directly inside `root`, sorted by name.
func sessionFolders(in root: URL) -> [URL] {
    let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return contents.filter { $0.pathExtension == "holos" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

// MARK: - Capture

/// One scripted capture frame of constant samples. `start` is on the fake capture's own clock; the frame
/// the capture delivers starts at `start + CaptureRequest.timelineOffset`.
struct FakeFrame: Sendable, Equatable {
    var track: String
    var start: Double
    var duration: Double
    var sampleRate: Double
    var channels: Int
    var value: Float

    init(track: String = "mic", start: Double, duration: Double = 0.1, sampleRate: Double = 48_000,
         channels: Int = 1, value: Float = 0.1) {
        self.track = track; self.start = start; self.duration = duration
        self.sampleRate = sampleRate; self.channels = channels; self.value = value
    }

    /// `count` contiguous frames of `duration` seconds from `start`.
    static func run(track: String = "mic", from start: Double = 0, count: Int, duration: Double = 0.1,
                    sampleRate: Double = 48_000) -> [FakeFrame] {
        let template = FakeFrame(track: track, start: start, duration: duration, sampleRate: sampleRate)
        return (0..<count).map { index in
            var frame = template
            frame.start = start + Double(index * template.frameCount) / sampleRate
            return frame
        }
    }

    var frameCount: Int { max(1, Int((duration * sampleRate).rounded())) }

    /// Seconds the frame's samples cover.
    var length: Double { Double(frameCount) / sampleRate }

    func captured(offset: Double) throws -> CapturedAudio {
        let frame = try PCMFrame(samples: [Float](repeating: value, count: frameCount * channels),
                                 sampleRate: sampleRate, channels: channels, startTime: start + offset)
        return CapturedAudio(track: track, frame: frame)
    }
}

/// What one fake capture epoch does.
struct FakeCaptureScript: Sendable {
    /// Delivered in order, each as soon as the consumer asks for the next frame.
    var frames: [FakeFrame]
    /// After the scripted frames, keep delivering frames like this one (its `start` is ignored; frames follow
    /// on from the last one), one per `duration` of real time, until `stop()`.
    var continuous: FakeFrame?
    /// The stream throws `failure` once this many frames have been delivered.
    var failAfterFrames: Int?
    var failure: HolosError
    /// `start` throws this.
    var startError: HolosError?
    /// `start` throws `CancellationError` (without the calling task being cancelled).
    var startCancels: Bool
    /// `stop()` takes this long before the stream finishes, like a platform stop that hangs.
    var stopDelay: Duration?
    var hostTimeOrigin: Double

    init(frames: [FakeFrame] = [], continuous: FakeFrame? = nil, failAfterFrames: Int? = nil,
         failure: HolosError = .incomplete("The fake capture failed."), startError: HolosError? = nil,
         stopDelay: Duration? = nil, hostTimeOrigin: Double = 1_000, startCancels: Bool = false) {
        self.frames = frames; self.continuous = continuous; self.failAfterFrames = failAfterFrames
        self.failure = failure; self.startError = startError; self.stopDelay = stopDelay
        self.hostTimeOrigin = hostTimeOrigin; self.startCancels = startCancels
    }
}

/// A scripted `MeetingCapture`. Its stream is pull-based: a frame is produced when the consumer asks for it,
/// so `consumedFrames` tells a test how many frames the consumer has finished handling.
@MainActor
final class FakeCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    let script: FakeCaptureScript
    private(set) var requests: [CaptureRequest] = []
    private(set) var stopCalls = 0
    /// Buffers this fake pretends it dropped (MeetingCapture gains `droppedBuffers` in PR2a).
    var droppedBuffers = 0
    private let state: FakeCaptureState

    init(script: FakeCaptureScript = FakeCaptureScript()) {
        self.script = script
        let state = FakeCaptureState()
        self.state = state
        frames = AsyncThrowingStream(unfolding: { try await state.next(script) })
    }

    var hostTimeOrigin: Double { script.hostTimeOrigin }

    /// Frames handed to the consumer so far.
    nonisolated var deliveredFrames: Int { state.delivered }

    /// Frames the consumer has finished with: it has asked for the frame after them.
    nonisolated var consumedFrames: Int { state.consumed }

    func start(_ request: CaptureRequest) async throws {
        requests.append(request)
        if let error = script.startError { throw error }
        if script.startCancels { throw CancellationError() }
        state.start(offset: request.timelineOffset)
    }

    func stop() async throws {
        stopCalls += 1
        if let delay = script.stopDelay { try? await Task.sleep(for: delay) }
        state.stop()
    }
}

/// The mutable part of a `FakeCapture`, shared with its stream.
final class FakeCaptureState: Sendable {
    private struct Inner {
        var started = false
        var stopped = false
        var offset = 0.0
        var delivered = 0
        var consumed = 0
        var nextContinuousStart: Double?
    }

    private enum Step {
        case wait, end, fail
        case deliver(FakeFrame, offset: Double)
        case pace(FakeFrame, offset: Double)
    }

    private let inner = Mutex(Inner())

    var delivered: Int { inner.withLock { $0.delivered } }
    var consumed: Int { inner.withLock { $0.consumed } }

    func start(offset: Double) {
        inner.withLock { $0.started = true; $0.offset = offset }
    }

    func stop() { inner.withLock { $0.stopped = true } }

    func next(_ script: FakeCaptureScript) async throws -> CapturedAudio? {
        inner.withLock { $0.consumed = $0.delivered }
        while true {
            let step: Step = inner.withLock { state in
                if state.stopped { return .end }
                guard state.started else { return .wait }
                if let limit = script.failAfterFrames, state.delivered >= limit {
                    state.stopped = true
                    return .fail
                }
                if state.delivered < script.frames.count {
                    let frame = script.frames[state.delivered]
                    state.delivered += 1
                    return .deliver(frame, offset: state.offset)
                }
                if var frame = script.continuous {
                    frame.start = state.nextContinuousStart ?? script.frames.last.map { $0.start + $0.length } ?? 0
                    return .pace(frame, offset: state.offset)
                }
                return .wait
            }
            switch step {
            case .end:
                return nil
            case .fail:
                throw script.failure
            case .deliver(let frame, let offset):
                return try frame.captured(offset: offset)
            case .wait:
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(2))
            case .pace(let frame, let offset):
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .seconds(frame.length))
                let deliver = inner.withLock { state -> Bool in
                    guard !state.stopped else { return false }
                    state.delivered += 1
                    state.nextContinuousStart = frame.start + frame.length
                    return true
                }
                return deliver ? try frame.captured(offset: offset) : nil
            }
        }
    }
}

/// Hands out a new `FakeCapture` per epoch: epoch n gets `scripts[n]`, or an empty script past the end.
@MainActor
final class FakeCaptureFactory {
    private let scripts: [FakeCaptureScript]
    private(set) var captures: [FakeCapture] = []

    init(_ scripts: [FakeCaptureScript] = []) { self.scripts = scripts }

    func make() -> any MeetingCapture {
        let script = captures.count < scripts.count ? scripts[captures.count] : FakeCaptureScript()
        let capture = FakeCapture(script: script)
        captures.append(capture)
        return capture
    }

    /// Every `CaptureRequest` any of its captures received, in order.
    var requests: [CaptureRequest] { captures.flatMap(\.requests) }
}

// MARK: - Speech

/// What one fake speech session does.
struct FakeSpeechScript: Sendable {
    /// Returned by `finish()`, with times relative to the session's first frame. Each segment is also
    /// reported as a final update once the audio fed to the session reaches its end; the rest at `finish()`.
    var segments: [TranscriptSegment]
    /// The factory throws this instead of creating the session.
    var makeError: HolosError?
    /// `append` throws this…
    var appendError: HolosError?
    /// …once this many seconds of audio were fed (nil: from the first frame).
    var appendErrorAfter: Double?
    /// `finish()` waits this long first.
    var finishDelay: Duration?
    /// `finish()` does not return until `cancel()`; it then throws `CancellationError`.
    var finishHangs: Bool
    /// `finish()` throws this, without reporting the segments not yet reported.
    var finishError: HolosError?

    init(segments: [TranscriptSegment] = [], makeError: HolosError? = nil, appendError: HolosError? = nil,
         finishDelay: Duration? = nil, finishHangs: Bool = false, appendErrorAfter: Double? = nil,
         finishError: HolosError? = nil) {
        self.segments = segments; self.makeError = makeError; self.appendError = appendError
        self.finishDelay = finishDelay; self.finishHangs = finishHangs
        self.appendErrorAfter = appendErrorAfter; self.finishError = finishError
    }
}

/// A scripted `LiveSpeechSession` that records what it was given.
actor FakeSpeech: LiveSpeechSession {
    nonisolated let locale: String
    nonisolated let backend: SpeechBackend
    nonisolated let contextualStrings: [String]
    private let script: FakeSpeechScript
    private let onUpdate: @Sendable (TranscriptUpdate) -> Void
    /// Start times of the frames fed, in order.
    private(set) var frameStarts: [Double] = []
    /// Seconds of audio fed.
    private(set) var fedSeconds = 0.0
    private(set) var finishCalls = 0
    private(set) var cancelled = false
    private var firstStart: Double?
    private var reported: Set<Int> = []

    init(locale: String, backend: SpeechBackend, contextualStrings: [String], script: FakeSpeechScript,
         onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) {
        self.locale = locale; self.backend = backend; self.contextualStrings = contextualStrings
        self.script = script; self.onUpdate = onUpdate
    }

    func append(_ frame: PCMFrame) async throws {
        if cancelled { throw CancellationError() }
        if let error = script.appendError, fedSeconds >= (script.appendErrorAfter ?? 0) - 1e-9 { throw error }
        frameStarts.append(frame.startTime)
        fedSeconds += frame.duration
        let base = firstStart ?? frame.startTime
        firstStart = base
        report(through: frame.startTime + frame.duration - base)
    }

    func finish() async throws -> [TranscriptSegment] {
        finishCalls += 1
        if let delay = script.finishDelay { try await Task.sleep(for: delay) }
        if script.finishHangs {
            while !cancelled { try await Task.sleep(for: .milliseconds(5)) }
        }
        if cancelled { throw CancellationError() }
        if let error = script.finishError { throw error }
        report(through: .infinity)
        return script.segments
    }

    func cancel() async { cancelled = true }

    private func report(through end: Double) {
        for (index, segment) in script.segments.enumerated() where !reported.contains(index) && segment.end <= end + 1e-9 {
            reported.insert(index)
            onUpdate(TranscriptUpdate(segment: segment, isFinal: true))
        }
    }
}

/// A `LiveSpeechFactory` whose n-th call uses `scripts[n]` (an empty script past the end). It records every
/// call, including calls that throw.
final class FakeSpeechFactory: Sendable {
    struct Call: Sendable, Equatable {
        var locale: String
        var backend: SpeechBackend
        var contextualStrings: [String]
    }

    private struct State {
        var calls: [Call] = []
        var sessions: [FakeSpeech] = []
    }

    private let scripts: [FakeSpeechScript]
    private let state = Mutex(State())

    init(_ scripts: [FakeSpeechScript] = []) { self.scripts = scripts }

    var factory: LiveSpeechFactory {
        { locale, backend, contextualStrings, onUpdate in
            try self.make(locale: locale, backend: backend, contextualStrings: contextualStrings, onUpdate: onUpdate)
        }
    }

    var calls: [Call] { state.withLock { $0.calls } }

    /// Sessions created, in order (calls that threw created none).
    var sessions: [FakeSpeech] { state.withLock { $0.sessions } }

    private func make(locale: String, backend: SpeechBackend, contextualStrings: [String],
                      onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) throws -> FakeSpeech {
        let script = state.withLock { state -> FakeSpeechScript in
            let index = state.calls.count
            state.calls.append(Call(locale: locale, backend: backend, contextualStrings: contextualStrings))
            return index < scripts.count ? scripts[index] : FakeSpeechScript()
        }
        if let error = script.makeError { throw error }
        let session = FakeSpeech(locale: locale, backend: backend, contextualStrings: contextualStrings,
                                 script: script, onUpdate: onUpdate)
        state.withLock { $0.sessions.append(session) }
        return session
    }
}

// MARK: - Reporter and dependency bundles

/// A `RecordingReporter` that keeps everything it is told.
final class CollectingReporter: RecordingReporter {
    struct Phrase: Sendable, Equatable {
        var track: String
        var segment: TranscriptSegment
    }

    private struct State {
        var phrases: [Phrase] = []
        var messages: [String] = []
    }

    private let state = Mutex(State())

    func phrase(_ segment: TranscriptSegment, track: String) {
        state.withLock { $0.phrases.append(Phrase(track: track, segment: segment)) }
    }

    func message(_ text: String) { state.withLock { $0.messages.append(text) } }

    var phrases: [Phrase] { state.withLock { $0.phrases } }
    var messages: [String] { state.withLock { $0.messages } }
}

extension RecordingDependencies {
    /// Fakes only: no microphone, speech assets, or signal handlers.
    static func testing(captures: FakeCaptureFactory, speech: FakeSpeechFactory = FakeSpeechFactory(),
                        postProcess: PostProcessHook? = nil, stop: any RecorderStopSource = ManualStopSource(),
                        reporter: any RecordingReporter = CollectingReporter()) -> RecordingDependencies {
        RecordingDependencies(makeCapture: { captures.make() }, makeSpeech: speech.factory, stop: stop,
                              reporter: reporter, postProcess: postProcess)
    }
}

extension RecordingOptions {
    /// An en-CA Speech recording named "Test meeting" into `root`.
    static func testing(root: URL, source: AudioSource = .microphone, duration: Double? = nil,
                        recordOnly: Bool = false, applicationBundleID: String? = nil,
                        vocabulary: [String] = []) -> RecordingOptions {
        RecordingOptions(name: "Test meeting", source: source, locale: "en-CA", backend: .speech, root: root,
                         duration: duration, recordOnly: recordOnly, applicationBundleID: applicationBundleID,
                         vocabulary: vocabulary)
    }
}
