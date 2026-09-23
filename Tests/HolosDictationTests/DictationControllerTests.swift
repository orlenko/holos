import Foundation
import Testing
import HolosCore
import HolosAudio
@testable import HolosDictation

@Test @MainActor func deniedPermissionNeverStartsCapture() {
    var updates: [DictationStatus] = []
    let dependencies = DictationDependencies(permission: { "denied" },
        makeCapture: { fatalError("capture must not start") },
        makeSpeech: { _, _, _ in fatalError("speech must not start") })
    let controller = DictationController(dependencies: dependencies) { updates.append($0) }
    #expect(controller.begin())
    #expect(updates.map(\.phase) == [.preparing, .failed])
    #expect(controller.status.utteranceID != nil)
    #expect(controller.status.message?.contains("System Settings") == true)
}

@MainActor
private final class FakeCapture: DictationCapture {
    private let pair = AsyncThrowingStream<CapturedAudio, Error>.makeStream()
    var frames: AsyncThrowingStream<CapturedAudio, Error> { pair.stream }
    var holdStart = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var startError: Error?
    var starts = 0
    var stops = 0

    func start() async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startWaiter = $0 } }
        if let startError { throw startError }
    }

    func stop() async throws {
        stops += 1
        pair.continuation.finish()
    }

    func releaseStart() { startWaiter?.resume(); startWaiter = nil }
    func fail(_ error: Error) { pair.continuation.finish(throwing: error) }
    func emit(_ frame: PCMFrame) { pair.continuation.yield(CapturedAudio(track: "mic", frame: frame)) }
}

private actor FakeSpeech: DictationSpeech {
    var appendError: Error?
    var finalSegments: [TranscriptSegment] = []
    private var holdFinish = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private(set) var appended = 0
    private(set) var finished = 0
    private(set) var cancelled = false

    func append(_ frame: PCMFrame) async throws {
        if let appendError { throw appendError }
        appended += 1
    }

    func finish() async throws -> [TranscriptSegment] {
        finished += 1
        if holdFinish { await withCheckedContinuation { finishWaiter = $0 } }
        return finalSegments
    }

    func cancel() async { cancelled = true }
    func setSegments(_ segments: [TranscriptSegment]) { finalSegments = segments }
    func setAppendError(_ error: Error) { appendError = error }
    func setHoldFinish(_ hold: Bool) { holdFinish = hold }
    func releaseFinish() { holdFinish = false; finishWaiter?.resume(); finishWaiter = nil }
}

@MainActor
private final class Harness {
    let capture = FakeCapture()
    let speech = FakeSpeech()
    var delaySpeech = false
    var speechWaiter: CheckedContinuation<any DictationSpeech, Error>?
    var update: (@Sendable (TranscriptUpdate) -> Void)?

    var dependencies: DictationDependencies {
        DictationDependencies(permission: { "authorized" }, makeCapture: { self.capture },
            makeSpeech: { _, _, onUpdate in
                self.update = onUpdate
                if self.delaySpeech {
                    return try await withCheckedThrowingContinuation { self.speechWaiter = $0 }
                }
                return self.speech
            })
    }

    func releaseSpeech() { speechWaiter?.resume(returning: speech); speechWaiter = nil }
    func emit(_ update: TranscriptUpdate) { self.update?(update) }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test @MainActor func releaseBeforeSpeechReadyNeverOpensMicrophone() async {
    let harness = Harness(); harness.delaySpeech = true
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    let id = controller.status.utteranceID
    #expect(await eventually { harness.speechWaiter != nil })
    controller.end()
    #expect(controller.status.phase == .finalizing)
    harness.releaseSpeech()
    #expect(await eventually { controller.status.phase == .failed })
    #expect(controller.status.utteranceID == id)
    #expect(harness.capture.starts == 0)
    #expect(await harness.speech.cancelled)
}

@Test @MainActor func immediateReleaseSkipsModelAndMicrophoneStartup() async {
    let harness = Harness()
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    controller.end()
    #expect(await eventually { controller.status.phase == .failed })
    #expect(harness.update == nil)
    #expect(harness.capture.starts == 0)
}

@Test @MainActor func releaseDuringHungStartupUsesFinalizationTimeout() async {
    let harness = Harness()
    harness.delaySpeech = true
    let controller = DictationController(finalizationTimeout: 0.05,
                                         dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { harness.speechWaiter != nil })
    controller.end()
    #expect(await eventually { controller.status.phase == .failed })
    #expect(controller.status.message?.contains("finalization timed out") == true)
    #expect(harness.capture.starts == 0)
    harness.releaseSpeech()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await harness.speech.cancelled)
    #expect(controller.status.phase == .failed)
}

