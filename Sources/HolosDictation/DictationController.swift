import Foundation
import HolosAudio
import HolosCore
import HolosSpeech

public enum DictationPhase: Sendable, Equatable {
    case idle, preparing, listening, finalizing, result, failed
}

public struct DictationStatus: Sendable, Equatable {
    public let phase: DictationPhase
    public let utteranceID: UUID?
    public let text: String
    /// Finalized recognition so far. It only grows within an utterance unless the recognizer reorders
    /// finals, so a consumer may stream it into a field; volatile words stay out of it.
    public let committedText: String
    public let message: String?

    public init(phase: DictationPhase, utteranceID: UUID? = nil, text: String = "", committedText: String = "",
                message: String? = nil) {
        self.phase = phase
        self.utteranceID = utteranceID
        self.text = text
        self.committedText = committedText
        self.message = message
    }

    /// One normalization for preview, committed, and final text, so committed text stays a prefix of the result.
    static func transcript(_ segments: [TranscriptSegment]) -> String {
        segments.sorted { $0.start < $1.start }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@MainActor
protocol DictationCapture: AnyObject {
    var frames: AsyncThrowingStream<CapturedAudio, Error> { get }
    func start() async throws
    func stop() async throws
}

protocol DictationSpeech: Sendable {
    func append(_ frame: PCMFrame) async throws
    func finish() async throws -> [TranscriptSegment]
    func cancel() async
}

extension AppleSpeechSession: DictationSpeech {}

@MainActor
private final class MicrophoneCapture: DictationCapture {
    private let capture = AudioCapture(bufferCapacity: 256)
    var frames: AsyncThrowingStream<CapturedAudio, Error> { capture.frames }
    func start() async throws { try await capture.start(source: .microphone) }
    func stop() async throws { try await capture.stop() }
}

@MainActor
struct DictationDependencies {
    var permission: () -> String
    var makeCapture: () -> any DictationCapture
    var makeSpeech: (String, SpeechBackend, @escaping @Sendable (TranscriptUpdate) -> Void) async throws -> any DictationSpeech

    static var live: Self {
        Self(permission: { AudioCapture.microphonePermission },
             makeCapture: { MicrophoneCapture() },
             makeSpeech: { locale, backend, onUpdate in
                 try await AppleSpeechSession.make(locale: locale, backend: backend, onUpdate: onUpdate)
             })
    }
}

/// One microphone utterance at a time. Calls are synchronous so hotkey handlers can capture the utterance ID immediately.
@MainActor
public final class DictationController {
    public private(set) var status = DictationStatus(phase: .idle)

    private let locale: String
    private let backend: SpeechBackend
    private let maximumDuration: TimeInterval
    private let finalizationTimeout: TimeInterval
    private let onUpdate: @MainActor (DictationStatus) -> Void
    private let dependencies: DictationDependencies

    private var generation: UUID?
    private var releaseRequested = false
    private var reducer = TranscriptReducer()
    private var capture: (any DictationCapture)?
    private var speech: (any DictationSpeech)?
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var prepareTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var stopTask: Task<Void, Error>?
    private var finalizationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var finalizationWatchdogTask: Task<Void, Never>?
    private var timeoutMessage: String?

    public init(locale: String = "en-CA", backend: SpeechBackend = .speech,
                maximumDuration: TimeInterval = 120,
                onUpdate: @escaping @MainActor (DictationStatus) -> Void) {
        self.locale = locale
        self.backend = backend
        self.maximumDuration = maximumDuration.isFinite && maximumDuration > 0 ? maximumDuration : 120
        self.finalizationTimeout = 30
        self.onUpdate = onUpdate
        self.dependencies = .live
    }

    init(locale: String = "en-CA", backend: SpeechBackend = .speech,
         maximumDuration: TimeInterval = 120, finalizationTimeout: TimeInterval = 30,
         dependencies: DictationDependencies,
         onUpdate: @escaping @MainActor (DictationStatus) -> Void) {
        self.locale = locale
        self.backend = backend
        self.maximumDuration = maximumDuration.isFinite && maximumDuration > 0 ? maximumDuration : 120
        self.finalizationTimeout = finalizationTimeout.isFinite && finalizationTimeout > 0 ? finalizationTimeout : 30
        self.onUpdate = onUpdate
        self.dependencies = dependencies
    }

    /// Returns false while an earlier utterance is still starting, recording, finishing, or stopping.
    @discardableResult
    public func begin() -> Bool {
        guard generation == nil, cleanupTask == nil else { return false }
        let id = UUID()
        generation = id
        releaseRequested = false
        reducer = TranscriptReducer()
        capture = nil
        speech = nil
        updateContinuation = nil
        prepareTask = nil
        previewTask = nil
        feedTask = nil
        stopTask = nil
        finalizationTask = nil
        finalizationWatchdogTask = nil
        timeoutMessage = nil
        publish(.init(phase: .preparing, utteranceID: id))
        guard generation == id else { return true }

        let permission = dependencies.permission()
        guard permission == "authorized" else {
            generation = nil
            publish(.init(phase: .failed, utteranceID: id,
                          message: Self.permissionMessage(permission)))
            return true
        }
        watchdogTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.maximumDuration))
            guard !Task.isCancelled else { return }
            self.watchdogFired(id)
        }
        prepareTask = Task { [weak self] in await self?.prepare(id) }
        return true
    }

    public func end() {
        guard let id = generation else { return }
        switch status.phase {
        case .preparing:
            releaseRequested = true
            watchdogTask?.cancel()
            publish(.init(phase: .finalizing, utteranceID: id,
                          message: "Finishing startup after key release."))
            guard generation == id else { return }
            startFinalizationWatchdog(id)
            prepareTask?.cancel()
        case .listening:
            watchdogTask?.cancel()
            publish(.init(phase: .finalizing, utteranceID: id, text: status.text,
                          committedText: status.committedText, message: timeoutMessage))
            guard generation == id else { return }
            startFinalizationWatchdog(id)
            finalizationTask = Task { [weak self] in await self?.finalize(id) }
        case .idle, .finalizing, .result, .failed:
            break
        }
    }

    /// Discards this utterance immediately and prevents all later callbacks from publishing a result.
    public func cancel() {
        guard generation != nil else {
            reducer = TranscriptReducer()
            if status.phase != .idle { publish(.init(phase: .idle)) }
            return
        }
        discardCurrent(publishing: .init(phase: .idle))
    }

    public func reset() { cancel() }

    private func prepare(_ id: UUID) async {
        guard generation == id else { return }
        if releaseRequested {
            finishReleasedBeforeReady(id)
            return
        }
        let pair = AsyncStream<TranscriptUpdate>.makeStream(bufferingPolicy: .bufferingOldest(256))
        updateContinuation = pair.continuation
        previewTask = Task { [weak self] in
            for await update in pair.stream { self?.accept(update, for: id) }
        }
        do {
            let session = try await dependencies.makeSpeech(locale, backend) { update in
                pair.continuation.yield(update)
            }
            guard generation == id else {
                pair.continuation.finish()
                await session.cancel()
                return
            }
            speech = session
            if releaseRequested {
                pair.continuation.finish()
                await session.cancel()
                finishReleasedBeforeReady(id)
                return
            }
            let microphone = dependencies.makeCapture()
            capture = microphone
            try await microphone.start()
            guard generation == id else {
                _ = try? await stopCapture(microphone).value
                pair.continuation.finish()
                await session.cancel()
                return
            }
            if releaseRequested {
                _ = try? await stopCapture(microphone).value
                pair.continuation.finish()
                await session.cancel()
                finishReleasedBeforeReady(id)
                return
            }
            publish(.init(phase: .listening, utteranceID: id))
            feedTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await audio in microphone.frames {
                        try Task.checkCancellation()
                        guard self.generation == id else { return }
                        guard audio.track == "mic" else { continue }
                        try await session.append(audio.frame)
                    }
                } catch {
                    self.fail(id, error: error)
                }
            }
        } catch {
            pair.continuation.finish()
            guard generation == id else { return }
            if releaseRequested {
                if let microphone = capture { _ = try? await stopCapture(microphone).value }
                if let speech { await speech.cancel() }
                finishReleasedBeforeReady(id)
            } else {
                fail(id, error: error)
            }
        }
    }

    private func finalize(_ id: UUID) async {
        guard generation == id, let microphone = capture, let session = speech else { return }
        do {
            try await stopCapture(microphone).value
            await feedTask?.value
            guard generation == id else { return }
            let segments = try await session.finish()
            updateContinuation?.finish()
            await previewTask?.value
            guard generation == id else { return }
            let text = DictationStatus.transcript(segments)
            generation = nil
            releaseRequested = false
            reducer = TranscriptReducer()
            watchdogTask?.cancel()
            finalizationWatchdogTask?.cancel()
            capture = nil
            speech = nil
            publish(.init(phase: .result, utteranceID: id, text: text, message: timeoutMessage))
        } catch {
            fail(id, error: error)
        }
    }

    private func accept(_ update: TranscriptUpdate, for id: UUID) {
        guard generation == id, status.phase == .listening || status.phase == .finalizing else { return }
        do {
            try reducer.apply(update)
            publish(.init(phase: status.phase, utteranceID: id,
                          text: DictationStatus.transcript(reducer.finalized + reducer.provisional),
                          committedText: DictationStatus.transcript(reducer.finalized), message: status.message))
        } catch {
            // The final segments returned by the engine remain authoritative.
        }
    }

    private func finishReleasedBeforeReady(_ id: UUID) {
        guard generation == id else { return }
        generation = nil
        watchdogTask?.cancel()
        finalizationWatchdogTask?.cancel()
        capture = nil
        speech = nil
        publish(.init(phase: .failed, utteranceID: id,
                      message: "Released before the microphone was ready. Press and hold to try again."))
    }

    private func fail(_ id: UUID, error: Error) {
        guard generation == id else { return }
        discardCurrent(publishing: .init(phase: .failed, utteranceID: id,
                                         message: error.localizedDescription))
    }

    private func discardCurrent(publishing terminal: DictationStatus) {
        generation = nil
        releaseRequested = false
        reducer = TranscriptReducer()
        watchdogTask?.cancel()
        finalizationWatchdogTask?.cancel()
        prepareTask?.cancel()
        feedTask?.cancel()
        finalizationTask?.cancel()
        updateContinuation?.finish()
        let microphone = capture
        let session = speech
        let preparation = prepareTask
        cleanupTask = Task { [weak self] in
            await preparation?.value
            if let microphone, let self { _ = try? await self.stopCapture(microphone).value }
            if let session { await session.cancel() }
            guard let self else { return }
            self.capture = nil
            self.speech = nil
            self.cleanupTask = nil
        }
        publish(terminal)
    }

    private func stopCapture(_ microphone: any DictationCapture) -> Task<Void, Error> {
        if let stopTask { return stopTask }
        let task = Task { try await microphone.stop() }
        stopTask = task
        return task
    }

    private func watchdogFired(_ id: UUID) {
        guard generation == id else { return }
        if status.phase == .listening {
            timeoutMessage = "Stopped after the maximum dictation duration."
            end()
        } else if status.phase == .preparing || status.phase == .finalizing {
            discardCurrent(publishing: .init(phase: .failed, utteranceID: id,
                                             message: "Dictation startup timed out. Try again."))
        }
    }

    private func finalizationTimedOut(_ id: UUID) {
        guard generation == id, status.phase == .finalizing else { return }
        discardCurrent(publishing: .init(phase: .failed, utteranceID: id,
                                         message: "Dictation finalization timed out. Try again."))
    }

    private func startFinalizationWatchdog(_ id: UUID) {
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.finalizationTimeout))
            guard !Task.isCancelled else { return }
            self.finalizationTimedOut(id)
        }
    }

    private func publish(_ newStatus: DictationStatus) {
        status = newStatus
        onUpdate(newStatus)
    }

    private static func permissionMessage(_ value: String) -> String {
        switch value {
        case "denied", "restricted":
            "Microphone access is blocked. Enable it for Holos in System Settings > Privacy & Security > Microphone."
        case "notDetermined":
            "Microphone access has not been granted. Use Holos microphone setup before dictating."
        default:
            "Microphone access is unavailable. Check Holos microphone settings and try again."
        }
    }
}
