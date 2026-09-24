import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosStorage

/// Transcribes saved audio: after a recording whose live transcription fell behind, and for
/// `holos session retranscribe`.
public enum TrackReplayer {
    static let bufferFrames: AVAudioFrameCount = 4096

    /// Transcribes a track's finalized chunks from disk, starting at session time `from` (seeking inside the
    /// chunk that contains it). `makeSpeech` defaults to AppleSpeechSession.make.
    public static func replay(directory: URL, track: String, locale: String, backend: SpeechBackend,
                              contextualStrings: [String] = [], from start: Double = 0,
                              makeSpeech: LiveSpeechFactory? = nil) async throws -> [TranscriptSegment] {
        guard start.isFinite else { throw HolosError.invalidInput("The replay start time must be a finite number.") }
        let from = max(0, start)
        let manifest = try SessionArchive.readManifest(at: directory)
        let chunks = manifest.chunks.filter { $0.track == track && $0.end > from }.sorted { $0.start < $1.start }
        let session = try await (makeSpeech ?? appleSpeechFactory)(locale, backend, contextualStrings) { _ in }
        do {
            for chunk in chunks {
                // TODO(PR2a): open chunks through HolosStorage (ChunkFile on main) instead of by path, so a
                // symlink in place of `audio/<track>` is never followed (meeting-design §1.7).
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativePath))
                let sampleRate = file.processingFormat.sampleRate
                var offset: AVAudioFramePosition = 0
                if from > chunk.start {
                    // Seek to the frame at `from`; frames before it are never fed.
                    let skip = ((from - chunk.start) * sampleRate).rounded(.down)
                    offset = skip < Double(file.length) ? AVAudioFramePosition(skip) : file.length
                    file.framePosition = offset
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bufferFrames) else {
                    throw HolosError.io("Could not allocate a replay buffer.")
                }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer, frameCount: bufferFrames)
                    guard buffer.frameLength > 0 else { break }
                    let frame = try PCMConversion.copy(buffer, startTime: chunk.start + Double(offset) / sampleRate)
                    try await session.append(frame)
                    offset += AVAudioFramePosition(buffer.frameLength)
                }
            }
            return try await session.finish().map { var segment = $0; segment.track = track; return segment }
        } catch { await session.cancel(); throw error }
    }
}
