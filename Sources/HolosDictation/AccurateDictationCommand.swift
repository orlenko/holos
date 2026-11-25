import Foundation
import HolosAudio
import HolosCore

public enum AccurateDictationModel: String, Codable, CaseIterable, Sendable {
    case whisper, parakeet

    public var title: String {
        switch self {
        case .whisper: "WhisperKit large-v3 turbo"
        case .parakeet: "Parakeet Ultra"
        }
    }
}

/// Recognizes a completed dictation capture. Only the CLI supplies the installed model.
public enum AccurateDictationCommand {
    public struct Request: Codable, Sendable {
        public let model: AccurateDictationModel
        public let locale: String
        public let vocabulary: [String]

        public init(model: AccurateDictationModel, locale: String, vocabulary: [String]) {
            self.model = model
            self.locale = locale
            self.vocabulary = model == .whisper ? RecognizerVocabulary.merged([vocabulary]) : []
        }
    }

    public enum Failure: Int32, Sendable {
        case modelUnavailable = 69
        case unsupportedLanguage = 65

        public static func message(code: Int32, model: AccurateDictationModel) -> String {
            switch Self(rawValue: code) {
            case .modelUnavailable:
                "\(model.title) could not load. Download it in Dictation settings, or repair it with voiceislocal setup --\(model.rawValue) --force."
            case .unsupportedLanguage:
                "\(model.title) does not support the selected dictation language."
            case nil:
                "\(model.title) could not recognize the complete recording (helper exit \(code)). Try dictating again."
            }
        }
    }

    public struct Outcome: Codable, Sendable {
        public let text: String
    }

    public static func run(audio: URL, request: Request, transcriber: any DeepTranscriber,
                           prompt: String, pieceEnd: ([Float]) -> Int) async throws -> Outcome {
        let reader = try DictationAudioFile.Reader(audio, pieceSeconds: 60, requireMono16k: true)
        let language = request.model == .whisper ? DeepTranscriptionModel.whisperLanguage(request.locale)
            : Locale(identifier: request.locale).language.languageCode?.identifier.lowercased()
        var parts: [String] = []
        var tail: [Float] = []
        while let frame = try reader.next() {
            var samples = tail + frame.samples
            tail.removeAll()
            if reader.hasMore {
                let cut = pieceEnd(samples)
                guard cut > 0, cut <= samples.count else { throw HolosError.invalidInput("Invalid audio cut.") }
                tail = Array(samples[cut...])
                samples.removeSubrange(cut...)
            }
            let segments = try await transcriber.transcribe(.init(samples: samples, language: language,
                                                                  prompt: prompt)) { _ in }
            guard !segments.contains(where: \.unheard) else {
                throw HolosError.incomplete("The model could not recognize part of the dictation. Try again.")
            }
            parts.append(contentsOf: segments.map(\.text))
        }
        try Task.checkCancellation()
        return Outcome(text: DictationTextPipeline.transcript(parts))
    }
}
