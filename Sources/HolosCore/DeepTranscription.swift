import Foundation

/// One stretch of a track for the deep transcriber (docs/meeting-design.md §4.16): 16 kHz mono Float32 samples, the
/// language to transcribe them in, and the vocabulary prompt given to every chunk.
public struct DeepTranscriptionRequest: Sendable {
    /// 16 kHz mono samples, -1...1.
    public var samples: [Float]
    /// The language as Whisper names it ("en", "fr"); nil lets the model detect it.
    public var language: String?
    /// The conditioning prompt (`DeepTranscriptionPrompt`); empty for none.
    public var prompt: String
    /// Where the recorded transcript has words in these samples: each word's start, in seconds from the samples'
    /// start (empty without a recorded transcript). Audio the transcriber's voice-activity chunking would leave out
    /// is decoded anyway where it has at least `recordedSpeechWords` of them.
    public var recordedWords: [Double]

    /// At least this many recorded words in a stretch make it speech: one the model leaves empty is lost speech, and
    /// one voice-activity chunking leaves out is decoded anyway.
    public static let recordedSpeechWords = 3

    public init(samples: [Float], language: String?, prompt: String, recordedWords: [Double] = []) {
        self.samples = samples; self.language = language; self.prompt = prompt; self.recordedWords = recordedWords
    }
}

/// One word the deep transcriber heard, in seconds from the start of the request's samples.
public struct DeepTranscribedWord: Sendable, Equatable {
    /// As the model wrote it, usually with its leading space (" Hello,").
    public var text: String
    public var start: Double
    public var end: Double
    public var probability: Double?

    public init(text: String, start: Double, end: Double, probability: Double? = nil) {
        self.text = text; self.start = start; self.end = end; self.probability = probability
    }
}

/// One segment the deep transcriber wrote, in seconds from the start of the request's samples.
public struct DeepTranscribedSegment: Sendable, Equatable {
    /// Without special tokens.
    public var text: String
    public var start: Double
    public var end: Double
    /// Empty when the model gave no word timings for it.
    public var words: [DeepTranscribedWord]
    /// Audible audio the model gave no words for, even decoded again in parts (`text` empty): the pass fails when the
    /// recorded transcript has words there, and accepts it where it has none (music, noise).
    public var unheard: Bool

    public init(text: String, start: Double, end: Double, words: [DeepTranscribedWord] = [], unheard: Bool = false) {
        self.text = text; self.start = start; self.end = end; self.words = words; self.unheard = unheard
    }
}

/// A local speech-to-text model run over saved audio after a meeting (docs/meeting-design.md §4.16). The command-line
/// tool's is WhisperKit's (`HolosWhisper`); tests pass fakes and never load a model.
public protocol DeepTranscriber: Sendable {
    /// What made the transcript, recorded in it (`Transcript.engine`): "whisper:<model>".
    var engine: String { get }
    /// How many prompt tokens `text` takes, so the prompt can be kept within the model's budget.
    func promptTokenCount(_ text: String) async throws -> Int
    /// Transcribes one stretch of audio. `progress` gets 0...1 of it, when known. Throws `CancellationError` when the
    /// task is cancelled.
    func transcribe(_ request: DeepTranscriptionRequest,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [DeepTranscribedSegment]
}

/// Whether the deep-transcription model is on this Mac (docs/meeting-design.md §4.16), from files only.
public enum DeepModelStatus: String, Codable, Sendable, Equatable {
    case notInstalled
    /// `voiceislocal setup --whisper` is downloading or checking it now.
    case downloading
    /// Downloaded and loaded once on this Mac by setup.
    case installed

    /// "not installed", "downloading", "installed".
    public var summary: String {
        switch self {
        case .notInstalled: "not installed"
        case .downloading: "downloading"
        case .installed: "installed"
        }
    }
}

/// The model deep transcription uses, and where it lives.
public enum DeepTranscriptionModel {
    /// The WhisperKit Core ML model (argmaxinc/whisperkit-coreml), about 1.6 GB.
    public static let name = "openai_whisper-large-v3-v20240930_turbo"
    /// The Hugging Face repository it comes from.
    public static let repository = "argmaxinc/whisperkit-coreml"
    /// About this many bytes are downloaded (1.63 GB in the repository's listing).
    public static let downloadBytes: Int64 = 1_630_000_000
    /// `Transcript.engine` of a transcript it made: "whisper:openai_whisper-large-v3-v20240930_turbo".
    public static let engine = engineName(name)
    /// The name people read: "Whisper large-v3 turbo".
    public static let displayName = "Whisper large-v3 turbo"
    /// What a deep transcription without the model says.
    public static let missingModelMessage = "The deep transcription model is not installed. Install it from "
        + "Settings, or run voiceislocal setup --whisper (about 1.6 GB)."

    /// "whisper:<model>".
    public static func engineName(_ model: String) -> String { "whisper:" + model }

    /// Whether `engine` (a `Transcript.engine`) names a Whisper model.
    public static func isWhisper(_ engine: String?) -> Bool { engine?.hasPrefix("whisper:") == true }

    /// `<supportRoot>/Models/whisperkit`, or `$HOLOS_WHISPER_MODELS_DIR` when it is set and not empty (a scratch
    /// folder for trying the model without the Application Support one).
    public static var root: URL { root(environment: ProcessInfo.processInfo.environment) }

    static func root(environment: [String: String]) -> URL {
        if let path = environment["HOLOS_WHISPER_MODELS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return HolosPaths.supportRoot(environment: environment)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("whisperkit", isDirectory: true)
    }

    /// `<root>/<model>`: the installed model.
    public static func directory(root: URL = root, model: String = name) -> URL {
        root.appendingPathComponent(model, isDirectory: true)
    }

    /// The Whisper language token of a locale: "en" for "en-CA", "fr" for "fr_CA", and Whisper's own spelling
    /// where it differs from the locale's ("no" for Norwegian Bokmål "nb", "tl" for Filipino "fil", "jw" for
    /// Javanese "jv", "he" for an old "iw"). Nil for a language Whisper does not know, which is then detected:
    /// WhisperKit would otherwise put the English token in place of a token it cannot find.
    public static func whisperLanguage(_ locale: String) -> String? {
        let identifier = locale.replacingOccurrences(of: "_", with: "-")
        guard let code = Locale(identifier: identifier).language.languageCode?.identifier.lowercased(),
              !code.isEmpty else { return nil }
        let token = whisperAliases[code] ?? code
        return whisperLanguages.contains(token) ? token : nil
    }

    /// Locale language codes Whisper spells otherwise.
    static let whisperAliases = ["nb": "no", "fil": "tl", "jv": "jw", "iw": "he", "in": "id", "ji": "yi",
                                 "zh-hant": "zh", "cmn": "zh"]

    /// Whisper's language tokens (WhisperKit 1.1.0's `Constants.languages`).
    static let whisperLanguages: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs", "cy", "da", "de",
        "el", "en", "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr",
        "ht", "hu", "hy", "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln",
        "lo", "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no",
        "oc", "pa", "pl", "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr",
        "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yi",
        "yo", "yue", "zh",
    ]
}
