import Foundation

// Contract file added by PR6 in wave 0 (docs/meeting-design.md §3.2). Value types shared by the recorder
// process, the CLI, and the menu bar app. No logic beyond trivial derived properties.

// MARK: - Open string codes

/// Recorder warnings shown in the menu and `voiceislocal record status`. Open string code.
public struct RecorderWarningCode: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Free space fell below 2 GB.
    public static let diskLow = RecorderWarningCode("diskLow")
    /// A track delivered no audio for more than 3 seconds.
    public static let trackStalled = RecorderWarningCode("trackStalled")
    /// Capture resumed after a system sleep shorter than 15 minutes; the gap is marked.
    public static let resumedAfterSleep = RecorderWarningCode("resumedAfterSleep")
    /// Capture restarted after an audio configuration change.
    public static let deviceChanged = RecorderWarningCode("deviceChanged")
    /// Live transcription fell behind; the rest is transcribed from saved audio after stop.
    public static let transcriptionBehind = RecorderWarningCode("transcriptionBehind")
    /// Laptop speakers are the output during a call, so remote voices reach the microphone (PR11).
    public static let echoRisk = RecorderWarningCode("echoRisk")
    /// Audio capture is not running and the recorder is retrying (phase `waiting`).
    public static let audioUnavailable = RecorderWarningCode("audioUnavailable")
    /// A call recording continues without the microphone because no input device is available.
    public static let microphoneUnavailable = RecorderWarningCode("microphoneUnavailable")
    /// The disk could not keep up, so some audio was dropped; the gap is marked.
    public static let audioDropped = RecorderWarningCode("audioDropped")
}

/// Why capture ended. Open string code.
public struct StopReason: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A stop control request (app, `voiceislocal record stop`, or legacy stop.request).
    public static let requested = StopReason("requested")
    /// SIGINT or SIGTERM.
    public static let signal = StopReason("signal")
    /// `--duration` elapsed.
    public static let duration = StopReason("duration")
    /// Free space fell below 500 MB.
    public static let diskLow = StopReason("diskLow")
    /// The system slept for 15 minutes or more while recording; the recording ends at the sleep point.
    public static let sleepTimeout = StopReason("sleepTimeout")
    /// Audio stayed unavailable for 10 minutes (phase `waiting`).
    public static let captureFailed = StopReason("captureFailed")
    /// Capture never started.
    public static let startFailed = StopReason("startFailed")
    /// The meeting stayed paused (including sleep while paused) for 6 hours.
    public static let pauseTimeout = StopReason("pauseTimeout")
    /// Written by a maintenance command into the status of a recorder that died.
    public static let interrupted = StopReason("interrupted")
}

// MARK: - Archive status strings (manifest.json "status")

/// Values of `SessionManifest.status`. The manifest keeps a String for schema-v1 compatibility.
public enum ArchiveStatus {
    public static let recording = "recording"
    public static let processing = "processing"
    public static let complete = "complete"
    public static let audioOnly = "audioOnly"
    public static let transcriptionIncomplete = "transcriptionIncomplete"
    public static let incomplete = "incomplete"
    public static let failed = "failed"
    public static let interrupted = "interrupted"
    /// Interrupted, then recovered with a rebuilt transcript (PR3).
    public static let recovered = "recovered"
}

// MARK: - Event kinds (events.jsonl "kind"); details are [String: String]

