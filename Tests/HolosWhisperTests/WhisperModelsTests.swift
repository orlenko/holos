import CoreML
import Foundation
import Synchronization
import Testing
@testable import HolosCore
@testable import HolosWhisper

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
