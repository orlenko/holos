import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Synchronization
import Testing

// Helpers for the PR2a recorder tests. Shared test helpers (Fakes.swift) belong to another PR in this wave
// (docs/meeting-design.md §1.8), so every name here starts with `recorder`.

/// A fast loop: control requests every 10 ms, ticks and heartbeats every 50 ms.
func recorderFastTuning(liveQueueSeconds: Double = LiveTrack.queueSeconds,
                        journalCapacity: Int = LiveTrack.journalCapacity,
                        pumpCapacitySeconds: Double = 60) -> RecorderTuning {
    RecorderTuning(poll: .milliseconds(10), tick: .milliseconds(50), stoppedPoll: .milliseconds(50),
                   pumpCapacitySeconds: pumpCapacitySeconds, liveQueueSeconds: liveQueueSeconds,
                   journalCapacity: journalCapacity)
}

/// Fake capture and speech with a fast loop, the given clock (a `ManualSessionClock` gives tests the time), and
/// optional status observer.
@MainActor
func recorderDependencies(captures: FakeCaptureFactory, speech: @escaping LiveSpeechFactory = FakeSpeechFactory().factory,
                          postProcess: PostProcessHook? = nil, stop: any RecorderStopSource = ManualStopSource(),
                          reporter: any RecordingReporter = CollectingReporter(), clock: (any SessionClock)? = nil,
                          timeouts: StopTimeouts = .standard, tuning: RecorderTuning = recorderFastTuning(),
                          makeCapture: (@MainActor @Sendable () -> any MeetingCapture)? = nil,
                          statusObserver: (@Sendable (RecorderStatus) -> Void)? = nil) -> RecordingDependencies {
    let fakeCapture: @MainActor @Sendable () -> any MeetingCapture = { captures.make() }
    var makeClock: (@Sendable (Double) -> any SessionClock)?
    if let clock {
        makeClock = { _ in clock }
    }
    var dependencies = RecordingDependencies(
        makeCapture: makeCapture ?? fakeCapture, makeSpeech: speech, stop: stop, reporter: reporter,
        postProcess: postProcess, makeClock: makeClock, timeouts: timeouts)
    dependencies.tuning = tuning
    dependencies.statusObserver = statusObserver
    return dependencies
}

/// The one session folder in `root`, once it exists.
@MainActor
func recorderSession(in root: URL) async -> URL? {
    var found: URL?
    _ = await eventually { found = sessionFolders(in: root).first; return found != nil }
    return found
}

/// Sends `command` like `holos record …` and waits up to 3 s for the recorder's answer.
func recorderSend(_ command: ControlCommand, label: String? = nil, to session: URL) async throws -> ControlAck? {
    let sessionID = session.deletingPathExtension().lastPathComponent
    let request = try RecorderChannel.send(command, label: label, session: session, sessionID: sessionID,
                                           sender: "cli")
    return await RecorderChannel.waitForAck(request, session: session, timeout: .seconds(3))
}

func recorderEvents(_ directory: URL, _ kind: String) throws -> [ArchiveEvent] {
    try SessionArchive.readEvents(at: directory).events.filter { $0.kind == kind }
}

