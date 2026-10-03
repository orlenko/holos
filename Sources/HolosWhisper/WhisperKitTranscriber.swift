import Foundation
import HolosCore
import os
@preconcurrency import WhisperKit

/// `DeepTranscriber` over WhisperKit (docs/meeting-design.md §4.16): the installed Whisper model on the Neural Engine,
/// with the decoding settings measured for meetings: the meeting's language when it has one, the vocabulary prompt on
/// every chunk, voice-activity chunking, word timestamps, and WhisperKit's default temperature fallback and
/// compression-ratio and log-probability thresholds (which kept it out of the repetition loops whisper.cpp fell into).
/// Loads only from the install folder; it never downloads. One transcription at a time: the stage calls it from one
/// task (hence `@unchecked Sendable` around WhisperKit's non-Sendable pipeline).
public final class WhisperKitTranscriber: DeepTranscriber, @unchecked Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "whisper")

    public let engine: String
    private let kit: WhisperKit

    private init(kit: WhisperKit, model: String) {
        self.kit = kit
        engine = DeepTranscriptionModel.engineName(model)
    }

    /// Loads the installed model (the first load on a Mac, or after an OS update, can take minutes while Core ML
    /// specializes it). Throws `unavailable` with the setup hint when it is not installed.
    public static func load(root: URL = DeepTranscriptionModel.root,
                            model: String = DeepTranscriptionModel.name) async throws -> WhisperKitTranscriber {
        guard WhisperModels.status(root: root, model: model) == .installed else {
            throw HolosError.unavailable(WhisperModels.missingModelMessage)
        }
        let directory = DeepTranscriptionModel.directory(root: root, model: model)
        do {
            let kit = try await WhisperKit(WhisperKitConfig(
                model: model, modelFolder: WhisperModels.modelFolder(in: directory, model: model).path,
                tokenizerFolder: directory, segmentSeeker: PromptAlignedSegmentSeeker(), verbose: false,
                logLevel: .none, prewarm: false, load: true,
                download: false))
            guard let tokenizer = kit.tokenizer else { throw HolosError.unavailable("its tokenizer did not load") }
            kit.textDecoder.logitsFilters = [PromptTimestampRulesFilter(specialTokens: tokenizer.specialTokens)]
            return WhisperKitTranscriber(kit: kit, model: model)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw HolosError.unavailable("The deep transcription model could not be loaded "
                + "(\(error.localizedDescription)). Run voiceislocal setup --whisper --force to install it again.")
        }
    }

    public func promptTokenCount(_ text: String) async throws -> Int {
        try promptTokens(text).count
    }

    public func transcribe(_ request: DeepTranscriptionRequest,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [DeepTranscribedSegment] {
        try Task.checkCancellation()
        guard !request.samples.isEmpty else { return [] }
        let tokens = request.prompt.isEmpty ? nil : try promptTokens(request.prompt)
        let options = DecodingOptions(
            verbose: false, task: .transcribe, language: request.language, usePrefillPrompt: true,
            detectLanguage: request.language == nil, skipSpecialTokens: true, withoutTimestamps: false,
            wordTimestamps: true, promptTokens: tokens, chunkingStrategy: .vad)
        // WhisperKit's own VAD path drops a chunk whose decoding fails without a trace; chunked here instead, each
        // chunk's result is seen, and a failed one is decoded again on its own.
        let window = kit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        let chunks = try await VADAudioChunker().chunkAll(audioArray: request.samples, maxChunkLength: window,
                                                          decodeOptions: options)
        var prompted = try await decode(chunks, options: options)
        // A prompt can make the model stop early in a chunk and leave speech out (§4.16). Each chunk is decoded without
        // it too, and keeps the prompted result only when that has at least `promptedShare` of the plain one's words.
        if tokens != nil {
            var plainOptions = options
            plainOptions.promptTokens = nil
            let plain = try await decode(chunks, options: plainOptions)
            var replaced = 0
            for index in prompted.indices where Self.keepsPlain(prompted: Self.wordCount(prompted[index]),
                                                                plain: Self.wordCount(plain[index])) {
                prompted[index] = plain[index]
                replaced += 1
            }
            fallbacks += replaced
            Self.log.info("Deep transcription: \(replaced, privacy: .public) of \(chunks.count, privacy: .public) chunks kept without the prompt")
        }
        chunkCount += chunks.count
        let results: [TranscriptionResult] = prompted.enumerated().flatMap { index, found -> [TranscriptionResult] in
            let seconds = Float(chunks[index].seekOffsetIndex) / Float(WhisperKit.sampleRate)
            for result in found {
                result.segments = result.segments.map {
                    TranscriptionUtilities.updateSegmentTimings(segment: $0, seekTime: seconds)
                }
            }
            return found
        }
        guard let tokenizer = kit.tokenizer else { throw HolosError.unavailable("The model's tokenizer is not loaded.") }
        let special = tokenizer.specialTokens.specialTokenBegin
        var segments: [DeepTranscribedSegment] = []
        for result in results {
            for segment in result.segments {
                let words = (segment.words ?? []).compactMap { word -> DeepTranscribedWord? in
                    guard word.tokens.contains(where: { $0 < special }), !Self.isSpecial(word.word) else { return nil }
                    return DeepTranscribedWord(text: word.word, start: Double(word.start), end: Double(word.end),
                                               probability: Double(word.probability))
                }
                let text = Self.withoutSpecialTokens(segment.text)
                segments.append(DeepTranscribedSegment(text: text, start: Double(segment.start),
                                                       end: Double(segment.end), words: words))
            }
        }
        progress(1)
        return segments.sorted { $0.start < $1.start }
    }

    /// Chunks decoded without their prompt's result, because the prompted one had fewer than `promptedShare` of its
    /// words, and chunks decoded, since the transcriber was loaded (for the log and the opt-in probe).
    private(set) var fallbacks = 0
    private(set) var chunkCount = 0

    /// A prompted chunk is kept when it has at least this share of the words the same chunk has without the prompt.
    static let promptedShare = 0.85

    /// Whether a chunk keeps its result without the prompt: the prompted one has fewer than `promptedShare` of its
    /// words.
    static func keepsPlain(prompted: Int, plain: Int) -> Bool {
        Double(prompted) < promptedShare * Double(plain)
    }

    private static func wordCount(_ results: [TranscriptionResult]) -> Int {
        results.reduce(0) { total, result in
            total + result.segments.reduce(0) { $0 + ($1.words?.count ?? $1.text.split(separator: " ").count) }
        }
    }

    /// Each chunk decoded with `options` (one window each); a chunk whose decoding fails is decoded again on its own,
    /// and one that fails again is empty (logged).
    private func decode(_ chunks: [AudioChunk], options: DecodingOptions) async throws -> [[TranscriptionResult]] {
        var single = options
        single.chunkingStrategy = nil
        single.clipTimestamps = []
        let stop: TranscriptionCallback = { _ in Task.isCancelled ? false : nil }
        var outcomes = await kit.transcribeWithOptions(audioArrays: chunks.map(\.audioSamples),
                                                       decodeOptionsArray: Array(repeating: single, count: chunks.count),
                                                       callback: stop)
        try Task.checkCancellation()
        for index in outcomes.indices {
            guard case .failure = outcomes[index] else { continue }
            outcomes[index] = await Result {
                try await kit.transcribe(audioArray: chunks[index].audioSamples, decodeOptions: single, callback: stop)
            }
            try Task.checkCancellation()
        }
        for (index, outcome) in outcomes.enumerated() {
            if case .failure(let error) = outcome {
                Self.log.error("Deep transcription: a chunk at \(chunks[index].seekOffsetIndex / WhisperKit.sampleRate, privacy: .public) s could not be decoded: \(String(describing: error), privacy: .public)")
            }
        }
        return try Self.requireAll(outcomes, startSeconds: chunks.map {
            Double($0.seekOffsetIndex) / Double(WhisperKit.sampleRate)
        })
    }

    /// Every chunk's results; throws `incomplete` naming the chunks that could not be decoded (also on their own), so a
    /// pass never publishes a transcript that leaves audio out without saying so.
    static func requireAll<T>(_ outcomes: [Result<T, any Error>], startSeconds: [Double]) throws -> [T] {
        var results: [T] = []
        var failed: [Int] = []
        for (index, outcome) in outcomes.enumerated() {
            switch outcome {
            case .success(let value): results.append(value)
            case .failure: failed.append(index)
            }
        }
        guard failed.isEmpty else {
            let starts = failed.map { index in
                index < startSeconds.count ? "\(Int(startSeconds[index].rounded())) s" : "?"
            }
            let what = failed.count == 1 ? "1 stretch of audio" : "\(failed.count) stretches of audio"
            throw HolosError.incomplete("\(what) (from \(starts.joined(separator: ", "))) could not be transcribed, "
                + "so the transcript would leave it out.")
        }
        return results
    }

    /// The prompt's tokens as the decoder takes them: a leading space (as Whisper's own previous-text context has),
    /// special tokens left out.
    private func promptTokens(_ text: String) throws -> [Int] {
        guard let tokenizer = kit.tokenizer else { throw HolosError.unavailable("The model's tokenizer is not loaded.") }
        let special = tokenizer.specialTokens.specialTokenBegin
        return tokenizer.encode(text: " " + text.trimmingCharacters(in: .whitespacesAndNewlines))
            .filter { $0 < special }
    }

    private static func isSpecial(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("<|") && trimmed.hasSuffix("|>")
    }

    /// `text` with any "<|…|>" token removed and whitespace trimmed.
    static func withoutSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
