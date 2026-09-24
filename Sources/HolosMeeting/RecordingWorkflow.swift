import Darwin
import Foundation
import HolosAudio
import HolosCore
import HolosStorage
import os

public struct RecordingOptions: Sendable, Equatable {
    public var name: String
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    /// The sessions folder; the recording is saved in `<root>/<SESSION-UUID>.holos`.
    public var root: URL
    /// Stop automatically after this many seconds.
    public var duration: Double?
    /// Save audio without speech recognition.
    public var recordOnly: Bool
    /// Capture system audio only from this application.
    public var applicationBundleID: String?
    /// Contextual strings for every speech session of this recording (§4.12).
    public var vocabulary: [String]

    public init(name: String, source: AudioSource, locale: String, backend: SpeechBackend, root: URL,
                duration: Double? = nil, recordOnly: Bool = false, applicationBundleID: String? = nil,
                vocabulary: [String] = []) {
        self.name = name; self.source = source; self.locale = locale; self.backend = backend; self.root = root
        self.duration = duration; self.recordOnly = recordOnly; self.applicationBundleID = applicationBundleID
        self.vocabulary = vocabulary
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

    /// No hardware defaults: tests use `.testing(...)` (Fakes.swift).
    public init(makeCapture: @escaping @MainActor @Sendable () -> any MeetingCapture,
                makeSpeech: @escaping LiveSpeechFactory, stop: any RecorderStopSource,
                reporter: any RecordingReporter, postProcess: PostProcessHook?) {
        self.makeCapture = makeCapture; self.makeSpeech = makeSpeech; self.stop = stop
        self.reporter = reporter; self.postProcess = postProcess
    }

    /// LiveMeetingCapture + AppleSpeechSession.make.
    public static func live(stop: any RecorderStopSource, reporter: any RecordingReporter,
                            postProcess: PostProcessHook?) -> RecordingDependencies {
        RecordingDependencies(makeCapture: { LiveMeetingCapture() }, makeSpeech: appleSpeechFactory,
                              stop: stop, reporter: reporter, postProcess: postProcess)
    }
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
    /// How often the loop checks the stop source, `stop.request`, the duration, and capture failure.
    static let pollInterval: Duration = .milliseconds(100)

    /// Records until stop, saves audio and transcript, then (with a hook) takes the processing lease,
    /// finishes the archive, and runs the hook under the lease (§4.6 steps 5–8).
    /// Capture failure: marks the archive incomplete and throws `HolosError.incomplete` (as today).
    /// Transcription failure: does not throw; the outcome carries the errors.
    /// Task cancellation: stops like a stop request, keeps the saved audio, finishes the archive without a
    /// partial transcript (`transcriptionIncomplete`, or `audioOnly` for record-only), skips post-processing,
    /// and rethrows `CancellationError`. Cancelled before capture starts: capture never starts and the archive
    /// is finished `failed` (a `startFailed` event with `cancelled`). Cancelled once the transcript is saved:
    /// the archive keeps its final status, the processing lease is released, and a hook that has not started
    /// is skipped. Cancelled during the hook: the hook's run ends as it chooses, and `CancellationError` is
    /// rethrown instead of an outcome.
    /// A `CancellationError` from any awaited dependency (starting or stopping capture, the frame stream,
    /// replaying saved audio, the processing lease) is handled as a cancellation, never as a capture or
    /// transcription failure; so is any error from starting or stopping capture or from a replay once the task
    /// is cancelled. The frame consumer is still drained and the chunk writer finished first. A live speech
    /// session's own `CancellationError` (its worker is cancelled when transcription falls behind) only moves
    /// that track to replay.
    @MainActor public static func run(_ options: RecordingOptions,
                                      dependencies: RecordingDependencies) async throws -> RecordingOutcome {
        let reporter = dependencies.reporter
        let stop = dependencies.stop
        defer { stop.restoreDefaultHandlers() }
        try validate(options)
        let archive = try SessionArchive.create(root: options.root, name: options.name, source: options.source,
                                                locale: options.locale, backend: options.backend)
        let writer = AudioChunkWriter(archive: archive)
        let capture = dependencies.makeCapture()
        let tracks = options.source == .microphoneAndSystem ? ["mic", "system"] : [options.source.rawValue]
        var live: [String: LiveTrack] = [:]
        do {
            if !options.recordOnly {
                for track in tracks {
                    try Task.checkCancellation()
                    do {
                        live[track] = try await LiveTrack.make(track: track, locale: options.locale,
                            backend: options.backend, contextualStrings: options.vocabulary,
                            makeSpeech: dependencies.makeSpeech, archive: archive, reporter: reporter)
                    } catch {
                        // A cancelled run is not a speech failure: it ends before capture starts.
                        try Task.checkCancellation()
                        reporter.message("Live \(track) transcription unavailable: \(error.localizedDescription). Recording will continue and transcription will be retried after stop.")
                    }
                }
            }
            // A run cancelled while setting up never opens the microphone or system audio.
            try Task.checkCancellation()
            try await capture.start(CaptureRequest(source: options.source,
                                                   applicationBundleID: options.applicationBundleID))
        } catch {
            stop.restoreDefaultHandlers()
            for feed in live.values { await feed.cancel() }
            let cancelledAtStart = error is CancellationError || Task.isCancelled
            let details = cancelledAtStart ? ["error": "Cancelled before capture started.", "cancelled": "true"]
                : ["error": error.localizedDescription]
            try? await archive.recordEvent(kind: MeetingEventKind.startFailed, details: details)
            try? await archive.finish(status: ArchiveStatus.failed)
            log.error("Session \(archive.id, privacy: .public) failed to start capture")
            if cancelledAtStart { throw CancellationError() }
            throw error
        }
        log.notice("Session \(archive.id, privacy: .public) started recording (\(options.source.rawValue, privacy: .public))")
        reporter.message("Recording \(archive.id): \(options.name)")
        reporter.message("Audio archive: \(archive.directory.path)")
        reporter.message("Press Ctrl-C to stop. Source labels identify tracks, not individual speakers.")

        // Frames are consumed off the main actor; the consumer only awaits the chunk writer.
        let feeds = live
        let frames = capture.frames
        let captureError = LockedValue<String?>(nil)
        // A frame stream that ends with CancellationError was cancelled, not failed.
        let captureCancelled = LockedValue(false)
        let consume = Task.detached(priority: .userInitiated) {
            do {
                for try await audio in frames {
                    let normalized = try await writer.append(audio)
                    feeds[audio.track]?.submit(normalized.frame)
                }
            } catch is CancellationError {
                captureCancelled.withLock { $0 = true }
                throw CancellationError()
            } catch {
                captureError.withLock { $0 = error.localizedDescription }
                throw error
            }
        }
        let controlURL = archive.directory.appendingPathComponent("control.json")
        defer { try? FileManager.default.removeItem(at: controlURL) }
        let stopURL = archive.directory.appendingPathComponent("stop.request")
        var recordingError: Error?
        // Cancelling the task that runs the workflow stops the recording like a stop request: the audio is
        // saved, the archive is finished, and CancellationError is rethrown (§1.4).
        var cancelled = false
        var stopReason = StopReason.requested
        do {
            let control = RecordingControl(schemaVersion: 1, sessionID: archive.id, pid: getpid(), startedAt: Date())
            try AtomicFile.create(try HolosJSON.encoder().encode(control), at: controlURL)
            try await archive.recordEvent(kind: MeetingEventKind.captureStarted,
                                          details: ["hostTimeOrigin": String(capture.hostTimeOrigin)])
            let clock = ContinuousClock()
            let started = clock.now
            while true {
                try Task.checkCancellation()
                if captureCancelled.value { throw CancellationError() }
                if stop.shouldStop { stopReason = stop is SignalStopController ? .signal : .requested; break }
                if captureError.value != nil { stopReason = .captureFailed; break }
                if FileManager.default.fileExists(atPath: stopURL.path) { stopReason = .requested; break }
                if let duration = options.duration, seconds(started.duration(to: clock.now)) >= duration {
                    stopReason = .duration; break
                }
                try await Task.sleep(for: pollInterval)
            }
        } catch is CancellationError {
            cancelled = true
        } catch { recordingError = error }
        // A cancellation while stopping is not a capture failure: the consumer is still drained and the writer
        // finished, and the saved audio is finished with the cancellation status below.
        do { try await capture.stop() } catch {
            if error is CancellationError || Task.isCancelled { cancelled = true }
            else { recordingError = recordingError ?? error }
        }
        // The consumer runs detached, so only its own CancellationError (from the frame stream) is a cancellation;
        // any other error from it is a capture failure that the run's cancellation did not cause.
        do { try await consume.value } catch is CancellationError { cancelled = true }
        catch { recordingError = recordingError ?? error }
        do { try await writer.finish() } catch is CancellationError { cancelled = true }
        catch { recordingError = recordingError ?? error }
        // Cancelled after a stop, while capture was stopping: still a cancellation.
        if Task.isCancelled { cancelled = true }
        // Even on failure, audio capture is stopped before recognition is cancelled.
        // Let another signal interrupt a framework that is slow to cancel.
        stop.restoreDefaultHandlers()
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
            for feed in feeds.values { await feed.cancel() }
            try? await archive.recordEvent(kind: MeetingEventKind.captureFailed, details: ["error": recordingError.localizedDescription])
            try? await archive.finish(status: ArchiveStatus.incomplete)
            log.error("Session \(archive.id, privacy: .public) stopped with a capture error; saved audio is kept")
            if cancelled { throw CancellationError() }
            throw HolosError.incomplete("Recording stopped with an error: \(recordingError.localizedDescription). Saved audio: \(archive.directory.path)")
        }
        // Without transcription, the saved audio can be transcribed later (`holos session retranscribe`).
        let untranscribed = options.recordOnly ? ArchiveStatus.audioOnly : ArchiveStatus.transcriptionIncomplete
        if cancelled {
            for feed in feeds.values { await feed.cancel() }
            try await finishCancelled(archive, status: savedAudio ? untranscribed : ArchiveStatus.incomplete)
        }
        log.notice("Session \(archive.id, privacy: .public) stopped capture (\(stopReason.rawValue, privacy: .public))")
        try await archive.setStatus(ArchiveStatus.processing)
        reporter.message("Audio saved. Finishing transcription; Ctrl-C exits processing and preserves the audio archive.")
        var segments: [TranscriptSegment] = []
        var transcriptErrors: [String] = []
        var transcriptionCancelled = false
        // Live tracks not yet finished; a cancelled transcription cancels them.
        var unfinished = Set(feeds.keys)
        for track in options.recordOnly ? [] : tracks {
            if Task.isCancelled { break }
            unfinished.remove(track)
            // A cancellation while finishing cancels the live speech session (LiveTrack.finish).
            if let feed = feeds[track], let finalized = await feed.finish() {
                segments += finalized.map { var segment = $0; segment.track = track; return segment }
            } else {
                // Cancelled while the live session finished: replay nothing.
                if Task.isCancelled { break }
                do {
                    reporter.message("Processing saved \(track) audio…")
                    segments += try await TrackReplayer.replay(directory: archive.directory, track: track,
                        locale: options.locale, backend: options.backend, contextualStrings: options.vocabulary,
                        makeSpeech: dependencies.makeSpeech)
                } catch {
                    // A cancelled replay is a cancellation, not a transcription failure.
                    if error is CancellationError || Task.isCancelled { transcriptionCancelled = true; break }
                    transcriptErrors.append("\(track): \(error.localizedDescription)")
                }
            }
        }
        // Cancelled during transcription: keep the audio, publish no partial transcript.
        if transcriptionCancelled || Task.isCancelled {
            for track in unfinished { await feeds[track]?.cancel() }
            try await finishCancelled(archive, status: untranscribed)
        }
        var transcriptID: String?
        if !options.recordOnly {
            segments.sort { $0.start == $1.start ? ($0.track ?? "") < ($1.track ?? "") : $0.start < $1.start }
            let transcript = Transcript(source: archive.directory.path, locale: options.locale,
                                        backend: options.backend, segments: segments)
            try await archive.saveTranscript(transcript)
            transcriptID = transcript.id
        }
        try await archive.recordEvent(kind: MeetingEventKind.captureStopped,
                                      details: ["transcriptionErrors": transcriptErrors.joined(separator: "; ")])
        let status = options.recordOnly ? ArchiveStatus.audioOnly
            : (transcriptErrors.isEmpty ? ArchiveStatus.complete : ArchiveStatus.transcriptionIncomplete)

        if Task.isCancelled {
            try await archive.finish(status: status)
            throw CancellationError()
        }

        // §4.6 steps 5–8: the lease is taken while the writer lock is still held, so the session is never
        // without a lock between capture and post-processing.
        var lease: ProcessingLease?
        var leaseCancelled = false
        if dependencies.postProcess != nil {
            do { lease = try await acquireLease(archive.directory, sessionID: archive.id, reporter: reporter) }
            catch { leaseCancelled = true }
        }
        defer { lease?.release() }
        try await archive.finish(status: status)
        // Cancelled while the lease was being taken: the archive is finished; skip the hook, release the lease.
        if leaseCancelled || Task.isCancelled {
            lease?.release()
            log.notice("Session \(archive.id, privacy: .public) cancelled before post-processing; archive finished as \(status, privacy: .public)")
            throw CancellationError()
        }
        var record: PostProcessingRecord?
        if let hook = dependencies.postProcess, let lease {
            record = await hook(archive.directory, lease, progressReporter(reporter))
            lease.release()
            log.notice("Session \(archive.id, privacy: .public) post-processing ended: \(record?.state.rawValue ?? "", privacy: .public)")
            // The hook never throws; a cancellation during it still ends the run with CancellationError.
            if Task.isCancelled { throw CancellationError() }
        }
        return RecordingOutcome(sessionID: archive.id, directory: archive.directory, archiveStatus: status,
                                stopReason: stopReason, transcriptID: transcriptID,
                                transcriptErrors: transcriptErrors, postProcessing: record)
    }

