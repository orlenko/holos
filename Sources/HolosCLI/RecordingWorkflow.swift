import AVFoundation
import Darwin
import Foundation
import HolosAudio
import HolosCore
import HolosSpeech
import HolosStorage
import Synchronization

private final class LockedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { value in body(&value) }
    }
}

final class StopController: Sendable {
    private let requested = LockedValue(false)
    private let sources: [any DispatchSourceSignal]
    init() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let state = requested
        sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { state.withLock { $0 = true } }
            source.resume()
            return source
        }
    }
    var shouldStop: Bool { requested.withLock { $0 } }
    /// Once audio is durable, a further signal can end model processing immediately.
    func restoreDefaultHandlers() {
        for source in sources { source.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
    deinit { for source in sources { source.cancel() } }
}

private final class LiveTrack: Sendable {
    let track: String
    private let continuation: AsyncStream<PCMFrame>.Continuation
    private let worker: Task<[TranscriptSegment], Error>
    private let journalWorker: Task<Void, Error>
    private let journal: AsyncStream<TranscriptSegment>.Continuation
    private let needsReplay: LockedValue<Bool>

    private init(track: String, continuation: AsyncStream<PCMFrame>.Continuation,
                 worker: Task<[TranscriptSegment], Error>, journalWorker: Task<Void, Error>,
                 journal: AsyncStream<TranscriptSegment>.Continuation, needsReplay: LockedValue<Bool>) {
        self.track = track; self.continuation = continuation; self.worker = worker
        self.journalWorker = journalWorker; self.journal = journal; self.needsReplay = needsReplay
    }

    static func make(track: String, locale: String, backend: SpeechBackend, archive: SessionArchive) async throws -> LiveTrack {
        let frames = AsyncStream<PCMFrame>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let updates = AsyncStream<TranscriptSegment>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let replay = LockedValue(false)
        let session = try await AppleSpeechSession.make(locale: locale, backend: backend) { update in
            if update.isFinal {
                Console.segment(update.segment, track: track)
                if case .dropped = updates.continuation.yield(update.segment) {
                    replay.withLock { $0 = true }
                }
            }
        }
        let journalWorker = Task {
            for await segment in updates.stream {
                try await archive.recordEvent(kind: "transcriptFinalized", details: [
                    "track": track, "text": segment.text, "start": String(segment.start), "end": String(segment.end),
                ])
            }
        }
        let worker = Task {
            do {
                for await frame in frames.stream { try await session.append(frame) }
                return try await session.finish()
            } catch {
                replay.withLock { $0 = true }
                Console.error("Live transcription paused for \(track): \(error.localizedDescription). Audio remains on disk.")
                await session.cancel()
                throw error
            }
        }
        return LiveTrack(track: track, continuation: frames.continuation, worker: worker,
                         journalWorker: journalWorker, journal: updates.continuation, needsReplay: replay)
    }

    func submit(_ frame: PCMFrame) {
        guard !needsReplay.withLock({ $0 }) else { return }
        if case .dropped = continuation.yield(frame) {
            needsReplay.withLock { $0 = true }
            Console.error("Transcription is behind on \(track); recording continues and saved audio will be processed after stop.")
            continuation.finish()
            worker.cancel()
        }
    }

    func finish() async -> [TranscriptSegment]? {
        continuation.finish()
        let result = try? await worker.value
        journal.finish()
        do { try await journalWorker.value }
        catch {
            Console.error("Could not persist live text: \(error.localizedDescription).")
            needsReplay.withLock { $0 = true }
        }
        return needsReplay.withLock { $0 } ? nil : result
    }

    func cancel() async {
        continuation.finish(); worker.cancel()
        _ = try? await worker.value
        journal.finish()
        _ = try? await journalWorker.value
    }
}

enum RecordingWorkflow {
    @MainActor
    static func run(name: String, source: AudioSource, locale: String, backend: SpeechBackend,
                    root: URL, duration: Double?, recordOnly: Bool, app: String?) async throws {
        let archive = try SessionArchive.create(root: root, name: name, source: source, locale: locale, backend: backend)
        let writer = AudioChunkWriter(archive: archive)
        let capture = AudioCapture()
        let stop = StopController()
        defer { stop.restoreDefaultHandlers() }
        var live: [String: LiveTrack] = [:]
        let tracks = source == .microphoneAndSystem ? ["mic", "system"] : [source.rawValue]
        do {
            if !recordOnly {
                for track in tracks {
                    do {
                        live[track] = try await LiveTrack.make(track: track, locale: locale, backend: backend, archive: archive)
                    } catch {
                        Console.error("Live \(track) transcription unavailable: \(error.localizedDescription). Recording will continue and transcription will be retried after stop.")
                    }
                }
            }
            try await capture.start(source: source, applicationBundleID: app)
        } catch {
            stop.restoreDefaultHandlers()
            for feed in live.values { await feed.cancel() }
            try? await archive.recordEvent(kind: "startFailed", details: ["error": error.localizedDescription])
            try? await archive.finish(status: "failed")
            throw error
        }
        Console.error("Recording \(archive.id): \(name)")
        Console.error("Audio archive: \(archive.directory.path)")
        Console.error("Press Ctrl-C to stop. Source labels identify tracks, not individual speakers.")
        let feeds = live
        let captureError = LockedValue<String?>(nil)
        let consume = Task {
            do {
                for try await audio in capture.frames {
                    let normalized = try await writer.append(audio)
                    feeds[audio.track]?.submit(normalized.frame)
                }
            } catch {
                captureError.withLock { $0 = error.localizedDescription }
                throw error
            }
        }
        let controlURL = archive.directory.appendingPathComponent("control.json")
        defer { try? FileManager.default.removeItem(at: controlURL) }
        let stopURL = archive.directory.appendingPathComponent("stop.request")
        var recordingError: Error?
        do {
            try writeJSON(RecordingControl(schemaVersion: 1, sessionID: archive.id, pid: getpid(), startedAt: Date()), to: controlURL)
            try await archive.recordEvent(kind: "captureStarted", details: ["hostTimeOrigin": String(capture.hostTimeOrigin)])
            let start = ContinuousClock.now
            while !stop.shouldStop, captureError.withLock({ $0 }) == nil,
                  !FileManager.default.fileExists(atPath: stopURL.path) {
                if let duration, start.duration(to: .now) >= .seconds(duration) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch { recordingError = error }
        do { try await capture.stop() } catch { recordingError = recordingError ?? error }
        do { try await consume.value } catch { recordingError = recordingError ?? error }
        do { try await writer.finish() } catch { recordingError = recordingError ?? error }
        // Even on failure, audio capture is stopped before recognition is cancelled.
        // Let another signal interrupt a framework that is slow to cancel.
        stop.restoreDefaultHandlers()
        if recordingError == nil {
            do {
                let saved = try SessionArchive.readManifest(at: archive.directory)
                if saved.chunks.isEmpty {
                    recordingError = HolosError.incomplete("No audio buffers were captured.")
                } else {
                    for track in tracks where !saved.chunks.contains(where: { $0.track == track }) {
                        Console.error("No \(track) audio buffers arrived; that source track is empty.")
                    }
                }
            } catch { recordingError = error }
        }
        if let recordingError {
            for feed in feeds.values { await feed.cancel() }
            try? await archive.recordEvent(kind: "captureFailed", details: ["error": recordingError.localizedDescription])
            try? await archive.finish(status: "incomplete")
            throw HolosError.incomplete("Recording stopped with an error: \(recordingError.localizedDescription). Saved audio: \(archive.directory.path)")
        }
        try await archive.setStatus("processing")
        Console.error("Audio saved. Finishing transcription; Ctrl-C exits processing and preserves the audio archive.")
        var segments: [TranscriptSegment] = []
        var transcriptErrors: [String] = []
        for track in recordOnly ? [] : tracks {
            if let feed = feeds[track], let finalized = await feed.finish() {
                segments += finalized.map { var segment = $0; segment.track = track; return segment }
            } else {
                do {
                    Console.error("Processing saved \(track) audio…")
                    segments += try await replay(directory: archive.directory, track: track, locale: locale, backend: backend)
                } catch { transcriptErrors.append("\(track): \(error.localizedDescription)") }
            }
        }
        if !recordOnly {
            segments.sort { $0.start == $1.start ? ($0.track ?? "") < ($1.track ?? "") : $0.start < $1.start }
            try await archive.saveTranscript(Transcript(source: archive.directory.path, locale: locale, backend: backend, segments: segments))
        }
        try await archive.recordEvent(kind: "captureStopped", details: ["transcriptionErrors": transcriptErrors.joined(separator: "; ")])
        try await archive.finish(status: recordOnly ? "audioOnly" : (transcriptErrors.isEmpty ? "complete" : "transcriptionIncomplete"))
        Console.error("Saved \(archive.directory.path)")
        if !transcriptErrors.isEmpty {
            throw HolosError.incomplete("Audio saved; transcription needs retry: \(transcriptErrors.joined(separator: "; ")).")
        }
    }

    static func replay(directory: URL, track: String, locale: String, backend: SpeechBackend) async throws -> [TranscriptSegment] {
        let manifest = try SessionArchive.readManifest(at: directory)
        let chunks = manifest.chunks.filter { $0.track == track }.sorted { $0.start < $1.start }
        let session = try await AppleSpeechSession.make(locale: locale, backend: backend) { _ in }
        do {
            for chunk in chunks {
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativePath))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                    throw HolosError.io("Could not allocate a replay buffer.")
                }
                var offset: Int64 = 0
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer, frameCount: 4096)
                    guard buffer.frameLength > 0 else { break }
                    let frame = try PCMConversion.copy(buffer, startTime: chunk.start + Double(offset) / file.processingFormat.sampleRate)
                    try await session.append(frame)
                    offset += Int64(buffer.frameLength)
                }
            }
            return try await session.finish().map { var segment = $0; segment.track = track; return segment }
        } catch { await session.cancel(); throw error }
    }
}

struct RecordingControl: Codable {
    var schemaVersion: Int
    var sessionID: String
    var pid: Int32
    var startedAt: Date
}
