import Foundation
import HolosCore

// The menu bar's meeting state machine (docs/meeting-design.md §5.8 PR4). Pure: every input is an event, every output
// an effect that `MeetingController` executes or hands to the app.

/// What the start panel asks the recorder to do.
public struct MeetingStartSettings: Codable, Sendable, Equatable {
    public var name: String
    /// .microphone ("In person") or .microphoneAndSystem ("Online call").
    public var source: AudioSource
    public var applicationBundleID: String?
    public var othersInRoom: Bool
    public var expectedSpeakers: Int?
    /// The meeting's languages, as locale identifiers ("fr-CA"); the recorder transcribes in the first (`locale`).
    /// The start panel chooses exactly one today. Empty leaves the choice to the recorder's own default.
    public var locales: [String]

    /// The language the recorder transcribes in, or nil for the recorder's default.
    public var locale: String? { locales.first }

    public init(name: String, source: AudioSource, applicationBundleID: String? = nil, othersInRoom: Bool = false,
                expectedSpeakers: Int? = nil, locales: [String] = []) {
        self.name = name; self.source = source; self.applicationBundleID = applicationBundleID
        self.othersInRoom = othersInRoom; self.expectedSpeakers = expectedSpeakers; self.locales = locales
    }

    private enum CodingKeys: String, CodingKey {
        case name, source, applicationBundleID, othersInRoom, expectedSpeakers, locales
    }

    /// Settings saved before meetings had a language decode with none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try container.decode(String.self, forKey: .name),
                  source: try container.decode(AudioSource.self, forKey: .source),
                  applicationBundleID: try container.decodeIfPresent(String.self, forKey: .applicationBundleID),
                  othersInRoom: try container.decode(Bool.self, forKey: .othersInRoom),
                  expectedSpeakers: try container.decodeIfPresent(Int.self, forKey: .expectedSpeakers),
                  locales: try container.decodeIfPresent([String].self, forKey: .locales) ?? [])
    }

    /// "Meeting 2026-09-23 14:00" in `timeZone`.
    public static func defaultName(now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(formatter.string(from: now))"
    }

    /// The settings as the recorder accepts them: system audio options only for a source with system audio, others
    /// in the room only for a call, a trimmed name (the default name when it is empty), a speaker count only
    /// within 1...20, and each language once, as "fr-CA" ("fr_CA" and blanks are cleaned up).
    public func normalized(now: Date = Date(), timeZone: TimeZone = .current) -> MeetingStartSettings {
        var settings = self
        settings.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.name.isEmpty { settings.name = Self.defaultName(now: now, timeZone: timeZone) }
        if source == .microphone { settings.applicationBundleID = nil }
        if source != .microphoneAndSystem { settings.othersInRoom = false }
        if let bundleID = settings.applicationBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) {
            settings.applicationBundleID = bundleID.isEmpty ? nil : bundleID
        }
        if let expected = expectedSpeakers, !(1...20).contains(expected) { settings.expectedSpeakers = nil }
        var seen = Set<String>()
        settings.locales = locales
            .map { DictationLanguage.identifier($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return settings
    }
}

public enum MeetingState: Sendable, Equatable {
    case idle
    case starting(sessionID: String, since: Date, pid: Int32?)
    /// Recorder phase starting…stopping (including waiting and unknown).
    case active(sessionID: String, status: RecorderStatus)
    /// Capture stopped; transcribing or post-processing.
    case finishing(sessionID: String, status: RecorderStatus?)
    case failed(sessionID: String?, message: String)

    /// The session this state follows, if any.
    public var sessionID: String? {
        switch self {
        case .idle: nil
        case .starting(let id, _, _), .active(let id, _), .finishing(let id, _): id
        case .failed(let id, _): id
        }
    }
}

public enum MeetingEvent: Sendable, Equatable {
    case startRequested(MeetingStartSettings, sessionID: String, at: Date)
    case launched(pid: Int32?, at: Date)
    case launchFailed(message: String)
    case statusRead(RecorderStatus?, liveness: RecorderLiveness, at: Date)
    case childExited(code: Int32, logTail: String?, at: Date)
    case tick(at: Date)
    case stopConfirmed
    case pauseRequested
    case resumeRequested
    case markerRequested(label: String?)
    case reattached(sessionID: String, status: RecorderStatus)
    case reviewOpened(sessionID: String)
    case dismissFailure
}