/// Event kinds. Details keys are listed per kind; numbers are written with `String(Double)`.
public enum MeetingEventKind {
    /// track, relativePath, start, sampleRate, channels
    public static let chunkOpened = "chunkOpened"
    /// hostTimeOrigin; from PR2 also epoch, timelineOffset
    public static let captureStarted = "captureStarted"
    /// track, text, start, end; from PR2 also segmentID and words (compact JSON array of TimedWord)
    public static let transcriptFinalized = "transcriptFinalized"
    /// track, previousEnd, nextStart, reason (a GapReason raw value, or timestampGap | formatChanged)
    public static let audioDiscontinuity = "audioDiscontinuity"
    /// track, previousEnd, nextStart, droppedSeconds: leading samples that would overlap the previous chunk were dropped
    public static let timestampOverlap = "timestampOverlap"
    /// error
    public static let startFailed = "startFailed"
    /// error; from PR2 also epoch
    public static let captureFailed = "captureFailed"
    /// at, reason, attempt, retryInSeconds: capture is not running and will be retried
    public static let captureWaiting = "captureWaiting"
    /// transcriptionErrors; from PR2 also reason (StopReason)
    public static let captureStopped = "captureStopped"
    /// chunks, unrecovered, previousStatus
    public static let archiveRecovered = "archiveRecovered"
    /// at
    public static let paused = "paused"
    /// at, epoch
    public static let resumed = "resumed"
    /// at, requestID, label (optional)
    public static let marker = "marker"
    /// at, phaseBeforeSleep (recording | paused | waiting)
    public static let systemWillSleep = "systemWillSleep"
    /// at, sleptSeconds, action (resume | wait | finalize)
    public static let didWake = "didWake"
    /// track, at, reason
    public static let deviceChanged = "deviceChanged"
    /// epoch, at, reason, timelineOffset
    public static let captureRestarted = "captureRestarted"
    /// freeBytes, action (warn | stop)
    public static let diskLow = "diskLow"
    /// track, silentSeconds
    public static let trackStalled = "trackStalled"
    /// track
    public static let trackResumed = "trackResumed"
    /// track, from: session time of the first audio that live transcription did not receive
    public static let transcriptionBehind = "transcriptionBehind"
    /// id, command, result
    public static let controlHandled = "controlHandled"
    /// file, reason
    public static let controlRejected = "controlRejected"
    /// transcriptID, journalSegments, replayedSeconds (PR3)
    public static let transcriptRebuilt = "transcriptRebuilt"
    /// The details `transcriptRebuilt` will have, journaled before the rebuilt transcript is saved, so a rebuild whose
    /// status or `transcriptRebuilt` could not be recorded is told from a transcript the recorder saved (PR3)
    public static let transcriptRebuilding = "transcriptRebuilding"
}

// MARK: - Meeting setup (meeting.json, vocabulary.json)

public enum MeetingMode: String, Codable, Sendable, CaseIterable {
    /// Microphone only (the built-in microphone); the microphone track is diarized.
    case inPerson
    /// Microphone (the system default input) and system audio; the system track is diarized.
    case call
}

public enum MeetingOrigin: String, Codable, Sendable {
    case recorded
    case imported
}

/// How a meeting was set up. Written once to `meeting.json` when a recording or import starts.
public struct MeetingInfo: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sessionID: String
    public var mode: MeetingMode
    /// In a call, also diarize the microphone track because other people share the room.
    /// `voiceislocal session diarize --others-in-room | --no-others-in-room` overrides it per run.
    public var othersInRoom: Bool
    /// Bundle ID whose audio the system track captures, when filtered with `--app`.
    public var applicationBundleID: String?
    public var origin: MeetingOrigin
    /// Original file name for `voiceislocal session import`; nil for recordings.
    public var importedFileName: String?
    /// Number of people the user expects, passed to the diarizer as a hint (optional).
    public var expectedSpeakers: Int?
    public var createdAt: Date

    public init(schemaVersion: Int = 1, sessionID: String, mode: MeetingMode, othersInRoom: Bool,
                applicationBundleID: String? = nil, origin: MeetingOrigin = .recorded,
                importedFileName: String? = nil, expectedSpeakers: Int? = nil, createdAt: Date = Date()) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.mode = mode
        self.othersInRoom = othersInRoom; self.applicationBundleID = applicationBundleID
        self.origin = origin; self.importedFileName = importedFileName
        self.expectedSpeakers = expectedSpeakers; self.createdAt = createdAt
    }

    /// Settings assumed for archives created before meeting.json existed.
    public static func inferred(sessionID: String, source: AudioSource, createdAt: Date) -> MeetingInfo {
        MeetingInfo(sessionID: sessionID, mode: source == .microphone ? .inPerson : .call,
                    othersInRoom: false, createdAt: createdAt)
    }
}

