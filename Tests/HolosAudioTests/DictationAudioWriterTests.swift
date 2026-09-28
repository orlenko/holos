import AVFoundation
import Darwin
import Foundation
import Testing
import HolosCore
import HolosStorage
@testable import HolosAudio

// DictationAudioWriter (docs/design.md "Dictation audio and Run Again"): a dictation's microphone frames as a private
// AAC file, from any capture format, and the frames read back for Run Again.

private func writerStore() throws -> (DictationHistoryStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-audio-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (DictationHistoryStore(directory: root.appendingPathComponent("History")), root)
}

/// `seconds` of a 440 Hz tone at `rate` with `channels`, as 0.1 s capture frames starting at `start`.
private func tone(seconds: Double, rate: Double, channels: Int, start: Double = 0) throws -> [PCMFrame] {
    let step = Int(rate / 10)
    var frames: [PCMFrame] = []
    var position = 0
    while Double(position) < seconds * rate {
        var samples: [Float] = []
        samples.reserveCapacity(step * channels)
        for index in 0..<step {
            let value = Float(0.3 * sin(2 * Double.pi * 440 * Double(position + index) / rate))
            for _ in 0..<channels { samples.append(value) }
        }
        frames.append(try PCMFrame(samples: samples, sampleRate: rate, channels: channels,
                                   startTime: start + Double(position) / rate))
        position += step
    }
    return frames
}

@Test(.timeLimit(.minutes(1))) func writerKeepsAPrivateMonoAACFileOfWhatItWasGiven() throws {
    let (store, root) = try writerStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let writer = DictationAudioWriter(store: store, id: id)
    #expect(writer.url == store.partialAudioURL(for: id))
    // Stereo at 48 kHz, then the microphone changes to mono at 44.1 kHz.
    for frame in try tone(seconds: 1.0, rate: 48_000, channels: 2) { writer.append(frame) }
    for frame in try tone(seconds: 0.5, rate: 44_100, channels: 1, start: 1.0) { writer.append(frame) }
    let finished = try #require(writer.finish())
    #expect(finished.partial == writer.url)
    #expect(abs(finished.seconds - 1.5) < 0.15, "About the 1.5 s given: \(finished.seconds)")
    var info = stat()
    #expect(lstat(finished.partial.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    // AAC at ~32 kbit/s plus the container (about 25 KB): far smaller than the 576 KB of PCM it came from.
    #expect(info.st_size > 0 && info.st_size < 64_000, "\(info.st_size) bytes")

    let file = try AVAudioFile(forReading: finished.partial)
    #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.sampleRate == HistoryAudio.sampleRate)
    let frames = try DictationAudioFile.frames(of: finished.partial)
    #expect(frames.allSatisfy { $0.channels == 1 && $0.sampleRate == HistoryAudio.sampleRate })
    #expect(zip(frames, frames.dropFirst()).allSatisfy { abs($0.startTime + $0.duration - $1.startTime) < 1e-6 })
    let total = frames.reduce(0) { $0 + $1.duration }
    #expect(abs(total - 1.5) < 0.15)
    #expect(frames.contains { frame in frame.samples.contains { abs($0) > 0.1 } }, "The tone is in the file.")
    #expect(abs(try DictationAudioFile.seconds(of: finished.partial) - total) < 0.01)

    // Frames after the end are not taken; a second finish has nothing.
    writer.append(try tone(seconds: 0.1, rate: 48_000, channels: 1)[0])
    #expect(writer.finish() == nil)
    #expect(FileManager.default.fileExists(atPath: finished.partial.path))
}

@Test(.timeLimit(.minutes(1))) func writerLeavesNothingWhenDiscardedOrGivenNothing() throws {
    let (store, root) = try writerStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let silent = DictationAudioWriter(store: store, id: UUID())
    #expect(silent.finish() == nil)
    #expect(!FileManager.default.fileExists(atPath: silent.url.path))
    #expect(!FileManager.default.fileExists(atPath: store.audioDirectory.path), "No folder for a dictation without audio.")

    let cancelled = DictationAudioWriter(store: store, id: UUID())
    for frame in try tone(seconds: 0.3, rate: 48_000, channels: 1) { cancelled.append(frame) }
    cancelled.discard()
    #expect(!FileManager.default.fileExists(atPath: cancelled.url.path))
    #expect(cancelled.finish() == nil)
    #expect(store.audioBytes() == 0)
}