public enum MeetingEffect: Sendable, Equatable {
    case launch(MeetingStartSettings, sessionID: String)
    case send(ControlCommand, label: String?, sessionID: String)
    /// SIGTERM to the child: a graceful stop while starting, or the 120 s start timeout.
    case terminateChild(sessionID: String)
    case announce(String)                // first menu line / status item tooltip
    case setDictationPaused(Bool)
    /// `speakersReady` from the reducer: post-processing ran to its end, so labels may be saved; `MeetingController`
    /// replaces it with the result of checking the saved labels.
    case finished(sessionID: String, summary: String, speakersReady: Bool)
    /// "Name Speakers — <name>…" at the top of the menu and a dot on the status item, until reviewed.
    case offerNaming(sessionID: String, name: String)
    case clearNamingOffer(sessionID: String)
}

/// The meeting the menu bar follows: the one the app launched, or a live one it found (docs/meeting-design.md §5.8
/// "Reducer rules").
public struct MeetingReducer: Sendable, Equatable {
    public private(set) var state: MeetingState = .idle
    /// The followed meeting's name, for messages.
    public private(set) var meetingName: String?
    /// The last `setDictationPaused` value emitted, so each change is emitted once.
    private var dictationPaused = false
    /// "Waiting for permission…" was announced for this start.
    private var permissionHintShown = false
    /// A stop was sent (or, while starting, the child was asked to terminate) for the followed session.
    public private(set) var stopRequested = false
    /// The stop was asked for while the recorder was still starting. The recorder notices it only once its start
    /// returns (after any permission prompt is answered), so the start timeout no longer applies, and a recording that
    /// ends with less than a second of audio was stopped before it started.
    public private(set) var stoppedWhileStarting = false

    /// Seconds after the start without a recording status before "Waiting for permission…".
    static let permissionHintSeconds = 5.0
    /// Seconds after the start before the recorder is terminated and the start fails.
    static let startTimeoutSeconds = 120.0
    /// A status older than this is stale (RecorderChannel's freshness).
    static let freshSeconds = 10.0

    static let alreadyRecording = "A meeting is already recording."
    static let stillSaving = "The last meeting is still being saved. Start the next one when it finishes."
    static let waitingForPermission = "Waiting for permission…"
    static let stoppedBeforeRecording = "The recorder stopped before recording started."
    static let stoppedUnexpectedly = "The recorder stopped unexpectedly. Recover the saved audio from Meetings."
    static let cancelledBeforeStart = "The recording was stopped before it started."
    static let stoppingWhileStarting =
        "Stopping. If macOS is asking for permission, the recorder stops once you answer the prompt."
    static let stillStopping =
        "The last recording is still stopping. If macOS is asking for permission, answer the prompt first."
    /// A recording stopped while starting that saved less audio than this was stopped before it started.
    static let cancelledRecordingSeconds = 1.0

    /// True while dictation must stay paused: the followed meeting is starting, or its phase `isMeetingActive`
    /// (docs/meeting-design.md §4.12).
    public var dictationShouldPause: Bool {
        switch state {
        case .starting: true
        case .active(_, let status): status.phase.isMeetingActive
        case .idle, .finishing, .failed: false
        }
    }

    public init() {}

    public mutating func reduce(_ event: MeetingEvent) -> [MeetingEffect] {
        var effects: [MeetingEffect]
        switch event {
        case .startRequested(let settings, let sessionID, let at):
            effects = startRequested(settings, sessionID: sessionID, at: at)
        case .launched(let pid, _):
            if case .starting(let id, let since, _) = state { state = .starting(sessionID: id, since: since, pid: pid) }
            effects = []
        case .launchFailed(let message):
            guard case .starting = state else { return [] }
            state = .failed(sessionID: nil, message: message)
            effects = []
        case .statusRead(let status, let liveness, let at):
            effects = statusRead(status, liveness: liveness, at: at)
        case .childExited(_, let logTail, _):
            effects = childExited(logTail: logTail)
        case .tick(let at):
            effects = tick(at: at)
        case .stopConfirmed:
            effects = stopConfirmed()
        case .pauseRequested:
            effects = control(.pause, label: nil)
        case .resumeRequested:
            effects = control(.resume, label: nil)
        case .markerRequested(let label):
            effects = control(.marker, label: label)
        case .reattached(let sessionID, let status):
            effects = reattached(sessionID: sessionID, status: status)
        case .reviewOpened(let sessionID):
            effects = [.clearNamingOffer(sessionID: sessionID)]
        case .dismissFailure:
            guard case .failed = state else { return [] }
            state = .idle
            effects = []
        }
        syncDictation(&effects)
        return effects
    }

