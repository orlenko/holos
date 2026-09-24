import Darwin
import Foundation
import HolosAudio
import HolosCore
import HolosStorage
import os
import Synchronization

public struct RecordingOptions: Sendable, Equatable {
    public var name: String
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    /// The sessions folder; the recording is saved in `<root>/<SESSION-UUID>.holos`.
    public var root: URL
    /// Stop automatically after this many seconds of session time.
    public var duration: Double?
    /// Save audio without speech recognition.
    public var recordOnly: Bool
    /// Capture system audio only from this application.
    public var applicationBundleID: String?
    /// Contextual strings for every speech session of this recording (§4.12): at most 1,000 entries of at most 100
    /// characters (longer entries are dropped). Saved as `vocabulary.json`.
    public var vocabulary: [String]
    /// The session ID (a UUID, passed to `SessionArchive.create(id:)`); nil makes one. No folder may exist for it.
    public var sessionID: String?
    /// In a call, also label speakers on the microphone track because others share the room. Only with mic+system.
    public var othersInRoom: Bool
    /// The number of people expected (1…20), a hint for speaker labelling.
    public var expectedSpeakers: Int?
    /// Report finalized phrases while recording (the CLI prints them); false for `--no-live-text`.
    public var liveText: Bool
    /// Which input the microphone track records (§4.12; PR2b chooses it from the source).
    public var microphone: MicrophoneSelection

    public init(name: String, source: AudioSource, locale: String, backend: SpeechBackend, root: URL,
                duration: Double? = nil, recordOnly: Bool = false, applicationBundleID: String? = nil,
                vocabulary: [String] = [], sessionID: String? = nil, othersInRoom: Bool = false,
                expectedSpeakers: Int? = nil, liveText: Bool = true, microphone: MicrophoneSelection = .systemDefault) {
        self.name = name; self.source = source; self.locale = locale; self.backend = backend; self.root = root
        self.duration = duration; self.recordOnly = recordOnly; self.applicationBundleID = applicationBundleID
        self.vocabulary = vocabulary; self.sessionID = sessionID; self.othersInRoom = othersInRoom
        self.expectedSpeakers = expectedSpeakers; self.liveText = liveText; self.microphone = microphone
    }
}

/// Everything a recording touches outside its session folder.
public struct RecordingDependencies: Sendable {
    public var makeCapture: @MainActor @Sendable () -> any MeetingCapture
    public var makeSpeech: LiveSpeechFactory
    public var stop: any RecorderStopSource
    public var reporter: any RecordingReporter
    /// nil: no post-processing (--no-postprocess, --record-only).
    public var postProcess: PostProcessHook?
    /// Makes the session clock from epoch 0's host-time origin, right after epoch 0's capture starts (§2.3).
    public var makeClock: @Sendable (Double) -> any SessionClock
    /// Free space on the sessions volume (§4.5).
    public var freeSpace: any FreeSpaceProvider
    public var timeouts: StopTimeouts
    /// Loop cadence and queue sizes; tests shorten them.
    var tuning = RecorderTuning()
    /// Tests only: sees every status.json written, in order.
    var statusObserver: (@Sendable (RecorderStatus) -> Void)?

    /// No hardware defaults: tests use `.testing(...)` (Fakes.swift). The defaults of the later parameters are
    /// inert: a clock that starts when epoch 0 starts, unlimited free space, and the standard timeouts.
    public init(makeCapture: @escaping @MainActor @Sendable () -> any MeetingCapture,
                makeSpeech: @escaping LiveSpeechFactory, stop: any RecorderStopSource,
                reporter: any RecordingReporter, postProcess: PostProcessHook?,
                makeClock: (@Sendable (Double) -> any SessionClock)? = nil,
                freeSpace: any FreeSpaceProvider = FixedFreeSpace(.max), timeouts: StopTimeouts = .standard) {
        self.makeCapture = makeCapture; self.makeSpeech = makeSpeech; self.stop = stop
        self.reporter = reporter; self.postProcess = postProcess
        self.makeClock = makeClock ?? { _ in ElapsedSessionClock() }
        self.freeSpace = freeSpace; self.timeouts = timeouts
    }

    /// LiveMeetingCapture + AppleSpeechSession.make, `ContinuousSessionClock`, and `VolumeFreeSpace`.
    public static func live(stop: any RecorderStopSource, reporter: any RecordingReporter,
                            postProcess: PostProcessHook?) -> RecordingDependencies {
        RecordingDependencies(makeCapture: { LiveMeetingCapture() }, makeSpeech: appleSpeechFactory,
                              stop: stop, reporter: reporter, postProcess: postProcess,
                              makeClock: { ContinuousSessionClock(hostTimeOrigin: $0) }, freeSpace: VolumeFreeSpace())
    }
}

/// How often the recorder loop runs and how much it queues (docs/meeting-design.md §4.2, §4.3, §4.6).
struct RecorderTuning: Sendable {
    /// Control requests, the stop source, `stop.request`, and the duration are checked this often while capturing.
    var poll: Duration = .milliseconds(100)
    /// The machine's tick and the status refresh.
    var tick: Duration = .seconds(1)
    /// Control requests are answered this often after capture stops.
    var stoppedPoll: Duration = .seconds(1)
    /// A restart's speech sessions and capture start may take this long before the loop moves on (§4.2).
    var restartLimit: Duration = .seconds(10)
    var pumpCapacitySeconds = 60.0
    var liveQueueSeconds = LiveTrack.queueSeconds
    var journalCapacity = LiveTrack.journalCapacity
}

/// How a recording that saved its audio ended.
public struct RecordingOutcome: Sendable, Equatable {
    public var sessionID: String
    public var directory: URL
    /// The ArchiveStatus value written at finish.
    public var archiveStatus: String
    public var stopReason: StopReason
    public var transcriptID: String?
    public var transcriptErrors: [String]
    /// The hook's record; nil when post-processing did not run.
    public var postProcessing: PostProcessingRecord?

    public init(sessionID: String, directory: URL, archiveStatus: String, stopReason: StopReason,
                transcriptID: String? = nil, transcriptErrors: [String] = [],
                postProcessing: PostProcessingRecord? = nil) {
        self.sessionID = sessionID; self.directory = directory; self.archiveStatus = archiveStatus
        self.stopReason = stopReason; self.transcriptID = transcriptID; self.transcriptErrors = transcriptErrors
        self.postProcessing = postProcessing
    }
}

public enum RecordingWorkflow {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")
    static let maxVocabularyEntries = 1_000
    static let maxVocabularyLength = 100

