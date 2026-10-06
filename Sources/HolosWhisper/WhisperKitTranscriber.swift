import CoreML
import Foundation
import HolosCore
import os
@preconcurrency import WhisperKit

/// `DeepTranscriber` over WhisperKit (docs/meeting-design.md §4.16): the installed Whisper model on the Neural Engine,
/// with the decoding settings measured for meetings: the meeting's language when it has one, the vocabulary prompt on
/// every chunk, voice-activity chunking, word timestamps, and WhisperKit's default temperature fallback and
/// compression-ratio and log-probability thresholds (which kept it out of the repetition loops whisper.cpp fell into),
/// but not its first-token log-probability check, which emptied whole chunks. A meeting in several languages has each
/// passage transcribed in the one of them the model hears in it (`WhisperLanguagePick`).
/// Loads only from the install folder; it never downloads. One transcription at a time: the stage calls it from one
/// task (hence `@unchecked Sendable` around WhisperKit's non-Sendable pipeline).
public final class WhisperKitTranscriber: DeepTranscriber, @unchecked Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "whisper")

    public let engine: String
    private let kit: WhisperKit
    /// Where the audio is cut into chunks: WhisperKit's voice-activity chunker (a fake one in the opt-in tests).
    var chunker: any AudioChunking = VADAudioChunker()

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
        // The meeting's languages to choose from, passage by passage: those WhisperKit has a token for, each once.
        var candidates: [String] = []
        for language in request.languages where Self.supportedLanguages.contains(language) {
            if !candidates.contains(language) { candidates.append(language) }
        }
        let chooses = candidates.count > 1
        // A language WhisperKit has no token for would be replaced by English: detected instead.
        let language = chooses ? nil : (request.choosesLanguages ? candidates.first : request.language)
            .flatMap { Self.supportedLanguages.contains($0) ? $0 : nil }
        let options = Self.decodingOptions(language: language, promptTokens: tokens)
        // WhisperKit's own VAD path drops a chunk whose decoding fails without a trace; chunked here instead (at most
        // `maxChunkSeconds` each), each chunk's result is seen, and a failed one is decoded again on its own.
        let maxSamples = Int(maxChunkSeconds * 16_000)
        let chunks = try await chunker.chunkAll(audioArray: request.samples, maxChunkLength: maxSamples,
                                                decodeOptions: options)
        // Audio the chunking left out is decoded too where the recorded transcript heard speech in it.
        let ranges = Self.plan(chunks: chunks.map { $0.seekOffsetIndex..<($0.seekOffsetIndex + $0.audioSamples.count) },
                               total: request.samples.count, recordedWords: request.recordedWords,
                               maxSamples: maxSamples)
        // Each stretch in its language: the request's, or, choosing, each passage's.
        let stretches: [(range: Range<Int>, language: String?)] = chooses
            ? try await languageRuns(ranges, samples: request.samples, languages: candidates)
            : ranges.map { ($0, language) }
        let recordedSamples = request.recordedWords.map { Int(($0 * 16_000).rounded(.down)) }
        var decoded: [Decoded] = []
        // Decoded language by language (the decoding settings name it), in the order the languages are listed.
        var order: [String?] = []
        for stretch in stretches where !order.contains(stretch.language) { order.append(stretch.language) }
        for stretchLanguage in order {
            let options = Self.decodingOptions(language: stretchLanguage, promptTokens: tokens)
            var plainOptions: DecodingOptions?
            if tokens != nil {
                plainOptions = options
                plainOptions?.promptTokens = nil
            }
            let spans = stretches.filter { $0.language == stretchLanguage }.map { stretch in
                Span(offset: stretch.range.lowerBound, samples: Array(request.samples[stretch.range]),
                     recordedWords: recordedSamples.filter { stretch.range.contains($0) }.count)
            }
            decoded += try await decodeChosen(spans, options: options, plain: plainOptions, depth: 0,
                                              recordedSamples: recordedSamples).map { span in
                var span = span
                span.language = chooses ? stretchLanguage : nil
                return span
            }
        }
        decoded.sort { $0.offset < $1.offset }
        chunkCount += stretches.count
        // Audible stretches the model gave no words for, even in halves: reported, for the pass to judge against the
        // recorded transcript (speech it would leave out, or music and noise).
        var segments: [DeepTranscribedSegment] = decoded.filter(\.unheard).map { span in
            DeepTranscribedSegment(text: "", start: Double(span.offset) / 16_000,
                                   end: Double(span.offset + span.count) / 16_000, unheard: true)
        }
        guard let tokenizer = kit.tokenizer else { throw HolosError.unavailable("The model's tokenizer is not loaded.") }
        let special = tokenizer.specialTokens.specialTokenBegin
        for span in decoded {
            let seconds = Float(span.offset) / Float(WhisperKit.sampleRate)
            for result in span.results {
                for segment in result.segments {
                    let segment = TranscriptionUtilities.updateSegmentTimings(segment: segment, seekTime: seconds)
                    let words = (segment.words ?? []).compactMap { word -> DeepTranscribedWord? in
                        guard word.tokens.contains(where: { $0 < special }), !Self.isSpecial(word.word) else {
                            return nil
                        }
                        return DeepTranscribedWord(text: word.word, start: Double(word.start), end: Double(word.end),
                                                   probability: Double(word.probability))
                    }
                    let text = Self.withoutSpecialTokens(segment.text)
                    segments.append(DeepTranscribedSegment(text: text, start: Double(segment.start),
                                                           end: Double(segment.end), words: words,
                                                           language: span.language))
                }
            }
        }
        progress(1)
        return segments.sorted { $0.start < $1.start }
    }

    /// Chunks decoded without their prompt's result, because the prompted one had fewer than `promptedShare` of its
    /// words, chunks decoded, and chunks decoded again in halves after they gave no words, since the transcriber was
    /// loaded (for the log and the opt-in probes).
    private(set) var fallbacks = 0
    private(set) var chunkCount = 0
    private(set) var splits = 0

    /// Each chunk decoded with a prompt since the transcriber was loaded: where it starts in its piece, its length, the
    /// words of both decodes, and which was kept (for the opt-in probe).
    struct ChunkDecision: Sendable, Equatable {
        var start: Double
        var seconds: Double
        var promptedWords: Int
        var plainWords: Int
        var keptPlain: Bool
    }

    private(set) var chunkLog: [ChunkDecision] = []

    /// Each passage whose language was chosen since the transcriber was loaded: where it starts in its piece, its
    /// length, the probability of each of the meeting's languages, and the one chosen (for the opt-in evaluation).
    struct LanguageDecision: Sendable, Equatable {
        var start: Double
        var seconds: Double
        var probabilities: [String: Double]
        var language: String
    }

    private(set) var languageLog: [LanguageDecision] = []
    /// Passages halved because their language was unsure, since the transcriber was loaded.
    private(set) var languageSplits = 0

    /// The stretches to decode of a request in several `languages` (Whisper's names, the preferred one first): each of
    /// `ranges` cut into passages at its pauses (`WhisperLanguagePick.passages`), each passage's language chosen among
    /// `languages` by the model's language detection (an unsure one halved and each half chosen on its own), and
    /// adjacent passages in one language joined again, within each range only (`runs(byStretch:)`): a run is never
    /// longer than the range it lies in.
    private func languageRuns(_ ranges: [Range<Int>], samples: [Float],
                              languages: [String]) async throws -> [(range: Range<Int>, language: String?)] {
        let frame = Int(WhisperLanguagePick.frameSeconds * 16_000)
        var stretches: [[(range: Range<Int>, language: String)]] = []
        for range in ranges {
            var passages: [(range: Range<Int>, language: String)] = []
            let stretch = Array(samples[range])
            let levels = WhisperLanguagePick.levels(stretch, frameSamples: frame)
            let activity = WhisperLanguagePick.activity(levels: levels)
            // In time order; an unsure passage is replaced by its halves, which are chosen next.
            var pending = WhisperLanguagePick.passages(activity: activity, frameSamples: frame, total: stretch.count)
                .map { (passage: $0, depth: 0) }
            while !pending.isEmpty {
                try Task.checkCancellation()
                let (passage, depth) = pending.removeFirst()
                let probabilities = WhisperLanguagePick.probabilities(
                    logits: try await languageLogits(Array(stretch[passage.range]), languages: languages))
                let language = WhisperLanguagePick.choice(probabilities, languages: languages) ?? languages[0]
                if (probabilities[language] ?? 0) < WhisperLanguagePick.confidentProbability,
                   depth < WhisperLanguagePick.maximumSplitDepth,
                   let halves = WhisperLanguagePick.halves(passage, activity: activity, levels: levels,
                                                           frameSamples: frame) {
                    languageSplits += 1
                    pending.insert(contentsOf: [(halves.0, depth + 1), (halves.1, depth + 1)], at: 0)
                    continue
                }
                let offset = range.lowerBound
                languageLog.append(LanguageDecision(start: Double(offset + passage.range.lowerBound) / 16_000,
                                                    seconds: Double(passage.range.count) / 16_000,
                                                    probabilities: probabilities, language: language))
                passages.append(((offset + passage.range.lowerBound)..<(offset + passage.range.upperBound), language))
            }
            stretches.append(passages)
        }
        return WhisperLanguagePick.runs(byStretch: stretches).map { ($0.range, $0.language) }
    }

    /// The model's language-detection logits for `samples` (its first 30 s), for each of `languages` (Whisper's
    /// names): the start-of-transcript step WhisperKit's `detectLangauge` takes, whose result keeps only the language
    /// it samples, read here for every language asked for.
    private func languageLogits(_ samples: [Float], languages: [String]) async throws -> [String: Float] {
        guard let tokenizer = kit.tokenizer else {
            throw HolosError.unavailable("The model's tokenizer is not loaded.")
        }
        guard kit.textDecoder.isModelMultilingual else {
            throw HolosError.unavailable("The deep transcription model cannot tell languages apart.")
        }
        var tokens: [String: Int] = [:]
        for language in languages {
            if let token = tokenizer.convertTokenToId("<|\(language)|>") { tokens[language] = token }
        }
        let window = kit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        guard let audio = kit.audioProcessor.padOrTrim(fromArray: samples.isEmpty ? [0] : samples, startAt: 0,
                                                        toLength: window),
              let mel = try await kit.featureExtractor.logMelSpectrogram(fromAudio: audio),
              let encoded = try await kit.audioEncoder.encodeFeatures(mel) else {
            throw HolosError.unavailable("The deep transcription model could not detect a passage's language.")
        }
        let inputs = try kit.textDecoder.prepareDecoderInputs(
            withPrompt: [tokenizer.specialTokens.startOfTranscriptToken])
        let reader = LanguageLogitsReader(tokens: tokens, eotToken: tokenizer.specialTokens.endToken)
        _ = try await kit.textDecoder.detectLanguage(from: encoded, using: inputs, sampler: reader,
                                                     options: DecodingOptions(verbose: false), temperature: 0)
        return reader.logits
    }

    /// The longest chunk given to the model. Whisper's window is 30 s, but WhisperKit's decoder holds 224 tokens in
    /// all, the prompt's included: a prompt of 110 tokens leaves room for about 80 words, which 30 s of fast speech
    /// exceeds, and such a chunk came back empty (§4.16). 20 s chunks leave room for the words of fast speech.
    let maxChunkSeconds = 20.0

    /// A chunk that gave no words though its audio is not near-silent is decoded again in two halves, split at its
    /// quietest moment, down to this length and at most `maximumSplitDepth` times.
    static let minimumSplitSeconds = 4.0
    static let maximumSplitDepth = 2
    /// Near-silence, as the deep transcription guards measure it (dBFS).
    static let silenceDB = -50.0

    /// A prompted chunk is kept when it has at least this share of the words the same chunk has without the prompt.
    static let promptedShare = 0.85

    /// Whether a chunk keeps its result without the prompt: the prompted one has fewer than `promptedShare` of its
    /// words.
    static func keepsPlain(prompted: Int, plain: Int) -> Bool {
        Double(prompted) < promptedShare * Double(plain)
    }

    /// The words of a decode: a segment's timed words, or its text's words when it has no timings.
    static func wordCount(_ results: [TranscriptionResult]) -> Int {
        results.reduce(0) { total, result in
            total + result.segments.reduce(0) { count, segment in
                let timed = segment.words?.count ?? 0
                return count + (timed > 0 ? timed : withoutSpecialTokens(segment.text).split(separator: " ").count)
            }
        }
    }

    /// The decoding settings of every chunk: `language` (nil: detected), the prompt, timestamps and word timestamps,
    /// WhisperKit's default temperature fallback and compression-ratio, log-probability and no-speech thresholds, and
    /// no first-token check: WhisperKit's (not in Whisper itself) sent whole chunks of speech through every fallback
    /// temperature to an empty result, most often with a prompt (on ten minutes of a call, 12 of about 40 chunks).
    static func decodingOptions(language: String?, promptTokens: [Int]?) -> DecodingOptions {
        DecodingOptions(
            verbose: false, task: .transcribe, language: language, usePrefillPrompt: true,
            detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: false,
            wordTimestamps: true, promptTokens: promptTokens, firstTokenLogProbThreshold: nil,
            chunkingStrategy: .vad)
    }

    /// WhisperKit's language tokens.
    static var supportedLanguages: Set<String> { Constants.languageCodes }

    /// A stretch decoded: where it starts and how long it is (in samples), what was kept, and whether it is audible
    /// audio that gave no words.
    private struct Decoded {
        var offset: Int
        var count: Int
        var results: [TranscriptionResult]
        var unheard: Bool
        /// The language it was decoded in, when chosen passage by passage.
        var language: String?
    }

    /// A stretch of the request's samples, `offset` samples from its start, with how many recorded words start in it.
    private struct Span {
        var offset: Int
        var samples: [Float]
        var recordedWords = 0
    }

    /// The stretches of a request's `total` samples to decode: the chunker's `chunks`, each stretch they leave out
    /// that is shorter than a second joined to the chunk before it (else after it), and each longer one where the
    /// recorded transcript has at least `DeepTranscriptionRequest.recordedSpeechWords` words (`recordedWords`, in
    /// seconds) decoded too, in pieces of at most `maxSamples`, those with a recorded word kept: speech the chunking
    /// would leave out without a trace (WhisperKit's chunker stops a second before the end, and another could skip
    /// what its voice-activity detection takes for silence). The rest of what it leaves out has no recorded speech.
    static func plan(chunks: [Range<Int>], total: Int, recordedWords: [Double], maxSamples: Int) -> [Range<Int>] {
        let sorted = chunks.map { $0.clamped(to: 0..<max(0, total)) }.filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard total > 0 else { return [] }
        let starts = recordedWords.map { Int(($0 * 16_000).rounded(.down)) }
        let joinSamples = 16_000
        var out: [Range<Int>] = []
        var position = 0
        func uncovered(_ gap: Range<Int>, before next: Range<Int>?) -> Range<Int>? {
            guard !gap.isEmpty else { return nil }
            if gap.count < joinSamples {
                if let last = out.last, last.upperBound == gap.lowerBound {
                    out[out.count - 1] = last.lowerBound..<gap.upperBound
                    return nil
                }
                if let next, next.lowerBound == gap.upperBound { return gap.lowerBound..<next.upperBound }
            }
            let inside = starts.filter { gap.contains($0) }
            if inside.count >= DeepTranscriptionRequest.recordedSpeechWords {
                let pieces = (gap.count + max(1, maxSamples) - 1) / max(1, maxSamples)
                let length = (gap.count + pieces - 1) / pieces
                var start = gap.lowerBound
                while start < gap.upperBound {
                    let piece = start..<min(gap.upperBound, start + length)
                    if inside.contains(where: { piece.contains($0) }) { out.append(piece) }
                    start = piece.upperBound
                }
            }
            return nil
        }
        for chunk in sorted where chunk.upperBound > position {
            let chunk = max(chunk.lowerBound, position)..<chunk.upperBound
            let joined = uncovered(position..<chunk.lowerBound, before: chunk)
            out.append(joined ?? chunk)
            position = chunk.upperBound
        }
        _ = uncovered(position..<total, before: nil)
        return out
    }

    /// Whether a decoded stretch is audible audio the model gave no words for: no words, and its audio is not
    /// near-silent or the recorded transcript has a word in it.
    static func isUnheard(words: Int, levelDB: Double, recordedWords: Int) -> Bool {
        words == 0 && (levelDB > silenceDB || recordedWords > 0)
    }

    /// `spans` decoded with the prompt and (with `plain`) without it, the better kept per span (`keepsPlain`); a span
    /// that gave no words in either though its audio is not near-silent (`needsSplit`) is decoded again in halves.
    private func decodeChosen(_ spans: [Span], options: DecodingOptions, plain: DecodingOptions?,
                              depth: Int, recordedSamples: [Int]) async throws -> [Decoded] {
        guard !spans.isEmpty else { return [] }
        var chosen = try await decode(spans.map(\.samples), offsets: spans.map(\.offset), options: options)
        var plainResults: [[TranscriptionResult]]?
        if let plain {
            plainResults = try await decode(spans.map(\.samples), offsets: spans.map(\.offset), options: plain)
        }
        var out: [Decoded] = []
        for index in spans.indices {
            if let plainResults {
                let promptedWords = Self.wordCount(chosen[index]), plainWords = Self.wordCount(plainResults[index])
                let keepsPlain = Self.keepsPlain(prompted: promptedWords, plain: plainWords)
                chunkLog.append(ChunkDecision(start: Double(spans[index].offset) / 16_000,
                                              seconds: Double(spans[index].samples.count) / 16_000,
                                              promptedWords: promptedWords, plainWords: plainWords,
                                              keptPlain: keepsPlain))
                if keepsPlain {
                    chosen[index] = plainResults[index]
                    fallbacks += 1
                }
            }
            let span = spans[index]
            let words = Self.wordCount(chosen[index])
            let level = Self.levelDB(span.samples)
            if Self.needsSplit(words: words, seconds: Double(span.samples.count) / 16_000, levelDB: level,
                               depth: depth, recordedWords: span.recordedWords) {
                splits += 1
                let cut = Self.quietestCut(span.samples)
                let halves = [span.offset..<(span.offset + cut), (span.offset + cut)..<(span.offset + span.samples.count)]
                    .map { range in
                        Span(offset: range.lowerBound, samples: Array(span.samples[(range.lowerBound - span.offset)...]
                                .prefix(range.count)),
                             recordedWords: recordedSamples.filter { range.contains($0) }.count)
                    }
                out += try await decodeChosen(halves, options: options, plain: plain, depth: depth + 1,
                                              recordedSamples: recordedSamples)
            } else {
                out.append(Decoded(offset: span.offset, count: span.samples.count, results: chosen[index],
                                   unheard: Self.isUnheard(words: words, levelDB: level,
                                                           recordedWords: span.recordedWords)))
            }
        }
        if depth == 0 {
            Self.log.info("Deep transcription: \(self.fallbacks, privacy: .public) chunks kept without the prompt, \(self.splits, privacy: .public) decoded again in halves")
        }
        return out
    }

    /// Whether a chunk is decoded again in halves: it gave no words, its audio is not near-silent or the recorded
    /// transcript has a word in it, it is long enough to halve, and it was not halved too often already.
    static func needsSplit(words: Int, seconds: Double, levelDB: Double, depth: Int, recordedWords: Int = 0) -> Bool {
        isUnheard(words: words, levelDB: levelDB, recordedWords: recordedWords) && seconds >= 2 * minimumSplitSeconds
            && depth < maximumSplitDepth
    }

    /// RMS level of `samples` in dBFS (-120 for silence).
    static func levelDB(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }

    /// Where to halve `samples`: the middle of the quietest 100 ms in their middle half.
    static func quietestCut(_ samples: [Float]) -> Int {
        let frame = 1_600
        let lower = samples.count / 4, upper = samples.count * 3 / 4
        guard upper - lower >= frame else { return samples.count / 2 }
        var best = (energy: Double.infinity, start: lower)
        var start = lower
        while start + frame <= upper {
            var energy = 0.0
            for index in start..<(start + frame) { energy += Double(samples[index] * samples[index]) }
            if energy < best.energy { best = (energy, start) }
            start += frame
        }
        return best.start + frame / 2
    }

    /// Each chunk decoded with `options` (one window each); a chunk whose decoding fails is decoded again on its own,
    /// and one that fails again is empty (logged).
    private func decode(_ chunks: [[Float]], offsets: [Int], options: DecodingOptions) async throws
        -> [[TranscriptionResult]] {
        var single = options
        single.chunkingStrategy = nil
        single.clipTimestamps = []
        let stop: TranscriptionCallback = { _ in Task.isCancelled ? false : nil }
        var outcomes = await kit.transcribeWithOptions(audioArrays: chunks,
                                                       decodeOptionsArray: Array(repeating: single, count: chunks.count),
                                                       callback: stop)
        try Task.checkCancellation()
        for index in outcomes.indices {
            guard case .failure = outcomes[index] else { continue }
            outcomes[index] = await Result {
                try await kit.transcribe(audioArray: chunks[index], decodeOptions: single, callback: stop)
            }
            try Task.checkCancellation()
        }
        for (index, outcome) in outcomes.enumerated() {
            if case .failure(let error) = outcome {
                Self.log.error("Deep transcription: a chunk at \(offsets[index] / WhisperKit.sampleRate, privacy: .public) s could not be decoded: \(String(describing: error), privacy: .public)")
            }
        }
        return try Self.requireAll(outcomes, startSeconds: offsets.map { Double($0) / Double(WhisperKit.sampleRate) })
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

/// A token sampler for WhisperKit's language-detection step that keeps the logits of the language tokens asked for,
/// then samples as WhisperKit does (greedy).
private final class LanguageLogitsReader: TokenSampling {
    private let tokens: [String: Int]
    private let greedy: GreedyTokenSampler
    private(set) var logits: [String: Float] = [:]

    init(tokens: [String: Int], eotToken: Int) {
        self.tokens = tokens
        greedy = GreedyTokenSampler(temperature: 0, eotToken: eotToken,
                                    decodingOptions: DecodingOptions(verbose: false))
    }

    func update(tokens current: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        let size = logits.count
        for (language, token) in tokens where token >= 0 && token < size {
            self.logits[language] = logits[[0, 0, NSNumber(value: token)]].floatValue
        }
        return await greedy.update(tokens: current, logits: logits, logProbs: logProbs)
    }

    func finalize(tokens current: [Int], logProbs: [Float]) -> SamplingResult {
        greedy.finalize(tokens: current, logProbs: logProbs)
    }
}