/// Contents of `vocabulary.json`: names and terms the recognizer should prefer (contextual strings).
/// Written once when a recording or import starts; at most 1,000 entries of at most 100 characters.
public struct MeetingVocabulary: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var strings: [String]

    public init(schemaVersion: Int = 1, strings: [String]) {
        self.schemaVersion = schemaVersion; self.strings = strings
    }
}

// MARK: - Control requests (control/<id>.json)

public enum ControlCommand: String, Codable, Sendable, CaseIterable {
    case stop, pause, resume, marker
}

/// One request from the app or CLI to a running recorder. Published atomically as
/// `control/<id>.json`; the recorder applies it at most once and deletes the file.
public struct ControlRequest: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int
    /// UUID string; also the file name.
    public var id: String
    /// Must equal the session folder's ID or the request is rejected.
    public var sessionID: String
    public var command: ControlCommand
    /// Marker label, at most 200 characters; ignored for other commands.
    public var label: String?
    public var createdAt: Date
    /// `mach_continuous_time` in nanoseconds when the request was written. The recorder applies
    /// requests in (sentAtNanos, id) order; the value is comparable across processes on one Mac.
    public var sentAtNanos: UInt64?
    /// "app" or "cli".
    public var sender: String

    public init(schemaVersion: Int = 1, id: String = UUID().uuidString, sessionID: String,
                command: ControlCommand, label: String? = nil, createdAt: Date = Date(),
                sentAtNanos: UInt64? = nil, sender: String) {
        self.schemaVersion = schemaVersion; self.id = id; self.sessionID = sessionID
        self.command = command; self.label = label; self.createdAt = createdAt
        self.sentAtNanos = sentAtNanos; self.sender = sender
    }
}

public enum ControlResult: String, Codable, Sendable {
    /// The command changed recorder state (or added a marker).
    case applied
    /// Valid but had no effect, e.g. pause while paused, or any command after capture stopped.
    case ignored
    /// Invalid for this session or phase; `message` says why.
    case rejected
}

public struct ControlAck: Codable, Sendable, Equatable {
    public var id: String
    public var command: ControlCommand
    public var result: ControlResult
    public var message: String?
    public var handledAt: Date

    public init(id: String, command: ControlCommand, result: ControlResult, message: String? = nil,
                handledAt: Date = Date()) {
        self.id = id; self.command = command; self.result = result
        self.message = message; self.handledAt = handledAt
    }
}

// MARK: - Post-processing (postprocess.json; mirrored in status.json)

/// Post-processing stage. Open string code.
public struct PostProcessingStage: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let transcript = PostProcessingStage("transcript")
    public static let render = PostProcessingStage("render")
    public static let diarize = PostProcessingStage("diarize")
    public static let align = PostProcessingStage("align")
    public static let recognize = PostProcessingStage("recognize")
    public static let export = PostProcessingStage("export")
}

public struct PostProcessingProgress: Codable, Sendable, Equatable {
    public var stage: PostProcessingStage
    public var track: String?
    /// 0...1 within the stage (and track), when known.
    public var fraction: Double?
    /// Short user-facing text, e.g. "Labelling speakers (system audio)…". Never transcript text.
    public var message: String

    public init(stage: PostProcessingStage, track: String? = nil, fraction: Double? = nil, message: String) {
        self.stage = stage; self.track = track; self.fraction = fraction; self.message = message
    }
}

