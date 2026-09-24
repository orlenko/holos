import AVFoundation
import Foundation
import HolosCore
import HolosStorage
import os
import Synchronization

/// Writes captured audio into `audio/<track>/NNNNNN.caf` chunks and registers each finished chunk with the archive.
///
/// Chunks are 16-bit little-endian integer PCM (the file converts Float32 on write, docs/meeting-design.md §5.4
/// PR2a); older Float32 chunks stay readable because readers use the file's processing format. Frame times follow
/// `FrameContinuity` (§2.3): jitter under 50 ms is written contiguously, a later frame closes the chunk and records
/// `audioDiscontinuity`, and samples that would overlap the previous chunk are dropped and recorded as
/// `timestampOverlap`, so audio is never written twice and no chunk starts before the previous one ends.
public actor AudioChunkWriter {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "capture")
    /// Timestamp drift above this is logged (at most once a minute per track).
    private static let driftLogThreshold = 0.01
    private static let driftLogInterval = 60.0

    private struct OpenChunk {
        var file: AVAudioFile?
        let relativePath: String
        let start: Double
        var end: Double
        let sampleRate: Double
        let channels: Int
        var frames: Int
    }

    /// What the writer remembers about a track between frames and chunks.
    private struct TrackState {
        /// End of the last written sample: where the next contiguous frame goes.
        var expected: Double
        var sampleRate: Double
        var channels: Int
        /// The reason the track's next `audioDiscontinuity` carries (a `GapReason` raw value).
        var pendingReason: String?
        /// Set by `closeAll(expectingGap:)` and `noteGap(track:reason:)`: the next frame starts a new chunk at its
        /// own time and records a discontinuity, whatever its timestamp says.
        var boundary = false
        /// Session time of the last drift log line.
        var lastDriftLog: Double?
    }

    private let archive: SessionArchive
    private let chunkDuration: Double
    private var current: [String: OpenChunk] = [:]
    private var sequence: [String: Int] = [:]
    private var tracks: [String: TrackState] = [:]
    /// Counters readable without waiting for the actor (a slow disk write must not delay a status update).
    private nonisolated let stats = WriterStats()

    public init(archive: SessionArchive, chunkDuration: Double = 30) {
        self.archive = archive; self.chunkDuration = chunkDuration
    }

    /// Writes `audio` and returns it as written: its start time snapped to the previous frame's end when it is
    /// contiguous, leading samples dropped when it overlaps (no samples when it lies entirely before the end).
    @discardableResult
    public func append(_ audio: CapturedAudio) async throws -> CapturedAudio {
        guard audio.track == "mic" || audio.track == "system" else { throw HolosError.invalidInput("Invalid capture track.") }
        let track = audio.track
        var frame = audio.frame
        guard frame.frameCount > 0 else { return audio }
        var startsNewChunk = false
        var discontinuity: (previousEnd: Double, reason: String)?
        if var state = tracks[track] {
            let formatChanged = frame.sampleRate != state.sampleRate || frame.channels != state.channels
            let decision = FrameContinuity.classify(frameStart: frame.startTime, frameCount: frame.frameCount,
                                                    sampleRate: frame.sampleRate, expected: state.expected)
            switch decision {
            case .overlap(let dropFrames):
                guard let rest = try await trimOverlap(frame, dropFrames: dropFrames, expected: state.expected,
                                                       track: track) else {
                    return CapturedAudio(track: track, frame: try PCMFrame(samples: [], sampleRate: frame.sampleRate,
                        channels: frame.channels, startTime: state.expected))
                }
                frame = rest
                if state.boundary || formatChanged {
                    startsNewChunk = true
                    discontinuity = (state.expected, state.pendingReason ?? "formatChanged")
                }
            case .contiguous(let drift):
                if state.boundary || formatChanged {
                    // A new epoch (or a format change) is not sample-continuous: keep the frame's own time, except
                    // that the new chunk never starts before the previous one ends: samples before it are dropped
                    // as for an overlap.
                    startsNewChunk = true
                    discontinuity = (state.expected, state.pendingReason ?? "formatChanged")
                    if drift < 0 {
                        // As in FrameContinuity: a millionth of a sample absorbs floating-point error.
                        let exact = (state.expected - frame.startTime) * frame.sampleRate
                        let dropFrames = exact.isFinite
                            ? Int(min(Double(frame.frameCount), max(0, (exact - 1e-6).rounded(.up))))
                            : frame.frameCount
                        if dropFrames > 0 {
                            guard let rest = try await trimOverlap(frame, dropFrames: dropFrames,
                                                                   expected: state.expected, track: track) else {
                                return CapturedAudio(track: track, frame: try PCMFrame(samples: [],
                                    sampleRate: frame.sampleRate, channels: frame.channels, startTime: state.expected))
                            }
                            frame = rest
                        } else {
                            // Less than one sample early: it starts where the previous chunk ends.
                            frame = try PCMFrame(samples: frame.samples, sampleRate: frame.sampleRate,
                                                 channels: frame.channels, startTime: state.expected)
                        }
                    }
                } else {
                    if abs(drift) > Self.driftLogThreshold,
                       state.lastDriftLog.map({ frame.startTime - $0 >= Self.driftLogInterval }) ?? true {
                        state.lastDriftLog = frame.startTime
                        tracks[track] = state
                        Self.log.info("\(track, privacy: .public) timestamps drift \(drift, privacy: .public) s from the samples")
                    }
                    frame = try PCMFrame(samples: frame.samples, sampleRate: frame.sampleRate,
                                         channels: frame.channels, startTime: state.expected)
                }
            case .gap:
                startsNewChunk = true
                discontinuity = (state.expected, state.pendingReason ?? "timestampGap")
            }
        }
        if startsNewChunk {
            try await close(track: track)
            if let discontinuity {
                try await archive.recordEvent(kind: MeetingEventKind.audioDiscontinuity, details: [
                    "track": track, "previousEnd": String(discontinuity.previousEnd),
                    "nextStart": String(frame.startTime), "reason": discontinuity.reason,
                ])
            }
        }
        if current[track] == nil { try await open(track: track, at: frame) }
        guard var open = current[track], let file = open.file else { throw HolosError.io("Missing audio writer.") }
        try file.write(from: PCMConversion.makeBuffer(frame))
        open.frames += frame.frameCount
        open.end = open.start + Double(open.frames) / open.sampleRate
        current[track] = open
        var state = tracks[track] ?? TrackState(expected: open.end, sampleRate: open.sampleRate, channels: open.channels)
        state.expected = open.end
        state.sampleRate = open.sampleRate
        state.channels = open.channels
        state.pendingReason = nil
        state.boundary = false
        tracks[track] = state
        stats.wrote(track: track, openBytes: Int64(open.frames) * Int64(open.channels) * 2, end: open.end)
        if Double(open.frames) / open.sampleRate >= chunkDuration { try await close(track: track) }
        return CapturedAudio(track: track, frame: frame)
    }

    /// Closes every open chunk.
    public func finish() async throws {
        for track in current.keys.sorted() { try await close(track: track) }
    }

    /// Closes every open chunk; the next discontinuity event on each track carries `reason` (unless an `overflow` is
    /// already pending there), and the track's next frame starts a new chunk at its own time.
    public func closeAll(expectingGap reason: GapReason) async throws {
        for track in tracks.keys.sorted() { markGap(track: track, reason: reason) }
        try await finish()
    }

    /// Sets the reason of the track's next `audioDiscontinuity` (unless an `overflow` is already pending there) and
    /// makes its next frame start a new chunk at its own time (audio was lost before it). Does nothing for a track
    /// with no audio yet.
    public func noteGap(track: String, reason: GapReason) {
        guard tracks[track] != nil else { return }
        markGap(track: track, reason: reason)
    }

    /// One discontinuity event covers everything between two frames, so one reason wins: a pending `overflow` is
    /// kept over a later boundary (a pause, a restart, a sleep), since audio was lost there and the boundary has its
    /// own journal event; any other pending reason gives way to the later one.
    private func markGap(track: String, reason: GapReason) {
        guard var state = tracks[track] else { return }
        if state.pendingReason != GapReason.overflow.rawValue { state.pendingReason = reason.rawValue }
        state.boundary = true
        tracks[track] = state
    }

    /// Bytes of finalized chunks plus frames × channels × 2 of open chunks (the audio data, without file headers).
    public nonisolated func bytesWritten() -> Int64 { stats.bytesWritten }

    /// The largest end time written on any track (0 before any audio).
    public nonisolated var lastFrameEnd: Double { stats.lastFrameEnd }

    /// Drops the first `dropFrames` frames of `frame`, which lie before `expected`, and records `timestampOverlap`.
    /// Returns the rest, starting at `expected`, or nil when nothing is left.
    private func trimOverlap(_ frame: PCMFrame, dropFrames: Int, expected: Double, track: String) async throws
        -> PCMFrame? {
        let dropped = min(dropFrames, frame.frameCount)
        try await archive.recordEvent(kind: MeetingEventKind.timestampOverlap, details: [
            "track": track, "previousEnd": String(expected), "nextStart": String(frame.startTime),
            "droppedSeconds": String(Double(dropped) / frame.sampleRate),
        ])
        Self.log.notice("Dropped \(dropped, privacy: .public) overlapping \(track, privacy: .public) frames")
        guard dropped < frame.frameCount else { return nil }
        // The rest starts within one sample of the previous end: it continues there.
        return try PCMFrame(samples: Array(frame.samples[(dropped * frame.channels)...]),
                            sampleRate: frame.sampleRate, channels: frame.channels, startTime: expected)
    }

    // MARK: - Chunks

    private func open(track: String, at frame: PCMFrame) async throws {
        let number = (sequence[track] ?? 0) + 1
        sequence[track] = number
        let path = String(format: "audio/%@/%06d.caf", track, number)
        let url = archive.directory.appendingPathComponent(path)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw HolosError.io("Refusing to overwrite existing audio chunk: \(path). Start a new recording session.")
        }
        let buffer = try PCMConversion.makeBuffer(frame)
        try await archive.recordEvent(kind: MeetingEventKind.chunkOpened, details: [
            "track": track, "relativePath": path, "start": String(frame.startTime),
            "sampleRate": String(frame.sampleRate), "channels": String(frame.channels),
        ])
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: frame.sampleRate,
            AVNumberOfChannelsKey: frame.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if let layout = buffer.format.settings[AVChannelLayoutKey] { settings[AVChannelLayoutKey] = layout }
        // The processing format is the Float32 capture format; the file converts to Int16 on write.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        current[track] = OpenChunk(file: file, relativePath: path, start: frame.startTime, end: frame.startTime,
                                   sampleRate: frame.sampleRate, channels: frame.channels, frames: 0)
    }

    private func close(track: String) async throws {
        guard var open = current.removeValue(forKey: track) else { return }
        open.file?.close()
        open.file = nil
        let file = try AVAudioFile(forReading: archive.directory.appendingPathComponent(open.relativePath))
        guard file.length == Int64(open.frames), file.processingFormat.sampleRate == open.sampleRate,
              file.processingFormat.channelCount == open.channels else {
            throw HolosError.incomplete("Finalized audio does not match the recorded frames: \(open.relativePath).")
        }
        file.close()
        try await archive.registerChunk(AudioChunkRecord(track: track, relativePath: open.relativePath,
            start: open.start, end: open.end, sampleRate: open.sampleRate, channels: open.channels, frameCount: open.frames))
        stats.finalized(track: track, bytes: Int64(open.frames) * Int64(open.channels) * 2)
    }
}

/// Byte and time counters of an `AudioChunkWriter`, readable from any thread.
private final class WriterStats: Sendable {
    private struct State {
        var finalizedBytes: Int64 = 0
        var openBytes: [String: Int64] = [:]
        var lastFrameEnd = 0.0
    }

    private let state = Mutex(State())

    var bytesWritten: Int64 { state.withLock { $0.finalizedBytes + $0.openBytes.values.reduce(0, +) } }
    var lastFrameEnd: Double { state.withLock { $0.lastFrameEnd } }

    func wrote(track: String, openBytes: Int64, end: Double) {
        state.withLock {
            $0.openBytes[track] = openBytes
            $0.lastFrameEnd = max($0.lastFrameEnd, end)
        }
    }

    func finalized(track: String, bytes: Int64) {
        state.withLock {
            $0.finalizedBytes += bytes
            $0.openBytes[track] = nil
        }
    }
}
