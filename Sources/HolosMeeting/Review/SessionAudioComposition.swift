import AVFoundation
import Foundation
import HolosCore
import HolosStorage
import os

/// A session's saved audio as one AVFoundation composition, for playback in the review window
/// (docs/meeting-design.md §5.10). Nothing is copied or rendered: the composition references the chunk files.
public enum SessionAudioComposition {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "review")

    /// Timescale of positions on the session timeline: a multiple of 16, 44.1, and 48 kHz, so a chunk that starts
    /// on a sample at those rates starts on an exact composition time.
    static let timescale: CMTimeScale = 7_056_000

    /// One chunk as it is placed in its composition track: `frames` frames of the file, from `skipFrames` on, at
    /// session time `start`.
    struct Piece: Sendable, Equatable {
        let chunk: AudioChunkRecord
        let skipFrames: Int
        let frames: Int
        let start: Double
    }

    /// One composition track per session track; every chunk inserted at its session start time, trimmed so
    /// that no chunk overlaps the previous one.
    ///
    /// Details:
    /// - Tracks are "mic", then "system", then any other track name in order. Chunks of a track are placed in
    ///   (start, file) order. A chunk that starts before the audio already placed (archives from before frame
    ///   continuity, §2.3) loses its leading samples up to that point, and one that lies entirely before it is left
    ///   out, as `TrackRenderer` does, so audio is never heard twice and the tracks stay on the session timeline.
    ///   Time between chunks is silence.
    /// - A chunk file that is missing, is not a regular file (a symbolic link is never followed), has a path that
    ///   leaves its session, or holds no audio is left out and logged; its time is silence. A session without any
    ///   playable chunk throws `HolosError.unavailable`.
    /// - A chunk shorter than the manifest says is used up to its end.
    /// - `async` because AVFoundation loads a file's tracks asynchronously (the synchronous accessors are deprecated);
    ///   it runs off the caller's actor and checks for cancellation per chunk.
    public static func make(session: URL, manifest: SessionManifest) async throws -> sending AVMutableComposition {
        let composition = AVMutableComposition()
        var placed = 0
        for (track, pieces) in plan(manifest) {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw HolosError.io("Cannot prepare the \(track) audio for playback.")
            }
            var end = CMTime.zero
            var inserted = 0
            for piece in pieces {
                try Task.checkCancellation()
                // The asset is kept until its track is inserted: an AVAssetTrack does not keep its asset alive.
                guard let (asset, source) = try await sourceTrack(piece.chunk, session: session) else { continue }
                defer { withExtendedLifetime(asset) {} }
                let requested = CMTimeRange(start: frameTime(piece.skipFrames, rate: piece.chunk.sampleRate),
                                            duration: frameTime(piece.frames, rate: piece.chunk.sampleRate))
                let available = try await source.load(.timeRange)
                let range = requested.intersection(available)
                guard range.duration > .zero else {
                    log.error("Audio chunk \(piece.chunk.id, privacy: .public) holds no audio where the manifest places it; left out of playback")
                    continue
                }
                let at = max(end, sessionTime(piece.start + (range.start - requested.start).seconds))
                if at > end {
                    compositionTrack.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
                }
                try compositionTrack.insertTimeRange(range, of: source, at: at)
                end = at + range.duration
                inserted += 1
            }
            if inserted == 0 {
                composition.removeTrack(compositionTrack)
            } else {
                placed += inserted
                log.info("Playback track \(track, privacy: .public): \(inserted, privacy: .public) of \(pieces.count, privacy: .public) chunks")
            }
        }
        guard placed > 0 else { throw HolosError.unavailable("This meeting has no saved audio to play.") }
        return composition
    }

    /// The pieces of every track in the order they are inserted (see `make`).
    static func plan(_ manifest: SessionManifest) -> [(track: String, pieces: [Piece])] {
        let names = Set(manifest.chunks.map(\.track))
        let ordered = ["mic", "system"].filter(names.contains) + names.subtracting(["mic", "system"]).sorted()
        return ordered.map { track in
            let chunks = manifest.chunks.filter { $0.track == track }
                .sorted { ($0.start, $0.relativePath) < ($1.start, $1.relativePath) }
            var pieces: [Piece] = []
            var placedEnd: Double?
            for chunk in chunks {
                let rate = chunk.sampleRate
                guard rate.isFinite, rate > 0, chunk.start.isFinite, chunk.start >= 0, chunk.frameCount > 0 else {
                    continue
                }
                var skip = 0
                if let placedEnd, chunk.start < placedEnd {
                    skip = Int(((placedEnd - chunk.start) * rate).rounded())
                    if skip >= chunk.frameCount { continue }
                }
                let kept = chunk.frameCount - skip
                let start = chunk.start + Double(skip) / rate
                pieces.append(Piece(chunk: chunk, skipFrames: skip, frames: kept, start: start))
                placedEnd = max(placedEnd ?? 0, start + Double(kept) / rate)
            }
            return (track, pieces)
        }
    }

    // MARK: - Private

    /// The chunk's asset and its first audio track, or nil (logged) when the chunk cannot be played.
    private static func sourceTrack(_ chunk: AudioChunkRecord,
                                    session: URL) async throws -> (AVURLAsset, AVAssetTrack)? {
        guard let url = chunkURL(chunk, session: session) else {
            log.error("Audio chunk \(chunk.id, privacy: .public) has a path outside its session; left out of playback")
            return nil
        }
        // Opened once through the session's folders without following links, so a link planted in place of the
        // chunk or a folder above it is refused rather than played (docs/meeting-design.md §1.7).
        do {
            guard try AtomicFile.openForReading(url) != nil else {
                log.error("Audio chunk \(chunk.id, privacy: .public) is missing; left out of playback")
                return nil
            }
        } catch let error as HolosError {
            log.error("Audio chunk \(chunk.id, privacy: .public) cannot be opened (\(ProcessSpawner.logCategory(error), privacy: .public)); left out of playback")
            return nil
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                log.error("Audio chunk \(chunk.id, privacy: .public) holds no audio track; left out of playback")
                return nil
            }
            return (asset, track)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("Audio chunk \(chunk.id, privacy: .public) is not readable audio; left out of playback")
            return nil
        }
    }

    /// `<session>/<relativePath>`, or nil when the path is absolute or has an empty, "." or ".." component.
    static func chunkURL(_ chunk: AudioChunkRecord, session: URL) -> URL? {
        let components = chunk.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !chunk.relativePath.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return session.appendingPathComponent(chunk.relativePath, isDirectory: false)
    }

    /// `frames` at `rate`: exact when the rate is a whole number of hertz.
    private static func frameTime(_ frames: Int, rate: Double) -> CMTime {
        if rate == rate.rounded(), rate <= Double(Int32.max) {
            return CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
        }
        return CMTime(seconds: Double(frames) / rate, preferredTimescale: timescale)
    }

    private static func sessionTime(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((max(0, seconds) * Double(timescale)).rounded()), timescale: timescale)
    }
}