@Test @MainActor func cancelBeforeSpeechReadySuppressesLateResult() async {
    let harness = Harness(); harness.delaySpeech = true
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { harness.speechWaiter != nil })
    controller.cancel()
    #expect(controller.status.phase == .idle)
    harness.releaseSpeech()
    #expect(await eventually { harness.capture.starts == 0 && controller.status.phase == .idle })
    harness.emit(.init(segment: .init(start: 0, end: 1, text: "late"), isFinal: true))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(controller.status.phase == .idle)
    #expect(controller.status.text.isEmpty)
    #expect(await harness.speech.cancelled)
}

@Test @MainActor func doubleBeginIsRejectedWithoutChangingIdentity() async {
    let harness = Harness(); harness.delaySpeech = true
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    let id = controller.status.utteranceID
    #expect(!controller.begin())
    #expect(controller.status.utteranceID == id)
    #expect(await eventually { harness.speechWaiter != nil })
    controller.cancel()
    harness.releaseSpeech()
}

@Test @MainActor func releaseDuringCaptureStartupStopsLateMicrophone() async {
    let harness = Harness(); harness.capture.holdStart = true
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { harness.capture.startWaiter != nil })
    controller.end()
    harness.capture.releaseStart()
    #expect(await eventually { controller.status.phase == .failed })
    #expect(harness.capture.stops == 1)
    #expect(await harness.speech.cancelled)
}

@Test @MainActor func previewReplacesVolatileTextAndFinalResultIsTrimmedOnce() async {
    let harness = Harness()
    await harness.speech.setSegments([.init(start: 0, end: 1, text: "  hello world  ")])
    var results: [DictationStatus] = []
    let controller = DictationController(dependencies: harness.dependencies) { results.append($0) }
    #expect(controller.begin())
    #expect(await eventually { controller.status.phase == .listening })
    harness.emit(.init(segment: .init(start: 0, end: 1, text: "hello"), isFinal: false))
    harness.emit(.init(segment: .init(start: 0, end: 1, text: "hello world"), isFinal: false))
    #expect(await eventually { controller.status.text == "hello world" })
    controller.end()
    #expect(await eventually { controller.status.phase == .result })
    #expect(controller.status.text == "hello world")
    #expect(results.filter { $0.phase == .result }.count == 1)
    harness.emit(.init(segment: .init(start: 0, end: 1, text: "stale"), isFinal: true))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(controller.status.text == "hello world")
    controller.reset()
    #expect(controller.status.phase == .idle)
    #expect(controller.status.text.isEmpty)
}

@Test @MainActor func captureAndRecognizerFailuresBecomeFailedStatuses() async {
    let captureHarness = Harness()
    captureHarness.capture.startError = HolosError.unavailable("Microphone unavailable")
    let first = DictationController(dependencies: captureHarness.dependencies) { _ in }
    #expect(first.begin())
    #expect(await eventually { first.status.phase == .failed })
    #expect(first.status.message?.contains("Microphone unavailable") == true)

    let speechHarness = Harness()
    let dependencies = DictationDependencies(permission: { "authorized" },
        makeCapture: { speechHarness.capture },
        makeSpeech: { _, _, _ in throw HolosError.unavailable("Speech assets missing") })
    let second = DictationController(dependencies: dependencies) { _ in }
    #expect(second.begin())
    #expect(await eventually { second.status.phase == .failed })
    #expect(second.status.message?.contains("Speech assets missing") == true)
    #expect(speechHarness.capture.starts == 0)
}

