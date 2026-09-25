import Darwin
import Dispatch
import Foundation
import HolosCore
import HolosStorage
import os
import Synchronization

// How the app starts a recorder, and the `voiceislocal` maintenance commands it runs (docs/meeting-design.md §4.1, §5.8).

/// Starts and stops the recorder of one meeting. `MeetingController` does not know which implementation it has: both
/// write the same `status.json` and read the same `control/`.
@MainActor public protocol RecorderLauncher: AnyObject {
    /// Starts a recorder for `sessionID`; returns the child pid (nil for in-process).
    func launch(_ settings: MeetingStartSettings, sessionID: String, root: URL, vocabularyFile: URL?) throws -> Int32?
    /// Asks the recorder of `sessionID` to stop gracefully. Returns false when this launcher does not run it (a
    /// meeting started in a terminal or by an earlier app) or the request could not be delivered.
    @discardableResult func terminate(sessionID: String) -> Bool
    /// Called on the main actor when a launched recorder ends: its exit code and the last line of its log. Read when
    /// a recorder is launched: that recorder's end calls the closure set at that time.
    var onExit: ((Int32, String?) -> Void)? { get set }      // exit code, last log line
}

// MARK: - Child process

/// Runs the bundled `voiceislocal record start` as a child in its own session (docs/meeting-design.md §4.1): stdin is
/// `/dev/null`, stdout and stderr append to `recorder-<SESSION-UUID>.log`, nothing else is inherited, and the child is
/// reaped with a process source plus `waitpid`. The recorder outlives the app; after a relaunch the app finds it again
/// through its `status.json` (`MeetingController.attachOnLaunch`).
@MainActor public final class ChildProcessLauncher: RecorderLauncher {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    public let executable: URL
    public let logDirectory: URL
    public var onExit: ((Int32, String?) -> Void)?
    /// Running children by session ID.
    private var children: [String: ChildWatcher] = [:]

    /// Default: Bundle.main.bundleURL/Contents/MacOS/voiceislocal.
    public init(executable: URL = ChildProcessLauncher.bundledExecutable,
                logDirectory: URL = SessionDeletion.defaultLogDirectory) {
        self.executable = executable
        self.logDirectory = logDirectory
    }

