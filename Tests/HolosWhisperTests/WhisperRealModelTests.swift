import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosMeeting
import HolosStorage
import HolosSynthesis
import Testing
@testable import HolosWhisper
@preconcurrency import WhisperKit

// Opt-in (HOLOS_WHISPER_MODEL_TESTS=1): the installed deep transcription model, never downloaded here. Point
// HOLOS_WHISPER_MODELS_DIR at a folder `voiceislocal setup --whisper` installed into (scripts/test.sh moves the default
// Application Support folder to a temporary one). Invented speech is rendered by the system synthesizer to a file and
// never played. Prints counts and times only.

private let modelTestsEnabled = ProcessInfo.processInfo.environment["HOLOS_WHISPER_MODEL_TESTS"] == "1"

/// Invented sentences, rendered to `folder` and read back as mono frames from session time `start`.
@MainActor
private func renderedSpeech(_ text: String, in folder: URL, start: Double) async throws -> [PCMFrame] {
    let url = folder.appendingPathComponent("speech-\(UUID().uuidString).caf")
    _ = try await NativeSpeechRenderer().render(text: text, to: url)
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw HolosError.io("Cannot allocate a buffer.")
    }
    try file.read(into: buffer)
    let channels = Int(format.channelCount)
    let count = Int(buffer.frameLength)
    var mono = [Float](repeating: 0, count: count)
    for channel in 0..<channels {
        guard let data = buffer.floatChannelData?[channel] else { continue }
        for index in 0..<count { mono[index] += data[index] / Float(channels) }
    }
    return [try PCMFrame(samples: mono, sampleRate: format.sampleRate, channels: 1, startTime: start)]
}

/// `frames` as 16 kHz mono samples.
private func samples16k(_ frames: [PCMFrame]) throws -> [Float] {
    guard let first = frames.first,
          let input = AVAudioFormat(standardFormatWithSampleRate: first.sampleRate, channels: 1),
          let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
          let converter = AVAudioConverter(from: input, to: output) else { throw HolosError.io("No converter.") }
    let all = frames.flatMap(\.samples)
    guard let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(all.count)),
          let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(
            Double(all.count) * 16_000 / first.sampleRate + 1_024)) else { throw HolosError.io("No buffer.") }
    source.frameLength = AVAudioFrameCount(all.count)
    for index in all.indices { source.floatChannelData![0][index] = all[index] }
    var fed = false
    var error: NSError?
    converter.convert(to: target, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return source
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
}

@Test(.enabled(if: modelTestsEnabled), .timeLimit(.minutes(30)))
func wordTimesFollowTheSpeechWithAndWithoutAPrompt() async throws {
    try #require(WhisperModels.status() == .installed)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-whisper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let speech = try samples16k(try await renderedSpeech(
        "The garden committee will meet on Thursday to plan the spring planting. Please bring your seed catalogues.",
        in: root, start: 0))
    // 3 s of silence before the speech, 25 s after it: one window of the model.
    let audio = [Float](repeating: 0, count: 48_000) + speech + [Float](repeating: 0, count: 15 * 16_000)
    let onset = 3 + Double(speech.firstIndex { abs($0) > 0.02 } ?? 0) / 16_000
    let transcriber = try await WhisperKitTranscriber.load()
    let long = "Garden committee. " + (1...40).map { "Quorvex\($0)" }.joined(separator: ", ") + "."
    for prompt in ["", "Garden committee. Catalogues, Thursday.", long] {
        let segments = try await transcriber.transcribe(
            DeepTranscriptionRequest(samples: audio, language: "en", prompt: prompt), progress: { _ in })
        let words = segments.flatMap(\.words)
        print("whisper timing (prompt \(prompt.count) characters): onset \(String(format: "%.2f", onset)) s; "
            + "first words at \(words.map { String(format: "%.2f", $0.start) }); last word ends "
            + "\(String(format: "%.2f", words.last?.end ?? 0)) s of \(String(format: "%.2f", 3 + Double(speech.count) / 16_000))")
        #expect((words.first?.start ?? 0) >= onset - 0.75, "The first word starts with the speech.")
    }
}

/// A voice-activity chunking that hears only the first `seconds` of the audio.
private struct DeafChunker: AudioChunking {
    var seconds: Double

    func chunkAll(audioArray: [Float], maxChunkLength: Int, decodeOptions: DecodingOptions?) async throws
        -> [AudioChunk] {
        let end = min(audioArray.count, Int(seconds * 16_000))
        return [AudioChunk(seekOffsetIndex: 0, audioSamples: Array(audioArray[..<end]))]
    }
}

