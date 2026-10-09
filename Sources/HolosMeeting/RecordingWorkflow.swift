import Darwin
import Foundation
import HolosAudio
import HolosCore
import HolosSpeech
import HolosStorage
import os

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
    /// Contextual strings for every speech session of this recording (§4.12), as `MeetingVocabulary.cleaned` keeps
    /// them. Saved as `vocabulary.json`.
    public var vocabulary: [String]
    /// The session ID (a UUID, passed to `SessionArchive.create(id:)`); nil makes one. No folder may exist for it.
    public var sessionID: String?
    /// In a call, also label speakers on the microphone track because others share the room. Only with mic+system.
    public var othersInRoom: Bool
    /// The number of people expected (1…20), a hint for speaker labelling.
    public var expectedSpeakers: Int?
    /// Report finalized phrases while recording (the CLI prints them); false for `--no-live-text`.
    public var liveText: Bool
    /// Which input the microphone track records (decision 9, §4.12): by default the built-in microphone for `mic`
    /// and the system default input for `mic+system` (the device the call app uses). Meetings from the app record
    /// the system default input either way (`MeetingStartSettings.app`, `--microphone default`).
    public var microphone: MicrophoneSelection
    /// The meeting's languages, `locale` first (docs/meeting-design.md §4.14). Live transcription uses `locale` only;
    /// with more than one, meeting.json records them and post-processing transcribes the audio again in each and
    /// merges the transcript. Empty: `locale` only.
    public var languages: [String]
    /// Capture the screen while recording, for on-device OCR after the recording (docs/meeting-design.md §4.15);
    /// nil: no screen capture.
    public var screen: ScreenCaptureTarget?
    /// Where `name` came from (docs/meeting-design.md §4.17): `user` when the user gave it (the start panel's field,
    /// `--name`), whatever it looks like; `default` for a name Voice is Local made up.
    public var nameSource: MeetingNameSource

    /// `microphone` nil chooses it from `source`: `.builtIn` for `mic`, `.systemDefault` otherwise.
    public init(name: String, source: AudioSource, locale: String, backend: SpeechBackend, root: URL,
                duration: Double? = nil, recordOnly: Bool = false, applicationBundleID: String? = nil,
                vocabulary: [String] = [], sessionID: String? = nil, othersInRoom: Bool = false,
                expectedSpeakers: Int? = nil, liveText: Bool = true, microphone: MicrophoneSelection? = nil,
                languages: [String] = [], screen: ScreenCaptureTarget? = nil,
                nameSource: MeetingNameSource = .user) {
        self.nameSource = nameSource
        self.name = name; self.source = source; self.locale = locale; self.backend = backend; self.root = root
        self.duration = duration; self.recordOnly = recordOnly; self.applicationBundleID = applicationBundleID
        self.vocabulary = vocabulary; self.sessionID = sessionID; self.othersInRoom = othersInRoom
        self.expectedSpeakers = expectedSpeakers; self.liveText = liveText
        self.microphone = microphone ?? Self.microphone(for: source)
        self.languages = languages
        self.screen = screen
    }

    /// Decision 9: in person records the built-in microphone; a call records the system default input.
    public static func microphone(for source: AudioSource) -> MicrophoneSelection {
        source == .microphone ? .builtIn : .systemDefault
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
    /// System sleep and wake, and the lid state (§4.4); nil: none are seen, and the lid counts as open.
    public var power: (any SystemPowerEvents)?
    /// Takes the idle-sleep assertion, named by its argument (§4.4). nil from it: no assertion is held.
    public var makePowerAssertion: @Sendable (String) -> PowerAssertion?
    /// Recording-only display assertion; inert in tests unless explicitly injected.
    public var makeDisplayAssertion: @Sendable (String) -> (any PowerAssertionHandle)? = { _ in nil }
    /// The built-in microphone and the system default input, looked up before every capture start (§4.12).
    public var findInputDevices: @Sendable () -> InputDevices
    /// Device-list changes and screen unlocks, after which a waiting recorder retries at once (§4.2); nil: none.
    public var environmentEvents: AudioEnvironmentEvents?
    /// A recorder running inside the app sets this to wait, after `run` returns, for an exited status that could not
    /// be written at once (`ExitRetry`); nil (a child recorder): the process exit releases the locks instead.
    public var exitStatusWait: ExitStatusWait?
    /// The language of a meeting from the app whose settings name none (`RecordingOptions(settings:…)`), as
    /// `voiceislocal record start` takes it without `--locale`; inert: `DictationLanguage.standard`.
    public var defaultLocale: @Sendable () async -> String = { DictationLanguage.standard }
    /// Loop cadence and queue sizes; tests shorten them.
    var tuning = RecorderTuning()
    /// Tests only: sees every status.json written, in order.
    var statusObserver: (@Sendable (RecorderStatus) -> Void)?
    /// Tests only: replaces the atomic write of status.json (to inject failures).
    var statusWrite: StatusWriter.FileWrite?
    /// Host-clock seconds, sampled with the session clock when a restart's timeline offset is taken
    /// (`CaptureRequest.offsetHostTime`). Tests pair it with a manual session clock.
    var hostTime: @Sendable () -> Double = { AudioCapture.hostSeconds() }

    /// No hardware defaults: tests use `.testing(...)` (Fakes.swift). The defaults of the later parameters are
    /// inert: a clock that starts when epoch 0 starts, unlimited free space, the standard timeouts, no power events
    /// or assertion, a placeholder built-in microphone that is also the default input, no environment events, and an
    /// unknown output route.
    public init(makeCapture: @escaping @MainActor @Sendable () -> any MeetingCapture,
                makeSpeech: @escaping LiveSpeechFactory, stop: any RecorderStopSource,
                reporter: any RecordingReporter, postProcess: PostProcessHook?,
                makeClock: (@Sendable (Double) -> any SessionClock)? = nil,
                freeSpace: any FreeSpaceProvider = FixedFreeSpace(.max), timeouts: StopTimeouts = .standard,
                power: (any SystemPowerEvents)? = nil,
                makePowerAssertion: @escaping @Sendable (String) -> PowerAssertion? = { _ in nil },
                findInputDevices: @escaping @Sendable () -> InputDevices = { RecordingDependencies.placeholderDevices },
                environmentEvents: AudioEnvironmentEvents? = nil) {
        self.makeCapture = makeCapture; self.makeSpeech = makeSpeech; self.stop = stop
        self.reporter = reporter; self.postProcess = postProcess
        self.makeClock = makeClock ?? { _ in ElapsedSessionClock() }
        self.freeSpace = freeSpace; self.timeouts = timeouts
        self.power = power; self.makePowerAssertion = makePowerAssertion
        self.findInputDevices = findInputDevices; self.environmentEvents = environmentEvents
    }

    /// LiveMeetingCapture + AppleSpeechSession.make, `ContinuousSessionClock`, `VolumeFreeSpace`, `SystemPowerMonitor`,
    /// `PowerAssertion`, `BuiltInMicrophone.devices`, `AudioEnvironmentEvents`, `AppleSpeechEngine.defaultLocale`.
    public static func live(stop: any RecorderStopSource, reporter: any RecordingReporter,
                            postProcess: PostProcessHook?) -> RecordingDependencies {
        var dependencies = RecordingDependencies(makeCapture: { IndependentMeetingCapture() }, makeSpeech: appleSpeechFactory,
                              stop: stop, reporter: reporter, postProcess: postProcess,
                              makeClock: { ContinuousSessionClock(hostTimeOrigin: $0) }, freeSpace: VolumeFreeSpace(),
                              power: livePowerMonitor(), makePowerAssertion: livePowerAssertion,
                              findInputDevices: { BuiltInMicrophone.devices() },
                              environmentEvents: AudioEnvironmentEvents())
        dependencies.defaultLocale = { await AppleSpeechEngine.defaultLocale(backend: .speech) }
        dependencies.makeDisplayAssertion = { reason in
            do { return try PowerAssertion(reason: reason, kind: .display) }
            catch {
                log.error("No display-sleep assertion: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return dependencies
    }

    /// The inert default of `findInputDevices`: a built-in microphone that is also the default input.
    public static let placeholderDevices: InputDevices = {
        let builtIn = InputDevice(id: 0, uid: "BuiltInMicrophoneDevice", name: "Built-in Microphone")
        return InputDevices(builtIn: builtIn, systemDefault: builtIn)
    }()

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "power")

    /// A recording without a sleep monitor keeps going; it just does not see sleep coming.
    private static func livePowerMonitor() -> SystemPowerMonitor? {
        do { return try SystemPowerMonitor() } catch {
            log.error("No sleep monitor: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func livePowerAssertion(_ reason: String) -> PowerAssertion? {
        do { return try PowerAssertion(reason: reason) } catch {
            log.error("No idle-sleep assertion: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
    /// How long the stop path retries the processing lease before post-processing is skipped (§4.6).
    var leaseRetry: Duration = .seconds(1)
    /// After `StatusWriter` gave up on the exited status, it is tried again this long later, then twice as long after
    /// each failure, up to `exitRetryLimit` (`ExitRetry`).
    var exitRetry: Duration = .seconds(5)
    var exitRetryLimit: Duration = .seconds(60)
    var pumpCapacitySeconds = 60.0
    var liveQueueSeconds = LiveTrack.queueSeconds
    var journalCapacity = LiveTrack.journalCapacity
    /// The stall limits (3 s to warn, 10 s to restart the microphone).
    var watchdog = TrackWatchdog()
    /// Everything done for a sleep before it is allowed (stop capture, close chunks) beyond the capture-stop limit;
    /// macOS waits at most 30 s (§4.4).
    var sleepMargin: Duration = .seconds(2)
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
    /// The hook's record; nil only when no hook was configured. A configured hook that could not run (the processing
    /// lease was held elsewhere or could not be taken) gives a `.failed` record whose message says why.
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

    /// Records until stop, saves audio and transcript, then (with a hook) takes the processing lease,
    /// finishes the archive, and runs the hook under the lease (§4.6 steps 5–8).
    ///
    /// The session folder gets `meeting.json`, `vocabulary.json` (when there is a vocabulary), and `status.json`,
    /// which is rewritten every second until it says `exited`. The loop runs `RecorderMachine`: capture restarts in
    /// new epochs after a failure or a device change, waits and retries while audio is unavailable, pauses, and
    /// answers control requests in `control/` (§4.1, §4.2). A finished recording returns an outcome whatever stopped it
    /// (`stopReason`), including 10 minutes without audio (`captureFailed`), a low disk (`diskLow`), and a sleep of 15
    /// minutes or more (`sleepTimeout`).
    ///
    /// Sleep and power (§4.4): the idle-sleep assertion is held from start to exit, except while paused. Before a
    /// system sleep capture stops and the chunks are closed, then the sleep is allowed; a wake within 15 minutes with
    /// the lid open resumes in a new epoch. A track that delivers nothing for 3 s is reported stalled, and a silent
    /// microphone is restarted. The microphone (§4.12): in person the built-in one, a call the system default input;
    /// a call without any input device records system audio alone until one appears, and a call whose microphone is
    /// the built-in one records system audio alone while the lid is closed, until the lid opens (or the screen is
    /// unlocked with it open). Closing the lid mid-recording on the built-in microphone restarts capture: a call goes
    /// on with system audio alone, a microphone-only recording waits for the lid.
    ///
    /// Throws before creating a session for invalid options, when the disk has too little space, and in person when
    /// the built-in microphone is missing. Capture never started: the archive is finished `failed` and the error is
    /// thrown. Audio could not be saved (the writer failed, or no audio arrived): marks the archive incomplete and
    /// throws `HolosError.incomplete`. Transcription failure: does not throw; the outcome carries the errors. A hook
    /// that cannot get the processing lease does not run: the outcome and `status.json` carry a `.failed`
    /// post-processing record saying so.
    ///
    /// Task cancellation: stops like a stop request, keeps the saved audio, finishes the archive without a partial
    /// transcript (`transcriptionIncomplete`, or `audioOnly` for record-only), skips post-processing, and rethrows
    /// `CancellationError`. Cancelled before capture starts: capture never starts and the archive is finished
    /// `failed` (a `startFailed` event with `cancelled`). Cancelled once the transcript is saved: the archive keeps
    /// its final status, the processing lease is released, and a hook that has not started is skipped. Cancelled
    /// during the hook: the hook's run ends as it chooses, and `CancellationError` is rethrown instead of an outcome.
    /// In every case `status.json` ends `exited` and no lock is left held; it says `exited` before the session's last
    /// lock (the writer lock, or the processing lease) is released, so `RecorderChannel.liveness` never reads `dead`
    /// on the way out.
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
        // A microphone-only recording without its microphone: refused before a session exists (§4.12).
        let devices = dependencies.findInputDevices()
        guard let plan = EpochPlan.make(options, devices: devices,
                                        lidOpen: dependencies.power?.isLidOpen() ?? true) else {
            throw HolosError.unavailable(EpochPlan.unavailableMessage(options, devices: devices))
        }
        try checkDisk(options, dependencies)
        let archive = try SessionArchive.create(root: options.root, name: options.name, source: options.source,
                                                locale: options.locale, backend: options.backend, id: options.sessionID)
        let recorder: Recorder
        do {
            recorder = try Recorder(archive: archive, options: options, dependencies: dependencies, plan: plan)
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
        if !options.languages.isEmpty {
            if let problem = DictationLanguage.meetingLanguagesProblem(options.languages) {
                throw HolosError.invalidInput(problem)
            }
            options.languages = DictationLanguage.meetingLanguages(options.languages)
            guard options.languages.first == DictationLanguage.identifier(options.locale) else {
                throw HolosError.invalidInput(
                    "The meeting's first language must be the one it is transcribed in live (\(options.locale)).")
            }
        }
        if let id = options.sessionID {
            guard let uuid = UUID(uuidString: id) else {
                throw HolosError.invalidInput("A session ID must be a UUID, like \(UUID().uuidString).")
            }
            options.sessionID = uuid.uuidString
        }
        options.vocabulary = MeetingVocabulary.cleaned(options.vocabulary)
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

/// One recording from its first status write to `exited` (docs/meeting-design.md §4.2, §4.6). Its work is split by
/// concern: `Recorder+Capture` (epochs), `+Power`, `+Status` (status.json and the journal) and `+Stop` (the stop
/// path); `RecorderExitSequence` writes the exited status and lets go of the locks still held at the end.
///
/// Invariants:
/// 1. Once `init` has succeeded, `run` ends through `exitSequence` (`finish`, or `finishUnlessWritten` in its catch)
///    before it returns or throws.
/// 2. The stop path takes the processing lease while it still holds the writer lock, and the recorder lets the lease
///    go only through `exitSequence` (`finish` or `release`).
/// 3. The stop path finishes the pump, awaits the writer task and finishes the chunk writer before it reads the
///    manifest, saves a transcript or takes the processing lease.
/// 4. The recorder calls `stop()` at most once per capture: `captureStopped` is set before each call and cleared
///    only for a new capture.
/// 5. The stop source, `stop.request` and the duration are each applied at most once (their `…Handled` flags).
/// 6. Once `cancelled` is set, `apply` applies no more inputs and `run` throws `CancellationError`.
/// 7. Every willSleep the loop drains is allowed (`allowSleep`) right after it is applied.
@MainActor
final class Recorder {
    static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

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
    /// live.json: the live tracks' volatile words, for the app's live transcript; closed once live speech ends.
    let liveText: LiveTextPublisher
    var machine: RecorderMachine
    /// Session time; a placeholder at 0 until epoch 0's capture starts.
    var clock: any SessionClock = ManualSessionClock(0)
    var capture: (any MeetingCapture)?
    var captureEpoch = 0
    /// What the current epoch records (epoch 0's is decided before the session is created).
    var plan: EpochPlan
    /// The idle-sleep assertion is wanted (from start to exit, except while paused, §4.4).
    var powerHeld = false
    var powerAssertion: PowerAssertion?
    var displayAssertion: (any PowerAssertionHandle)?
    var displayHeld = false
    /// willSleep tokens not yet acknowledged.
    var pendingSleepTokens: [Int] = []
    /// While a willSleep waits for the loop: when the sleep must be allowed (the capture-stop limit plus
    /// `tuning.sleepMargin` after it was drained). Every step before `allowSleep` ends by then.
    var sleepDeadline: ContinuousClock.Instant?
    var sleepBudget: Duration { dependencies.timeouts.captureStop + dependencies.tuning.sleepMargin }
    /// The lid state at the last tick.
    var lidOpen = true
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
    /// Writes `exited` and lets go of the locks the recorder still holds when the run ends.
    lazy var exitSequence = RecorderExitSequence(
        archive: archive, status: status, liveText: liveText, tuning: dependencies.tuning,
        exitStatusWait: dependencies.exitStatusWait) { [weak self] in await self?.answerStoppedRequests() }

    init(archive: SessionArchive, options: RecordingOptions, dependencies: RecordingDependencies,
         plan: EpochPlan) throws {
        self.archive = archive
        self.options = options
        self.dependencies = dependencies
        self.plan = plan
        let tracks = options.source == .microphoneAndSystem ? ["mic", "system"] : [options.source.rawValue]
        self.tracks = tracks
        machine = RecorderMachine(tracks: tracks, watchdog: dependencies.tuning.watchdog)
        writer = AudioChunkWriter(archive: archive)
        pump = ChunkWriterPump(writer: writer, capacitySeconds: dependencies.tuning.pumpCapacitySeconds)
        let directory = archive.directory
        liveText = LiveTextPublisher(session: directory)
        let info = MeetingInfo(sessionID: archive.id, mode: options.source == .microphone ? .inPerson : .call,
                               othersInRoom: options.othersInRoom, applicationBundleID: options.applicationBundleID,
                               expectedSpeakers: options.expectedSpeakers,
                               languages: options.languages.count > 1 ? options.languages : nil,
                               nameSource: options.nameSource)
        try AtomicFile.create(try HolosJSON.encoder().encode(info), at: SessionPaths.meetingInfo(directory))
        if !options.vocabulary.isEmpty {
            try AtomicFile.create(try HolosJSON.encoder().encode(MeetingVocabulary(strings: options.vocabulary)),
                                  at: SessionPaths.vocabulary(directory))
        }
        let now = Date()
        let initial = RecorderStatus(
            sessionID: archive.id, name: options.name, pid: getpid(), phase: .starting, sequence: 0, startedAt: now,
            updatedAt: now, source: options.source, microphoneName: plan.microphoneName,
            microphoneIsSystemDefault: options.source == .system ? nil : options.microphone == .systemDefault,
            tracks: tracks.map { TrackStatus(track: $0, transcription: options.recordOnly ? .off : .live) })
        status = try StatusWriter(session: directory, initial: initial, heartbeat: dependencies.tuning.tick,
                                  observer: dependencies.statusObserver, write: dependencies.statusWrite)
        lastStatusPhase = .starting
    }

    func run() async throws -> RecordingOutcome {
        // The Mac does not idle-sleep from start to exit, except while paused (§4.4).
        holdPower(true)
        defer { holdDisplay(false); holdPower(false) }
        // Sleep and wake during the start (a permission prompt, speech setup) are queued for the loop, which drains
        // them first; the monitor lets the Mac sleep at once meanwhile (§4.4). A failed start detaches here; a
        // finished loop has detached already.
        let power = dependencies.power
        power?.observe()
        defer { power?.detach() }
        await archive.setJournalSync(.interval(seconds: 1))
        try await start()
        holdDisplay(true)
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
                try? await archive.finish(status: ArchiveStatus.transcriptionIncomplete, keepingLock: true)
                archiveOpen = false
            }
            await exitSequence.finishUnlessWritten {
                let saved = (try? SessionArchive.readManifest(at: archive.directory).status) ?? ArchiveStatus.incomplete
                return RecorderExit(archiveStatus: saved, reason: machine.stopReason ?? .requested,
                                    message: error is CancellationError ? "Cancelled." : error.localizedDescription)
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
            // Plan epoch 0 again from the devices and lid of now: the default input or the lid may have changed
            // while the speech sessions and the permission prompt were set up. A plan that is no longer possible
            // keeps the first one, and the capture's own start then fails and is reported.
            if let fresh = EpochPlan.make(options, devices: dependencies.findInputDevices(),
                                          lidOpen: dependencies.power?.isLidOpen() ?? true), fresh != plan {
                let name = fresh.microphoneName
                if name != plan.microphoneName { await updateStatus { $0.microphoneName = name } }
                plan = fresh
            }
            let capture = dependencies.makeCapture()
            self.capture = capture
            captureStopped = false
            monitor.begin(epoch: 0)
            try await capture.start(CaptureRequest(source: plan.source,
                                                   applicationBundleID: options.applicationBundleID,
                                                   timelineOffset: 0, microphone: options.microphone,
                                                   screen: options.screen,
                                                   sessionDirectory: options.screen == nil ? nil : archive.directory))
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
            try? await archive.finish(status: ArchiveStatus.failed, keepingLock: true)
            archiveOpen = false
            await exitSequence.finish(RecorderExit(archiveStatus: ArchiveStatus.failed, reason: .startFailed,
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
        let liveText = self.liveText
        return LiveTrack(track: track, locale: options.locale, backend: options.backend,
                         contextualStrings: options.vocabulary, makeSpeech: dependencies.makeSpeech,
                         events: { kind, details in try await archive.recordEvent(kind: kind, details: details) },
                         reporter: reporter, showPhrases: options.liveText, timeouts: dependencies.timeouts,
                         queueSeconds: dependencies.tuning.liveQueueSeconds,
                         journalCapacity: dependencies.tuning.journalCapacity,
                         onVolatile: { track, segments in liveText.set(track: track, segments: segments) })
    }

    /// Consumes one epoch's frames off the main actor. It never waits for the disk or speech: it only stamps arrival
    /// times, brings frames to 48 kHz mono (a microphone keeps its device's format, §4.5), and hands them to the pump
    /// and the live tracks (§4.3).
    func startConsumer(_ capture: any MeetingCapture, epoch: Int) {
        let frames = capture.frames
        let monitor = self.monitor
        let pump = self.pump
        let feeds = live
        let clock = self.clock
        consumer = Task.detached(priority: .userInitiated) {
            let format = RecordingFormatConverter()
            func deliver(_ audio: CapturedAudio) {
                if let reason = audio.discontinuity {
                    pump.noteGap(track: audio.track, reason: reason)
                    feeds[audio.track]?.boundary()
                }
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
        // Sleep waits for the loop only while it runs; before and after, the monitor lets the Mac sleep at once (§4.4).
        // Events queued since `observe()` in `run()` stay and are drained first.
        let power = dependencies.power
        power?.attach()
        defer {
            power?.detach()
            pendingSleepTokens.removeAll()
        }
        // Epoch 0 was planned before the speech sessions and permissions were set up. A plan that records the
        // microphone counts as made with the lid open, so a lid that closed during that setup is caught as a closing
        // on the first tick (and restarts without a built-in microphone that went silent).
        lidOpen = plan.tracks.contains(TrackWatchdog.microphoneTrack) ? true : (power?.isLidOpen() ?? true)
        // Epoch 0's capture started just before the loop: its stall timers start now, at session time ~0.
        await apply(.captureStarted(epoch: 0, tracks: plan.tracks, at: clock.now(),
                                    lidClosed: plan.microphoneOffWithLidClosed))
        while machine.stopReason == nil {
            if Task.isCancelled { cancelled = true }
            // Cancelled, or a capture stop ended with CancellationError.
            if cancelled { return }
            if writerFailed.value { return }
            // Power first: a sleep is acknowledged within seconds, and a capture end it causes is then ignored. Each
            // event is timed by its arrival, not by this drain: after a restart that held the loop past macOS's 30 s
            // limit, willSleep and didWake come in together after the wake, and only their arrival tells the length
            // of the sleep. An event from before epoch 0's capture started (queued during the start) is at a negative
            // session time: clamping it to 0 would shorten a sleep that began and ended during the start to nothing.
            let drained = clock.now()
            for timed in power?.pendingTimedEvents() ?? [] {
                let at = drained - max(0, timed.secondsAgo)
                switch timed.event {
                case .willSleep(let token):
                    pendingSleepTokens.append(token)
                    sleepDeadline = ContinuousClock.now.advanced(by: sleepBudget)
                    await apply(.willSleep(at: at))
                    // The machine allows it after closing chunks; whatever happened, the Mac is never held awake.
                    allowSleep()
                case .didWake:
                    await apply(.didWake(at: at, lidOpen: power?.isLidOpen() ?? true))
                }
            }
            for event in monitor.drain() { await apply(event) }
            let environmentReasons = dependencies.environmentEvents?.pendingReasons() ?? []
            for reason in environmentReasons {
                if microphoneStillMissing() { continue }
                await apply(.retryNow(reason: reason, at: clock.now()))
            }
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
                let lid = power?.isLidOpen() ?? true
                if lid, !lidOpen, !microphoneStillMissing() {
                    await apply(.retryNow(reason: Self.lidOpened, at: clock.now()))
                } else if !lid, lidOpen, closingLidDropsMicrophone() {
                    await apply(.retryNow(reason: RecorderMachine.lidClosed, at: clock.now()))
                }
                lidOpen = lid
                let free = try? dependencies.freeSpace.availableBytes(at: archive.directory)
                await apply(.tick(at: clock.now(), lidOpen: lid, freeBytes: free, lastFrameAt: monitor.lastFrameAt()))
                await refreshStatus()
            } else if machine.phase != lastStatusPhase {
                await refreshStatus()
            }
            if machine.stopReason != nil { break }
            try? await Task.sleep(for: dependencies.tuning.poll)
        }
    }

    /// A call recording without the microphone whose next epoch would still lack it (no input device yet, or the
    /// built-in microphone with the lid still closed): a lid, unlock, or device-list event then restarts nothing.
    private func microphoneStillMissing() -> Bool {
        guard machine.phase == .recording || machine.phase == .starting, machine.microphoneMissing else { return false }
        let next = EpochPlan.make(options, devices: dependencies.findInputDevices(),
                                  lidOpen: dependencies.power?.isLidOpen() ?? true)
        return next?.tracks.contains(TrackWatchdog.microphoneTrack) != true
    }

    /// The lid just closed while the current epoch records a microphone that the next epoch would drop: the built-in
    /// one, chosen explicitly or as the system default input. Core Audio may keep it listed and deliver silence, so
    /// neither the stall watchdog nor a device change would restart capture. An external default input keeps going.
    private func closingLidDropsMicrophone() -> Bool {
        let microphone = TrackWatchdog.microphoneTrack
        guard machine.phase == .recording || machine.phase == .starting, options.source != .system,
              plan.tracks.contains(microphone), !machine.microphoneMissing else { return false }
        let next = EpochPlan.make(options, devices: dependencies.findInputDevices(), lidOpen: false)
        return next?.tracks.contains(microphone) != true
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
            await clearWarning(code)
        case .allowSleep:
            allowSleep()
        case .holdPowerAssertion(let hold):
            holdPower(hold)
        case .finish(let reason):
            Self.log.notice("Session \(self.archive.id, privacy: .public) is stopping (\(reason.rawValue, privacy: .public))")
        }
        return nil
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