/// A control request for machine and inbox tests.
func recorderRequest(_ command: ControlCommand, id: String = UUID().uuidString, sessionID: String = "S",
                     label: String? = nil, sentAtNanos: UInt64? = nil,
                     createdAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> ControlRequest {
    ControlRequest(id: id, sessionID: sessionID, command: command, label: label, createdAt: createdAt,
                   sentAtNanos: sentAtNanos, sender: "cli")
}

/// The acknowledgement effect the machine emits (its dates are placeholders the loop stamps).
func recorderAck(_ request: ControlRequest, _ result: ControlResult, _ message: String? = nil) -> RecorderEffect {
    .acknowledge(ControlAck(id: request.id, command: request.command, result: result, message: message,
                            handledAt: RecorderMachine.placeholderDate))
}

/// A machine that is recording epoch 0 (its first frame arrived at `at`).
func recorderRunningMachine(at: Double = 0) -> RecorderMachine {
    var machine = RecorderMachine()
    _ = machine.handle(.captureRunning(epoch: 0, at: at))
    return machine
}

/// A tick with nothing else to say.
func recorderTick(_ at: Double, freeBytes: Int64? = nil) -> RecorderInput {
    .tick(at: at, lidOpen: true, freeBytes: freeBytes, lastFrameAt: [:])
}

/// A speech session that finalizes one segment per `segmentSeconds` of audio fed, each with a word at every whole
/// second (`<prefix><n>`, n counted from its first frame). Its `append` blocks once when fed audio at or after
/// `blockAt`: for `blockFor`, or, with `blockUntil`, until that condition holds (polled every millisecond).
actor RecorderWordSpeech: LiveSpeechSession {
    let prefix: String
    let segmentSeconds: Double
    let blockAt: Double?
    let blockFor: Duration
    private let blockUntil: (@Sendable () -> Bool)?
    private let onUpdate: @Sendable (TranscriptUpdate) -> Void
    private(set) var fedSeconds = 0.0
    private(set) var firstFrameStart: Double?
    private var fedEnd = 0.0
    private var blocked = false
    private var reported = 0
    private(set) var cancelled = false

    init(prefix: String, segmentSeconds: Double = 5, blockAt: Double? = nil, blockFor: Duration = .zero,
         blockUntil: (@Sendable () -> Bool)? = nil, onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) {
        self.prefix = prefix; self.segmentSeconds = segmentSeconds; self.blockAt = blockAt
        self.blockFor = blockFor; self.blockUntil = blockUntil; self.onUpdate = onUpdate
    }

    func append(_ frame: PCMFrame) async throws {
        if cancelled { throw CancellationError() }
        if firstFrameStart == nil { firstFrameStart = frame.startTime }
        if let blockAt, !blocked, frame.startTime >= blockAt {
            blocked = true
            if let blockUntil {
                while !blockUntil(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
            } else {
                try? await Task.sleep(for: blockFor)
            }
        }
        fedSeconds += frame.duration
        fedEnd = max(fedEnd, frame.startTime + frame.duration)
        while (Double(reported) + 1) * segmentSeconds <= fedEnd + 1e-6 {
            onUpdate(TranscriptUpdate(segment: segment(reported), isFinal: true))
            reported += 1
        }
    }

    /// Every full segment, and the words of the last, partial one that were fed completely.
    func finish() async throws -> [TranscriptSegment] {
        if cancelled { throw CancellationError() }
        var segments = (0..<reported).map { segment($0) }
        let partial = segment(reported, until: fedEnd)
        if !partial.words.isEmpty { segments.append(partial) }
        return segments
    }

    func cancel() async { cancelled = true }

    /// Segment `index`: words at each whole second it covers (only those that end by `until`).
    private func segment(_ index: Int, until: Double = .infinity) -> TranscriptSegment {
        let start = Double(index) * segmentSeconds
        var text = ""
        var words: [TimedWord] = []
        var second = start
        while second < start + segmentSeconds - 1e-9, second + 0.5 <= until + 1e-9 {
            if !text.isEmpty { text += " " }
            let word = "\(prefix)\(Int(second.rounded()))"
            words.append(TimedWord(text: word, start: second, end: second + 0.5, utf16Offset: text.utf16.count,
                                   utf16Length: word.utf16.count))
            text += word
            second += 1
        }
        return TranscriptSegment(id: "\(prefix)-\(index)", start: start, end: min(start + segmentSeconds, until),
                                 text: text, words: words)
    }
}

/// Waits `seconds` of wall time whether or not the calling task is cancelled, like a platform call that ignores
/// cancellation.
func recorderWaitIgnoringCancellation(_ seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

/// A `LiveSpeechFactory` that ignores cancellation: each call returns `speech`'s next session only after `seconds`.
func recorderLateSpeechFactory(_ speech: FakeSpeechFactory, after seconds: Double) -> LiveSpeechFactory {
    let factory = speech.factory
    return { locale, backend, strings, onUpdate in
        await recorderWaitIgnoringCancellation(seconds)
        return try await factory(locale, backend, strings, onUpdate)
    }
}

/// Polls the async `condition` every 5 ms until it holds or `timeout` passes, and returns its last value.
@MainActor
func recorderEventually(timeout: Duration = .seconds(30), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A `LiveSpeechFactory` handing out the sessions `make` returns, in call order, and remembering them.
final class RecorderSpeechFactory: Sendable {
    private let sessions = Mutex<[any LiveSpeechSession]>([])
    private let calls = Mutex(0)
    private let make: @Sendable (Int, @escaping @Sendable (TranscriptUpdate) -> Void) async throws -> any LiveSpeechSession

    init(_ make: @escaping @Sendable (Int, @escaping @Sendable (TranscriptUpdate) -> Void) async throws
         -> any LiveSpeechSession) {
        self.make = make
    }

    var factory: LiveSpeechFactory {
        { _, _, _, onUpdate in
            let call = self.calls.withLock { count -> Int in defer { count += 1 }; return count }
            let session = try await self.make(call, onUpdate)
            self.sessions.withLock { $0.append(session) }
            return session
        }
    }

    var made: [any LiveSpeechSession] { sessions.withLock { $0 } }
}
