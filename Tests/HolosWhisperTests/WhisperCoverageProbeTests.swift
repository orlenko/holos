import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosStorage
import Testing
@testable import HolosWhisper

// Opt-in probe (docs/meeting-design.md §4.16): HOLOS_DEEP_PROBE_SESSION=<a copy of a .holos folder>, with the model
// installed (HOLOS_WHISPER_MODELS_DIR), transcribes ten minutes of one track (HOLOS_DEEP_PROBE_TRACK, default system;
// from HOLOS_DEEP_PROBE_START seconds, default 1200) and counts the recorded transcript's words there with no Whisper
// word within 3 s. Prints numbers only.

private let probedSession = ProcessInfo.processInfo.environment["HOLOS_DEEP_PROBE_SESSION"]

@Test(.enabled(if: probedSession != nil), .timeLimit(.minutes(30)))
func probeHowMuchOfATrackWhisperCovers() async throws {
    let environment = ProcessInfo.processInfo.environment
    let session = URL(fileURLWithPath: try #require(probedSession), isDirectory: true)
    let track = environment["HOLOS_DEEP_PROBE_TRACK"] ?? "system"
    let start = Double(environment["HOLOS_DEEP_PROBE_START"] ?? "1200") ?? 1200
    let manifest = try SessionArchive.readManifest(at: session)
    // The recorded transcript: the base of the last deep transcription, else the current one.
    let events = try SessionArchive.readEvents(at: session).events
    let current = try SessionArchive.currentTranscriptID(at: session)
    let id = try #require(events.last { $0.kind == MeetingEventKind.deepTranscribed }?.details["base"] ?? current)
    let recorded = try HolosJSON.decoder().decode(Transcript.self, from: Data(contentsOf: SessionPaths.transcript(
        id, in: session)))
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("holos-probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: track,
                                            to: temp.appendingPathComponent("\(track).caf"))
    let file = try AVAudioFile(forReading: rendered.url, commonFormat: .pcmFormatFloat32, interleaved: false)
    file.framePosition = AVAudioFramePosition(start * 16_000)
    let count = AVAudioFrameCount(600 * 16_000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
    try file.read(into: buffer, frameCount: count)
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let transcriber = try await WhisperKitTranscriber.load()
    let prompt = environment["HOLOS_DEEP_PROBE_PROMPT"] ?? ""
    let clock = ContinuousClock()
    let began = clock.now
    let segments = try await transcriber.transcribe(
        DeepTranscriptionRequest(samples: samples, language: "en", prompt: prompt), progress: { _ in })
    let elapsed = began.duration(to: clock.now)
    let deep = segments.flatMap(\.words).map { $0.start + start }.sorted()
    let apple = recorded.segments.filter { $0.track == track }.flatMap(\.words)
        .filter { $0.start >= start + 3 && $0.start < start + 597 }
    let uncovered = apple.filter { word in !deep.contains { abs($0 - word.start) <= 3 } }
    print("probe \(track) from \(Int(start)) s: \(segments.count) segments, \(deep.count) words in \(elapsed); "
        + "\(apple.count) recorded words, \(uncovered.count) with no Whisper word within 3 s; "
        + "\(transcriber.fallbacks) of \(transcriber.chunkCount) chunks kept without the prompt")
}