    /// Records until stop, saves audio and transcript, then (with a hook) takes the processing lease,
    /// finishes the archive, and runs the hook under the lease (§4.6 steps 5–8).
    ///
    /// The session folder gets `meeting.json`, `vocabulary.json` (when there is a vocabulary), and `status.json`,
    /// which is rewritten every second until it says `exited`. The loop runs `RecorderMachine`: capture restarts in
    /// new epochs after a failure or a device change, waits and retries while audio is unavailable, pauses, and
    /// answers control requests in `control/` (§4.1, §4.2). A finished recording returns an outcome whatever stopped it
    /// (`stopReason`), including 10 minutes without audio (`captureFailed`) and a low disk (`diskLow`).
    ///
    /// Throws before creating a session for invalid options and when the disk has too little space. Capture never
    /// started: the archive is finished `failed` and the error is thrown. Audio could not be saved (the writer failed,
    /// or no audio arrived): marks the archive incomplete and throws `HolosError.incomplete`. Transcription failure:
    /// does not throw; the outcome carries the errors.
    ///
    /// Task cancellation: stops like a stop request, keeps the saved audio, finishes the archive without a partial
    /// transcript (`transcriptionIncomplete`, or `audioOnly` for record-only), skips post-processing, and rethrows
    /// `CancellationError`. Cancelled before capture starts: capture never starts and the archive is finished
    /// `failed` (a `startFailed` event with `cancelled`). Cancelled once the transcript is saved: the archive keeps
    /// its final status, the processing lease is released, and a hook that has not started is skipped. Cancelled
    /// during the hook: the hook's run ends as it chooses, and `CancellationError` is rethrown instead of an outcome.
    /// In every case `status.json` ends `exited` and no lock is left held.
    ///
    /// A `CancellationError` from an awaited dependency (starting or stopping capture, replaying saved audio, the
    /// processing lease) is handled as a cancellation, never as a capture or transcription failure; so is any error
    /// from starting or stopping capture or from a replay once the task is cancelled. The frame consumer is still
    /// drained and the chunk writer finished first. A frame stream that ends with an error of its own, even
    /// `CancellationError`, is a capture failure: capture restarts in a new epoch (§4.2). A live speech session's
    /// `CancellationError` only moves that track to replay.
    @MainActor public static func run(_ options: RecordingOptions,
                                      dependencies: RecordingDependencies) async throws -> RecordingOutcome {
        let stop = dependencies.stop
        defer { stop.restoreDefaultHandlers() }
        let options = try validated(options)
        try checkDisk(options, dependencies)
        let archive = try SessionArchive.create(root: options.root, name: options.name, source: options.source,
                                                locale: options.locale, backend: options.backend, id: options.sessionID)
        let recorder: Recorder
        do {
            recorder = try Recorder(archive: archive, options: options, dependencies: dependencies)
        } catch {
            try? await archive.recordEvent(kind: MeetingEventKind.startFailed, details: ["error": error.localizedDescription])
            try? await archive.finish(status: ArchiveStatus.failed)
            log.error("Session \(archive.id, privacy: .public) could not write its setup files")
            throw error
        }
        return try await recorder.run()
    }

    /// The stop reason a finished recording journaled (`captureStopped.reason`), for post-processing started right
    /// after it: a `diskLow` stop skips rendering (§4.7). Nil when none was recorded.
    public static func recordedStopReason(session: URL) -> StopReason? {
        guard let journal = try? SessionArchive.readEvents(at: session) else { return nil }
        return journal.events.last { $0.kind == MeetingEventKind.captureStopped }?.details["reason"].map(StopReason.init)
    }

    // MARK: - Start checks

    private static func validated(_ options: RecordingOptions) throws -> RecordingOptions {
        var options = options
        if let duration = options.duration, !duration.isFinite || duration <= 0 {
            throw HolosError.invalidInput("Duration must be positive and finite.")
        }
        if options.source == .microphone, options.applicationBundleID != nil {
            throw HolosError.invalidInput("--app applies to system audio, not mic-only recording.")
        }
        if options.othersInRoom, options.source != .microphoneAndSystem {
            throw HolosError.invalidInput("--others-in-room applies to mic+system recordings.")
        }
        if let expected = options.expectedSpeakers, !(1...20).contains(expected) {
            throw HolosError.invalidInput("The expected number of speakers must be between 1 and 20.")
        }
        if let id = options.sessionID {
            guard let uuid = UUID(uuidString: id) else {
                throw HolosError.invalidInput("A session ID must be a UUID, like \(UUID().uuidString).")
            }
            options.sessionID = uuid.uuidString
        }
        options.vocabulary = Array(options.vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxVocabularyLength }
            .prefix(maxVocabularyEntries))
        return options
    }

    private static func checkDisk(_ options: RecordingOptions, _ dependencies: RecordingDependencies) throws {
        let free: Int64
        do {
            free = try dependencies.freeSpace.availableBytes(at: options.root)
        } catch {
            log.error("Cannot measure free space before recording: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch DiskPolicy.startCheck(freeBytes: free, source: options.source) {
        case .refuse(let message): throw HolosError.unavailable(message)
        case .warn(let message): dependencies.reporter.message(message)
        case .ok, .stop: break
        }
    }
}

// MARK: - Recorder

/// One recording from its first status write to `exited` (docs/meeting-design.md §4.2, §4.6).
@MainActor
private final class Recorder {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    let options: RecordingOptions
    let dependencies: RecordingDependencies
    let archive: SessionArchive
    let status: StatusWriter
    let writer: AudioChunkWriter
    let pump: ChunkWriterPump
    let monitor = EpochMonitor()
    let tracks: [String]
    var reporter: any RecordingReporter { dependencies.reporter }

    var live: [String: LiveTrack] = [:]
    var machine = RecorderMachine()
    /// Session time; a placeholder at 0 until epoch 0's capture starts.
    var clock: any SessionClock = ManualSessionClock(0)
    var capture: (any MeetingCapture)?
    var captureEpoch = 0
    /// `stop()` was called on the current capture.
    var captureStopped = false
    /// The current capture's dropped-buffer count at the last status refresh.
    var lastCaptureDrops = 0
    var consumer: Task<Void, Never>?
    var writerTask: Task<Void, Error>?
    let writerFailed = LockedValue(false)
    /// The reason of the last `stopCapture`, recorded with the restart that follows it.
    var lastGapReason: GapReason?
    /// Stop requests the loop made itself (a stop source or `stop.request`); their acknowledgements are not shown.
    var internalRequests: Set<String> = []
    var stopSourceHandled = false
    var legacyStopHandled = false
    var durationHandled = false
    var shownWarnings: Set<RecorderWarningCode> = []
    var lastStatusPhase: RecorderPhase?
    var cancelled = false
    var recordingError: Error?
    var archiveOpen = true
    /// status.json says exited.
    var exited = false
    var stoppedInbox: Task<Void, Never>?

