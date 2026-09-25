import AVFoundation
import Foundation
import Testing
import HolosCore
@testable import HolosDiarization
import HolosSpeakers
import HolosSynthesis

/// Opt-in (`HOLOS_DIARIZATION_FIXTURE=1`): diarizes a synthetic three-voice conversation with the real models. The
/// models come from `HOLOS_FIXTURE_MODELS_DIR` (the folder `voiceislocal setup --speakers` installs, which holds
/// `speaker-diarization/`), else from the user's real model folder, `~/Library/Application Support/Holos/Models/
/// speaker-diarization-coreml@df2625ac79a7`. Needs three installed English system voices; no microphone, no network.
@Suite struct FluidDiarizerFixtureTests {
    static let enabled = ProcessInfo.processInfo.environment["HOLOS_DIARIZATION_FIXTURE"] == "1"

    @Test(.enabled(if: FluidDiarizerFixtureTests.enabled), .timeLimit(.minutes(10)))
    @MainActor func threeVoiceFixtureMeetsDER() async throws {
        let environment = ProcessInfo.processInfo.environment
        let models = environment["HOLOS_FIXTURE_MODELS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FluidModels.defaultDirectory(supportRoot: HolosPaths.applicationSupport)
        let status = FluidModels.status(directory: models)
        try #require(status == .verified,
                     "Speaker models at \(models.path) are \(status.summary); run voiceislocal setup --speakers first.")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let voices = try fixtureVoices()
        let audio = folder.appendingPathComponent("conversation-16k.caf")
        let conversation = try await fixtureConversation(voices: voices, in: folder, to: audio)

        let diarizer = FluidDiarizer(modelsDirectory: models)
        let clock = ContinuousClock()
        let started = clock.now
        let output = try await diarizer.diarize(DiarizationRequest(audio: audio, track: "system"), progress: { _ in })
        let wall = clock.now - started
        let hypothesis = output.segments.map { LabelledInterval(speaker: $0.speaker, start: $0.start, end: $0.end) }
        let score = DiarizationScoring.der(reference: conversation.reference, hypothesis: hypothesis, collar: 0.25)
        let clusters = Set(output.segments.map(\.speaker)).count

        print("""
            threeVoiceFixtureMeetsDER: voices \(voices.joined(separator: ", ")); \
            \(String(format: "%.1f", conversation.duration)) s of audio, \
            12 turns; diarized in \(wall) (engine \(String(format: "%.2f", output.processingSeconds)) s); \
            \(clusters) clusters, \(output.segments.count) segments, \(output.windows.count) windows; \
            DER \(String(format: "%.2f", score.der * 100)) % (miss \(String(format: "%.2f", score.missSeconds)) s, \
            false alarm \(String(format: "%.2f", score.falseAlarmSeconds)) s, \
            confusion \(String(format: "%.2f", score.confusionSeconds)) s of \
            \(String(format: "%.2f", score.referenceSeconds)) s)
            """)
        #expect(clusters == 3)
        #expect(score.der < 0.10)
        #expect(Set(output.centroids.keys) == Set(output.segments.map(\.speaker)))
        #expect(output.centroids.values.allSatisfy { $0.count == 256 })
        #expect(!output.windows.isEmpty && output.windows.allSatisfy { $0.vector.count == 256 })
        let info = try await diarizer.engineInfo()
        #expect(info.models.first?.sha256 == ModelTreeDigest.digest(of: PinnedModels.files))
    }
}

// MARK: - Helpers (prefixed: other test files in this target may declare their own)

/// Twelve passages of plain narration; each turn speaks two of them, cut to the turn's length.
private let fixtureTurns = [
    "The river valley was quiet in the early morning, and the fishing boats waited along the wooden dock while the fog lifted slowly over the water and the hills.",
    "We should look at the budget for the new library before the end of the month, because the building work needs to start before the autumn rain begins.",
    "My grandmother kept a small garden behind the house, with tomatoes, beans, and a row of tall sunflowers that leaned toward the kitchen window every summer.",
    "The train from the coast arrived twenty minutes late, so most of the passengers missed the connection and waited for the evening bus into the city centre.",
    "I think the committee should publish the report online, so that everyone in the neighbourhood can read the proposals and send their comments before the vote.",
    "On clear nights you can see the lights of the harbour from the top of the hill, and the old lighthouse still turns its lamp even though no ships come in.",
    "The bakery on the corner opens at six, and by seven there is usually a line of people waiting for bread, coffee, and the warm cinnamon rolls they sell out of.",
    "Please remember that the parking lot behind the arena will be closed next week while the crews repaint the lines and repair the lights near the main entrance.",
    "When the snow finally melted, the trail along the creek turned to mud, and the hikers had to cross on flat stones that the rangers placed across the water.",
    "The music teacher asked every student to practise for twenty minutes a day, and by the spring concert the whole orchestra played the long piece without stopping.",
    "Our neighbours adopted a large grey dog from the shelter, and now it greets everyone who walks past the fence with a slow wag of its enormous tail.",
    "The museum will show old maps of the region this winter, including a hand drawn chart of the islands that a surveyor made more than two hundred years ago.",
]

