import CoreML
import Foundation
import Synchronization
import Testing
@testable import HolosCore
@testable import HolosWhisper
@preconcurrency import WhisperKit

/// Model status and install with a fake download and load check: no network, no model.
@Suite struct WhisperModelsTests {
    private let model = "openai_whisper-test"

    @Test func statusIsNotInstalledUntilTheMarkerAndFilesArePresent() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WhisperModels.status(root: root, model: model) == .notInstalled)
        let directory = DeepTranscriptionModel.directory(root: root, model: model)
        try writeFakeModel(in: directory)
        // Files without the marker: an install that did not finish.
        #expect(WhisperModels.status(root: root, model: model) == .notInstalled)
        try writeMarker(in: directory, model: model)
        #expect(WhisperModels.status(root: root, model: model) == .installed)
        // Another model's marker does not count.
        try writeMarker(in: directory, model: "another")
        #expect(WhisperModels.status(root: root, model: model) == .notInstalled)
        try writeMarker(in: directory, model: model)
        // A missing tokenizer makes it unusable offline.
        try FileManager.default.removeItem(at: WhisperModels.tokenizerFolder(in: directory)
            .appendingPathComponent("tokenizer.json"))
        #expect(WhisperModels.status(root: root, model: model) == .notInstalled)
    }

    @Test func setUpDownloadsIntoStagingChecksAndPublishes() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let notices = Mutex<[String]>([])
        let checked = Mutex<[URL]>([])
        let last = Mutex<Double>(0)
        try await WhisperModels.setUp(
            root: root, model: model, force: false,
            download: { staging, model, progress in
                #expect(staging.lastPathComponent == model + ".download")
                try self.writeFakeModel(in: staging)
                progress(1)
                return WhisperModels.modelFolder(in: staging, model: model)
            },
            check: { folder, tokenizerBase in
                checked.withLock { $0.append(folder) }
                #expect(FileManager.default.fileExists(atPath: WhisperModels.tokenizerFolder(in: tokenizerBase)
                    .appendingPathComponent("tokenizer.json").path))
            },
            notice: { line in notices.withLock { $0.append(line) } },
            progress: { value in last.withLock { $0 = value } })
        #expect(WhisperModels.status(root: root, model: model) == .installed)
        #expect(checked.withLock { $0.count } == 1)
        #expect(last.withLock { $0 } == 1)
        #expect(!FileManager.default.fileExists(atPath: WhisperModels.stagingFolder(root: root, model: model).path))
        #expect(notices.withLock { $0.first?.hasPrefix("Downloading") } == true)

        // Installed: kept without downloading, unless forced.
        try await WhisperModels.setUp(root: root, model: model, force: false,
                                      download: { _, _, _ in Issue.record("downloaded again"); return root },
                                      check: { _, _ in }, notice: { _ in }, progress: { _ in })
        try await WhisperModels.setUp(
            root: root, model: model, force: true,
            download: { staging, model, _ in
                try self.writeFakeModel(in: staging)
                return WhisperModels.modelFolder(in: staging, model: model)
            },
            check: { _, _ in }, notice: { _ in }, progress: { _ in })
        #expect(WhisperModels.status(root: root, model: model) == .installed)
        #expect(!FileManager.default.fileExists(atPath: WhisperModels.stagingFolder(root: root, model: model).path))
    }

    @Test func aFailedLoadLeavesTheDownloadToResumeAndNothingInstalled() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: HolosError.self) {
            try await WhisperModels.setUp(
                root: root, model: model, force: false,
                download: { staging, model, _ in
                    try self.writeFakeModel(in: staging)
                    return WhisperModels.modelFolder(in: staging, model: model)
                },
                check: { _, _ in throw HolosError.unavailable("cannot load") }, notice: { _ in }, progress: { _ in })
        }
        #expect(WhisperModels.status(root: root, model: model) == .notInstalled)
        // The staging folder stays, so the next setup resumes it.
        let staging = WhisperModels.stagingFolder(root: root, model: model)
        #expect(FileManager.default.fileExists(atPath: staging.path))
        let resumed = Mutex<Bool>(false)
        try await WhisperModels.setUp(
            root: root, model: model, force: false,
            download: { staging, model, _ in
                resumed.withLock { $0 = FileManager.default.fileExists(atPath: WhisperModels.modelFolder(
                    in: staging, model: model).appendingPathComponent("AudioEncoder.mlmodelc").path) }
                return WhisperModels.modelFolder(in: staging, model: model)
            },
            check: { _, _ in }, notice: { _ in }, progress: { _ in })
        #expect(resumed.withLock { $0 })
        #expect(WhisperModels.status(root: root, model: model) == .installed)
    }

    @Test func aForcedSetupDownloadsAgainFromScratch() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        // An earlier download left files behind (maybe damaged ones the downloader would keep).
        let staging = WhisperModels.stagingFolder(root: root, model: model)
        try writeFakeModel(in: staging)
        let leftover = Mutex<Bool>(true)
        let notices = Mutex<[String]>([])
        try await WhisperModels.setUp(
            root: root, model: model, force: true,
            download: { staging, model, _ in
                leftover.withLock { $0 = FileManager.default.fileExists(atPath: WhisperModels.modelFolder(
                    in: staging, model: model).appendingPathComponent("AudioEncoder.mlmodelc").path) }
                try self.writeFakeModel(in: staging)
                return WhisperModels.modelFolder(in: staging, model: model)
            },
            check: { _, _ in }, notice: { line in notices.withLock { $0.append(line) } }, progress: { _ in })
        #expect(!leftover.withLock { $0 }, "--force starts from an empty folder.")
        #expect(notices.withLock { $0 }.first?.hasPrefix("Downloading") == true)
        #expect(WhisperModels.status(root: root, model: model) == .installed)
    }

    @Test func removeDeletesTheInstallAndTheDownload() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = DeepTranscriptionModel.directory(root: root, model: model)
        try writeFakeModel(in: directory)
        try writeMarker(in: directory, model: model)
        try writeFakeModel(in: WhisperModels.stagingFolder(root: root, model: model))
        try WhisperModels.remove(root: root, model: model)
        #expect(WhisperModels.status(root: root, model: model) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: WhisperModels.stagingFolder(root: root, model: model).path))
    }

    @Test func specialTokensAreRemovedFromSegmentText() {
        #expect(WhisperKitTranscriber.withoutSpecialTokens("<|startoftranscript|><|en|> Hello there.<|endoftext|>")
            == "Hello there.")
        #expect(WhisperKitTranscriber.withoutSpecialTokens("  plain  ") == "plain")
    }

    @Test func promptRowsAreSkippedBeforeWordsAreAligned() throws {
        let special = 50_257
        #expect(PromptAlignedSegmentSeeker.promptRows(nil, specialTokenBegin: special) == 0)
        #expect(PromptAlignedSegmentSeeker.promptRows([], specialTokenBegin: special) == 0)
        #expect(PromptAlignedSegmentSeeker.promptRows([1, 2, 3, special + 5], specialTokenBegin: special) == 4)
        #expect(PromptAlignedSegmentSeeker.promptRows(Array(repeating: 7, count: 400), specialTokenBegin: special)
            == 112, "WhisperKit keeps the last 111 prompt tokens, after <|startofprev|>.")

        let weights = try MLMultiArray(shape: [4, 3], dataType: .float32)
        for index in 0..<12 { weights[index] = NSNumber(value: Float(index)) }
        let moved = try PromptAlignedSegmentSeeker.shifted(weights, by: 2)
        #expect((0..<12).map { moved[$0].floatValue } == [6, 7, 8, 9, 10, 11, 0, 0, 0, 0, 0, 0])
    }

    @Test func timestampRulesFindTheTaskTokenAfterAPrompt() {
        let transcribe = 50_360, translate = 50_359
        // Without a prompt WhisperKit's own filter applies.
        #expect(PromptTimestampRulesFilter.sampleBegin([50_258, 50_259, transcribe, 50_365], transcribe: transcribe,
                                                       translate: translate) == nil)
        // <|startofprev|>, two prompt tokens, <|startoftranscript|>, <|en|>, <|transcribe|>, <|0.00|>, then text.
        let prompted = [50_362, 11, 12, 50_258, 50_259, transcribe, 50_365, 400]
        #expect(PromptTimestampRulesFilter.sampleBegin(prompted, transcribe: transcribe, translate: translate) == 7)
        #expect(PromptTimestampRulesFilter.sampleBegin(Array(prompted.prefix(6)), transcribe: transcribe,
                                                       translate: translate) == nil, "Still prefilling.")
    }

    @Test func aChunkKeepsItsPlainResultWhenThePromptLostWords() {
        #expect(WhisperKitTranscriber.keepsPlain(prompted: 70, plain: 100))
        #expect(!WhisperKitTranscriber.keepsPlain(prompted: 85, plain: 100))
        #expect(!WhisperKitTranscriber.keepsPlain(prompted: 0, plain: 0))
        // The prompt invented speaker labels ("Jane Doe-") that the plain decode does not have: plain is kept when it
        // covers the speech, and the prompted result stays when plain dropped the speech.
        #expect(WhisperKitTranscriber.keepsPlain(prompted: 60, plain: 50, promptedLabels: 10, plainLabels: 0))
        #expect(!WhisperKitTranscriber.keepsPlain(prompted: 60, plain: 20, promptedLabels: 10, plainLabels: 0))
        #expect(!WhisperKitTranscriber.keepsPlain(prompted: 20, plain: 0, promptedLabels: 2, plainLabels: 0))
        #expect(!WhisperKitTranscriber.keepsPlain(prompted: 50, plain: 50, promptedLabels: 2, plainLabels: 2))
    }

    @Test func aPromptNameLabelCountsOnlyWhenTheOtherDecodeHasNoneOfItsWords() {
        func words(_ texts: [String]) -> [DeepTranscribedWord] {
            texts.enumerated().map { DeepTranscribedWord(text: $1, start: Double($0), end: Double($0 + 1)) }
        }
        let promptWords = DeepTranscribedLabel.promptWords("Sync. Jane Doe-Smith, Omar.")
        // The prompted decode addressed "Jane Doe-Smith"; the plain one wrote "Jane Dosmith": said, not invented.
        let addressed = words([" Jane", " Doe", "-Smith,", " can", " you", " share?"])
        #expect(DeepTranscribedLabel.count(in: addressed, promptWords: promptWords).words == 3)
        #expect(DeepTranscribedLabel.count(in: addressed, promptWords: promptWords,
                                           heard: ["jane", "dosmith", "can", "you", "share"]).words == 0)
        // Names that are not in the prompt are never a dash label.
        #expect(DeepTranscribedLabel.count(in: words([" Mary", " Smith", "-Jones", " will", " present."]),
                                           promptWords: promptWords).labels == 0)
    }

    @Test func punctuationIsMergedPerSegmentWithoutDroppingHyphens() {
        func word(_ text: String, _ token: Int, _ start: Float, _ end: Float) -> WordTiming {
            WordTiming(word: text, tokens: [token], start: start, end: end, probability: 0.9)
        }
        // Whisper tokenizes "Jane Doe- Yeah." as [" Jane", " Doe", "-", " Yeah", "."]: "-" has no leading space while
        // " Yeah" does. WhisperKit's own pass deleted "-", stripping the label's dash and shifting every later
        // sub-segment's words by one token; `PromptAlignedSegmentSeeker.mergePunctuations` attaches "-" to " Doe-".
        let merged = PromptAlignedSegmentSeeker.mergePunctuations([
            word(" Jane", 1, 0.0, 0.2), word(" Doe", 2, 0.2, 0.4), word("-", 12, 0.4, 0.45),
            word(" Yeah", 3, 0.5, 0.8), word(".", 13, 0.8, 0.85),
        ])
        #expect(merged.map(\.word) == [" Jane", " Doe-", " Yeah."])
        #expect(merged.flatMap(\.tokens) == [1, 2, 12, 3, 13], "Every token stays accounted for.")
        #expect(merged[1].end == 0.45 && merged[2].end == 0.85)

        // A spaced dash between two spaced words is kept as its own word rather than deleted, and quotes join the word
        // they wrap.
        let quoted = PromptAlignedSegmentSeeker.mergePunctuations([
            word(" \"", 20, 1.0, 1.1), word("Hello", 21, 1.1, 1.4), word("\"", 22, 1.4, 1.5),
            word(" -", 23, 1.6, 1.7), word(" world", 24, 1.7, 2.0),
        ])
        #expect(quoted.map(\.word) == [" \"Hello\"", " -", " world"])
        #expect(quoted.flatMap(\.tokens) == [20, 21, 22, 23, 24])
    }

    @Test func wordsAndSegmentsInTrailingZeroPaddingAreClippedToTheChunk() {
        let special = 50_257
        func word(_ text: String, _ start: Float, _ end: Float) -> WordTiming {
            WordTiming(word: text, tokens: [10], start: start, end: end, probability: 0.9)
        }
        func segment(_ text: String, _ start: Float, _ end: Float, _ words: [WordTiming]?) -> TranscriptionSegment {
            TranscriptionSegment(id: 0, seek: 0, start: start, end: end, text: text, tokens: [10],
                                 tokenLogProbs: [[10: -0.1]], temperature: 0, avgLogprob: -0.1, compressionRatio: 1,
                                 noSpeechProb: 0, words: words)
        }
        // An 18 s chunk padded by WhisperKit to 30 s: a real passage whose last word DTW stretched to 29 s, a second
        // passage with a repeat starting right before the 18 s cut and running into the zero-padding, and a passage
        // wholly inside the zero-padding at 29–30 s.
        let stretched = segment(" First sentence here", 0.5, 29.2, [
            word(" First", 0.5, 1.0), word(" sentence", 1.0, 2.0), word(" here", 2.0, 29.2),
        ])
        let trailing = segment(" Kept words you have", 10.0, 29.8, [
            word(" Kept", 10.0, 11.0), word(" words", 11.0, 17.6),
            word(" you", 17.9, 18.5), word(" have", 18.5, 29.8),
        ])
        let hallucinated = segment(" Repeated in padding", 29.1, 30.0, [
            word(" Repeated", 29.1, 29.5), word(" in", 29.5, 29.8), word(" padding", 29.8, 30.0),
        ])
        let untimedInPadding = segment(" Untimed padding", 22.0, 25.0, nil)
        let clipped = WhisperKitTranscriber.clippedSegments(
            [stretched, trailing, hallucinated, untimedInPadding], chunkSeconds: 18.0, specialTokenBegin: special)
        #expect(clipped.count == 2)
        #expect(clipped[0].end == 18.0 && clipped[0].words?.last?.end == 18.0)
        #expect(clipped[1].text == " Kept words" && clipped[1].words?.map(\.word) == [" Kept", " words"])
        #expect(clipped[1].end == 17.6)
    }

    @Test func aChunkThatCannotBeDecodedFailsThePass() throws {
        struct Broken: Error {}
        let fine: [Result<[Int], any Error>] = [.success([1]), .success([])]
        #expect(try WhisperKitTranscriber.requireAll(fine, startSeconds: [0, 30]) == [[1], []])
        let broken: [Result<[Int], any Error>] = [.success([1]), .failure(Broken()), .failure(Broken())]
        let error = #expect(throws: HolosError.self) {
            _ = try WhisperKitTranscriber.requireAll(broken, startSeconds: [0, 30, 60])
        }
        #expect(error?.localizedDescription.hasPrefix("2 stretches of audio (from 30 s, 60 s) could not be transcribed")
            == true, "Never published as a transcript that silently leaves the audio out.")
    }

    @Test func chunksAreDecodedWithoutTheFirstTokenCheck() {
        // Regression: WhisperKit's first-token log-probability check emptied whole chunks of speech, most often with a
        // prompt, leaving 20–30 s stretches out of the transcript.
        let options = WhisperKitTranscriber.decodingOptions(language: "en", promptTokens: [11, 12])
        #expect(options.firstTokenLogProbThreshold == nil)
        #expect(options.compressionRatioThreshold == 2.4 && options.logProbThreshold == -1.0,
                "The fallback thresholds stay WhisperKit's defaults.")
        #expect(options.wordTimestamps && !options.withoutTimestamps && options.promptTokens == [11, 12])
        #expect(WhisperKitTranscriber.decodingOptions(language: nil, promptTokens: nil).detectLanguage)
    }

    @Test func aChunkWithSpeechButNoWordsIsDecodedAgainInHalves() {
        // A 20 s chunk of speech that came back empty (its words did not fit the decoder): halved.
        #expect(WhisperKitTranscriber.needsSplit(words: 0, seconds: 20, levelDB: -25, depth: 0))
        #expect(!WhisperKitTranscriber.needsSplit(words: 3, seconds: 20, levelDB: -25, depth: 0))
        #expect(!WhisperKitTranscriber.needsSplit(words: 0, seconds: 20, levelDB: -70, depth: 0), "Silence stays empty.")
        #expect(!WhisperKitTranscriber.needsSplit(words: 0, seconds: 6, levelDB: -25, depth: 0), "Too short to halve.")
        #expect(!WhisperKitTranscriber.needsSplit(words: 0, seconds: 20, levelDB: -25,
                                                  depth: WhisperKitTranscriber.maximumSplitDepth))
        var samples = [Float](repeating: 0.3, count: 16_000 * 10)
        for index in 70_000..<71_600 { samples[index] = 0 }
        #expect(abs(WhisperKitTranscriber.quietestCut(samples) - 70_800) <= 1_600, "Halved in the pause.")
        #expect(WhisperKitTranscriber.levelDB(samples) > -12 && WhisperKitTranscriber.levelDB([0, 0]) == -120)
    }

    @Test func speechTheChunkingLeavesOutIsDecodedWhereTheRecordedTranscriptHeardIt() {
        let second = 16_000
        let max = 20 * second
        // A fake voice-activity chunking that found speech in 0–10 s and 40–50 s of 60 s, and nothing else.
        let vad = [0..<(10 * second), (40 * second)..<(50 * second)]
        // No recorded words outside them: only the chunks are decoded.
        #expect(WhisperKitTranscriber.plan(chunks: vad, total: 60 * second, recordedWords: [1, 2, 3, 41],
                                           maxSamples: max) == vad)
        // Three recorded words in 12–15 s: that stretch is decoded too, in pieces of at most 20 s, those with a word.
        let planned = WhisperKitTranscriber.plan(chunks: vad, total: 60 * second, recordedWords: [12, 13.5, 14.9, 52],
                                                 maxSamples: max)
        #expect(planned == [0..<(10 * second), (10 * second)..<(25 * second), (40 * second)..<(50 * second)])
        // Fewer than three there (music, or a word or two of noise): left out, as the chunking chose.
        #expect(WhisperKitTranscriber.plan(chunks: vad, total: 60 * second, recordedWords: [12, 13.5],
                                           maxSamples: max) == vad)
        // Three words in the 10 s after the last chunk: decoded.
        #expect(WhisperKitTranscriber.plan(chunks: vad, total: 60 * second, recordedWords: [51, 53, 55],
                                           maxSamples: max).last == (50 * second)..<(60 * second))
        // No chunk at all (the chunking heard nothing) with recorded speech: decoded in pieces.
        #expect(WhisperKitTranscriber.plan(chunks: [], total: 45 * second, recordedWords: [1, 2, 3, 44],
                                           maxSamples: max) == [0..<(15 * second), (30 * second)..<(45 * second)])
        // A stretch shorter than a second is joined to the chunk before it (or the one after it, at the start).
        #expect(WhisperKitTranscriber.plan(chunks: [(second / 2)..<(20 * second), (20 * second)..<(39 * second)],
                                           total: 39 * second + second / 2, recordedWords: [],
                                           maxSamples: max)
            == [0..<(20 * second), (20 * second)..<(39 * second + second / 2)])
    }

    @Test func whisperKitsChunkingLeavesNoAudioOutOfThePlan() async throws {
        // WhisperKit's chunker stops less than a second before the end: that tail is decoded with the last chunk.
        let samples = (0..<(40 * 16_000 + 8_000)).map { Float(sin(Double($0) * 0.05)) * 0.2 }
        let chunks = try await VADAudioChunker().chunkAll(audioArray: samples, maxChunkLength: 20 * 16_000,
                                                          decodeOptions: nil)
        let ranges = chunks.map { $0.seekOffsetIndex..<($0.seekOffsetIndex + $0.audioSamples.count) }
        #expect(ranges.last?.upperBound ?? 0 < samples.count, "The chunker leaves the tail out.")
        let planned = WhisperKitTranscriber.plan(chunks: ranges, total: samples.count, recordedWords: [],
                                                 maxSamples: 20 * 16_000)
        #expect(planned.first?.lowerBound == 0 && planned.last?.upperBound == samples.count)
        #expect(zip(planned, planned.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func aQuietStretchWithRecordedWordsThatComesBackEmptyIsUnheard() {
        #expect(WhisperKitTranscriber.isUnheard(words: 0, levelDB: -25, recordedWords: 0))
        #expect(!WhisperKitTranscriber.isUnheard(words: 0, levelDB: -70, recordedWords: 0), "Silence.")
        #expect(WhisperKitTranscriber.isUnheard(words: 0, levelDB: -70, recordedWords: 3),
                "Quiet speech the recorded transcript heard is reported, for the pass to fail on.")
        #expect(!WhisperKitTranscriber.isUnheard(words: 4, levelDB: -70, recordedWords: 3))
        #expect(WhisperKitTranscriber.needsSplit(words: 0, seconds: 20, levelDB: -70, depth: 0, recordedWords: 3))
    }

    @Test func theLanguageTableMatchesWhisperKits() {
        #expect(DeepTranscriptionModel.whisperLanguages == WhisperKitTranscriber.supportedLanguages)
    }

    @Test func localesMapToWhisperLanguages() {
        #expect(DeepTranscriptionModel.whisperLanguage("en-CA") == "en")
        #expect(DeepTranscriptionModel.whisperLanguage("fr_CA") == "fr")
        #expect(DeepTranscriptionModel.isWhisper("whisper:x"))
        #expect(!DeepTranscriptionModel.isWhisper(nil))
    }

    // MARK: - Helpers

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFakeModel(in directory: URL) throws {
        let folder = WhisperModels.modelFolder(in: directory, model: model)
        for name in WhisperModels.requiredModels {
            let bundle = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("fake".utf8).write(to: bundle.appendingPathComponent("model.mil"))
        }
        let tokenizer = WhisperModels.tokenizerFolder(in: directory)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
    }

    private func writeMarker(in directory: URL, model: String) throws {
        let marker = WhisperModels.Marker(model: model, repository: "test/repo", installedAt: Date())
        try HolosJSON.encoder().encode(marker).write(to: directory.appendingPathComponent(WhisperModels.markerName))
    }
}