    init(archive: SessionArchive, options: RecordingOptions, dependencies: RecordingDependencies) throws {
        self.archive = archive
        self.options = options
        self.dependencies = dependencies
        tracks = options.source == .microphoneAndSystem ? ["mic", "system"] : [options.source.rawValue]
        writer = AudioChunkWriter(archive: archive)
        pump = ChunkWriterPump(writer: writer, capacitySeconds: dependencies.tuning.pumpCapacitySeconds)
        let directory = archive.directory
        let info = MeetingInfo(sessionID: archive.id, mode: options.source == .microphone ? .inPerson : .call,
                               othersInRoom: options.othersInRoom, applicationBundleID: options.applicationBundleID,
                               expectedSpeakers: options.expectedSpeakers)
        try AtomicFile.create(try HolosJSON.encoder().encode(info), at: SessionPaths.meetingInfo(directory))
        if !options.vocabulary.isEmpty {
            try AtomicFile.create(try HolosJSON.encoder().encode(MeetingVocabulary(strings: options.vocabulary)),
                                  at: SessionPaths.vocabulary(directory))
        }
        let now = Date()
        let initial = RecorderStatus(
            sessionID: archive.id, name: options.name, pid: getpid(), phase: .starting, sequence: 0, startedAt: now,
            updatedAt: now, source: options.source,
            tracks: tracks.map { TrackStatus(track: $0, transcription: options.recordOnly ? .off : .live) })
        status = try StatusWriter(session: directory, initial: initial, heartbeat: dependencies.tuning.tick,
                                  observer: dependencies.statusObserver)
        lastStatusPhase = .starting
    }

    func run() async throws -> RecordingOutcome {
        await archive.setJournalSync(.interval(seconds: 1))
        try await start()
        Self.log.notice("Session \(self.archive.id, privacy: .public) started recording (\(self.options.source.rawValue, privacy: .public))")
        reporter.message("Recording \(archive.id): \(options.name)")
        reporter.message("Audio archive: \(archive.directory.path)")
        reporter.message("Press Ctrl-C to stop. Source labels identify tracks, not individual speakers.")
        await runLoop()
        do {
            return try await stopPath()
        } catch {
            // Whatever failed after the audio was saved (a transcript that could not be written, say), the archive is
            // finished, the status ends exited, and no control request is left behind.
            if archiveOpen {
                try? await archive.finish(status: ArchiveStatus.transcriptionIncomplete)
                archiveOpen = false
            }
            if !exited {
                let saved = (try? SessionArchive.readManifest(at: archive.directory).status) ?? ArchiveStatus.incomplete
                await exitStatus(RecorderExit(archiveStatus: saved, reason: machine.stopReason ?? .requested,
                                              message: error is CancellationError ? "Cancelled." : error.localizedDescription))
            }
            throw error
        }
    }

    // MARK: - Start

    /// Creates the live speech sessions, then starts capture epoch 0 and the session clock.
    private func start() async throws {
        do {
            if !options.recordOnly {
                for track in tracks {
                    try Task.checkCancellation()
                    let feed = makeLiveTrack(track)
                    live[track] = feed
                    try await feed.prepareSession(epoch: 0, epochStart: 0)
                }
            }
            // A run cancelled while setting up never opens the microphone or system audio.
            try Task.checkCancellation()
            let capture = dependencies.makeCapture()
            self.capture = capture
            captureStopped = false
            monitor.begin(epoch: 0)
            try await capture.start(CaptureRequest(source: options.source,
                                                   applicationBundleID: options.applicationBundleID,
                                                   timelineOffset: 0, microphone: options.microphone))
        } catch {
            dependencies.stop.restoreDefaultHandlers()
            for feed in live.values { await feed.cancel() }
            if let capture {
                captureStopped = true
                _ = await awaitWithTimeout(dependencies.timeouts.captureStop, cancellable: false) {
                    try await capture.stop()
                }
            }
            let cancelledAtStart = error is CancellationError || Task.isCancelled
            let details = cancelledAtStart ? ["error": "Cancelled before capture started.", "cancelled": "true"]
                : ["error": error.localizedDescription]
            try? await archive.recordEvent(kind: MeetingEventKind.startFailed, details: details)
            try? await archive.finish(status: ArchiveStatus.failed)
            archiveOpen = false
            await exitStatus(RecorderExit(archiveStatus: ArchiveStatus.failed, reason: .startFailed,
                                    message: details["error"]))
            Self.log.error("Session \(self.archive.id, privacy: .public) failed to start capture")
            if cancelledAtStart { throw CancellationError() }
            throw error
        }
        guard let capture else { return }
        clock = dependencies.makeClock(capture.hostTimeOrigin)
        await recordEvent(MeetingEventKind.captureStarted, [
            "hostTimeOrigin": String(capture.hostTimeOrigin), "epoch": "0", "timelineOffset": "0",
        ])
        let pump = self.pump
        let failed = writerFailed
        writerTask = Task.detached(priority: .userInitiated) {
            do { try await pump.run() } catch {
                failed.withLock { $0 = true }
                throw error
            }
        }
        startConsumer(capture, epoch: 0)
    }

    private func makeLiveTrack(_ track: String) -> LiveTrack {
        let archive = self.archive
        return LiveTrack(track: track, locale: options.locale, backend: options.backend,
                         contextualStrings: options.vocabulary, makeSpeech: dependencies.makeSpeech,
                         events: { kind, details in try await archive.recordEvent(kind: kind, details: details) },
                         reporter: reporter, showPhrases: options.liveText, timeouts: dependencies.timeouts,
                         queueSeconds: dependencies.tuning.liveQueueSeconds,
                         journalCapacity: dependencies.tuning.journalCapacity)
    }

    /// Consumes one epoch's frames off the main actor. It never waits for the disk or speech: it only stamps arrival
    /// times, brings frames to 48 kHz mono (a microphone keeps its device's format, §4.5), and hands them to the pump
    /// and the live tracks (§4.3).
    private func startConsumer(_ capture: any MeetingCapture, epoch: Int) {
        let frames = capture.frames
        let monitor = self.monitor
        let pump = self.pump
        let feeds = live
        let clock = self.clock
        consumer = Task.detached(priority: .userInitiated) {
            let format = RecordingFormatConverter()
            func deliver(_ audio: CapturedAudio) {
                if audio.followsDrop {
                    // The capture queue was full just before this frame: the gap is marked right here.
                    pump.noteGap(track: audio.track, reason: .overflow)
                    monitor.noteDrop()
                }
                if !pump.push(audio) { monitor.noteDrop() }
                feeds[audio.track]?.push(audio.frame, epoch: epoch)
            }
            /// The resamplers' last few milliseconds, before the end is reported.
            func flush() {
                do { for audio in try format.flush() { deliver(audio) } } catch {
                    Logger(subsystem: "ca.orlenko.holos.app", category: "recorder").error("Cannot flush converted audio: \(error.localizedDescription, privacy: .public)")
                }
            }
            do {
                for try await captured in frames {
                    // Nil while the resampler holds this frame's samples for the next one.
                    let audio = try format.convert(captured)
                    monitor.received(epoch: epoch, audio: audio ?? captured, at: clock.now())
                    if let audio { deliver(audio) }
                }
                flush()
                monitor.ended(epoch: epoch, error: nil, at: clock.now())
            } catch {
                flush()
                monitor.ended(epoch: epoch, error: error, at: clock.now())
            }
        }
    }

