import Foundation
import HolosCore
@testable import HolosDiarization
import HolosSynthesis
import HolosTestSupport
import Testing

@Test func missingUltraModelFailsLocallyWithoutCreatingFiles() throws {
    let temp = try TemporaryDirectory("missing-ultra")
    defer { temp.remove() }
    #expect(throws: HolosError.self) { try ParakeetTranscriber.load(directory: temp.url) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    #expect(!ParakeetTranscriber.languages.contains("ja"))
    #expect(!ParakeetTranscriber.languages.contains("bs"))
    #expect(ParakeetTranscriber.languages.count == 25)
}

@Test func ultraRejectsAChangedVocabularyEvenWhenItsSizeAndRevisionMatch() throws {
    let temp = try TemporaryDirectory("ultra-verification")
    defer { temp.remove() }
    let folder = ParakeetModels.repo(in: temp.url)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(ParakeetPins.revision.utf8).write(to: folder.appendingPathComponent(FluidModels.revisionMarkerName))
    let file = folder.appendingPathComponent("parakeet_vocab.json")
    try Data("abc".utf8).write(to: file)
    let pinned = try ModelTreeDigest.manifest(of: folder)
    #expect(try ParakeetModels.verified(temp.url, pinned: pinned))
    try Data("xyz".utf8).write(to: file)
    #expect(try !ParakeetModels.verified(temp.url, pinned: pinned))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_PARAKEET_FIXTURE_MODELS_DIR"] != nil),
      .timeLimit(.minutes(5)))
func verifiedUltraRecognizesGeneratedSpeech() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["HOLOS_PARAKEET_FIXTURE_MODELS_DIR"])
    let recognizer = try ParakeetTranscriber.load(directory: URL(fileURLWithPath: path))
    let temp = try TemporaryDirectory("ultra-speech")
    defer { temp.remove() }
    let audio = temp.url.appendingPathComponent("speech.caf")
    _ = try await NativeSpeechRenderer().render(text: "The blue umbrella is beside the garden gate.", to: audio)
    let samples = try AudioFixtures.mono16k(audio)
    let words = try await recognizer.transcribe(.init(samples: samples, language: "en", prompt: "")) { _ in }
    #expect(words.map(\.text).joined(separator: " ").lowercased().contains("umbrella"))
    #expect(words.allSatisfy { $0.start >= 0 && $0.end >= $0.start })
    await #expect(throws: HolosError.self) {
        try await recognizer.transcribe(.init(samples: samples, language: "ja", prompt: "")) { _ in }
    }
}
