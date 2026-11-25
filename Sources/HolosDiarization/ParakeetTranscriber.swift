import FluidAudio
import Foundation
import HolosCore

/// A CLI-only recognizer for a separately displayed meeting candidate.
public struct ParakeetTranscriber: DeepTranscriber {
    private let manager: AsrManager
    public let engine = "parakeet-ultra"

    public static func load(directory: URL = ParakeetModels.directory) throws -> Self {
        guard try ParakeetModels.verified(directory) else {
            throw HolosError.unavailable("Download and verify Parakeet Ultra from the meeting’s comparison dialog or run voiceislocal setup --parakeet.")
        }
        let models = try AsrModels.loadLocal(from: ParakeetModels.repo(in: directory), version: .ultra)
        return Self(manager: AsrManager(models: models))
    }

    public func promptTokenCount(_ text: String) async throws -> Int {
        guard text.isEmpty else { throw HolosError.invalidInput("Parakeet comparison does not support vocabulary prompts.") }
        return 0
    }

    // The model card's languages. FluidAudio's script filter also accepts some languages outside this set.
    static let languages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    public static func supports(locale: String) -> Bool {
        guard let code = Locale(identifier: locale).language.languageCode?.identifier.lowercased() else { return false }
        return languages.contains(code)
    }

    public func transcribe(_ request: DeepTranscriptionRequest,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [DeepTranscribedSegment] {
        guard let code = request.language, Self.languages.contains(code), let language = Language(rawValue: code) else {
            throw HolosError.invalidInput("Parakeet Ultra does not support this recognition language.")
        }
        _ = try await promptTokenCount(request.prompt)
        try Task.checkCancellation()
        var state = try TdtDecoderState(decoderLayers: AsrModelVersion.ultra.decoderLayers)
        guard !request.samples.isEmpty else { return [] }
        // A short track or the tail of a cut can be shorter than the decoder's minimum input.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let samples = request.samples.count >= minimum ? request.samples
            : request.samples + Array(repeating: 0, count: minimum - request.samples.count)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        try Task.checkCancellation()
        progress(1)
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            if result.text.isEmpty { return [] }
            return [.init(text: result.text, start: 0, end: Double(request.samples.count) / 16_000)]
        }
        return words.map {
            .init(text: $0.word, start: $0.startTime, end: $0.endTime,
                  words: [.init(text: $0.word, start: $0.startTime, end: $0.endTime)])
        }
    }
}
