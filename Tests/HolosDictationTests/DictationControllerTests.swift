import Foundation
import Testing
import HolosCore
import HolosAudio
@testable import HolosDictation

@Test @MainActor func deniedPermissionNeverStartsCapture() {
    var updates: [DictationStatus] = []
    let dependencies = DictationDependencies(permission: { "denied" },
        makeCapture: { fatalError("capture must not start") },
        makeSpeech: { _, _, _, _ in fatalError("speech must not start") })
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
    func emit(_ frame: PCMFrame, track: String = "mic") {
        pair.continuation.yield(CapturedAudio(track: track, frame: frame))
    }
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
    /// The locale of each recognizer made, in order.
    var locales: [String] = []
    /// The contextual strings of each recognizer made, in order.
    var vocabularies: [[String]] = []

    var dependencies: DictationDependencies {
        DictationDependencies(permission: { "authorized" }, makeCapture: { self.capture },
            makeSpeech: { locale, _, vocabulary, onUpdate in
                self.locales.append(locale)
                self.vocabularies.append(vocabulary)
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

/// Advances watchdog sleeps explicitly. Even cancelled sleeps can return late, as a platform callback can.
@MainActor
private final class DictationSleeper {
    private(set) var durations: [Duration] = []
    private(set) var completed = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        durations.append(duration)
        await withCheckedContinuation { waiters.append($0) }
        completed += 1
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func drain() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
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

@Test @MainActor func aLocaleChangeAppliesFromTheNextUtterance() async {
    let harness = Harness(); harness.delaySpeech = true
    let controller = DictationController(locale: "en-CA", dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    controller.locale = "fr-CA"  // before this utterance's recognizer is made; it keeps en-CA
    #expect(await eventually { harness.speechWaiter != nil })
    controller.cancel()
    harness.releaseSpeech()
    #expect(await eventually { controller.begin() })
    #expect(await eventually { harness.speechWaiter != nil })
    #expect(harness.locales == ["en-CA", "fr-CA"])
    controller.cancel()
    harness.releaseSpeech()
}

/// A reload of words.json or corrections.json sets new contextual strings while an utterance starts; it keeps the
/// ones it began with.
@Test @MainActor func aVocabularyChangeAppliesFromTheNextUtterance() async {
    let harness = Harness(); harness.delaySpeech = true
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    controller.contextualStrings = ["Keycloak"]
    #expect(controller.begin())
    controller.contextualStrings = ["Keycloak", "kubectl"]  // before the recognizer is made
    #expect(await eventually { harness.speechWaiter != nil })
    controller.cancel()
    harness.releaseSpeech()
    #expect(await eventually { controller.begin() })
    #expect(await eventually { harness.speechWaiter != nil })
    #expect(harness.vocabularies == [["Keycloak"], ["Keycloak", "kubectl"]])
    controller.cancel()
    harness.releaseSpeech()
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
    let sleeper = DictationSleeper()
    defer { sleeper.drain() }
    harness.delaySpeech = true
    let controller = DictationController(sleep: sleeper.sleep,
                                         dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { harness.speechWaiter != nil && sleeper.durations.count == 1 })
    controller.end()
    #expect(await eventually { sleeper.durations == [.seconds(120), .seconds(30)] })
    sleeper.advance() // the cancelled startup sleep must not fail finalization
    #expect(await eventually { sleeper.completed == 1 })
    #expect(controller.status.phase == .finalizing)
    sleeper.advance()
    #expect(await eventually { controller.status.phase == .failed })
    #expect(controller.status.message?.contains("finalization timed out") == true)
    #expect(harness.capture.starts == 0)
    harness.releaseSpeech()
    #expect(await eventually { controller.begin() })
    controller.cancel()
    #expect(await harness.speech.cancelled)
    #expect(controller.status.phase == .idle)
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

@Test @MainActor func committedTextCarriesOnlyFinalsAndPrefixesTheResult() async {
    let harness = Harness()
    await harness.speech.setSegments([.init(start: 0, end: 1, text: " Hello there. "),
                                      .init(start: 1, end: 2, text: "How are you?")])
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { controller.status.phase == .listening })
    harness.emit(.init(segment: .init(start: 0, end: 1, text: "Hello there."), isFinal: true))
    harness.emit(.init(segment: .init(start: 1, end: 2, text: "How are"), isFinal: false))
    #expect(await eventually { controller.status.text == "Hello there. How are" })
    #expect(controller.status.committedText == "Hello there.")
    controller.end()
    #expect(controller.status.committedText == "Hello there.")
    #expect(await eventually { controller.status.phase == .result })
    #expect(controller.status.text == "Hello there. How are you?")
    #expect(controller.status.text.hasPrefix("Hello there."))
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
        makeSpeech: { _, _, _, _ in throw HolosError.unavailable("Speech assets missing") })
    let second = DictationController(dependencies: dependencies) { _ in }
    #expect(second.begin())
    #expect(await eventually { second.status.phase == .failed })
    #expect(second.status.message?.contains("Speech assets missing") == true)
    #expect(speechHarness.capture.starts == 0)
}

@Test @MainActor func dictationContinuesPastTheOldCutoffAndFinishesOnRelease() async throws {
    let harness = Harness()
    harness.delaySpeech = true
    let sleeper = DictationSleeper()
    defer { sleeper.drain() }
    let segments: [TranscriptSegment] = [.init(start: 0, end: 1, text: "First sentence."),
                                          .init(start: 600, end: 601, text: "Still dictating.")]
    await harness.speech.setSegments(segments)
    let controller = DictationController(sleep: sleeper.sleep,
                                         dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { harness.speechWaiter != nil && sleeper.durations == [.seconds(120)] })
    harness.releaseSpeech()
    #expect(await eventually { controller.status.phase == .listening })
    let id = controller.status.utteranceID
    // Simulate the old two-minute watchdog returning after startup, without waiting on wall time.
    sleeper.advance()
    #expect(await eventually { sleeper.completed == 1 })
    #expect(controller.status.phase == .listening)
    #expect(controller.status.utteranceID == id)
    #expect(harness.capture.stops == 0)
    #expect(await harness.speech.finished == 0)
    for segment in segments { harness.emit(.init(segment: segment, isFinal: true)) }
    harness.capture.emit(try PCMFrame(samples: [0.1], sampleRate: 16_000, channels: 1, startTime: 600))
    #expect(await eventually { controller.status.committedText == "First sentence. Still dictating." })
    controller.end()
    #expect(await eventually { controller.status.phase == .result })
    #expect(controller.status.text == "First sentence. Still dictating.")
    #expect(controller.status.message == nil)
    #expect(harness.capture.stops == 1)
    #expect(await harness.speech.appended == 1)
    #expect(await harness.speech.finished == 1)
}

@Test @MainActor func longDictationCanStillBeCancelled() async {
    let harness = Harness()
    harness.delaySpeech = true
    let sleeper = DictationSleeper()
    defer { sleeper.drain() }
    let controller = DictationController(sleep: sleeper.sleep, dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually { harness.speechWaiter != nil && sleeper.durations.count == 1 })
    harness.releaseSpeech()
    #expect(await eventually { controller.status.phase == .listening })
    sleeper.advance()
    #expect(await eventually { sleeper.completed == 1 })
    #expect(controller.status.phase == .listening)
    harness.emit(.init(segment: .init(start: 600, end: 601, text: "Late words."), isFinal: true))
    #expect(await eventually { controller.status.committedText == "Late words." })
    controller.cancel()
    #expect(controller.status.phase == .idle)
    #expect(await eventually { harness.capture.stops == 1 })
    #expect(await harness.speech.cancelled)
    #expect(await harness.speech.finished == 0)
}

@Test(arguments: [false, true]) @MainActor
func hungSpeechOrMicrophoneStartupStillTimesOut(microphone: Bool) async {
    let harness = Harness()
    let sleeper = DictationSleeper()
    defer { sleeper.drain() }
    harness.delaySpeech = !microphone
    harness.capture.holdStart = microphone
    let controller = DictationController(sleep: sleeper.sleep, dependencies: harness.dependencies) { _ in }
    #expect(controller.begin())
    #expect(await eventually {
        sleeper.durations == [.seconds(120)] &&
        (microphone ? harness.capture.startWaiter != nil : harness.speechWaiter != nil)
    })
    sleeper.advance()
    #expect(await eventually { controller.status.phase == .failed })
    #expect(controller.status.message == "Dictation startup timed out. Try again.")
    if microphone { harness.capture.releaseStart() } else { harness.releaseSpeech() }
    #expect(await eventually { controller.begin() }) // cleanup must finish before another utterance
    controller.cancel()
    #expect(harness.capture.stops == (microphone ? 1 : 0))
    #expect(await harness.speech.cancelled)
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
        }, makeSpeech: { _, _, _, _ in FakeSpeech() })
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

@Test @MainActor func frameTapGetsEveryMicrophoneFrameTheRecognizerTookBeforeTheResult() async throws {
    let harness = Harness()
    await harness.speech.setSegments([.init(start: 0, end: 1, text: "hello")])
    var tapped: [(UUID, Double)] = []
    var phaseAtTap: [DictationPhase] = []
    let controller = DictationController(dependencies: harness.dependencies) { _ in }
    controller.frameTap = { id, frame in
        tapped.append((id, frame.startTime))
        phaseAtTap.append(controller.status.phase)
    }
    #expect(controller.begin())
    let id = try #require(controller.status.utteranceID)
    #expect(await eventually { controller.status.phase == .listening })
    for index in 0..<3 {
        harness.capture.emit(try PCMFrame(samples: Array(repeating: 0.1, count: 160), sampleRate: 16_000, channels: 1,
                                          startTime: Double(index) * 0.01))
    }
    // Another track's audio is neither recognized nor kept.
    harness.capture.emit(try PCMFrame(samples: [0.2], sampleRate: 16_000, channels: 1, startTime: 0), track: "system")
    #expect(await eventually { tapped.count == 3 })
    controller.end()
    #expect(await eventually { controller.status.phase == .result })
    #expect(tapped.map(\.0) == [id, id, id])
    #expect(tapped.map(\.1) == [0, 0.01, 0.02])
    #expect(await harness.speech.appended == 3)
    #expect(!phaseAtTap.contains(.result))
}
