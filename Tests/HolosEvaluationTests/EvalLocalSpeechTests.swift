import AVFoundation
import Foundation
import Testing
import HolosAudio
import HolosCore
import HolosStorage
import HolosSynthesis
@testable import HolosEvaluation
@testable import HolosMeeting
import HolosTestSupport

// `voiceislocal eval local` with Apple's real speech recognition, on speech rendered to a file (never played).
// Opt-in (HOLOS_SPEECH_FIXTURE=1), and skipped when no English speech model or voice is installed.

@Suite struct EvalLocalSpeechTests {
    static let enabled = ProcessInfo.processInfo.environment["HOLOS_SPEECH_FIXTURE"] == "1"

    @MainActor
    @Test(.enabled(if: EvalLocalSpeechTests.enabled), .timeLimit(.minutes(5)))
    func evalLocalTranscribesRenderedSpeech() async throws {
        let live = LanguageDetectionDependencies.live
        var locale: String?
        for candidate in ["en-US", "en-CA", "en-GB"] where await live.modelStatus(candidate, .speech) == "installed" {
            locale = candidate
            break
        }
        guard let locale, let voice = NativeSpeechRenderer.bestVoice(language: "en-US") else { return }
        let temp = try TemporaryDirectory("eval-speech")
        defer { temp.remove() }
        let rendered = try await NativeSpeechRenderer().render(
            text: "We ship three builds to the team every Monday morning.", voiceIdentifier: voice.id,
            to: temp.url.appendingPathComponent("speech.caf"))
        let samples = try evalMono16k(rendered.url)
        try #require(samples.count > 16_000)

        let archive = try SessionArchive.create(root: temp.url.appendingPathComponent("sessions"), name: "Speech",
                                                source: .microphone, locale: locale, backend: .speech)
        let writer = AudioChunkWriter(archive: archive)
        let padded = [Float](repeating: 0, count: 8_000) + samples + [Float](repeating: 0, count: 16_000)
        try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(samples: padded, sampleRate: 16_000,
                                                                                channels: 1, startTime: 0)))
        try await writer.finish()
        try await archive.finish(status: ArchiveStatus.complete)

        let record = try await EvalLocal.run(session: archive.directory, options: .init(), vocabulary: ["Monday"])
        let transcript = try EvalLocal.transcript(of: record, in: archive.directory)
        #expect(record.languages == [locale])
        #expect(transcript.text.lowercased().contains("monday"))
        #expect(transcript.segments.allSatisfy { $0.track == "mic" })
    }
}

/// A rendered file as 16 kHz mono Float32.
private func evalMono16k(_ url: URL) throws -> [Float] {
    let input = try AVAudioFile(forReading: url)
    let whole = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                              frameCapacity: AVAudioFrameCount(input.length)))
    try input.read(into: whole)
    let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                            interleaved: false))
    let converter = try #require(AVAudioConverter(from: input.processingFormat, to: target))
    let capacity = AVAudioFrameCount((Double(whole.frameLength) * 16_000 / input.processingFormat.sampleRate)
        .rounded(.up)) + 1_024
    let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
    final class Delivery { var pending: AVAudioPCMBuffer? }
    let delivery = Delivery()
    delivery.pending = whole
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
        let next = delivery.pending
        delivery.pending = nil
        inputStatus.pointee = next == nil ? .endOfStream : .haveData
        return next
    }
    if let conversionError { throw conversionError }
    try #require(status != .error)
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}
