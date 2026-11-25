import Foundation
import HolosCore
import HolosTestSupport
import Testing
@testable import HolosDictation

private actor TermRecognizer: DeepTranscriber {
    nonisolated let engine = "fixture"
    let failOnSecondPiece: Bool
    var requests: [DeepTranscriptionRequest] = []

    init(failOnSecondPiece: Bool = false) { self.failOnSecondPiece = failOnSecondPiece }
    func promptTokenCount(_ text: String) async throws -> Int { text.count }
    func transcribe(_ request: DeepTranscriptionRequest, progress: @escaping @Sendable (Double) -> Void)
        async throws -> [DeepTranscribedSegment] {
        requests.append(request)
        if requests.count == 2, failOnSecondPiece {
            return [.init(text: "", start: 0, end: 1, unheard: true)]
        }
        return [.init(text: "night", start: 0, end: 1)]
    }
}

@Test(arguments: AccurateDictationModel.allCases)
func accurateDictationUsesApprovedTermsAndConfirmedCorrections(_ model: AccurateDictationModel) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let audio = temp.url.appendingPathComponent("invented.caf")
    try AudioFixtures.writeCAF(at: audio, frames: 1024, sampleRate: 16_000)
    let corrections = CorrectionList(entries: [.init(heard: "night", meant: "KNYTE")])
    let terms = RecognizerVocabulary.dictation(wordList: ["Copperleaf"], corrections: corrections, language: "en-CA")
    let config = AccurateDictationCommand.Request(model: model, locale: "en-CA", vocabulary: terms)
    #expect(config.vocabulary == (model == .whisper ? ["Copperleaf", "KNYTE"] : []))
    let engine = TermRecognizer()
    let outcome = try await AccurateDictationCommand.run(audio: audio, request: config, transcriber: engine,
                                                         prompt: config.vocabulary.joined(separator: ", ")) { $0.count }
    let requests = await engine.requests
    #expect(requests.count == 1)
    #expect(requests.first?.samples.count == 1024)
    #expect(requests.first?.language == "en")
    #expect(requests.first?.prompt == (model == .whisper ? "Copperleaf, KNYTE" : ""))
    #expect(outcome.text == "night")
    let pipeline = DictationTextPipeline(language: "en-CA", removeFillers: false, corrections: corrections)
    let output = await pipeline.run(segments: [outcome.text])
    #expect(!output.aiFixed)
    #expect(output.corrections == 1)
    #expect(output.written == "KNYTE")
}

@Test(arguments: [false, true])
func accurateDictationProcessesEverySampleAndRefusesAnIncompleteLaterPiece(fail: Bool) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let audio = temp.url.appendingPathComponent("long.caf")
    let count = 16_000 * 60 + 513
    try AudioFixtures.writeCAF(at: audio, frames: count, sampleRate: 16_000)
    let engine = TermRecognizer(failOnSecondPiece: fail)
    let config = AccurateDictationCommand.Request(model: .parakeet, locale: "fr-CA", vocabulary: [])
    func run() async throws -> String {
        try await AccurateDictationCommand.run(audio: audio, request: config, transcriber: engine, prompt: "") {
            $0.count - 177
        }.text
    }
    if fail { await #expect(throws: HolosError.self) { try await run() } }
    else { #expect(try await run() == "night night") }
    let sizes = await engine.requests.map { $0.samples.count }
    // AVAudioFile may deliver a shorter first buffer than requested. Every sample must still reach a piece.
    #expect(sizes.count == 2)
    #expect(sizes.reduce(0, +) == count)
    #expect((sizes.last ?? 0) > 177)
}
