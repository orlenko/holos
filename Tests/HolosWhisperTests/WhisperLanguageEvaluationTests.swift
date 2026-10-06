import AVFoundation
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing
@testable import HolosWhisper

// Opt-in evaluation (docs/meeting-design.md §4.16, a meeting in several languages): HOLOS_DEEP_LANGUAGE_EVAL=<folder>
// of 16 kHz mono .wav files (invented speech, rendered to files and never played), with the model installed
// (HOLOS_WHISPER_MODELS_DIR). Each file is transcribed as one stretch of a track in several ways, and each result is
// written to <folder>/results/<file>.<way>.json for scoring outside the suite:
// - `chosen`: each passage in the language chosen among the meeting's (what the pass does);
// - one forced language per meeting language (`fr`, `en`), and `auto` (Whisper's own detection, unrestricted);
// - `merge`: the forced transcriptions merged passage by passage by the languages stage's rule (`LanguageMerge`).
// HOLOS_DEEP_LANGUAGE_EVAL_LANGUAGES (default "fr-CA,en-CA") are the meeting's languages, the preferred one first;
// HOLOS_DEEP_LANGUAGE_EVAL_PROMPT is the vocabulary prompt (default none); HOLOS_DEEP_LANGUAGE_EVAL_WAYS=chosen runs
// the first way only. With HOLOS_DEEP_LANGUAGE_EVAL_APPLE=1 a second test writes what a meeting in these languages
// gets without the pass: each file imported as a meeting (Apple's speech recognition, in the first language) into a
// temporary folder, then the languages stage's merge (`apple`), and the import's own transcript (`apple-first`); it
// needs those languages' speech models installed. Prints counts and times only.

private let evaluationFolder = ProcessInfo.processInfo.environment["HOLOS_DEEP_LANGUAGE_EVAL"]

private struct EvaluatedWord: Encodable {
    var text: String
    var start: Double
    var end: Double
}

private struct EvaluatedSegment: Encodable {
    var start: Double
    var end: Double
    var text: String
    var language: String?
    var words: [EvaluatedWord]
}

private struct EvaluatedPassage: Encodable {
    var start: Double
    var seconds: Double
    var probabilities: [String: Double]
    var language: String
}

private struct Evaluation: Encodable {
    var way: String
    /// Seconds of processing (for `merge`, the forced transcriptions' together).
    var seconds: Double
    var segments: [EvaluatedSegment]
    var passages: [EvaluatedPassage]
    /// Passages halved because their language was unsure.
    var halved: Int
}

