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
    /// that no chunk overlaps the audio inserted before it.
    ///
    /// Details:
    /// - Tracks are "mic", then "system", then any other track name in order. Chunks of a track are placed in
    ///   (start, file) order. A chunk that starts before the audio already inserted (archives from before frame
    ///   continuity, §2.3) loses its leading samples up to that point, and one that lies entirely before it is left
    ///   out, as `TrackRenderer` does, so audio is never heard twice and the tracks stay on the session timeline.
    ///   Time between chunks is silence.
    /// - A chunk that cannot be played is left out and logged, and only its own time is silence: a file that is
    ///   missing, is not a regular file (a symbolic link is never followed), has a path that leaves its session, is
    ///   not readable audio, holds no audio track, whose track or time range cannot be loaded, or that AVFoundation
    ///   refuses to insert. Overlaps are trimmed against the audio actually inserted (`TrackPlacement`), so a chunk
    ///   left out never shortens the next one. A session without any playable chunk throws `HolosError.unavailable`.
    /// - A chunk shorter than the manifest says is used up to its end, and only that much counts as inserted.
    /// - `async` because AVFoundation loads a file's tracks asynchronously (the synchronous accessors are deprecated);
    ///   it runs off the caller's actor and checks for cancellation per chunk.
    public static func make(session: URL, manifest: SessionManifest) async throws -> sending AVMutableComposition {
        let composition = AVMutableComposition()
        var placed = 0
        for (track, chunks) in order(manifest) {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw HolosError.io("Cannot prepare the \(track) audio for playback.")
            }
            var placement = TrackPlacement()
            var end = CMTime.zero
            var inserted = 0
            for chunk in chunks {
                try Task.checkCancellation()
                // The asset is kept until its track is inserted: an AVAssetTrack does not keep its asset alive.
                guard let (asset, source, available) = try await readableSource(chunk, session: session) else {
                    continue
                }
                defer { withExtendedLifetime(asset) {} }
                guard let piece = placement.piece(for: chunk, available: available) else {
                    log.error("Audio chunk \(chunk.id, privacy: .public) holds no audio after what is already placed; left out of playback")
                    continue
                }
                let range = CMTimeRange(start: frameTime(piece.skipFrames, rate: chunk.sampleRate),
                                        duration: frameTime(piece.frames, rate: chunk.sampleRate))
                let at = max(end, sessionTime(piece.start))
                // Inserted at the track's end first, then moved to its place by the silence before it, so a refused
                // insertion leaves the track as it was.
                do {
                    try compositionTrack.insertTimeRange(range, of: source, at: end)
                } catch {
                    log.error("Audio chunk \(chunk.id, privacy: .public) could not be added to playback; left out")
                    continue
                }
                if at > end {
                    compositionTrack.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
                }
                end = at + range.duration
                placement.placed(piece)
                inserted += 1
            }
            if inserted == 0 {
                composition.removeTrack(compositionTrack)
            } else {
                placed += inserted
                log.info("Playback track \(track, privacy: .public): \(inserted, privacy: .public) of \(chunks.count, privacy: .public) chunks")
            }
        }
        guard placed > 0 else { throw HolosError.unavailable("This meeting has no saved audio to play.") }
        return composition
    }

    /// Where a track's chunks go, one chunk at a time. Pure: a chunk is placed from what its file actually holds
    /// (`available`, frames from the file's start) and trimmed only against the pieces `placed` so far.
    struct TrackPlacement: Sendable {
        /// Session time where the audio inserted so far ends; nil before the first piece.
        private(set) var placedEnd: Double?

        /// The part of `chunk` to insert: the frames of `available` within the manifest's `frameCount`, less any
        /// that start before `placedEnd`. Nil when nothing is left (no audio, or all of it already covered).
        func piece(for chunk: AudioChunkRecord, available: Range<Int>?) -> Piece? {
            let rate = chunk.sampleRate
            guard let available, rate.isFinite, rate > 0, chunk.start.isFinite, chunk.start >= 0 else { return nil }
            let first = max(0, available.lowerBound)
            let end = min(chunk.frameCount, available.upperBound)
            guard first < end else { return nil }
            var skip = first
            if let placedEnd, chunk.start + Double(skip) / rate < placedEnd {
                skip = max(skip, Int(((placedEnd - chunk.start) * rate).rounded()))
            }
            guard skip < end else { return nil }
            return Piece(chunk: chunk, skipFrames: skip, frames: end - skip, start: chunk.start + Double(skip) / rate)
        }

        /// `piece` was inserted.
        mutating func placed(_ piece: Piece) {
            placedEnd = max(placedEnd ?? 0, piece.start + Double(piece.frames) / piece.chunk.sampleRate)
        }
    }

    /// The chunks of every track in the order they are inserted (see `make`), without chunks whose manifest record
    /// cannot place them (no frames, no rate, no start).
    static func order(_ manifest: SessionManifest) -> [(track: String, chunks: [AudioChunkRecord])] {
        let names = Set(manifest.chunks.map(\.track))
        let ordered = ["mic", "system"].filter(names.contains) + names.subtracting(["mic", "system"]).sorted()
        return ordered.map { track in
            let chunks = manifest.chunks.filter { chunk in
                chunk.track == track && chunk.sampleRate.isFinite && chunk.sampleRate > 0 && chunk.start.isFinite
                    && chunk.start >= 0 && chunk.frameCount > 0
            }
            return (track, chunks.sorted { ($0.start, $0.relativePath) < ($1.start, $1.relativePath) })
        }
    }

    /// The pieces of every track as `make` inserts them, given the frames each chunk file actually holds
    /// (`available`; nil for a chunk that cannot be played). Pure: the declared intervals come from `manifest`.
    static func plan(_ manifest: SessionManifest,
                     available: (AudioChunkRecord) -> Range<Int>?) -> [(track: String, pieces: [Piece])] {
        order(manifest).map { track, chunks in
            var placement = TrackPlacement()
            var pieces: [Piece] = []
            for chunk in chunks {
                guard let piece = placement.piece(for: chunk, available: available(chunk)) else { continue }
                placement.placed(piece)
                pieces.append(piece)
            }
            return (track, pieces)
        }
    }

    // MARK: - Private

    /// The chunk's asset, its first audio track, and the frames that track holds (from the file's start), or nil
    /// (logged) when the chunk cannot be played. Only cancellation is thrown.
    private static func readableSource(_ chunk: AudioChunkRecord,
                                       session: URL) async throws -> (AVURLAsset, AVAssetTrack, Range<Int>)? {
        guard let (asset, track) = try await sourceTrack(chunk, session: session) else { return nil }
        let timeRange: CMTimeRange
        do {
            timeRange = try await track.load(.timeRange)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("Audio chunk \(chunk.id, privacy: .public): its time range cannot be read; left out of playback")
            return nil
        }
        let rate = chunk.sampleRate
        let start = timeRange.start.seconds * rate
        let end = timeRange.end.seconds * rate
        guard timeRange.isValid, start.isFinite, end.isFinite, end > start,
              end < Double(Int.max), start > -Double(Int.max) else {
            log.error("Audio chunk \(chunk.id, privacy: .public) holds no audio; left out of playback")
            return nil
        }
        return (asset, track, Int(start.rounded())..<Int(end.rounded()))
    }

    /// The chunk's asset and its first audio track, or nil (logged) when the chunk cannot be played.
    private static func sourceTrack(_ chunk: AudioChunkRecord,
                                    session: URL) async throws -> (AVURLAsset, AVAssetTrack)? {
        guard let url = chunkURL(chunk, session: session) else {
            log.error("Audio chunk \(chunk.id, privacy: .public) has a path outside its session; left out of playback")
            return nil
        }
        // Opened once through the session's folders without following links, so a link found in place of the chunk
        // or a folder above it is refused rather than played (docs/meeting-design.md §1.7). AVFoundation then opens
        // the path itself; it cannot be given this descriptor. The window between the check and that open is one of
        // the check-then-act windows the §1.7 threat model accepts: only a hostile process of the same user could
        // swap a link in there, and such a process can already read every session directly.
        do {
            guard try AtomicFile.openForReading(url) != nil else {
                log.error("Audio chunk \(chunk.id, privacy: .public) is missing; left out of playback")
                return nil
            }
        } catch {
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