    /// A stop request could not be published and no signal reached the recorder: the meeting is still recording, so
    /// Stop, Pause, Resume, and Add Marker work again.
    mutating func stopWasNotDelivered() {
        guard case .active = state else { return }
        stopRequested = false
    }

    // MARK: - Events

    private mutating func startRequested(_ settings: MeetingStartSettings, sessionID: String,
                                         at: Date) -> [MeetingEffect] {
        switch state {
        case .idle, .failed:
            state = .starting(sessionID: sessionID, since: at, pid: nil)
            meetingName = settings.name
            permissionHintShown = false
            stopRequested = false
            stoppedWhileStarting = false
            return [.launch(settings, sessionID: sessionID)]
        case .finishing:
            return [.announce(Self.stillSaving)]
        case .starting, .active:
            return [.announce(Self.alreadyRecording)]
        }
    }

    private mutating func statusRead(_ status: RecorderStatus?, liveness: RecorderLiveness,
                                     at: Date) -> [MeetingEffect] {
        guard let followed = state.sessionID else { return [] }
        if let status, status.sessionID != followed { return [] }
        if let status { meetingName = status.name }
        let fresh = status.map { Self.isFresh($0, liveness: liveness, at: at) } ?? false
        switch state {
        case .idle:
            return []
        case .starting:
            // While starting, liveness comes from the child process: a missing folder or status is normal.
            guard let status else { return [] }
            if status.phase == .exited { return exited(status) }
            guard fresh else { return [] }
            return follow(followed, status, keepStarting: true)
        case .active:
            if let status, status.phase == .exited { return exited(status) }
            if liveness == .dead { return fail(followed, Self.stoppedUnexpectedly) }
            guard let status, fresh else { return [] }
            return follow(followed, status, keepStarting: false)
        case .finishing(_, let last):
            if let status, status.phase == .exited { return exited(status) }
            if liveness == .dead {
                // An in-process recorder's labelling child releases the lease when it exits, a moment before the
                // recorder writes exited; its status is still being rewritten then. Only a status that stopped
                // changing means the recorder is gone.
                let latest = status ?? last
                if let latest, at.timeIntervalSince(latest.updatedAt) < Self.freshSeconds { return [] }
                return labellingStopped(followed, lastPhase: latest?.phase)
            }
            guard let status, fresh else { return [] }
            return follow(followed, status, keepStarting: false)
        case .failed:
            guard let status else { return [] }
            if status.phase == .exited {
                // A recorder that saved audio after all (it was stopped by the start timeout) reports how it went; one
                // that saved nothing leaves the failure as it is.
                return savedNothing(status) ? [] : exited(status)
            }
            guard fresh, status.phase != .starting else { return [] }
            return follow(followed, status, keepStarting: false)
        }
    }

    /// Moves to `active` or `finishing` from a fresh status of the followed session. With `keepStarting`, a status
    /// still in phase `starting` (permission prompts, speech setup) leaves the state `starting`.
    private mutating func follow(_ sessionID: String, _ status: RecorderStatus,
                                 keepStarting: Bool) -> [MeetingEffect] {
        switch status.phase {
        case .starting where keepStarting:
            return []
        case .transcribing, .postprocessing:
            state = .finishing(sessionID: sessionID, status: status)
        case .exited:
            return exited(status)
        default:
            state = .active(sessionID: sessionID, status: status)
        }
        return []
    }

    private mutating func exited(_ status: RecorderStatus) -> [MeetingEffect] {
        let sessionID = status.sessionID
        if status.exit?.reason == .interrupted {
            // Not the recorder's own exit: a maintenance command marked a recorder that died (§4.1).
            switch state {
            case .starting, .active: return fail(sessionID, Self.stoppedUnexpectedly)
            case .finishing(_, let last): return labellingStopped(sessionID, lastPhase: last?.phase)
            case .idle, .failed: return []
            }
        }
        if stoppedWhileStarting, savedNothing(status) || status.recordedSeconds < Self.cancelledRecordingSeconds {
            // The user stopped the recorder before capture started. It noticed only once its start returned (a
            // permission prompt was answered), then stopped at once with nothing or a moment of audio: nothing failed,
            // and there is no meeting to report.
            switch state {
            case .starting, .active, .finishing:
                state = .idle
                return [.announce(Self.cancelledBeforeStart)]
            case .idle, .failed:
                return []
            }
        }
        if savedNothing(status) {
            switch state {
            case .starting, .active, .finishing:
                return fail(sessionID, status.exit?.message ?? Self.stoppedBeforeRecording, keepSession: false)
            case .idle, .failed:
                return []
            }
        }
        state = .idle
        // Post-processing ran to its end, perhaps with a warning (partial): labels may be saved. `MeetingController`
        // checks the saved labels before it reports them ready or offers naming.
        let ready = status.exit?.postprocessing == .succeeded || status.exit?.postprocessing == .partial
        var effects: [MeetingEffect] = [.finished(sessionID: sessionID, summary: Self.summary(status),
                                                  speakersReady: ready)]
        if ready { effects.append(.offerNaming(sessionID: sessionID, name: status.name)) }
        return effects
    }

