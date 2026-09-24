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
    public static func replay(directory: URL, track: String, locale: String, backend: SpeechBackend,
                              contextualStrings: [String] = [], from start: Double = 0,
                              makeSpeech: LiveSpeechFactory? = nil) async throws -> [TranscriptSegment] {
        guard start.isFinite else { throw HolosError.invalidInput("The replay start time must be a finite number.") }
        let from = max(0, start)
        let manifest = try SessionArchive.readManifest(at: directory)
        let chunks = manifest.chunks.filter { $0.track == track && $0.end > from }.sorted { $0.start < $1.start }
        let factory = makeSpeech ?? appleSpeechFactory
        let make: @Sendable () async throws -> any LiveSpeechSession = {
            try await factory(locale, backend, contextualStrings) { _ in }
        }
        let current = LockedValue<(any LiveSpeechSession)?>(try await make())
        // Cancelling the task cancels the session too: a speech framework's `append` or `finish` may not
        // observe task cancellation, and a cancelled replay returns no segments.
        return try await withTaskCancellationHandler {
            try await feed(chunks: chunks, directory: directory, track: track, from: from, make: make,
                           current: current)
        } onCancel: {
            if let session = current.value { Task { await session.cancel() } }
        }
    }

    private static func feed(chunks: [AudioChunkRecord], directory: URL, track: String, from: Double,
                             make: @Sendable () async throws -> any LiveSpeechSession,
                             current: LockedValue<(any LiveSpeechSession)?>) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        /// Session time of the current session's first frame.
        var base: Double?
        /// End of the audio fed so far.
        var expected: Double?
        do {
            for chunk in chunks {
                try Task.checkCancellation()
                // TODO: open chunks through HolosStorage (a descriptor from the folder chain) instead of by path, so
                // a symlink in place of `audio/<track>` is never followed (meeting-design §1.7).
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativePath))
                let sampleRate = file.processingFormat.sampleRate
                let firstNeeded = max(from, expected ?? 0)
                if let end = expected, base != nil, max(chunk.start, firstNeeded) - end > sessionGapSeconds {
                    segments += try await finishCurrent(current, base: base, track: track)
                    try Task.checkCancellation()
                    current.withLock { $0 = nil }
                    let next = try await make()
                    current.withLock { $0 = next }
                    base = nil
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
                    try await session.append(frame)
                    offset += AVAudioFramePosition(buffer.frameLength)
                    expected = chunk.start + Double(offset) / sampleRate
                }
            }
            try Task.checkCancellation()
            segments += try await finishCurrent(current, base: base ?? from, track: track)
            try Task.checkCancellation()
            return segments
        } catch {
            if let session = current.value { await session.cancel() }
            throw error
        }
    }

    /// Finishes the current session and moves its segments to the session timeline.
    private static func finishCurrent(_ current: LockedValue<(any LiveSpeechSession)?>, base: Double?,
                                      track: String) async throws -> [TranscriptSegment] {
        guard let session = current.value else { throw CancellationError() }
        let segments = try await session.finish()
        return segments.map { LiveTrack.shifted($0, by: base ?? 0, track: track) }
    }
}