@Test @MainActor func maximumDurationStopsLostKeyUp() async {
    let harness = Harness()
    await harness.speech.setSegments([.init(start: 0, end: 1, text: " timed result ")])
    let controller = DictationController(maximumDuration: 0.25,
                                         dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { controller.status.phase == .result })
    #expect(controller.status.text == "timed result")
    #expect(controller.status.message?.contains("maximum dictation duration") == true)
    #expect(harness.capture.stops == 1)
}

@Test @MainActor func captureStreamFailureStopsMicrophone() async {
    let harness = Harness()
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { controller.status.phase == .listening })
    harness.capture.fail(HolosError.incomplete("Capture disconnected"))
    #expect(await eventually { controller.status.phase == .failed })
    #expect(controller.status.message?.contains("Capture disconnected") == true)
    #expect(await eventually { harness.capture.stops == 1 })
    #expect(await harness.speech.cancelled)
}

@Test @MainActor func recognizerAppendFailureStopsMicrophone() async throws {
    let harness = Harness()
    await harness.speech.setAppendError(HolosError.unavailable("Recognizer stopped"))
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { controller.status.phase == .listening })
    let frame = try PCMFrame(samples: Array(repeating: 0.1, count: 16),
                             sampleRate: 16_000, channels: 1, startTime: 0)
    harness.capture.emit(frame)
    #expect(await eventually { controller.status.phase == .failed })
    #expect(controller.status.message?.contains("Recognizer stopped") == true)
    #expect(await eventually { harness.capture.stops == 1 })
}

@Test @MainActor func rapidRepressWaitsForPriorMicrophoneCleanup() async {
    var captures: [FakeCapture] = []
    let dependencies = DictationDependencies(permission: { "authorized" },
        makeCapture: {
            let capture = FakeCapture()
            captures.append(capture)
            return capture
        }, makeSpeech: { _, _, _ in FakeSpeech() })
    let controller = DictationController(dependencies: dependencies) { _ in }
    #expect(controller.begin())
    let firstID = controller.status.utteranceID
    #expect(await eventually { controller.status.phase == .listening })
    controller.cancel()
    #expect(!controller.begin())
    #expect(await eventually { captures[0].stops == 1 })
    #expect(await eventually { controller.begin() })
    #expect(controller.status.utteranceID != firstID)
    #expect(await eventually { controller.status.phase == .listening })
    #expect(captures.count == 2)
    #expect(captures[0].stops == 1)
    controller.cancel()
}

@Test @MainActor func finalizationTimeoutSuppressesLateResult() async {
    let harness = Harness()
    await harness.speech.setHoldFinish(true)
    await harness.speech.setSegments([.init(start: 0, end: 1, text: "late result")])
    var resultCount = 0
    let controller = DictationController(finalizationTimeout: 0.15,
                                         dependencies: harness.dependencies) { status in
        if status.phase == .result { resultCount += 1 }
    }
    #expect(controller.begin())
    #expect(await eventually { controller.status.phase == .listening })
    controller.end()
    #expect(await eventually { controller.status.phase == .failed })
    #expect(controller.status.message?.contains("finalization timed out") == true)
    await harness.speech.releaseFinish()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(resultCount == 0)
    #expect(await harness.speech.cancelled)
}

@Test @MainActor func idleCallbackCannotBeginBeforeCleanupGateExists() async {
    let harness = Harness()
    var controller: DictationController?
    var callbackBegin: Bool?
    controller = DictationController(dependencies: harness.dependencies) { status in
        if status.phase == .idle && status.utteranceID == nil {
            callbackBegin = controller?.begin()
        }
    }
    #expect(controller?.begin() == true)
    #expect(await eventually { controller?.status.phase == .listening })
    controller?.cancel()
    #expect(callbackBegin == false)
    #expect(await eventually { harness.capture.stops == 1 })
    controller = nil
}