@Test(.enabled(if: evaluationFolder != nil), .timeLimit(.minutes(120)))
func evaluateChoosingEachPassagesLanguage() async throws {
    let environment = ProcessInfo.processInfo.environment
    let folder = URL(fileURLWithPath: try #require(evaluationFolder), isDirectory: true)
    let locales = DictationLanguage.meetingLanguages(
        DictationLanguage.list(environment["HOLOS_DEEP_LANGUAGE_EVAL_LANGUAGES"] ?? "fr-CA,en-CA"))
    let codes = locales.compactMap(DeepTranscriptionModel.whisperLanguage)
    try #require(codes.count == locales.count && codes.count > 1, "Name two or more languages Whisper knows.")
    let prompt = environment["HOLOS_DEEP_LANGUAGE_EVAL_PROMPT"] ?? ""
    let chosenOnly = environment["HOLOS_DEEP_LANGUAGE_EVAL_WAYS"] == "chosen"
    let results = folder.appendingPathComponent("results", isDirectory: true)
    try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let transcriber = try await WhisperKitTranscriber.load()
    let clock = ContinuousClock()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    for file in files {
        let samples = try monoSamples(file)
        let name = file.deletingPathExtension().lastPathComponent
        var forced: [String: (segments: [DeepTranscribedSegment], seconds: Double)] = [:]
        func save(_ way: String, _ segments: [EvaluatedSegment], seconds: Double,
                  passages: [EvaluatedPassage] = [], halved: Int = 0) throws {
            let data = try encoder.encode(Evaluation(way: way, seconds: seconds, segments: segments,
                                                     passages: passages, halved: halved))
            try data.write(to: results.appendingPathComponent("\(name).\(way).json"))
            print("language evaluation \(name) \(way): \(segments.count) segments, "
                + "\(segments.reduce(0) { $0 + $1.words.count }) words, \(passages.count) passages "
                + "(\(halved) halved), "
                + String(format: "%.1f s for %.1f s of audio", seconds, Double(samples.count) / 16_000))
        }
        func run(_ request: DeepTranscriptionRequest) async throws -> ([DeepTranscribedSegment], Double) {
            let began = clock.now
            let segments = try await transcriber.transcribe(request, progress: { _ in })
            let elapsed = began.duration(to: clock.now)
            return (segments, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }

        let before = transcriber.languageLog.count
        let halvedBefore = transcriber.languageSplits
        let (chosen, chosenSeconds) = try await run(
            DeepTranscriptionRequest(samples: samples, language: nil, languages: codes, prompt: prompt))
        let passages = transcriber.languageLog[before...].map {
            EvaluatedPassage(start: $0.start, seconds: $0.seconds, probabilities: $0.probabilities,
                             language: $0.language)
        }
        try save("chosen", chosen.map(evaluated), seconds: chosenSeconds, passages: Array(passages),
                 halved: transcriber.languageSplits - halvedBefore)
        if chosenOnly { continue }
        for code in codes {
            let (segments, seconds) = try await run(DeepTranscriptionRequest(samples: samples, language: code,
                                                                              prompt: prompt))
            forced[code] = (segments, seconds)
            try save(code, segments.map(evaluated), seconds: seconds)
        }
        let (auto, autoSeconds) = try await run(DeepTranscriptionRequest(samples: samples, language: nil,
                                                                          prompt: prompt))
        try save("auto", auto.map(evaluated), seconds: autoSeconds)

        // The languages stage's rule over the forced transcriptions, as one microphone track.
        let candidates = zip(locales, codes).map { locale, code in
            LanguageMerge.Candidate(language: locale, segments: (forced[code]?.segments ?? []).compactMap { segment in
                DeepAudio.transcriptSegment(DeepHeardSegment(track: "mic", start: segment.start, end: segment.end,
                                                             text: segment.text, words: segment.words, levelDB: -20))
            })
        }
        let merged = LanguageMerge.merge(candidates, scorer: NaturalLanguageScorer().scorer)
        try save("merge", merged.segments.map(evaluated),
                 seconds: codes.reduce(0) { $0 + (forced[$1]?.seconds ?? 0) })
    }
}

private let appleEvaluation = ProcessInfo.processInfo.environment["HOLOS_DEEP_LANGUAGE_EVAL_APPLE"] == "1"

@Test(.enabled(if: evaluationFolder != nil && appleEvaluation), .timeLimit(.minutes(120)))
func evaluateTheRecognizersMergeOfTheSameFiles() async throws {
    let environment = ProcessInfo.processInfo.environment
    let folder = URL(fileURLWithPath: try #require(evaluationFolder), isDirectory: true)
    let locales = DictationLanguage.meetingLanguages(
        DictationLanguage.list(environment["HOLOS_DEEP_LANGUAGE_EVAL_LANGUAGES"] ?? "fr-CA,en-CA"))
    let results = folder.appendingPathComponent("results", isDirectory: true)
    try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-language-eval-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let clock = ContinuousClock()
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in files {
        let name = file.deletingPathExtension().lastPathComponent
        let began = clock.now
        let session = try await SessionImporter.importAudio(from: file, name: name, root: root, locale: locales[0],
                                                            backend: .speech, languages: locales)
        let imported = try #require(try SessionArchive.currentTranscriptID(at: session))
        let record = try await MeetingPostProcessor(voiceSamples: .none).run(session: session, lease: nil)
        let elapsed = began.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let merged = try #require(try SessionArchive.currentTranscriptID(at: session))
        for (way, id) in [("apple", merged), ("apple-first", imported)] {
            let transcript = try SessionFiles.transcript(id: id, session: session)
            let segments = transcript.segments.map(evaluated)
            try encoder.encode(Evaluation(way: way, seconds: seconds, segments: segments, passages: [], halved: 0))
                .write(to: results.appendingPathComponent("\(name).\(way).json"))
            print("language evaluation \(name) \(way): \(segments.count) segments, "
                + "\(segments.reduce(0) { $0 + $1.words.count }) words, record \(record.state.rawValue), "
                + String(format: "%.1f s with the import", seconds))
        }
    }
}

/// A transcript segment as the files hold it, its language as Whisper names it.
private func evaluated(_ segment: TranscriptSegment) -> EvaluatedSegment {
    EvaluatedSegment(start: segment.start, end: segment.end, text: segment.text,
                     language: segment.language.flatMap(DeepTranscriptionModel.whisperLanguage),
                     words: segment.words.map { EvaluatedWord(text: $0.text, start: $0.start, end: $0.end) })
}

private func evaluated(_ segment: DeepTranscribedSegment) -> EvaluatedSegment {
    EvaluatedSegment(start: segment.start, end: segment.end, text: segment.text, language: segment.language,
                     words: segment.words.map { EvaluatedWord(text: $0.text, start: $0.start, end: $0.end) })
}

/// A 16 kHz mono file's samples.
private func monoSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    try #require(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}