    // MARK: - Loop

    private func runLoop() async {
        var inbox = ControlInbox(session: archive.directory, sessionID: archive.id)
        let wall = ContinuousClock()
        var nextTick = wall.now
        let stopRequest = archive.directory.appendingPathComponent("stop.request")
        while machine.stopReason == nil {
            if Task.isCancelled { cancelled = true }
            // Cancelled, or a capture stop ended with CancellationError.
            if cancelled { return }
            if writerFailed.value { return }
            for event in monitor.drain() { await apply(event) }
            for item in inbox.poll() {
                switch item {
                case .request(let request):
                    await apply(.control(request, at: clock.now()))
                case .rejected(let file, let reason):
                    await rejected(file: file, reason: reason)
                }
            }
            if !stopSourceHandled, dependencies.stop.shouldStop {
                stopSourceHandled = true
                if dependencies.stop is SignalStopController {
                    await apply(.signal(at: clock.now()))
                } else {
                    await apply(.control(internalStopRequest(sender: "app"), at: clock.now()))
                }
            }
            if !legacyStopHandled, FileManager.default.fileExists(atPath: stopRequest.path) {
                legacyStopHandled = true
                await apply(.control(internalStopRequest(sender: "cli"), at: clock.now()))
            }
            if !durationHandled, let duration = options.duration, clock.now() >= duration {
                durationHandled = true
                await apply(.durationElapsed(at: clock.now()))
            }
            if wall.now >= nextTick {
                nextTick = wall.now.advanced(by: dependencies.tuning.tick)
                let free = try? dependencies.freeSpace.availableBytes(at: archive.directory)
                await apply(.tick(at: clock.now(), lidOpen: true, freeBytes: free, lastFrameAt: monitor.lastFrameAt()))
                await refreshStatus()
            } else if machine.phase != lastStatusPhase {
                await refreshStatus()
            }
            if machine.stopReason != nil { break }
            try? await Task.sleep(for: dependencies.tuning.poll)
        }
    }

    /// Feeds one input to the machine and executes its effects in order, then any inputs they produced. A cancelled
    /// run applies nothing more: the loop is about to stop, and a capture end caused by the cancellation is not a
    /// capture failure.
    private func apply(_ input: RecorderInput) async {
        var pending = [input]
        while !pending.isEmpty {
            if Task.isCancelled || cancelled {
                cancelled = true
                return
            }
            let next = pending.removeFirst()
            for effect in RecorderMachine.acknowledgingFirst(machine.handle(next)) {
                if let followUp = await execute(effect) { pending.append(followUp) }
            }
        }
    }

    private func execute(_ effect: RecorderEffect) async -> RecorderInput? {
        switch effect {
        case .stopCapture(let reason):
            await stopCapture(reason: reason)
        case .startCapture(let epoch):
            return await startCapture(epoch: epoch)
        case .recordEvent(let kind, let details):
            await recordEvent(kind, details)
        case .acknowledge(var ack):
            ack.handledAt = Date()
            // The status that carries the answer also carries its effect (paused, stopping, a new marker count).
            await acknowledge(ack, phase: machine.phase, markers: machine.markers)
        case .warn(let warning):
            await warn(warning)
        case .clearWarning(let code):
            shownWarnings.remove(code)
            let session = archive.id
            do { try await status.update { $0.warnings.removeAll { $0.code == code } } } catch {
                Self.log.error("Session \(session, privacy: .public): cannot write status.json: \(error.localizedDescription, privacy: .public)")
            }
        case .allowSleep, .holdPowerAssertion:
            // The power assertion and sleep acknowledgement arrive with PR2b.
            break
        case .finish(let reason):
            Self.log.notice("Session \(self.archive.id, privacy: .public) is stopping (\(reason.rawValue, privacy: .public))")
        }
        return nil
    }

    /// Stops the current capture (≤ the capture-stop timeout), drains its consumer, closes every open chunk with
    /// `reason` pending once the frames before it are written, and sends a boundary to each live track.
    private func stopCapture(reason: GapReason) async {
        lastGapReason = reason
        await stopCurrentCapture()
        let pump = self.pump
        if case .timedOut = await awaitWithTimeout(dependencies.timeouts.captureStop, {
            try await pump.closeAll(expectingGap: reason)
        }) {
            // Still queued behind a slow disk; the frames after it go into new chunks all the same.
            Self.log.notice("Session \(self.archive.id, privacy: .public): chunks close after the disk catches up")
        }
        for feed in live.values { feed.boundary() }
    }

    /// Asks the current capture to stop (at most the capture-stop timeout), then waits for its consumer. A cancelled run
    /// waits too: the microphone and system audio are released before it returns. A `CancellationError` from the stop
    /// (or any error once the run is cancelled) marks the run cancelled; another error is returned for the stop path
    /// to report, and only logged when capture restarts.
    @discardableResult
    private func stopCurrentCapture() async -> Error? {
        guard let capture, !captureStopped else { return nil }
        captureStopped = true
        monitor.requestStop(epoch: captureEpoch)
        let limit = dependencies.timeouts.captureStop
        let outcome = await awaitWithTimeout(limit, cancellable: false) { try await capture.stop() }
        var abandon = false
        var failure: Error?
        switch outcome {
        case .finished(.success):
            break
        case .finished(.failure(let error)):
            if error is CancellationError || Task.isCancelled {
                cancelled = true
            } else {
                failure = error
                Self.log.error("Session \(self.archive.id, privacy: .public): capture stop failed: \(error.localizedDescription, privacy: .public)")
            }
        case .timedOut:
            abandon = true
            let seconds = Self.seconds(limit)
            Self.log.error("Session \(self.archive.id, privacy: .public): capture did not stop within \(seconds, privacy: .public) s; abandoned")
            await recordEvent(MeetingEventKind.captureFailed, [
                "epoch": String(captureEpoch), "error": "Capture did not stop within \(seconds) s",
            ])
        case .cancelled:
            abandon = true
        }
        guard let consumer else { return failure }
        self.consumer = nil
        if abandon { consumer.cancel() }
        // A stopped stream ends at once; one that never ends is abandoned.
        if case .finished = await awaitWithTimeout(limit, cancellable: false, { await consumer.value }) { return failure }
        consumer.cancel()
        _ = await awaitWithTimeout(.seconds(1), cancellable: false) { await consumer.value }
        return failure
    }