/// Result of one stage. Open string code.
public struct StageResult: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let succeeded = StageResult("succeeded")
    public static let skipped = StageResult("skipped")
    public static let failed = StageResult("failed")
}

public struct StageOutcome: Codable, Sendable, Equatable {
    public var stage: PostProcessingStage
    public var result: StageResult
    public var message: String?
    public var seconds: Double

    public init(stage: PostProcessingStage, result: StageResult, message: String? = nil, seconds: Double = 0) {
        self.stage = stage; self.result = result; self.message = message; self.seconds = seconds
    }
}

/// Overall post-processing state. Open string code.
public struct PostProcessingState: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running = PostProcessingState("running")
    /// Every applicable stage succeeded (expected skips allowed, §4.7).
    public static let succeeded = PostProcessingState("succeeded")
    /// Exports were written but a speaker stage was skipped or failed.
    public static let partial = PostProcessingState("partial")
    public static let failed = PostProcessingState("failed")
    /// Nothing to do (e.g. audio-only session with no transcript).
    public static let skipped = PostProcessingState("skipped")
}

/// Contents of `postprocess.json`, and the value `MeetingPostProcessor.run` returns.
public struct PostProcessingRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sessionID: String
    public var state: PostProcessingState
    public var progress: PostProcessingProgress?
    public var stages: [StageOutcome]
    /// The run that became `speakers/head.json`, if any.
    public var runID: String?
    /// The transcript the run was built from.
    public var transcriptID: String?
    /// The microphone-track choice used for this run (from meeting.json unless overridden).
    public var othersInRoom: Bool?
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var message: String?

    public init(schemaVersion: Int = 1, sessionID: String, state: PostProcessingState,
                progress: PostProcessingProgress? = nil, stages: [StageOutcome] = [], runID: String? = nil,
                transcriptID: String? = nil, othersInRoom: Bool? = nil, pid: Int32, startedAt: Date,
                updatedAt: Date, message: String? = nil) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.state = state
        self.progress = progress; self.stages = stages; self.runID = runID
        self.transcriptID = transcriptID; self.othersInRoom = othersInRoom; self.pid = pid
        self.startedAt = startedAt; self.updatedAt = updatedAt; self.message = message
    }
}

// MARK: - Recorder status (status.json)

public enum RecorderPhase: String, Codable, Sendable, CaseIterable {
    case starting, recording, paused, waiting, sleeping, stopping, transcribing, postprocessing, exited
    /// A phase written by a newer Holos. Decoded from any unrecognized value; never written.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecorderPhase(rawValue: raw) ?? .unknown
    }

    /// True from launch until capture has stopped. Dictation stays paused while this is true.
    public var isMeetingActive: Bool {
        switch self {
        case .starting, .recording, .paused, .waiting, .sleeping, .stopping, .unknown: true
        case .transcribing, .postprocessing, .exited: false
        }
    }
}

/// Live transcription state of one track. Open string code.
public struct TranscriptionState: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Live transcription is keeping up.
    public static let live = TranscriptionState("live")
    /// Live transcription stopped; the rest is transcribed from saved audio after stop.
    public static let behind = TranscriptionState("behind")
    /// `--record-only`, or live transcription could not start.
    public static let off = TranscriptionState("off")
}

public struct TrackStatus: Codable, Sendable, Equatable {
    /// "mic" or "system".
    public var track: String
    public var transcription: TranscriptionState
    /// Session time of the end of the last captured frame.
    public var lastFrameSeconds: Double?
    /// Session time of the end of the last finalized phrase.
    public var lastFinalizedSeconds: Double?
    public var sampleRate: Double?
    public var channels: Int?
    public var stalled: Bool
    /// Seconds of captured audio waiting to be written to disk.
    public var backlogSeconds: Double?