    /// `VoiceIsLocal.app/Contents/MacOS/voiceislocal`, the command-line tool bundled with the app.
    public nonisolated static var bundledExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/voiceislocal", isDirectory: false)
    }

    /// ["record", "start", "--session-id", id, "--name=<name>", "--source", src, ("--locale=<locale>")?,
    ///  ("--app", id)?, ("--others-in-room")?, ("--microphone", "default" | "built-in")?,
    ///  ("--expected-speakers", n)?, ("--vocabulary-file", path)?,
    ///  "--no-live-text", "--directory", root.path]
    ///
    /// The name is joined to its option: as a separate element, a name starting with "-" ("- standup") would be
    /// parsed as an option and the recorder would exit with a usage error. The locale is joined the same way.
    public nonisolated static func arguments(_ settings: MeetingStartSettings, sessionID: String, root: URL,
                                             vocabularyFile: URL?) -> [String] {
        var arguments = ["record", "start", "--session-id", sessionID, "--name=\(settings.name)",
                         "--source", settings.source.rawValue]
        if let locale = settings.locale { arguments.append("--locale=\(locale)") }
        if let app = settings.applicationBundleID { arguments += ["--app", app] }
        if settings.othersInRoom { arguments.append("--others-in-room") }
        if let microphone = settings.microphone { arguments += ["--microphone", microphone.argument] }
        if let expected = settings.expectedSpeakers { arguments += ["--expected-speakers", String(expected)] }
        if let vocabularyFile { arguments += ["--vocabulary-file", vocabularyFile.path] }
        arguments += ["--no-live-text", "--directory", root.path]
        return arguments
    }

    /// The recorder's log: `<logDirectory>/recorder-<SESSION-UUID>.log`.
    public func logFile(sessionID: String) -> URL {
        logDirectory.appendingPathComponent("recorder-\(sessionID).log", isDirectory: false)
    }

    public func launch(_ settings: MeetingStartSettings, sessionID: String, root: URL,
                       vocabularyFile: URL?) throws -> Int32? {
        guard SessionArchive.validToken(sessionID), UUID(uuidString: sessionID) != nil else {
            throw HolosError.invalidInput("Expected a session UUID.")
        }
        guard children[sessionID] == nil else {
            throw HolosError.unavailable("A recorder is already running for this meeting.")
        }
        try AtomicFile.ensurePrivateDirectory(logDirectory)
        let log = logFile(sessionID: sessionID)
        let pid = try ProcessSpawner.spawn(
            executable: executable,
            arguments: Self.arguments(settings, sessionID: sessionID, root: root, vocabularyFile: vocabularyFile),
            standardOutput: .file(log, append: true), standardError: .sameAsOutput,
            environment: ["HOLOS_RECORDER_PARENT": "app"])
        Self.log.notice("Session \(sessionID, privacy: .public): recorder started as pid \(pid, privacy: .public)")
        let exit = onExit
        children[sessionID] = ChildWatcher(pid: pid) { [weak self] code in
            self?.children[sessionID] = nil
            Self.log.notice("Session \(sessionID, privacy: .public): recorder exited with \(code, privacy: .public)")
            exit?(code, ProcessSpawner.lastLine(of: log))
        }
        return pid
    }

    /// SIGTERM: the recorder stops gracefully (audio saved, post-processing runs).
    @discardableResult
    public func terminate(sessionID: String) -> Bool {
        guard let child = children[sessionID] else { return false }
        guard kill(child.pid, SIGTERM) == 0 else {
            Self.log.error("Session \(sessionID, privacy: .public): cannot signal the recorder: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }
        return true
    }

    /// The pid of the running recorder of `sessionID`, if this launcher started it.
    public func pid(sessionID: String) -> Int32? { children[sessionID]?.pid }
}

// MARK: - In-process

/// Runs `RecordingWorkflow.run` inside the app (decision 4's fallback, docs/meeting-design.md §4.1), with the same
/// options as the child. Frames are consumed off the main actor; an activity keeps App Nap and timer coalescing away
/// while recording. Post-processing still runs in a `voiceislocal session diarize` child, which inherits the processing lease
/// (`--lease-fd 3`), so FluidAudio stays out of the app and the session is never without a lock.
@MainActor public final class InProcessLauncher: RecorderLauncher {
    private nonisolated static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    public var onExit: ((Int32, String?) -> Void)?
    public let executable: URL
    public let logDirectory: URL
    private var running: [String: (task: Task<Void, Never>, stop: ManualStopSource, labelling: LabellingStarted)] = [:]

    public init(executable: URL = ChildProcessLauncher.bundledExecutable,
                logDirectory: URL = SessionDeletion.defaultLogDirectory) {
        self.executable = executable
        self.logDirectory = logDirectory
    }

    /// True while a recording runs in this process (the app waits for it before quitting).
    public var isRecording: Bool { !running.isEmpty }

    public func launch(_ settings: MeetingStartSettings, sessionID: String, root: URL,
                       vocabularyFile: URL?) throws -> Int32? {
        guard running.isEmpty else { throw HolosError.unavailable("A meeting is already recording in Voice is Local.") }
        let vocabulary = try vocabularyFile.map { try VocabularyFile.consume($0) } ?? []
        // The app always passes the language chosen in the start panel; `standard` only for a caller that does not.
        let options = RecordingOptions(name: settings.name, source: settings.source,
                                       locale: settings.locale ?? DictationLanguage.standard, backend: .speech,
                                       root: root, applicationBundleID: settings.applicationBundleID,
                                       vocabulary: vocabulary, sessionID: sessionID,
                                       othersInRoom: settings.othersInRoom,
                                       expectedSpeakers: settings.expectedSpeakers, liveText: false,
                                       microphone: settings.microphone)
        let stop = ManualStopSource()
        let log = Self.labellingLog(in: logDirectory, sessionID: sessionID)
        let labelling = LabellingStarted()
        let hook = Self.childPostProcessHook(executable: executable, log: log)
        var dependencies = makeDependencies(stop) { session, lease, progress in
            labelling.set()
            return await hook(session, lease, progress)
        }
        let exitWait = ExitStatusWait()
        dependencies.exitStatusWait = exitWait
        let exit = onExit
        let task = Task { @MainActor [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Voice is Local meeting recording")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var code: Int32 = 0
            var message: String?
            do {
                let outcome = try await RecordingWorkflow.run(options, dependencies: dependencies)
                code = Self.exitCode(outcome)
            } catch {
                code = 1
                message = error.localizedDescription
            }
            // The exited status could not be written yet (`ExitRetry`): the recording has not ended until it is, so
            // it stays running here (the controller keeps following it, and a quit waits for it).
            if exitWait.retrying {
                self?.exitRetrying.insert(sessionID)
                Self.log.notice("Session \(sessionID, privacy: .public): waiting for the exited status to be written")
                let written = await exitWait.finished()
                self?.exitRetrying.remove(sessionID)
                if !written, code == 0 {
                    code = 1
                    message = "The meeting's folder disappeared before Voice is Local could record that it ended."
                }
            }
            self?.running[sessionID] = nil
            Self.log.notice("Session \(sessionID, privacy: .public): in-process recording ended with \(code, privacy: .public)")
            exit?(code, message)
        }
        running[sessionID] = (task, stop, labelling)
        return nil
    }

    /// For a quit once the transcript is saved: every recording here that has reached speaker labelling stops
    /// following it. Its labelling child keeps the processing lease and finishes on its own; the recording writes its
    /// exited status (labelling still running) and ends, so `isRecording` turns false. A recording that has not
    /// reached labelling yet (still saving its transcript) is left alone. Returns true when one was told.
    @discardableResult
    public func leaveLabellingToItsChild() -> Bool {
        var told = false
        for recording in running.values where recording.labelling.isSet {
            recording.task.cancel()
            told = true
        }
        return told
    }

    /// The recording's dependencies from its stop source and post-process hook: the live ones (tests replace them).
    var makeDependencies: @MainActor (ManualStopSource, @escaping PostProcessHook) -> RecordingDependencies = {
        stop, hook in
        RecordingDependencies.live(stop: stop, reporter: LoggingReporter(), postProcess: hook)
    }

    /// Recordings whose run returned but whose exited status is still being retried (`ExitRetry`).
    private var exitRetrying: Set<String> = []

    /// True while a recording here ended but could not yet write its exited status: its locks are held and it is
    /// still retrying, so quitting now would cut that short.
    public var isWritingExit: Bool { !exitRetrying.isEmpty }

    /// Like SIGTERM to a child: a graceful stop.
    @discardableResult
    public func terminate(sessionID: String) -> Bool {
        guard let recording = running[sessionID] else { return false }
        recording.stop.requestStop()
        return true
    }

    /// The CLI's exit code for an outcome (docs/meeting-design.md §1.4).
    static func exitCode(_ outcome: RecordingOutcome) -> Int32 {
        if !outcome.transcriptErrors.isEmpty || outcome.stopReason == .captureFailed { return 1 }
        if [.diskLow, .sleepTimeout, .pauseTimeout].contains(outcome.stopReason) { return 3 }
        if let state = outcome.postProcessing?.state, state == .failed || state == .partial { return 3 }
        return 0
    }

    /// `<directory>/recorder-<SESSION-UUID>.log` for the labelling child's stderr, creating the folder; nil when the
    /// folder cannot be made (the child's stderr is then discarded: an unusable log never stops the labelling).
    nonisolated static func labellingLog(in directory: URL, sessionID: String) -> URL? {
        do {
            try AtomicFile.ensurePrivateDirectory(directory)
        } catch {
            log.error("Session \(sessionID, privacy: .public): no log folder for speaker labelling; its output is discarded: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        return directory.appendingPathComponent("recorder-\(sessionID).log", isDirectory: false)
    }

    /// The post-process hook of an in-process recording: `voiceislocal session diarize <path> --after-recording --json
    /// --lease-fd 3` in a child that inherits the lease; its stderr goes to `log`.
    nonisolated static func childPostProcessHook(executable: URL, log: URL?) -> PostProcessHook {
        { session, lease, progress in
            await handOffPostProcessing(
                session: session, lease: lease, executable: executable,
                arguments: ["session", "diarize", session.path, "--after-recording", "--json", "--lease-fd", "3"],
                log: log, progress: progress)
        }
    }

    /// Hands `lease` to a child running `executable arguments` with the lease's descriptor at fd 3
    /// (`ProcessingLease.handOff`): the lock is never free between this process and the child. Mirrors the child's
    /// `postprocess.json` progress, waits for it, and returns the record it printed on stdout (else the one it saved;
    /// else a `.failed` record). If the spawn fails the lease is still held here, and the failure is recorded.
    nonisolated static func handOffPostProcessing(
        session: URL, lease: ProcessingLease, executable: URL, arguments: [String], log: URL?,
        progress: @escaping @Sendable (PostProcessingProgress) -> Void,
        pollInterval: Duration = .milliseconds(250)) async -> PostProcessingRecord {
        let startedAt = Date()
        let sessionID = (try? SessionArchive.readManifest(at: session).id) ?? session.deletingPathExtension().lastPathComponent
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-postprocess-\(UUID().uuidString).json", isDirectory: false)
        defer { ProcessSpawner.removeRegularFile(output) }
        // A log that cannot be opened (its folder gone or unwritable, a link in its place) is dropped: the spawn
        // would fail on it, and the labelling would be reported as failed only because its log was unavailable.
        let log = log.flatMap { ProcessSpawner.canAppend(to: $0) ? $0 : nil }
        let pid: pid_t
        do {
            pid = try lease.handOff { descriptor in
                try ProcessSpawner.spawn(executable: executable, arguments: arguments,
                                         standardOutput: .file(output, append: false),
                                         standardError: log.map { .file($0, append: true) } ?? .null,
                                         inheritedDescriptors: [(from: descriptor, to: 3)])
            }
        } catch {
            Self.log.error("Session \(sessionID, privacy: .public): speaker labelling could not start (\(ProcessSpawner.logCategory(error), privacy: .public)): \(error.localizedDescription, privacy: .private)")
            return PostProcessingRecord(sessionID: sessionID, state: .failed, pid: getpid(), startedAt: startedAt,
                                        updatedAt: Date(),
                                        message: "Speaker labelling could not start: \(error.localizedDescription) Use Label Speakers in Meetings later.")
        }
        var lastProgress: PostProcessingProgress?
        var code: Int32?
        while code == nil {
            code = ProcessSpawner.reapIfExited(pid)
            if code != nil { break }
            if Task.isCancelled {
                // The child keeps the lease and finishes on its own; this process stops mirroring it.
                return PostProcessingRecord(sessionID: sessionID, state: .running, pid: pid, startedAt: startedAt,
                                            updatedAt: Date(), message: "Speaker labelling continues in the background.")
            }
            if let record = readRecord(session), record.sessionID == sessionID, record.state == .running,
               let current = record.progress, current != lastProgress {
                lastProgress = current
                progress(current)
            }
            try? await Task.sleep(for: pollInterval)
        }
        if let data = try? AtomicFile.readIfPresent(output, maxBytes: 1 << 20),
           let record = try? HolosJSON.decoder().decode(PostProcessingRecord.self, from: data) {
            return record
        }
        if let record = readRecord(session), record.sessionID == sessionID, record.state != .running {
            return record
        }
        let details = log.map { " Details: \($0.path)" } ?? ""
        return PostProcessingRecord(sessionID: sessionID, state: .failed, pid: pid, startedAt: startedAt,
                                    updatedAt: Date(),
                                    message: "Speaker labelling stopped (exit code \(code ?? -1)). Use Label Speakers in Meetings.\(details)")
    }

    /// postprocess.json; nil when missing or unreadable.
    private nonisolated static func readRecord(_ session: URL) -> PostProcessingRecord? {
        guard let data = try? AtomicFile.readIfPresent(SessionPaths.postprocess(session), maxBytes: 1 << 20) else {
            return nil
        }
        return try? HolosJSON.decoder().decode(PostProcessingRecord.self, from: data)
    }
}

/// Set once an in-process recording's post-process hook has started: the lease hand-off to the labelling child follows
/// at once, and a cancellation from then on only stops the recording from waiting for that child.
final class LabellingStarted: Sendable {
    private let value = Mutex(false)

    func set() { value.withLock { $0 = true } }

    var isSet: Bool { value.withLock { $0 } }
}

/// Logs the recorder's progress lines; never transcript text.
private struct LoggingReporter: RecordingReporter {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    func phrase(_ segment: TranscriptSegment, track: String) {}

    func message(_ text: String) {
        Self.log.notice("\(text, privacy: .private)")
    }
}

// MARK: - Maintenance commands

/// Runs `voiceislocal session recover|diarize|delete`, `voiceislocal setup --speakers`, and `voiceislocal doctor` for the app, each
/// detached in its own session (POSIX_SPAWN_SETSID, nothing inherited), so a quit app never cuts one short. Callers
/// add `--json` for the commands that print JSON (`setup` has none).
@MainActor public final class MaintenanceLauncher {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    public let executable: URL
    private var children: [Int32: ChildWatcher] = [:]

    public init(executable: URL) {
        self.executable = executable
    }

    /// Runs `holos <arguments>` detached with stdout and stderr discarded; returns the pid. `onExit` gets the exit
    /// code (128 + the signal for a killed child).
    @discardableResult
    public func run(_ arguments: [String], onExit: @escaping @MainActor (Int32) -> Void) throws -> Int32 {
        try run(arguments, standardOutput: nil, standardError: nil, onExit: onExit)
    }

    /// Like `run(_:onExit:)`, with stdout and stderr written to the given files (created 0600 and truncated; the same
    /// URL for both interleaves them). Nil discards.
    @discardableResult
    public func run(_ arguments: [String], standardOutput: URL?, standardError: URL?,
                    onExit: @escaping @MainActor (Int32) -> Void) throws -> Int32 {
        let output: ProcessSpawner.Output = standardOutput.map { .file($0, append: false) } ?? .null
        let error: ProcessSpawner.Output = if let standardError {
            standardError == standardOutput ? .sameAsOutput : .file(standardError, append: false)
        } else {
            .null
        }
        let pid = try ProcessSpawner.spawn(executable: executable, arguments: arguments, standardOutput: output,
                                           standardError: error)
        Self.log.notice("Maintenance command \(arguments.first ?? "", privacy: .public) \(arguments.dropFirst().first ?? "", privacy: .public) started as pid \(pid, privacy: .public)")
        children[pid] = ChildWatcher(pid: pid) { [weak self] code in
            self?.children[pid] = nil
            onExit(code)
        }
        return pid
    }

    /// Pids of the maintenance commands still running.
    public var runningPIDs: [Int32] { Array(children.keys) }
}

// MARK: - Reaping

/// Waits for one child with a process source on the main queue plus `waitpid(WNOHANG)`, and reports its exit code
/// once. Also checks right after it is set up, so a child that exited before the source existed is still reaped.
/// The exit event can arrive a moment before the child can be waited for; the watcher then checks again every
/// `retryInterval` until it is reaped.
@MainActor final class ChildWatcher {
    let pid: pid_t
    private var source: (any DispatchSourceProcess)?
    private var completion: (@MainActor (Int32) -> Void)?
    private let reaper: @MainActor (pid_t) -> Int32?
    private let retryInterval: DispatchTimeInterval

    init(pid: pid_t, reaper: @escaping @MainActor (pid_t) -> Int32? = { ProcessSpawner.reapIfExited($0) },
         retryInterval: DispatchTimeInterval = .milliseconds(20),
         completion: @escaping @MainActor (Int32) -> Void) {
        self.pid = pid
        self.reaper = reaper
        self.retryInterval = retryInterval
        self.completion = completion
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reapAfterExit() }
        }
        self.source = source
        source.resume()
        // A process source made after the child exited may never fire.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { _ = self?.reap() }
        }
    }

    /// The child exited: it is reaped now, or as soon as it can be waited for.
    private func reapAfterExit() {
        guard completion != nil, !reap() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            MainActor.assumeIsolated { self?.reapAfterExit() }
        }
    }

    /// Reaps the child if it has ended and reports its exit; true once reported.
    private func reap() -> Bool {
        guard completion != nil else { return true }
        guard let code = reaper(pid) else { return false }
        source?.cancel()
        source = nil
        let done = completion
        completion = nil
        done?(code)
        return true
    }
}