@Test(.enabled(if: modelTestsEnabled), .timeLimit(.minutes(30)))
func speechTheChunkingMissesIsTranscribedWhereTheRecordedTranscriptHeardIt() async throws {
    try #require(WhisperModels.status() == .installed)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-whisper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let speech = try samples16k(try await renderedSpeech(
        "The garden committee will meet on Thursday to plan the spring planting.", in: root, start: 0))
    // 5 s of silence, then the speech: the fake chunking hears only the silence.
    let audio = [Float](repeating: 0, count: 5 * 16_000) + speech + [Float](repeating: 0, count: 16_000)
    let transcriber = try await WhisperKitTranscriber.load()
    transcriber.chunker = DeafChunker(seconds: 5)
    let missed = try await transcriber.transcribe(
        DeepTranscriptionRequest(samples: audio, language: "en", prompt: ""), progress: { _ in })
    #expect(missed.flatMap(\.words).isEmpty, "Without recorded words, what the chunking left out stays out.")
    let recorded = (0..<6).map { 5.5 + Double($0) * 0.5 }
    let segments = try await transcriber.transcribe(
        DeepTranscriptionRequest(samples: audio, language: "en", prompt: "", recordedWords: recorded),
        progress: { _ in })
    let text = segments.map(\.text).joined(separator: " ").lowercased()
    print("whisper missed by the chunking: \(segments.flatMap(\.words).count) words")
    #expect(text.contains("garden") && text.contains("thursday"))
    #expect((segments.flatMap(\.words).first?.start ?? 0) >= 4.5, "Timed from the request's start.")
}

@Test(.enabled(if: modelTestsEnabled), .timeLimit(.minutes(30)))
func theInstalledModelTranscribesASessionAgain() async throws {
    #expect(WhisperModels.status() == .installed,
            "Install the model first: HOLOS_WHISPER_MODELS_DIR=<folder> voiceislocal setup --whisper")
    try #require(WhisperModels.status() == .installed)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-whisper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 4 s of quiet, the speech, then 20 s of digital silence.
    let speech = try await renderedSpeech(
        "The garden committee will meet on Thursday to plan the spring planting. Please bring your seed catalogues.",
        in: root, start: 4)
    let speechSeconds = speech.reduce(0) { $0 + $1.duration }
    // The silences are written at the speech's sample rate: a track keeps one format.
    let rate = speech[0].sampleRate
    let archive = try SessionArchive.create(root: root, name: "Garden committee", source: .microphone,
                                            locale: "en-US", backend: .speech)
    try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: .inPerson, othersInRoom: false, createdAt: Date()),
                             to: SessionPaths.meetingInfo(archive.directory))
    let writer = AudioChunkWriter(archive: archive)
    try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(
        samples: [Float](repeating: 0, count: Int(4 * rate)), sampleRate: rate, channels: 1, startTime: 0)))
    for frame in speech { try await writer.append(CapturedAudio(track: "mic", frame: frame)) }
    try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(
        samples: [Float](repeating: 0, count: Int(20 * rate)), sampleRate: rate, channels: 1,
        startTime: 4 + speechSeconds)))
    try await writer.finish()
    // A rough recorded transcript, as the live recognizer might have left it.
    let recorded = Transcript(source: "fixture", locale: "en-US", backend: .speech, segments: [
        TranscriptSegment(start: 4, end: 4 + speechSeconds, text: "the garden committee will meet on Thursday",
                          track: "mic"),
    ])
    try await archive.saveTranscript(recorded, writeLegacyExports: false)
    try await archive.finish(status: ArchiveStatus.complete)
    let session = archive.directory

    let dependencies = DeepTranscriptionDependencies(
        modelStatus: { WhisperModels.status() }, makeTranscriber: { try await WhisperKitTranscriber.load() },
        // A long prompt, as a real word list gives: word times must not move with its length.
        wordList: { ["catalogues"] + (1...40).map { "Quorvex\($0)" } }, names: { [] })
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = try await SessionDeepTranscribeCommand.run(
        SessionDeepTranscribeCommand.Request(session: session), voiceSamples: .none, diarizer: nil, freeSpace: FixedFreeSpace(.max),
        wordFixes: .none, deepTranscription: dependencies)
    let elapsed = started.duration(to: clock.now)
    #expect(outcome.exitCode == 0, "\(outcome.summary)")
    let id = try #require(try SessionArchive.currentTranscriptID(at: session))
    let current = try HolosJSON.decoder().decode(Transcript.self, from: Data(contentsOf: SessionPaths.transcript(
        id, in: session)))
    #expect(current.engine == DeepTranscriptionModel.engine)
    let text = current.text.lowercased()
    #expect(text.contains("garden") && text.contains("thursday") && text.contains("catalogue"))
    #expect(current.segments.allSatisfy { $0.start >= 3 && $0.end <= 4 + speechSeconds + 1.5 },
            "Nothing is kept over the silence after the speech.")
    #expect(current.segments.flatMap(\.words).allSatisfy { $0.start >= 3 })
    print("whisper model test timings: segments \(current.segments.map { "\($0.start)-\($0.end)" }); words "
        + "\(current.segments.flatMap(\.words).map { String(format: "%.2f", $0.start) })")
    print("whisper model test: \(current.segments.count) segments, \(current.segments.flatMap(\.words).count) words "
        + "for \(String(format: "%.1f", speechSeconds)) s of speech; \(elapsed) including the model load")
}