    public init(track: String, transcription: TranscriptionState, lastFrameSeconds: Double? = nil,
                lastFinalizedSeconds: Double? = nil, sampleRate: Double? = nil, channels: Int? = nil,
                stalled: Bool = false, backlogSeconds: Double? = nil) {
        self.track = track; self.transcription = transcription; self.lastFrameSeconds = lastFrameSeconds
        self.lastFinalizedSeconds = lastFinalizedSeconds; self.sampleRate = sampleRate
        self.channels = channels; self.stalled = stalled; self.backlogSeconds = backlogSeconds
    }
}

public struct RecorderWarning: Codable, Sendable, Equatable {
    public var code: RecorderWarningCode
    /// Short user-facing text; never transcript text.
    public var message: String
    public var since: Date

    public init(code: RecorderWarningCode, message: String, since: Date = Date()) {
        self.code = code; self.message = message; self.since = since
    }
}

public struct RecorderExit: Codable, Sendable, Equatable {
    /// The manifest status written at finish (see `ArchiveStatus`).
    public var archiveStatus: String
    public var reason: StopReason
    public var message: String?
    /// nil when post-processing did not run.
    public var postprocessing: PostProcessingState?
    /// The post-processing record's message, e.g. "No speaker labels: speaker models are not installed."
    public var postprocessingMessage: String?

    public init(archiveStatus: String, reason: StopReason, message: String? = nil,
                postprocessing: PostProcessingState? = nil, postprocessingMessage: String? = nil) {
        self.archiveStatus = archiveStatus; self.reason = reason; self.message = message
        self.postprocessing = postprocessing; self.postprocessingMessage = postprocessingMessage
    }
}

/// Contents of `status.json`, rewritten atomically by the recorder at least once per second
/// (a heartbeat from launch until exit) and on every phase change. Kept after exit with `phase == .exited`.
public struct RecorderStatus: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sessionID: String
    public var name: String
    public var pid: Int32
    public var phase: RecorderPhase
    /// Increments on every write, so a reader can detect a stalled writer.
    public var sequence: Int
    public var startedAt: Date
    public var updatedAt: Date
    public var source: AudioSource
    /// Name of the input device recorded on the microphone track, for display.
    public var microphoneName: String?
    /// Session time now: time since capture first started, including pauses and sleep.
    public var elapsedSeconds: Double
    /// Audio actually captured on the longest track.
    public var recordedSeconds: Double
    public var bytesWritten: Int64
    public var freeBytes: Int64?
    public var tracks: [TrackStatus]
    /// Last finalized phrase, at most 200 characters. The session folder is private (0700).
    public var lastPhrase: String?
    public var warnings: [RecorderWarning]
    public var markers: Int
    public var progress: PostProcessingProgress?
    /// The 32 most recent acknowledgements, newest last.
    public var handledRequests: [ControlAck]
    /// Set only when `phase == .exited`.
    public var exit: RecorderExit?

    public init(schemaVersion: Int = 1, sessionID: String, name: String, pid: Int32, phase: RecorderPhase,
                sequence: Int, startedAt: Date, updatedAt: Date, source: AudioSource,
                microphoneName: String? = nil, elapsedSeconds: Double = 0, recordedSeconds: Double = 0,
                bytesWritten: Int64 = 0, freeBytes: Int64? = nil, tracks: [TrackStatus] = [],
                lastPhrase: String? = nil, warnings: [RecorderWarning] = [], markers: Int = 0,
                progress: PostProcessingProgress? = nil, handledRequests: [ControlAck] = [],
                exit: RecorderExit? = nil) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.name = name; self.pid = pid
        self.phase = phase; self.sequence = sequence; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.source = source; self.microphoneName = microphoneName; self.elapsedSeconds = elapsedSeconds
        self.recordedSeconds = recordedSeconds; self.bytesWritten = bytesWritten; self.freeBytes = freeBytes
        self.tracks = tracks; self.lastPhrase = lastPhrase; self.warnings = warnings; self.markers = markers
        self.progress = progress; self.handledRequests = handledRequests; self.exit = exit
    }
}