    /// Starts epoch `epoch` (§2.3): the next speech sessions are ready first, then capture starts at
    /// timelineOffset max(clock.now(), lastFrameEnd + 0.01). A start failure comes back as `startFailed`.
    ///
    /// Neither step can hold up the loop: a speech session not ready within `tuning.restartLimit` is made later by
    /// its live track, and a capture that has not started by then is abandoned (stopped once its start returns) and
    /// reported as `startFailed`, so the waiting and backoff rules take over.
    private func startCapture(epoch: Int) async -> RecorderInput? {
        if cancelled || Task.isCancelled { return nil }
        let limit = dependencies.tuning.restartLimit
        let epochStart = clock.now()
        let feeds = Array(live.values)
        // The tracks' sessions are made concurrently; a creation that fails makes that track fall behind.
        if !feeds.isEmpty {
            _ = await awaitWithTimeout(limit) {
                await withTaskGroup(of: Void.self) { group in
                    for feed in feeds {
                        group.addTask { try? await feed.prepareSession(epoch: epoch, epochStart: epochStart) }
                    }
                }
            }
        }
        // The offset follows both the last frame received and the last sample written (contiguous frames are written
        // back to back, which can run past their timestamps).
        let lastEnd = [monitor.lastFrameEnd(), writer.lastFrameEnd > 0 ? writer.lastFrameEnd : nil].compactMap { $0 }.max()
        let offset = max(clock.now(), lastEnd.map { $0 + 0.01 } ?? 0)
        let capture = dependencies.makeCapture()
        self.capture = capture
        captureEpoch = epoch
        captureStopped = false
        lastCaptureDrops = 0
        monitor.begin(epoch: epoch)
        let request = CaptureRequest(source: options.source, applicationBundleID: options.applicationBundleID,
                                     timelineOffset: offset, microphone: options.microphone)
        let starting = Task { @MainActor in try await capture.start(request) }
        switch await awaitWithTimeout(limit, { try await starting.value }) {
        case .finished(.success):
            break
        case .finished(.failure(let error)):
            Self.log.error("Session \(self.archive.id, privacy: .public): epoch \(epoch, privacy: .public) failed to start")
            return .captureEnded(epoch: epoch, .startFailed(message: error.localizedDescription), at: clock.now())
        case .timedOut, .cancelled:
            // Abandoned: whenever the start returns, the capture is stopped so nothing keeps recording unseen.
            starting.cancel()
            captureStopped = true
            Task { @MainActor in
                _ = await starting.result
                try? await capture.stop()
            }
            if Task.isCancelled {
                cancelled = true
                return nil
            }
            let seconds = Self.seconds(limit)
            Self.log.error("Session \(self.archive.id, privacy: .public): epoch \(epoch, privacy: .public) did not start within \(seconds, privacy: .public) s; abandoned")
            return .captureEnded(epoch: epoch, .startFailed(message: "Audio capture did not start within \(seconds) s."),
                                 at: clock.now())
        }
        await recordEvent(MeetingEventKind.captureStarted, [
            "hostTimeOrigin": String(capture.hostTimeOrigin), "epoch": String(epoch), "timelineOffset": String(offset),
        ])
        await recordEvent(MeetingEventKind.captureRestarted, [
            "epoch": String(epoch), "at": String(clock.now()), "reason": (lastGapReason ?? .captureRestarted).rawValue,
            "timelineOffset": String(offset),
        ])
        startConsumer(capture, epoch: epoch)
        return nil
    }