/// Three installed English system voices that differ as much as possible: a female and a male voice, then a second
/// male voice from another English locale (two compact female voices merged in a trial run), else any voice from
/// another locale. Better quality first; super-compact voices only when nothing else is left (one can vanish while the
/// system replaces it with its compact version); novelty and Eloquence voices never.
/// `HOLOS_FIXTURE_VOICES` (three comma-separated identifiers) overrides the choice.
@MainActor private func fixtureVoices() throws -> [String] {
    if let listed = ProcessInfo.processInfo.environment["HOLOS_FIXTURE_VOICES"], !listed.isEmpty {
        let identifiers = listed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        try #require(identifiers.count == 3 && identifiers.allSatisfy { AVSpeechSynthesisVoice(identifier: $0) != nil },
                     "HOLOS_FIXTURE_VOICES must name three installed voice identifiers.")
        return identifiers
    }
    func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        let identifier = voice.identifier
        if identifier.contains("speech.synthesis.voice") || identifier.contains("eloquence") { return 2 }
        return identifier.contains("super-compact") ? 1 : 0
    }
    let candidates = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") }
        .sorted { (rank($0), -$0.quality.rawValue, $0.identifier) < (rank($1), -$1.quality.rawValue, $1.identifier) }
    var chosen: [AVSpeechSynthesisVoice] = []
    func pick(_ matches: (AVSpeechSynthesisVoice) -> Bool) {
        guard chosen.count < 3, let voice = candidates.first(where: { voice in
            rank(voice) < 2 && matches(voice) && !chosen.contains { $0.identifier == voice.identifier }
        }) else { return }
        chosen.append(voice)
    }
    func newLocale(_ voice: AVSpeechSynthesisVoice) -> Bool { !chosen.contains { $0.language == voice.language } }
    pick { $0.gender == .female }
    pick { $0.gender == .male }
    pick { $0.gender == .male && newLocale($0) }
    pick(newLocale)
    pick { _ in true }
    pick { _ in true }
    try #require(chosen.count == 3, "The fixture needs three installed English system voices.")
    return chosen.map(\.identifier)
}

private struct FixtureConversation {
    var reference: [LabelledInterval]
    var duration: Double
}

/// Renders twelve alternating turns (speakers 0, 1, 2, 0, …) of 5–8 s with 0.6 s of silence between them into one
/// 16 kHz mono Int16 CAF. The reference marks, per turn, where its voice is audible (10 ms frames above −40 dBFS,
/// with pauses under 0.25 s bridged), so it holds speech only.
@MainActor private func fixtureConversation(voices: [String], in folder: URL,
                                             to output: URL) async throws -> FixtureConversation {
    let rate = 16_000.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false, AVAudioFileTypeKey: kAudioFileCAFType,
    ]
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                            interleaved: false))
    let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    let renderer = NativeSpeechRenderer()
    let gap = [Float](repeating: 0, count: Int(0.6 * rate))
    var written = 0
    var reference: [LabelledInterval] = []

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        written += samples.count
    }

    try append(gap)
    for (turn, text) in fixtureTurns.enumerated() {
        let speaker = turn % 3
        let target = 5.0 + Double((turn * 7) % 4) // 5, 8, 7, 6, 5, …
        // Two passages, so even a fast voice speaks for longer than the turn; the clip is cut to `target`.
        let passage = text + " " + fixtureTurns[(turn + 5) % fixtureTurns.count]
        let rendered = try await renderer.render(text: passage, voiceIdentifier: voices[speaker],
                                                 to: folder.appendingPathComponent("turn-\(turn).caf"))
        let speech = fixtureTrimmed(try fixtureMono16k(rendered.url))
        try #require(Double(speech.count) / rate >= target - 0.5,
                     "Turn \(turn) rendered only \(Double(speech.count) / rate) s of speech.")
        let clip = Array(speech.prefix(Int(target * rate)))
        let start = Double(written) / rate
        reference += fixtureVoiceActivity(clip, rate: rate).map {
            LabelledInterval(speaker: "voice\(speaker)", start: start + $0.lowerBound, end: start + $0.upperBound)
        }
        try append(clip)
        try append(gap)
    }
    file.close()
    return FixtureConversation(reference: reference, duration: Double(written) / rate)
}

/// The rendered file (one short turn) as 16 kHz mono Float32.
private func fixtureMono16k(_ url: URL) throws -> [Float] {
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
    // The converter calls the input block synchronously inside `convert`: first the whole turn, then end of stream.
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

/// Drops leading and trailing silence (below −40 dBFS).
private func fixtureTrimmed(_ samples: [Float]) -> [Float] {
    let threshold: Float = 0.01
    guard let first = samples.firstIndex(where: { abs($0) > threshold }),
          let last = samples.lastIndex(where: { abs($0) > threshold }) else { return [] }
    return Array(samples[first...last])
}

/// Seconds (from the clip start) where the clip is audible: 10 ms frames with RMS above −40 dBFS, pauses under
/// 0.25 s bridged, islands under 50 ms dropped.
private func fixtureVoiceActivity(_ clip: [Float], rate: Double) -> [Range<Double>] {
    let frame = Int(rate / 100)
    var active: [Bool] = []
    var index = 0
    while index < clip.count {
        let slice = clip[index..<min(clip.count, index + frame)]
        let energy = slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(slice.count)
        active.append(energy.squareRoot() > 0.01)
        index += frame
    }
    var runs: [Range<Int>] = []
    var start: Int?
    for (position, isActive) in active.enumerated() {
        if isActive, start == nil { start = position }
        if !isActive, let begin = start {
            runs.append(begin..<position)
            start = nil
        }
    }
    if let begin = start { runs.append(begin..<active.count) }
    var merged: [Range<Int>] = []
    for run in runs {
        if let last = merged.last, run.lowerBound - last.upperBound < 25 {
            merged[merged.count - 1] = last.lowerBound..<run.upperBound
        } else {
            merged.append(run)
        }
    }
    return merged.filter { $0.count >= 5 }.map { Double($0.lowerBound) / 100..<Double($0.upperBound) / 100 }
}