    private mutating func childExited(logTail: String?) -> [MeetingEffect] {
        switch state {
        case .starting(let sessionID, _, _):
            if stopRequested {
                state = .idle
                return [.announce(Self.cancelledBeforeStart)]
            }
            let tail = logTail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return fail(sessionID, tail.flatMap { $0.isEmpty ? nil : $0 } ?? Self.stoppedBeforeRecording)
        case .active(let sessionID, _):
            return fail(sessionID, Self.stoppedUnexpectedly)
        case .finishing(let sessionID, let status):
            return labellingStopped(sessionID, lastPhase: status?.phase)
        case .idle, .failed:
            return []
        }
    }

    private mutating func tick(at: Date) -> [MeetingEffect] {
        guard case .starting(let sessionID, let since, _) = state else { return [] }
        // A recorder asked to stop while starting is waiting for its start to return (a permission prompt, speech
        // setup) and stops then; failing it here would report a timeout the user did not care about.
        guard !stoppedWhileStarting else { return [] }
        let elapsed = at.timeIntervalSince(since)
        if elapsed >= Self.startTimeoutSeconds {
            let log = "~/Library/Logs/Holos/recorder-\(sessionID).log"
            return [.terminateChild(sessionID: sessionID)]
                + fail(sessionID, "The recorder did not start within 2 minutes. Details: \(log)")
        }
        if elapsed >= Self.permissionHintSeconds, !permissionHintShown {
            permissionHintShown = true
            return [.announce(Self.waitingForPermission)]
        }
        return []
    }

    private mutating func stopConfirmed() -> [MeetingEffect] {
        switch state {
        case .starting(let sessionID, _, _):
            guard !stopRequested else { return [] }
            stopRequested = true
            stoppedWhileStarting = true
            return [.terminateChild(sessionID: sessionID), .announce(Self.stoppingWhileStarting)]
        case .active(let sessionID, let status):
            guard !stopRequested, status.phase != .stopping else { return [] }
            stopRequested = true
            return [.send(.stop, label: nil, sessionID: sessionID)]
        case .idle, .finishing, .failed:
            return []
        }
    }

    private func control(_ command: ControlCommand, label: String?) -> [MeetingEffect] {
        guard case .active(let sessionID, _) = state, !stopRequested else { return [] }
        return [.send(command, label: label, sessionID: sessionID)]
    }

    private mutating func reattached(sessionID: String, status: RecorderStatus) -> [MeetingEffect] {
        switch state {
        case .idle, .failed: break
        case .starting, .active, .finishing: return []
        }
        guard status.sessionID == sessionID else { return [] }
        switch status.phase {
        case .exited:
            return []
        case .transcribing, .postprocessing:
            state = .finishing(sessionID: sessionID, status: status)
        default:
            state = .active(sessionID: sessionID, status: status)
        }
        meetingName = status.name
        permissionHintShown = false
        stopRequested = false
        stoppedWhileStarting = false
        return []
    }

    // MARK: - Helpers

    /// Fails the followed start or meeting. `keepSession` keeps the session ID, so a fresh status from it can still
    /// bring the meeting back (a recorder that was only slow).
    private mutating func fail(_ sessionID: String, _ message: String, keepSession: Bool = true) -> [MeetingEffect] {
        state = .failed(sessionID: keepSession ? sessionID : nil, message: message)
        return []
    }

    /// The recorder went away while transcribing or labelling speakers.
    private mutating func labellingStopped(_ sessionID: String, lastPhase: RecorderPhase?) -> [MeetingEffect] {
        state = .idle
        let name = meetingName ?? "the meeting"
        let summary = lastPhase == .transcribing
            ? "Voice is Local stopped while saving \(name). Recover it from Meetings."
            : "Saved \(name). Speaker labelling stopped; Voice is Local will retry it, or use Label Speakers in Meetings."
        return [.finished(sessionID: sessionID, summary: summary, speakersReady: false)]
    }

