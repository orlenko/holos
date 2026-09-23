import AVFoundation
import Foundation
import HolosCore
import HolosStorage

public actor AudioChunkWriter {
    private struct OpenChunk {
        var file: AVAudioFile?
        let relativePath: String
        let start: Double
        var end: Double
        let sampleRate: Double
        let channels: Int
        var frames: Int
    }

    private let archive: SessionArchive
    private let chunkDuration: Double
    private var current: [String: OpenChunk] = [:]
    private var sequence: [String: Int] = [:]
    private struct TrackPosition { let end: Double; let sampleRate: Double; let channels: Int }
    private var positions: [String: TrackPosition] = [:]

    public init(archive: SessionArchive, chunkDuration: Double = 30) {
        self.archive = archive; self.chunkDuration = chunkDuration
    }

    @discardableResult
    public func append(_ audio: CapturedAudio) async throws -> CapturedAudio {
        guard audio.track == "mic" || audio.track == "system" else { throw HolosError.invalidInput("Invalid capture track.") }
        var frame = audio.frame
        guard frame.frameCount > 0 else { return audio }
        if let open = positions[audio.track] {
            let gap = frame.startTime - open.end
            let tolerance = 1 / max(frame.sampleRate, open.sampleRate)
            if abs(gap) > tolerance || frame.sampleRate != open.sampleRate || frame.channels != open.channels {
                try await close(track: audio.track)
                try await archive.recordEvent(kind: "audioDiscontinuity", details: [
                    "track": audio.track, "previousEnd": String(open.end), "nextStart": String(frame.startTime),
                    "reason": abs(gap) > tolerance ? "timestampGap" : "formatChanged",
                ])
            } else {
                frame = try PCMFrame(samples: frame.samples, sampleRate: frame.sampleRate,
                                     channels: frame.channels, startTime: open.end)
            }
        }
        if current[audio.track] == nil {
            let number = (sequence[audio.track] ?? 0) + 1
            sequence[audio.track] = number
            let path = String(format: "audio/%@/%06d.caf", audio.track, number)
            let url = archive.directory.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw HolosError.io("Refusing to overwrite existing audio chunk: \(path). Start a new recording session.")
            }
            let buffer = try PCMConversion.makeBuffer(frame)
            try await archive.recordEvent(kind: "chunkOpened", details: [
                "track": audio.track, "relativePath": path, "start": String(frame.startTime),
                "sampleRate": String(frame.sampleRate), "channels": String(frame.channels),
            ])
            var settings = buffer.format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            current[audio.track] = OpenChunk(file: file, relativePath: path, start: frame.startTime,
                end: frame.startTime, sampleRate: frame.sampleRate, channels: frame.channels, frames: 0)
        }
        guard var open = current[audio.track], let file = open.file else { throw HolosError.io("Missing audio writer.") }
        try file.write(from: PCMConversion.makeBuffer(frame))
        open.frames += frame.frameCount
        open.end = open.start + Double(open.frames) / open.sampleRate
        current[audio.track] = open
        positions[audio.track] = TrackPosition(end: open.end, sampleRate: open.sampleRate, channels: open.channels)
        if Double(open.frames) / open.sampleRate >= chunkDuration { try await close(track: audio.track) }
        return CapturedAudio(track: audio.track, frame: frame)
    }

    public func finish() async throws {
        for track in current.keys.sorted() { try await close(track: track) }
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
    }
}