    /// "5" or "0.2": a limit in seconds for a message.
    static func seconds(_ duration: Duration) -> String {
        let (whole, fraction) = duration.components
        return fraction == 0 ? String(whole)
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(whole) + Double(fraction) / 1e18)
    }

    private func internalStopRequest(sender: String) -> ControlRequest {
        let request = ControlRequest(sessionID: archive.id, command: .stop,
                                     sentAtNanos: RecorderChannel.continuousNanoseconds(), sender: sender)
        internalRequests.insert(request.id)
        return request
    }

    // MARK: - Status

    private func recordEvent(_ kind: String, _ details: [String: String]) async {
        do { try await archive.recordEvent(kind: kind, details: details) } catch {
            Self.log.error("Session \(self.archive.id, privacy: .public): cannot journal \(kind, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Journals the answer and adds it to status.json, with `phase` and `markers` when the loop is still running.
    private func acknowledge(_ ack: ControlAck, phase: RecorderPhase? = nil, markers: Int? = nil) async {
        guard !internalRequests.contains(ack.id) else { return }
        var details = ["id": ack.id, "command": ack.command.rawValue, "result": ack.result.rawValue]
        if let message = ack.message { details["message"] = message }
        if archiveOpen { await recordEvent(MeetingEventKind.controlHandled, details) }
        if let phase { lastStatusPhase = phase }
        await updateStatus { status in
            if let phase { status.phase = phase }
            if let markers { status.markers = markers }
            status.handledRequests.append(ack)
            if status.handledRequests.count > 32 { status.handledRequests.removeFirst(status.handledRequests.count - 32) }
        }
    }

    private func rejected(file: String, reason: String) async {
        Self.log.notice("Session \(self.archive.id, privacy: .public): rejected a control request: \(reason, privacy: .public)")
        if archiveOpen { await recordEvent(MeetingEventKind.controlRejected, ["file": file, "reason": reason]) }
    }

    private func warn(_ warning: RecorderWarning) async {
        let isNew = shownWarnings.insert(warning.code).inserted
        if isNew { reporter.message(warning.message) }
        let code = warning.code
        let message = warning.message
        await updateStatus { status in
            if let index = status.warnings.firstIndex(where: { $0.code == code }) {
                status.warnings[index].message = message
            } else {
                status.warnings.append(RecorderWarning(code: code, message: message, since: Date()))
            }
        }
    }

    private func updateStatus(_ change: @escaping @Sendable (inout RecorderStatus) -> Void) async {
        do { try await status.update(change) } catch {
            Self.log.error("Session \(self.archive.id, privacy: .public): cannot write status.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setPhase(_ phase: RecorderPhase) async {
        lastStatusPhase = phase
        await updateStatus { $0.phase = phase }
    }

    /// Rewrites the live fields of status.json (every tick, and when the phase changes).
    private func refreshStatus() async {
        // Drops with no frame after them yet (so no `followsDrop` frame) still warn.
        let captureDrops = capture?.droppedBuffers ?? 0
        let newCaptureDrops = captureDrops > lastCaptureDrops
        lastCaptureDrops = captureDrops
        if monitor.takeDropped() || newCaptureDrops {
            await warn(RecorderWarning(code: .audioDropped,
                                       message: "The disk could not keep up, so some audio was dropped; the gap is marked."))
        }
        if live.values.contains(where: { $0.transcription == .behind }), !shownWarnings.contains(.transcriptionBehind) {
            await warn(RecorderWarning(code: .transcriptionBehind,
                                       message: "Live transcription fell behind; the rest is transcribed from the saved audio after stop."))
        }
        let phase = machine.phase
        lastStatusPhase = phase
        let elapsed = clock.now()
        let seen = monitor.trackInfo()
        let backlog = pump.backlogSeconds()
        let bytes = writer.bytesWritten()
        let free = try? dependencies.freeSpace.availableBytes(at: archive.directory)
        let markers = machine.markers
        let recordOnly = options.recordOnly
        let trackStatuses = tracks.map { track -> TrackStatus in
            let info = seen[track]
            return TrackStatus(track: track, transcription: recordOnly ? .off : (live[track]?.transcription ?? .behind),
                               lastFrameSeconds: info?.lastFrameEnd,
                               lastFinalizedSeconds: live[track]?.lastFinalizedSeconds,
                               sampleRate: info?.sampleRate, channels: info?.channels, stalled: false,
                               backlogSeconds: backlog[track] ?? 0)
        }
        let latest = live.values.max { ($0.lastFinalizedSeconds ?? -1) < ($1.lastFinalizedSeconds ?? -1) }
        let phrase = latest?.lastPhrase
        let recorded = seen.values.map(\.seconds).max() ?? 0
        await updateStatus { status in
            status.phase = phase
            status.elapsedSeconds = elapsed
            status.recordedSeconds = recorded
            status.bytesWritten = bytes
            status.freeBytes = free
            status.tracks = trackStatuses
            status.lastPhrase = phrase
            status.markers = markers
        }
    }

    // MARK: - Stop path

    /// §4.6 steps 1–9.
    private func stopPath() async throws -> RecordingOutcome {
        let stopReason = machine.stopReason ?? (writerFailed.value ? .captureFailed : .requested)
        await setPhase(.stopping)
        answerRequestsWhileStopping()
        // 1. Stop capture, drain the consumer, let the pump drain into the writer, close every chunk. A failed stop is a
        // capture error (a timeout only records captureFailed); a CancellationError from it is a cancellation.
        if let failure = await stopCurrentCapture() { recordingError = recordingError ?? failure }
        pump.finish()
        if let writerTask {
            do { try await writerTask.value } catch { recordingError = recordingError ?? error }
        }
        do { try await writer.finish() } catch { recordingError = recordingError ?? error }
        if Task.isCancelled { cancelled = true }
        // Audio is durable: a second signal now ends processing at once.
        dependencies.stop.restoreDefaultHandlers()
        if stopReason == .startFailed, !cancelled, recordingError == nil {
            try await failStart()
        }
        var savedAudio = false
        if recordingError == nil {
            do {
                let saved = try SessionArchive.readManifest(at: archive.directory)
                savedAudio = !saved.chunks.isEmpty
                if saved.chunks.isEmpty {
                    if !cancelled { recordingError = HolosError.incomplete("No audio buffers were captured.") }
                } else {
                    for track in tracks where !saved.chunks.contains(where: { $0.track == track }) {
                        reporter.message("No \(track) audio buffers arrived; that source track is empty.")
                    }
                }
            } catch { recordingError = error }
        }
        if let recordingError {
            for feed in live.values { await feed.cancel() }
            await recordEvent(MeetingEventKind.captureFailed, ["error": recordingError.localizedDescription])
            try? await archive.finish(status: ArchiveStatus.incomplete)
            archiveOpen = false
            await exitStatus(RecorderExit(archiveStatus: ArchiveStatus.incomplete, reason: stopReason,
                                    message: recordingError.localizedDescription))
            Self.log.error("Session \(self.archive.id, privacy: .public) stopped with a capture error; saved audio is kept")
            if cancelled { throw CancellationError() }
            throw HolosError.incomplete("Recording stopped with an error: \(recordingError.localizedDescription). Saved audio: \(archive.directory.path)")
        }
        // Without transcription, the saved audio can be transcribed later (`holos session retranscribe`).
        let untranscribed = options.recordOnly ? ArchiveStatus.audioOnly : ArchiveStatus.transcriptionIncomplete
        if cancelled {
            try await finishCancelled(status: savedAudio ? untranscribed : ArchiveStatus.incomplete)
        }
        Self.log.notice("Session \(self.archive.id, privacy: .public) stopped capture (\(stopReason.rawValue, privacy: .public))")
        try await archive.setStatus(ArchiveStatus.processing)
        await setPhase(.transcribing)
        reporter.message("Audio saved. Finishing transcription; Ctrl-C exits processing and preserves the audio archive.")

        // 2–3. Finish live speech; replay only what it missed, and merge at word level.
        var segments: [TranscriptSegment] = []
        var transcriptErrors: [String] = []
        var transcriptionCancelled = false
        for track in options.recordOnly ? [] : tracks {
            if Task.isCancelled { break }
            guard let feed = live[track] else { continue }
            let result = await feed.finish()
            if Task.isCancelled { break }
            guard let behindFrom = result.behindFrom else {
                segments += result.segments
                continue
            }
            let coverage = TranscriptCoverage.coverageEnd(live: result.segments, behindFrom: behindFrom)
            var replayed: [TranscriptSegment] = []
            do {
                reporter.message("Processing saved \(track) audio…")
                // Every speech call of the replay has a time limit (§1.3), like the live finish before it.
                replayed = try await TrackReplayer.replay(directory: archive.directory, track: track,
                    locale: options.locale, backend: options.backend, contextualStrings: options.vocabulary,
                    from: max(0, coverage - 2), makeSpeech: dependencies.makeSpeech, timeouts: dependencies.timeouts)
            } catch let partial as ReplayIncomplete {
                // Speech stopped answering: keep what it returned; the track is incomplete.
                replayed = partial.segments
                transcriptErrors.append("\(track): \(partial.localizedDescription)")
            } catch {
                // A cancelled replay is a cancellation, not a transcription failure.
                if error is CancellationError || Task.isCancelled {
                    transcriptionCancelled = true
                    break
                }
                transcriptErrors.append("\(track): \(error.localizedDescription)")
            }
            segments += TranscriptCoverage.merge(live: result.segments, replayed: replayed, coverageEnd: coverage)
        }
        // Cancelled during transcription: keep the audio, publish no partial transcript.
        if transcriptionCancelled || Task.isCancelled {
            try await finishCancelled(status: untranscribed)
        }
        // 4. The transcript, named by transcripts/current.json.
        var transcriptID: String?
        if !options.recordOnly {
            segments.sort { $0.start == $1.start ? ($0.track ?? "") < ($1.track ?? "") : $0.start < $1.start }
            let transcript = Transcript(source: archive.directory.path, locale: options.locale,
                                        backend: options.backend, segments: segments)
            try await archive.saveTranscript(transcript, writeLegacyExports: false)
            transcriptID = transcript.id
        }
        try await archive.recordEvent(kind: MeetingEventKind.captureStopped, details: [
            "transcriptionErrors": transcriptErrors.joined(separator: "; "), "reason": stopReason.rawValue,
        ])
        let finalStatus = options.recordOnly ? ArchiveStatus.audioOnly
            : (transcriptErrors.isEmpty ? ArchiveStatus.complete : ArchiveStatus.transcriptionIncomplete)
        if Task.isCancelled {
            try await archive.finish(status: finalStatus)
            archiveOpen = false
            await exitStatus(RecorderExit(archiveStatus: finalStatus, reason: stopReason, message: "Cancelled."))
            throw CancellationError()
        }

        // 5–6. The lease is taken while the writer lock is still held, so the session is never without a lock
        // between capture and post-processing.
        var lease: ProcessingLease?
        var leaseCancelled = false
        if dependencies.postProcess != nil {
            do { lease = try await acquireLease() } catch { leaseCancelled = true }
        }
        defer { lease?.release() }
        try await archive.finish(status: finalStatus)
        archiveOpen = false
        // Cancelled while the lease was being taken: the archive is finished; skip the hook, release the lease.
        if leaseCancelled || Task.isCancelled {
            Self.log.notice("Session \(self.archive.id, privacy: .public) cancelled before post-processing; archive finished as \(finalStatus, privacy: .public)")
            await exitStatus(RecorderExit(archiveStatus: finalStatus, reason: stopReason, message: "Cancelled."))
            lease?.release()
            throw CancellationError()
        }
        // 7. Post-processing under the lease; its progress is mirrored into status.json in order.
        var postRecord: PostProcessingRecord?
        if let hook = dependencies.postProcess, let lease {
            await setPhase(.postprocessing)
            let mirror = ProgressMirror(status: status)
            postRecord = await hook(archive.directory, lease, progressHandler(mirror))
            await mirror.finish()
            Self.log.notice("Session \(self.archive.id, privacy: .public) post-processing ended: \(postRecord?.state.rawValue ?? "", privacy: .public)")
            // The hook never throws; a cancellation during it still ends the run with CancellationError.
            if Task.isCancelled {
                await exitStatus(RecorderExit(archiveStatus: finalStatus, reason: stopReason, message: "Cancelled.",
                                        postprocessing: postRecord?.state, postprocessingMessage: postRecord?.message))
                lease.release()
                throw CancellationError()
            }
        }
        // 8–9. status.json says exited, then the lease is released, so no one reads a `postprocessing` status without
        // a lock as a dead recorder; leftover requests are deleted.
        await exitStatus(RecorderExit(archiveStatus: finalStatus, reason: stopReason,
                                postprocessing: postRecord?.state, postprocessingMessage: postRecord?.message))
        lease?.release()
        return RecordingOutcome(sessionID: archive.id, directory: archive.directory, archiveStatus: finalStatus,
                                stopReason: stopReason, transcriptID: transcriptID,
                                transcriptErrors: transcriptErrors, postProcessing: postRecord)
    }

    /// Epoch 0 ended before its first frame: nothing was recorded.
    private func failStart() async throws -> Never {
        for feed in live.values { await feed.cancel() }
        let journal = try? SessionArchive.readEvents(at: archive.directory)
        let message = journal?.events.last { $0.kind == MeetingEventKind.startFailed }?.details["error"]
            ?? "Audio capture stopped before any audio arrived."
        try? await archive.finish(status: ArchiveStatus.failed)
        archiveOpen = false
        await exitStatus(RecorderExit(archiveStatus: ArchiveStatus.failed, reason: .startFailed, message: message))
        Self.log.error("Session \(self.archive.id, privacy: .public): capture ended before any audio")
        throw HolosError.incomplete("Audio capture did not start: \(message)")
    }

    /// Cancels live speech, records the stop, finishes the archive with `status`, and rethrows the cancellation.
    private func finishCancelled(status archiveStatus: String) async throws -> Never {
        for feed in live.values { await feed.cancel() }
        try? await archive.recordEvent(kind: MeetingEventKind.captureStopped, details: ["cancelled": "true"])
        try? await archive.finish(status: archiveStatus)
        archiveOpen = false
        await exitStatus(RecorderExit(archiveStatus: archiveStatus, reason: machine.stopReason ?? .requested,
                                message: "Cancelled."))
        Self.log.notice("Session \(self.archive.id, privacy: .public) cancelled; archive finished as \(archiveStatus, privacy: .public)")
        throw CancellationError()
    }

    /// Takes the processing lease (retry 1 s) off the main actor. On failure, post-processing is skipped. Throws only
    /// `CancellationError`.
    private func acquireLease() async throws -> ProcessingLease? {
        let directory = archive.directory
        let sessionID = archive.id
        do {
            return try await Task.detached { try SessionArchive.acquireProcessingLease(at: directory) }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch HolosError.unavailable {
            Self.log.error("Session \(sessionID, privacy: .public): processing lease held elsewhere; post-processing skipped")
            reporter.message("Another Holos process is labelling this meeting.")
            return nil
        } catch {
            let code = error as NSError
            Self.log.error("Session \(sessionID, privacy: .public): cannot take the processing lease (\(code.domain, privacy: .public) \(code.code, privacy: .public)): \(error.localizedDescription, privacy: .private); post-processing skipped")
            reporter.message("Speaker labelling skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// Mirrors progress into status.json and passes each new message to the reporter once, so repeated progress
    /// updates of one step (fractions) print one line.
    private func progressHandler(_ mirror: ProgressMirror) -> @Sendable (PostProcessingProgress) -> Void {
        let reporter = self.reporter
        let last = LockedValue<String?>(nil)
        return { progress in
            mirror.send(progress)
            let isNew = last.withLock { previous in
                guard previous != progress.message else { return false }
                previous = progress.message
                return true
            }
            if isNew { reporter.message(progress.message) }
        }
    }

    /// After capture stops, every request is acknowledged `ignored` once a second until exit (§4.6).
    private func answerRequestsWhileStopping() {
        guard stoppedInbox == nil else { return }
        let interval = dependencies.tuning.stoppedPoll
        stoppedInbox = Task { [weak self] in
            while !Task.isCancelled {
                await self?.answerStoppedRequests()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func answerStoppedRequests() async {
        var inbox = ControlInbox(session: archive.directory, sessionID: archive.id)
        for item in inbox.poll() {
            switch item {
            case .request(let request):
                await acknowledge(ControlAck(id: request.id, command: request.command, result: .ignored,
                                             message: RecorderMachine.alreadyStopping))
            case .rejected(let file, let reason):
                await rejected(file: file, reason: reason)
            }
        }
    }

    /// Stops answering requests (after a last answer), writes phase `exited`, and deletes leftover requests.
    private func exitStatus(_ exit: RecorderExit) async {
        guard !exited else { return }
        exited = true
        if let stoppedInbox {
            stoppedInbox.cancel()
            await stoppedInbox.value
            self.stoppedInbox = nil
        }
        await answerStoppedRequests()
        do { try await status.finish(exit: exit) } catch {
            Self.log.error("Session \(self.archive.id, privacy: .public): cannot write the final status: \(error.localizedDescription, privacy: .public)")
        }
        ControlInbox.removeLeftovers(session: archive.directory)
    }
}

extension RecorderMachine {
    /// The order in which the loop executes `effects`: as emitted, except that acknowledgements go ahead of stopping or
    /// starting capture. The machine has already decided the change, and a sender waits only 3 s for its answer
    /// (§4.1), while a capture stop, the drain of the chunks queued before it, or the next epoch's speech sessions can
    /// take longer.
    static func acknowledgingFirst(_ effects: [RecorderEffect]) -> [RecorderEffect] {
        func isCapture(_ effect: RecorderEffect) -> Bool {
            switch effect {
            case .stopCapture, .startCapture: true
            default: false
            }
        }
        func isAck(_ effect: RecorderEffect) -> Bool {
            if case .acknowledge = effect { return true }
            return false
        }
        guard let first = effects.firstIndex(where: isCapture) else { return effects }
        let rest = effects[first...]
        return Array(effects[..<first]) + rest.filter(isAck) + rest.filter { !isAck($0) }
    }
}

// MARK: - Shared with the frame consumer

/// What the frame consumer tells the loop, shared off the main actor.
final class EpochMonitor: Sendable {
    struct TrackInfo: Sendable, Equatable {
        /// Session time at which the consumer last received a frame (watchdog time).
        var lastFrameAt: Double
        /// Session time of the end of the last frame.
        var lastFrameEnd: Double
        /// Seconds of audio received.
        var seconds: Double
        var sampleRate: Double
        var channels: Int
    }

    private struct State {
        var epoch = 0
        var sawFrame = false
        var stopRequested: Set<Int> = []
        var events: [RecorderInput] = []
        var tracks: [String: TrackInfo] = [:]
        var dropped = false
    }

    private let state = Mutex(State())

    func begin(epoch: Int) {
        state.withLock { state in
            state.epoch = epoch
            state.sawFrame = false
            // A stop requested after its epoch's stream had already ended is never matched; an older epoch's end
            // is stale for the machine anyway.
            state.stopRequested = state.stopRequested.filter { $0 >= epoch }
        }
    }

    func requestStop(epoch: Int) { state.withLock { _ = $0.stopRequested.insert(epoch) } }

    /// Tests only: stop requests not yet matched with their epoch's end.
    var pendingStopRequests: Int { state.withLock { $0.stopRequested.count } }

    func received(epoch: Int, audio: CapturedAudio, at: Double) {
        state.withLock { state in
            if epoch == state.epoch, !state.sawFrame {
                state.sawFrame = true
                state.events.append(.captureRunning(epoch: epoch, at: at))
            }
            let frame = audio.frame
            var info = state.tracks[audio.track] ?? TrackInfo(lastFrameAt: at, lastFrameEnd: 0, seconds: 0,
                                                             sampleRate: frame.sampleRate, channels: frame.channels)
            info.lastFrameAt = at
            info.lastFrameEnd = max(info.lastFrameEnd, frame.startTime + frame.duration)
            info.seconds += frame.duration
            info.sampleRate = frame.sampleRate
            info.channels = frame.channels
            state.tracks[audio.track] = info
        }
    }

    /// The frame stream of `epoch` ended, with `error` or normally.
    func ended(epoch: Int, error: Error?, at: Double) {
        state.withLock { state in
            let end: CaptureEnd
            // An epoch's stream ends once: its entry goes, so restarts over a long recording do not pile up.
            if state.stopRequested.remove(epoch) != nil {
                end = .requested
            } else if let interruption = error as? CaptureInterruption {
                end = interruption == .userStoppedSharing ? .userStoppedSharing : .configurationChanged
            } else if let error {
                end = .failed(message: error.localizedDescription)
            } else {
                end = .failed(message: "Audio capture ended unexpectedly.")
            }
            state.events.append(.captureEnded(epoch: epoch, end, at: at))
        }
    }

    func drain() -> [RecorderInput] {
        state.withLock { state in
            defer { state.events.removeAll() }
            return state.events
        }
    }

    func noteDrop() { state.withLock { $0.dropped = true } }

    /// True once after audio was dropped.
    func takeDropped() -> Bool {
        state.withLock { state in
            defer { state.dropped = false }
            return state.dropped
        }
    }

    /// The largest frame end on any track; nil before any audio.
    func lastFrameEnd() -> Double? { state.withLock { $0.tracks.values.map(\.lastFrameEnd).max() } }

    func lastFrameAt() -> [String: Double] { state.withLock { $0.tracks.mapValues(\.lastFrameAt) } }

    func trackInfo() -> [String: TrackInfo] { state.withLock { $0.tracks } }
}

/// Post-processing progress on its way into status.json: one queue read by one task, so updates land in order; a
/// burst is coalesced to its latest value.
private final class ProgressMirror: Sendable {
    private let queue = WorkQueue<PostProcessingProgress>(capacity: .infinity) { _ in 0 }
    private let task: Task<Void, Never>

    init(status: StatusWriter) {
        let queue = self.queue
        task = Task {
            while let first = await queue.next() {
                var latest = first
                while !queue.isEmpty, let newer = await queue.next() { latest = newer }
                let progress = latest
                try? await status.update { status in
                    status.phase = .postprocessing
                    status.progress = progress
                }
            }
        }
    }

    func send(_ progress: PostProcessingProgress) { queue.push(progress) }

    /// Writes what is queued and stops.
    func finish() async {
        queue.close()
        await task.value
    }
}