    /// Emits `setDictationPaused` when the pause the state calls for changed.
    private mutating func syncDictation(_ effects: inout [MeetingEffect]) {
        let wanted = dictationShouldPause
        guard wanted != dictationPaused else { return }
        dictationPaused = wanted
        effects.append(.setDictationPaused(wanted))
    }

    /// Nothing was saved: capture never started.
    private func savedNothing(_ status: RecorderStatus) -> Bool {
        guard let exit = status.exit else { return false }
        return exit.reason == .startFailed || exit.archiveStatus == ArchiveStatus.failed
    }

    /// A status the recorder rewrote less than 10 s before `at`, with a lock held behind it.
    static func isFresh(_ status: RecorderStatus, liveness: RecorderLiveness, at: Date) -> Bool {
        guard liveness == .capturing || liveness == .processing else { return false }
        return at.timeIntervalSince(status.updatedAt) < freshSeconds
    }

    /// "Saved Council meeting (2:58:12). Labelled 9 speakers in 343 turns." and the like.
    static func summary(_ status: RecorderStatus) -> String {
        let seconds = status.recordedSeconds > 0 ? status.recordedSeconds : status.elapsedSeconds
        var parts = ["Saved \(status.name) (\(MeetingFormat.clock(seconds)))."]
        if let exit = status.exit {
            if let reason = stopExplanation(exit.reason) { parts.append(reason) }
            switch exit.archiveStatus {
            case ArchiveStatus.transcriptionIncomplete:
                parts.append("Part of the transcript is missing; transcribe the saved audio again later.")
            case ArchiveStatus.audioOnly:
                parts.append("No transcript was made.")
            case ArchiveStatus.incomplete:
                parts.append("The recording ended with an error: \(exit.message ?? "unknown error").")
            default:
                break
            }
            switch exit.postprocessing {
            case nil:
                break
            case .succeeded?:
                parts.append(exit.postprocessingMessage ?? "Speakers labelled.")
            case .some:
                parts.append(exit.postprocessingMessage ?? "Speaker labelling did not finish.")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func stopExplanation(_ reason: StopReason) -> String? {
        switch reason {
        case .diskLow: "It stopped because free disk space fell below 500 MB."
        case .sleepTimeout: "It ended where the Mac went to sleep for 15 minutes or more."
        case .pauseTimeout: "It ended after staying paused for 6 hours."
        case .captureFailed: "It ended after audio stayed unavailable for 10 minutes."
        default: nil
        }
    }
}

/// Text formats shared by the menu, the windows, and the reducer's messages.
public enum MeetingFormat {
    /// h:mm:ss, e.g. "2:58:12" or "0:04:05".
    public static func clock(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, min(seconds, 1e9))) : 0
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// Decimal gigabytes with one decimal ("0.9 GB"), as the disk policy counts them.
    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), Double(max(0, bytes)) / 1e9)
    }

    /// A byte count for tables: "812 MB" below 1 GB, else "1.4 GB".
    public static func size(_ bytes: Int64) -> String {
        if bytes < 1_000_000_000 {
            return "\(max(0, bytes) / 1_000_000) MB"
        }
        return gigabytes(bytes)
    }
}

/// What decides the meeting lines of the menu and which of them are enabled: the state without what the recorder
/// rewrites every second (clock, sizes, free space, labelling progress). The app rebuilds the menu only when this
/// changes, and otherwise retitles the clock and progress lines in place.
public struct MeetingMenuLayout: Sendable, Equatable {
    private enum Step: Sendable, Equatable { case idle, starting, active, finishing, failed }

    private var step: Step
    private var sessionID: String?
    /// Active: the phase picks the headline, Pause or Resume, and what is enabled.
    private var phase: RecorderPhase?
    private var name: String?
    private var source: AudioSource?
    private var microphoneName: String?
    private var transcription: [TranscriptionState] = []
    private var warnings: [String] = []
    /// Failed: the message line.
    private var message: String?

    public init(_ state: MeetingState) {
        sessionID = state.sessionID
        switch state {
        case .idle:
            step = .idle
        case .starting:
            step = .starting
        case .active(_, let status):
            step = .active
            phase = status.phase
            name = status.name
            source = status.source
            microphoneName = status.microphoneName
            transcription = status.tracks.map(\.transcription)
            warnings = status.warnings.map(\.message)
        case .finishing:
            step = .finishing
        case .failed(_, let failure):
            step = .failed
            message = failure
        }
    }
}
