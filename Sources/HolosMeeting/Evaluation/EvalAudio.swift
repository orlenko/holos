import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosStorage

/// The audio the evaluation sends or plays: a track rendered to one 16 kHz mono file (`TrackRenderer`, pauses over
/// 60 s shortened to 5 s), its energy, and AAC .m4a files cut from it.
public enum EvalAudio {
    public static let sampleRate = TrackRenderer.sampleRate
    /// AAC bit rate for 16 kHz mono speech: about 1.2 MB per five minutes, far under OpenAI's 25 MB limit.
    static let bitRate = 32_000
    /// OpenAI's upload limit.
    public static let maxUploadBytes = 25 * 1_000_000

    /// Renders `track` of `session` to `url` (a 16 kHz mono CAF).
    public static func render(session: URL, manifest: SessionManifest, track: String, to url: URL) throws
        -> RenderedTrack {
        try TrackRenderer.render(session: session, manifest: manifest, track: track, to: url)
    }

    /// RMS level of each `windowSeconds` window of `url` (full scale 1).
    public static func rms(of url: URL, windowSeconds: Double = 0.1) throws -> [Float] {
        try requireRegularFile(url)
        let file = try AVAudioFile(forReading: url)
        let windowFrames = AVAudioFrameCount(max(1, (windowSeconds * file.processingFormat.sampleRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: windowFrames * 64) else {
            throw HolosError.io("Could not allocate an audio buffer.")
        }
        var levels: [Float] = []
        var sum: Float = 0
        var count: AVAudioFrameCount = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            for index in 0..<Int(buffer.frameLength) {
                let sample = channel[index]
                sum += sample * sample
                count += 1
                if count == windowFrames {
                    levels.append((sum / Float(count)).squareRoot())
                    sum = 0
                    count = 0
                }
            }
        }
        if count > 0 { levels.append((sum / Float(count)).squareRoot()) }
        return levels
    }

    /// Refuses anything but a regular file at `url` (a symbolic link put in place of a render is never followed).
    static func requireRegularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not a regular file; nothing was sent.")
        }
    }

    /// Writes frames [start, end) of `source` to `destination` as AAC in an .m4a, replacing it. The file is written
    /// under a temporary name and renamed, so a cancelled write leaves no half file.
    public static func writeM4A(from source: URL, startFrame: Int, endFrame: Int, to destination: URL) throws {
        try requireRegularFile(source)
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial.m4a")
        try AtomicFile.ensurePrivateDirectory(destination.deletingLastPathComponent())
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ]
            let output = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
            input.framePosition = AVAudioFramePosition(max(0, startFrame))
            let last = AVAudioFramePosition(min(Int(input.length), endFrame))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                throw HolosError.io("Could not allocate an audio buffer.")
            }
            while input.framePosition < last {
                try Task.checkCancellation()
                let wanted = AVAudioFrameCount(min(AVAudioFramePosition(16_384), last - input.framePosition))
                try input.read(into: buffer, frameCount: wanted)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
            output.close()
            chmod(temporary.path, 0o600)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
