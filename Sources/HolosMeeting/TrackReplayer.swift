import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosStorage

/// Transcribes saved audio: after a recording whose live transcription fell behind, and for
/// `holos session retranscribe`.
public enum TrackReplayer {
    static let bufferFrames: AVAudioFrameCount = 4096
    /// A gap between chunks longer than this starts a new speech session (docs/meeting-design.md §2.3, R19).
    static let sessionGapSeconds = 1.0

    /// Transcribes a track's finalized chunks from disk, starting at session time `from` (seeking inside the
    /// chunk that contains it). `makeSpeech` defaults to AppleSpeechSession.make.
    ///
    /// Every speech session sees frame times that start at 0; the session time of its first frame is added back to
    /// the segments it returns. A new session starts at every gap over 1 s. Samples that would overlap audio already
    /// fed (overlapping chunks in an older archive) are skipped.
    ///
    /// With `timeouts` (the recorder's stop path, docs/meeting-design.md §1.3, §4.6), creating a session and each
    /// `append` may take at most `speechFinishBase`, and each `finish` at most `speechFinish(audioSeconds:)` of the audio
    /// that session was fed. When one does not return in time, the session is cancelled and the replay throws
    /// `ReplayIncomplete`, which carries the segments already returned.
    public static func replay(directory: URL, track: String, locale: String, backend: SpeechBackend,
                              contextualStrings: [String] = [], from start: Double = 0,
                              makeSpeech: LiveSpeechFactory? = nil,
                              timeouts: StopTimeouts? = nil) async throws -> [TranscriptSegment] {
        guard start.isFinite else { throw HolosError.invalidInput("The replay start time must be a finite number.") }
        let from = max(0, start)
        let manifest = try SessionArchive.readManifest(at: directory)
        let chunks = manifest.chunks.filter { $0.track == track && $0.end > from }.sorted { $0.start < $1.start }
        let factory = makeSpeech ?? appleSpeechFactory
        let limits = ReplayLimits(timeouts: timeouts)
        let make: @Sendable () async throws -> any LiveSpeechSession = {
            try await limits.run(limits.step, "start") { try await factory(locale, backend, contextualStrings) { _ in } }
        }
        let first: any LiveSpeechSession
        do { first = try await make() } catch let timeout as ReplayTimeout {
            throw ReplayIncomplete(segments: [], message: timeout.message)
        }
        let current = LockedValue<(any LiveSpeechSession)?>(first)
        // Cancelling the task cancels the session too: a speech framework's `append` or `finish` may not
        // observe task cancellation, and a cancelled replay returns no segments.
        return try await withTaskCancellationHandler {
            try await feed(chunks: chunks, directory: directory, track: track, from: from, make: make,
                           current: current, limits: limits)
        } onCancel: {
            if let session = current.value { Task { await session.cancel() } }
        }
    }