    private static func validate(_ options: RecordingOptions) throws {
        if let duration = options.duration, !duration.isFinite || duration <= 0 {
            throw HolosError.invalidInput("Duration must be positive and finite.")
        }
        if options.source == .microphone, options.applicationBundleID != nil {
            throw HolosError.invalidInput("--app applies to system audio, not mic-only recording.")
        }
    }

    /// Records the stop, finishes the archive with `status`, and rethrows the cancellation.
    private static func finishCancelled(_ archive: SessionArchive, status: String) async throws -> Never {
        try? await archive.recordEvent(kind: MeetingEventKind.captureStopped, details: ["cancelled": "true"])
        try? await archive.finish(status: status)
        log.notice("Session \(archive.id, privacy: .public) cancelled; archive finished as \(status, privacy: .public)")
        throw CancellationError()
    }

    /// Takes the processing lease (retry 1 s) off the main actor. On failure, post-processing is skipped.
    /// Throws only `CancellationError`.
    private static func acquireLease(_ directory: URL, sessionID: String,
                                     reporter: any RecordingReporter) async throws -> ProcessingLease? {
        do {
            return try await Task.detached { try SessionArchive.acquireProcessingLease(at: directory) }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch HolosError.unavailable {
            log.error("Session \(sessionID, privacy: .public): processing lease held elsewhere; post-processing skipped")
            reporter.message("Another Holos process is labelling this meeting.")
            return nil
        } catch {
            let code = error as NSError
            log.error("Session \(sessionID, privacy: .public): cannot take the processing lease (\(code.domain, privacy: .public) \(code.code, privacy: .public)): \(error.localizedDescription, privacy: .private); post-processing skipped")
            reporter.message("Speaker labelling skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// Passes a post-processing message to the reporter when it differs from the previous one, so repeated
    /// progress updates of one step (fractions) print one line.
    private static func progressReporter(_ reporter: any RecordingReporter)
        -> @Sendable (PostProcessingProgress) -> Void {
        let last = LockedValue<String?>(nil)
        return { progress in
            let isNew = last.withLock { previous in
                guard previous != progress.message else { return false }
                previous = progress.message
                return true
            }
            if isNew { reporter.message(progress.message) }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// Contents of `control.json`, written while capture runs (PR2a replaces it with `status.json`).
struct RecordingControl: Codable {
    var schemaVersion: Int
    var sessionID: String
    var pid: Int32
    var startedAt: Date
}
