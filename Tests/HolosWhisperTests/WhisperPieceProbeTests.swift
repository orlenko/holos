import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosEvaluation
import HolosMeeting
import HolosStorage
import Testing
@testable import HolosWhisper

// Opt-in probe (docs/meeting-design.md §4.16): HOLOS_DEEP_PIECE_SESSION=<a copy of a .holos folder>, with the model
// installed (HOLOS_WHISPER_MODELS_DIR), cuts one track (HOLOS_DEEP_PIECE_TRACK, default system) into pieces as the
// pass does, transcribes the piece holding HOLOS_DEEP_PIECE_AT seconds with the prompt of a local run
// (HOLOS_DEEP_PIECE_RUN, its run.json `prompt`; none without), and prints each chunk's start, length, and word counts
// with and without the prompt, then the stretches of the piece with no word. Numbers only.

private let pieceSession = ProcessInfo.processInfo.environment["HOLOS_DEEP_PIECE_SESSION"]

@Test(.enabled(if: pieceSession != nil), .timeLimit(.minutes(30)))
func probeOnePieceAsThePassCutsIt() async throws {
    let environment = ProcessInfo.processInfo.environment
    let session = URL(fileURLWithPath: try #require(pieceSession), isDirectory: true)
    let track = environment["HOLOS_DEEP_PIECE_TRACK"] ?? "system"
    let at = Double(environment["HOLOS_DEEP_PIECE_AT"] ?? "960") ?? 960
    var prompt = ""
    if let run = environment["HOLOS_DEEP_PIECE_RUN"] {
        let record = try HolosJSON.decoder().decode(LocalRunRecord.self, from: Data(contentsOf: EvalPaths.localRecord(
            run, in: session)))
        prompt = record.prompt ?? ""
    }
    let manifest = try SessionArchive.readManifest(at: session)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("holos-piece-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: track,
                                            to: temp.appendingPathComponent("\(track).caf"))
    let file = try AVAudioFile(forReading: rendered.url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = Int(file.length)
    let pieceFrames = Int(DeepAudio.pieceSeconds) * DeepAudio.sampleRate
    let searchFrames = Int(DeepAudio.cutSearchSeconds) * DeepAudio.sampleRate
    func read(_ start: Int, _ count: Int) throws -> [Float] {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(count)))
        file.framePosition = AVAudioFramePosition(start)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    var position = 0
    var piece: [Float] = []
    while position < frames {
        let remaining = frames - position
        var samples = try read(position, min(remaining, pieceFrames))
        if remaining > pieceFrames {
            samples.removeSubrange(DeepAudio.quietestCut(samples, searchFrom: samples.count - searchFrames)...)
        }
        if Double(position + samples.count) / 16_000 > at {
            piece = samples
            break
        }
        position += samples.count
    }
    let pieceStart = Double(position) / 16_000
    let transcriber = try await WhisperKitTranscriber.load()
    let segments = try await transcriber.transcribe(
        DeepTranscriptionRequest(samples: piece, language: "en", prompt: prompt), progress: { _ in })
    print("piece \(track) from \(Int(pieceStart)) s, \(piece.count / 16_000) s, prompt \(prompt.count) characters: "
        + "\(segments.count) segments, \(segments.flatMap(\.words).count) words")
    for chunk in transcriber.chunkLog {
        print(String(format: "chunk %.1f+%.1fs prompted %d plain %d kept %@", pieceStart + chunk.start, chunk.seconds,
                     chunk.promptedWords, chunk.plainWords, chunk.keptPlain ? "plain" : "prompted"))
    }
    // Stretches of more than 10 s with no word.
    var last = 0.0
    for word in segments.flatMap(\.words).sorted(by: { $0.start < $1.start }) {
        if word.start - last > 10 {
            print(String(format: "no words %.1f-%.1f", pieceStart + last, pieceStart + word.start))
        }
        last = max(last, word.end)
    }
    let segmentSpans = segments.map { String(format: "%.1f-%.1f/%d", pieceStart + $0.start, pieceStart + $0.end, $0.words.count) }
    print("segments: " + segmentSpans.joined(separator: " "))
}