    private static func feed(chunks: [AudioChunkRecord], directory: URL, track: String, from: Double,
                             make: @Sendable () async throws -> any LiveSpeechSession,
                             current: LockedValue<(any LiveSpeechSession)?>,
                             limits: ReplayLimits) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        /// Session time of the current session's first frame.
        var base: Double?
        /// End of the audio fed so far.
        var expected: Double?
        /// Seconds of audio fed to the current session.
        var fed = 0.0
        do {
            for chunk in chunks {
                try Task.checkCancellation()
                // TODO: open chunks through HolosStorage (a descriptor from the folder chain) instead of by path, so
                // a symlink in place of `audio/<track>` is never followed (meeting-design §1.7).
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativePath))
                let sampleRate = file.processingFormat.sampleRate
                let firstNeeded = max(from, expected ?? 0)
                if let end = expected, base != nil, max(chunk.start, firstNeeded) - end > sessionGapSeconds {
                    segments += try await finishCurrent(current, base: base, track: track, fed: fed, limits: limits)
                    try Task.checkCancellation()
                    current.withLock { $0 = nil }
                    let next = try await make()
                    current.withLock { $0 = next }
                    base = nil
                    fed = 0
                }
                var offset: AVAudioFramePosition = 0
                if firstNeeded > chunk.start {
                    // Seek to the first frame at or after `firstNeeded`; frames before it are never fed.
                    let skip = ((firstNeeded - chunk.start) * sampleRate - 1e-6).rounded(.up)
                    offset = skip < Double(file.length) ? AVAudioFramePosition(max(0, skip)) : file.length
                    file.framePosition = offset
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bufferFrames) else {
                    throw HolosError.io("Could not allocate a replay buffer.")
                }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer, frameCount: bufferFrames)
                    guard buffer.frameLength > 0 else { break }
                    let time = chunk.start + Double(offset) / sampleRate
                    let origin = base ?? time
                    base = origin
                    let frame = try PCMConversion.copy(buffer, startTime: max(0, time - origin))
                    guard let session = current.value else { throw CancellationError() }
                    try await limits.run(limits.step, "append") { try await session.append(frame) }
                    offset += AVAudioFramePosition(buffer.frameLength)
                    fed += frame.duration
                    expected = chunk.start + Double(offset) / sampleRate
                }
            }
            try Task.checkCancellation()
            segments += try await finishCurrent(current, base: base ?? from, track: track, fed: fed, limits: limits)
            try Task.checkCancellation()
            return segments
        } catch let timeout as ReplayTimeout {
            // The session may be stuck in the call that timed out: cancel it without waiting.
            if let session = current.value { Task { await session.cancel() } }
            throw ReplayIncomplete(segments: segments, message: timeout.message)
        } catch {
            if let session = current.value { await session.cancel() }
            throw error
        }
    }

    /// Finishes the current session and moves its segments to the session timeline.
    private static func finishCurrent(_ current: LockedValue<(any LiveSpeechSession)?>, base: Double?,
                                      track: String, fed: Double, limits: ReplayLimits) async throws
        -> [TranscriptSegment] {
        guard let session = current.value else { throw CancellationError() }
        let segments = try await limits.run(limits.finish(fed), "finish") { try await session.finish() }
        return segments.map { LiveTrack.shifted($0, by: base ?? 0, track: track) }
    }
}

/// A replay that stopped because speech did not answer in time (`TrackReplayer.replay` with timeouts). `segments`
/// are those already returned, on the session timeline; the rest of the track is not transcribed.
struct ReplayIncomplete: LocalizedError, Sendable {
    var segments: [TranscriptSegment]
    var message: String
    var errorDescription: String? { message }
}

/// One speech call that did not return within its limit.
private struct ReplayTimeout: Error {
    var message: String
}

/// The time limits of a replay's speech calls; none without timeouts.
private struct ReplayLimits: Sendable {
    let timeouts: StopTimeouts?

    /// Creating a session, or one `append`.
    var step: Duration? { timeouts?.speechFinishBase }

    func finish(_ fed: Double) -> Duration? { timeouts?.speechFinish(audioSeconds: fed) }

    /// Runs `operation` within `limit` (nil: no limit). A timeout throws `ReplayTimeout`; a cancelled caller
    /// `CancellationError`.
    func run<Value: Sendable>(_ limit: Duration?, _ what: String,
                              _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard let limit else { return try await operation() }
        switch await awaitWithTimeout(limit, operation) {
        case .finished(let result):
            return try result.get()
        case .timedOut:
            throw ReplayTimeout(message: "Speech did not \(what == "start" ? "start" : "respond") within \(Self.seconds(limit)) s while transcribing the saved audio; the rest of the track is not transcribed.")
        case .cancelled:
            throw CancellationError()
        }
    }

    static func seconds(_ duration: Duration) -> String {
        let (whole, fraction) = duration.components
        return fraction == 0 ? String(whole)
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(whole) + Double(fraction) / 1e18)
    }
}