// MARK: - posix_spawn

/// The one `posix_spawn` helper for every child the app starts (docs/meeting-design.md §1.7 rule 4, §4.1):
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` so a child inherits no descriptor but fds 0–2 and the ones named, default signal
/// handlers and an empty signal mask, and (by default) `POSIX_SPAWN_SETSID`, so the child gets no terminal SIGHUP and
/// no signal sent to the app's process group. The file helpers are public for the app's command outputs.
public enum ProcessSpawner {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    enum Output: Sendable, Equatable {
        /// `/dev/null`.
        case null
        /// A file opened O_WRONLY|O_CREAT|O_NOFOLLOW (0600), appended to or truncated.
        case file(URL, append: Bool)
        /// Only for stderr: the same file as stdout.
        case sameAsOutput
        /// An open descriptor of the caller's, such as a pipe's write end (not closed by `spawn`).
        case descriptor(Int32)
    }

    /// True when `url` can be opened as `Output.file(url, append: true)` would open it (creating it, 0600).
    static func canAppend(to url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_APPEND, 0o600)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }

    /// Spawns `executable` with `arguments` (argv[0] is the executable's path). stdin is `/dev/null`.
    /// `inheritedDescriptors` are placed at their target numbers with `posix_spawn_file_actions_adddup2` (the copy loses
    /// close-on-exec; the source must not already have the target number). The environment is this process's plus
    /// `environment`. Returns the pid; throws `HolosError.unavailable` when the executable is missing and
    /// `HolosError.io` for any other failure.
    static func spawn(executable: URL, arguments: [String], standardOutput: Output, standardError: Output,
                      inheritedDescriptors: [(from: Int32, to: Int32)] = [], newSession: Bool = true,
                      environment: [String: String] = [:]) throws -> pid_t {
        var opened: [Int32] = []
        defer { for fd in opened { Darwin.close(fd) } }
        func open(_ output: Output) throws -> Int32? {
            if case .descriptor(let fd) = output { return fd }
            guard case .file(let url, let append) = output else { return nil }
            let flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | (append ? O_APPEND : O_TRUNC)
            let fd = Darwin.open(url.path, flags, 0o600)
            guard fd >= 0 else {
                throw HolosError.io("Cannot open \(url.lastPathComponent) for the child's output: \(String(cString: strerror(errno))).")
            }
            opened.append(fd)
            return fd
        }
        let outFD = try open(standardOutput)
        let errFD = standardError == .sameAsOutput ? outFD : try open(standardError)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let outFD {
            posix_spawn_file_actions_adddup2(&actions, outFD, 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        if let errFD {
            posix_spawn_file_actions_adddup2(&actions, errFD, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        for (from, to) in inheritedDescriptors {
            guard from != to, to > 2 else {
                throw HolosError.invalidInput("An inherited descriptor must move to a new number above 2.")
            }
            posix_spawn_file_actions_adddup2(&actions, from, to)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if newSession { flags |= POSIX_SPAWN_SETSID }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        let argv = ([executable.path] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        let envp = merged.map { strdup("\($0.key)=\($0.value)") }
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv + [nil], envp + [nil])
        guard code == 0 else {
            let reason = String(cString: strerror(code))
            if code == ENOENT {
                throw HolosError.unavailable("The voiceislocal tool is missing at \(executable.path). Rebuild Voice is Local with scripts/build-app.sh.")
            }
            throw HolosError.io("Cannot start \(executable.lastPathComponent): \(reason).")
        }
        return pid
    }

    /// The exit code of `pid` if it has ended (reaping it), else nil. 128 + the signal for a killed child; -1 when it
    /// cannot be waited for (not a child, or already reaped).
    static func reapIfExited(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == 0 { return nil }
            if result == pid { return exitCode(status) }
            if errno == EINTR { continue }
            return -1
        }
    }

    /// When process `pid` started, in microseconds since 1970; nil when no such process runs (or it cannot be
    /// inspected). With the pid it names one process: a pid the system reuses later belongs to a process that started
    /// later.
    static func startTime(of pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    /// A category of `error` that is safe to log publicly ("unavailable", "io", "NSCocoaErrorDomain 4"): error texts
    /// can hold user paths, which are logged only as private (docs/meeting-design.md §1.5).
    public static func logCategory(_ error: any Error) -> String {
        if let error = error as? HolosError {
            return switch error {
            case .invalidInput: "invalidInput"
            case .unavailable: "unavailable"
            case .permissionDenied: "permissionDenied"
            case .incomplete: "incomplete"
            case .io: "io"
            }
        }
        if error is CancellationError { return "cancelled" }
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }

    /// WEXITSTATUS, or 128 + WTERMSIG.
    static func exitCode(_ status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        if low != 0x7f { return 128 + low }
        return -1
    }

    /// The last non-empty line of a log (from its last 4 KiB), without ArgumentParser's "Error: " prefix, at most 300
    /// characters. Nil when there is none.
    public static func lastLine(of url: URL) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let length = Int(min(info.st_size, 4_096))
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = pread(fd, &buffer, length, info.st_size - off_t(length))
        guard read > 0 else { return nil }
        let text = String(decoding: buffer.prefix(read), as: UTF8.self)
        guard var line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return nil }
        if line.hasPrefix("Error: ") { line = String(line.dropFirst(7)) }
        return String(line.prefix(300))
    }

    /// Removes `url` if it is a regular file (never following a link, never a folder), and only the file that was
    /// checked: a different file renamed onto its name meanwhile is left alone (`AtomicFile.removeRegularFile`).
    public static func removeRegularFile(_ url: URL) {
        AtomicFile.removeRegularFile(url)
    }

    /// Removes the regular files in `folder` whose names start with `prefix` and that were last modified before
    /// `cutoff` (left by an app that crashed). Links, folders, newer files, and a file renamed onto a checked name
    /// after the check are left alone. Also finishes the removals of files in `folder` that a crash interrupted
    /// (`AtomicFile.removeStrandedRemovalFolders`, for folders older than `AtomicFile.strandedRemovalGrace`): the
    /// vocabulary and command-output files are removed there, by the app or the recorder.
    public static func removeStaleFiles(in folder: URL, prefix: String, suffix: String = "", olderThan cutoff: Date) {
        AtomicFile.removeStrandedRemovalFolders(
            in: folder, olderThan: Date().addingTimeInterval(-AtomicFile.strandedRemovalGrace))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            AtomicFile.removeRegularFile(folder.appendingPathComponent(name, isDirectory: false)) { info in
                Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff
            }
        }
    }
}
