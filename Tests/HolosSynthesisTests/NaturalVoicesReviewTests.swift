import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

// Review of PR #116: a pack is moved into place only when every listed file is complete (A1), numbers are compared
// alike on both sides of the check (C2), a long text is written as it is made (C1), and a pack is tidied only once it
// is installed (C3).

@Suite struct NaturalVoicePackFilesTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pack-\(UUID().uuidString)")

    @Test func theFilterMatchesFluidAudiosForAPack() {
        for kept in ["v2.1/english/cond_prefill.mlmodelc", "v2.1/english/cond_prefill.mlmodelc/weights/weight.bin",
                     "v2.1/english/constants_bin/alba.safetensors", "v2.1/english/manifest.json",
                     "v2.1/french_24l/flowlm_step.mlmodelc/coremldata.bin"] {
            #expect(NaturalVoicePackFiles.wanted(kept), "\(kept)")
        }
        for skipped in ["v2.1/english/cond_prefill.mlpackage", "v2.1/english/cond_prefill.mlpackage/Manifest.json",
                        "v2.1/english/flowlm_stepv2.mlmodelc/weights/weight.bin", "v2.1/english/cond_step.mlmodelc",
                        "v2.1/english/constants/bos.npy", "v2.1/english/verify.wav", "v2.1/english/.DS_Store",
                        "v2.1/english/flowlm_step_ane.mlmodelc/model.mil"] {
            #expect(!NaturalVoicePackFiles.wanted(skipped), "\(skipped)")
        }
    }

    @Test func aListingGivesItsFilesWithSizesAndChecksums() throws {
        let listing = Data("""
            [{"type":"directory","oid":"x","size":0,"path":"v2.1/english/constants_bin"},
             {"type":"file","oid":"a","size":243,"path":"v2.1/english/cond_prefill.mlmodelc/coremldata.bin",
              "lfs":{"oid":"ABC","size":243,"pointerSize":130}},
             {"type":"file","oid":"b","size":228662,"path":"v2.1/english/cond_prefill.mlmodelc/model.mil"},
             {"type":"file","oid":"c","size":5,"path":"v2.1/english/cond_prefill.mlpackage/Manifest.json"}]
            """.utf8)
        #expect(try NaturalVoicePackFiles.files(fromListing: listing) == [
            .init(path: "v2.1/english/cond_prefill.mlmodelc/coremldata.bin", size: 243, sha256: "ABC"),
            .init(path: "v2.1/english/cond_prefill.mlmodelc/model.mil", size: 228_662),
        ])
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func aCutOffOrDamagedFileIsFound() throws {
        // The listing's checksum of the weights (not the checksum of what is written below).
        let weights = NaturalVoicePackFiles.Expected(
            path: "v2.1/english/flowlm_step.mlmodelc/weights/weight.bin", size: 8,
            sha256: "c5a1ff1da1a1aab6b26f0a2d5fb73e66e4e3cc1a7e4fe5b4eca1c5c2a4d6c8fa")
        let mil = NaturalVoicePackFiles.Expected(path: "v2.1/english/flowlm_step.mlmodelc/model.mil", size: 4)
        let voice = NaturalVoicePackFiles.Expected(path: "v2.1/english/constants_bin/alba.safetensors", size: 3)
        try write(mil.path, "mil!")
        // The weights were cut off: only a partial file is there. The voice has the wrong size.
        try write(weights.path + ".partial", "weig")
        try write(voice.path, "alba")
        #expect(NaturalVoicePackFiles.problems([weights, mil, voice], in: folder) == [weights.path, voice.path])
        // Whole, but other content than the listing's checksum.
        try write(weights.path, "weights?")
        #expect(NaturalVoicePackFiles.problems([weights], in: folder) == [weights.path])
        let real = try NaturalVoicePackFiles.sha256(of: folder.appendingPathComponent(weights.path))
        let right = NaturalVoicePackFiles.Expected(path: weights.path, size: 8, sha256: real.uppercased())
        try write(voice.path, "alb")
        #expect(NaturalVoicePackFiles.problems([right, mil, voice], in: folder).isEmpty)
    }
}

@Suite struct NaturalVoiceInstallReviewTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pocket-\(UUID().uuidString)")

    private final class Log: Sendable {
        let events = Mutex<[String]>([])
        func add(_ event: String) { events.withLock { $0.append(event) } }
        var all: [String] { events.withLock { $0 } }
    }

    /// A download that writes one file per call and says whether the earlier ones were still there.
    private func download(_ log: Log) -> NaturalVoiceModels.Download {
        { _, base, _ in
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.sorted() ?? []
            log.add("download sees \(kept)")
            try Data("x".utf8).write(to: base.appendingPathComponent("file\(kept.count + 1)"))
        }
    }

    @Test func aPackThatDoesNotLoadInPlaceKeepsItsFilesForTheNextDownload() async throws {
        let log = Log()
        let failing: NaturalVoiceModels.WarmUp = { _, _ in throw HolosError.io("did not load") }
        await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(log),
                                               warmUp: failing, notice: { _ in }, progress: { _ in })
        }
        // In place, not loading: it goes back to staging, and the download finds what it had (to check and complete
        // it), instead of starting from nothing.
        await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(log),
                                               warmUp: failing, notice: { _ in }, progress: { _ in })
        }
        #expect(log.all == ["download sees []", "download sees [\"file1\"]"])
    }

    @Test func aPackIsTidiedOnlyOnceItIsInstalled() async throws {
        let log = Log()
        let finish: NaturalVoiceModels.Finish = { _, base in
            let marked = FileManager.default.fileExists(atPath: base.appendingPathComponent("installed.json").path)
            log.add("finish, marked \(marked)")
        }
        let failing: NaturalVoiceModels.WarmUp = { _, _ in throw HolosError.io("did not load") }
        await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false, download: download(log),
                                               warmUp: failing, finish: finish, notice: { _ in }, progress: { _ in })
        }
        #expect(!log.all.contains { $0.hasPrefix("finish") })
        try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false, download: download(log),
                                           warmUp: { _, _ in }, finish: finish, notice: { _ in }, progress: { _ in })
        #expect(log.all.last == "finish, marked true")
        // A setup that finds it installed finishes a tidy-up a crash cut off.
        try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false, download: download(log),
                                           warmUp: { _, _ in }, finish: finish, notice: { _ in }, progress: { _ in })
        #expect(log.all.filter { $0 == "finish, marked true" }.count == 2)
    }
}

@Suite struct SpeechChunkCheckNumberTests {
    @Test func englishYearsDecimalsAndOrdinalsMatchHoweverTheyAreHeard() {
        let text = "In 2015 the tower was 3.5 metres tall and came 2nd in a contest of 1,500 entries."
        for heard in [
            "in twenty fifteen the tower was three point five metres tall and came second in a contest of fifteen hundred entries",
            "in 2015 the tower was 3.5 metres tall and came 2nd in a contest of 1500 entries",
            "in two thousand and fifteen the tower was three point five metres tall and came second in a contest of one thousand five hundred entries",
        ] {
            #expect(SpeechChunkCheck.evaluate(expected: text, heard: heard).passed, "\(heard)")
        }
        #expect(!SpeechChunkCheck.evaluate(
            expected: text, heard: "in twenty fifteen the parrot sang loudly beside the river of entries").passed)
    }

    @Test func frenchYearsDecimalsAndOrdinalsMatchHoweverTheyAreHeard() {
        let text = "En 2015, la tour mesurait 3,5 mètres et arrivait 2e sur 1 500 projets."
        for heard in [
            "en deux mille quinze la tour mesurait trois virgule cinq mètres et arrivait deuxième sur mille cinq cents projets",
            "en 2015 la tour mesurait 3,5 mètres et arrivait 2e sur 1500 projets",
        ] {
            #expect(SpeechChunkCheck.evaluate(expected: text, heard: heard).passed, "\(heard)")
        }
        #expect(!SpeechChunkCheck.evaluate(
            expected: text, heard: "en deux mille quinze le chat dormait sous la table du jardin").passed)
    }
}

/// A backend whose takes can be watched as they are asked for.
private actor WatchedBackend: NaturalSpeechBackend {
    private var count = 0
    private let watch: @Sendable (Int) -> Void

    init(watch: @escaping @Sendable (Int) -> Void) { self.watch = watch }

    func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float] {
        count += 1
        watch(count)
        return [Float](repeating: 0.25, count: 24_000)
    }
}

@MainActor private final class NoFallback: ParagraphFallback {
    func samples(for text: String, language: String, sampleRate: Double) async throws -> (samples: [Float], voice: String) {
        throw HolosError.io("not expected")
    }
}

@MainActor @Suite struct NaturalSpeechIncrementalWriteTests {
    @Test func paragraphsAreWrittenAsTheyAreMade() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sizes = Mutex<[Int: Int64]>([:])
        let backend = WatchedBackend { take in
            // Before each paragraph is made, what the temporary file beside the output already holds.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let size = names.filter { $0.hasPrefix(".holos-") }.compactMap { name -> Int64? in
                let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                return (attributes?[.size] as? NSNumber)?.int64Value
            }.reduce(0, +)
            sizes.withLock { $0[take] = size }
        }
        let renderer = NaturalSpeechRenderer(backend: backend, checker: nil, fallback: NoFallback(),
                                             installedPacks: { [.english] })
        let output = folder.appendingPathComponent("part.caf")
        let result = try await renderer.render(text: "One.\n\nTwo.\n\nThree.", voiceIdentifier: "pocket:en:alba",
                                               rate: nil, to: output)
        // 1 s per paragraph and two 0.6 s pauses.
        #expect(abs(result.duration - 4.2) < 0.001)
        let seen = sizes.withLock { $0 }
        // Before the third paragraph, the first two (2.6 s of 16-bit samples, about 125 KB) are already on disk.
        #expect((seen[3] ?? 0) > 120_000)
        #expect((seen[2] ?? 0) > 70_000)
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasPrefix(".holos-") })
    }
}

@Suite struct NaturalSpeechPlanLongParagraphTests {
    private let sentence = "The keeper carried rainwater up the rocky path every single morning, counting his steps."

    @Test func aLongParagraphIsFedInBoundedGroupsOfWholeSentences() {
        let paragraph = Array(repeating: sentence, count: 60).joined(separator: " ")
        let blocks = NaturalSpeechPlan.blocks("Heading\n\n" + paragraph + "\n\nLast one.")
        let groups = blocks.dropFirst().dropLast()
        #expect(groups.count >= 5)
        #expect(groups.allSatisfy { $0.text.count <= NaturalSpeechPlan.maximumBlockLength })
        #expect(groups.allSatisfy { $0.text.hasSuffix("steps.") && $0.text.hasPrefix("The keeper") })
        #expect(groups.map(\.text).joined(separator: " ") == paragraph)
        // The voice's own pauses between the groups; the paragraph's after the last.
        #expect(groups.dropLast().allSatisfy { $0.pauseAfter == 0 })
        #expect(groups.last?.pauseAfter == NaturalSpeechPlan.paragraphPause)
        #expect(blocks.first?.isHeading == true)
        #expect(blocks.dropFirst().allSatisfy { !$0.isHeading })
    }

    @Test func aLongSentenceIsSplitAtClausesThenWords() {
        let clauses = Array(repeating: "and then the gulls came back over the grey stone wall", count: 40)
            .joined(separator: ", ") + "."
        let byClause = NaturalSpeechPlan.split(clauses, maximumLength: 1_000)
        #expect(byClause.count > 1)
        #expect(byClause.allSatisfy { $0.count <= 1_000 && ($0.hasSuffix(",") || $0.hasSuffix(".")) })
        #expect(byClause.joined(separator: " ") == clauses)
        let words = Array(repeating: "marigold", count: 400).joined(separator: " ")
        let byWord = NaturalSpeechPlan.split(words, maximumLength: 1_000)
        #expect(byWord.allSatisfy { $0.count <= 1_000 })
        #expect(byWord.joined(separator: " ") == words)
        let unbroken = String(repeating: "x", count: 2_500)
        #expect(NaturalSpeechPlan.split(unbroken, maximumLength: 1_000).map(\.count) == [1_000, 1_000, 500])
    }
}

/// Counts the samples each take holds (0.1 s per word, as the renderer tests' fake).
private actor CountingBackend: NaturalSpeechBackend {
    private(set) var largest = 0
    private(set) var calls = 0

    func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float] {
        calls += 1
        let samples = [Float](repeating: 0.25, count: text.split(separator: " ").count * 2_400)
        largest = max(largest, samples.count)
        return samples
    }
}

@MainActor @Suite struct NaturalSpeechLongTextTests {
    @Test func aTextWithoutBlankLinesNeverHoldsMoreThanABlocksSamples() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-long-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentence = "The keeper carried rainwater up the rocky path every single morning, counting his steps."
        // About 20,000 characters, 3,000 words, in one paragraph.
        let text = Array(repeating: sentence, count: 220).joined(separator: " ")
        let backend = CountingBackend()
        let renderer = NaturalSpeechRenderer(backend: backend, checker: nil, fallback: NoFallback(),
                                             installedPacks: { [.english] })
        let result = try await renderer.render(text: text, voiceIdentifier: "pocket:en:alba", rate: nil,
                                               to: folder.appendingPathComponent("long.caf"))
        let words = text.split(separator: " ").count
        #expect(abs(result.duration - Double(words) * 0.1) < 0.01)
        #expect(await backend.calls >= 20)
        // No take holds more than one block: at most 1,000 characters, under 200 words.
        #expect(await backend.largest <= 200 * 2_400)
    }
}

@Suite struct NaturalVoiceTemporariesTests {
    @Test func staleFoldersOfNaturalVoicesAreSweptAndNothingElse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let old = now.addingTimeInterval(-2 * 24 * 60 * 60)
        func make(_ name: String, changed: Date, file: Bool = false) throws {
            let url = folder.appendingPathComponent(name)
            if file {
                try Data("x".utf8).write(to: url)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url.appendingPathComponent("paragraph.caf"))
            }
            try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: url.path)
        }
        try make("holos-check-A", changed: old)
        try make("holos-fallback-B", changed: old)
        try make("holos-natural-C", changed: old)
        try make("holos-preview-D", changed: old)
        try make("holos-check-recent", changed: now)
        try make("holos-say-E", changed: old)
        try make("holos-check-file", changed: old, file: true)
        let removed = NaturalVoiceTemporaries.sweep(in: folder, now: now)
        #expect(removed == ["holos-check-A", "holos-fallback-B", "holos-natural-C", "holos-preview-D"])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["holos-check-file", "holos-check-recent", "holos-say-E"])
    }
}

@Suite struct NaturalSpeechPlanCodexTests {
    @Test func blankLinesWithSpacesOrTabsSeparateParagraphs() {
        let blocks = NaturalSpeechPlan.blocks("First one.\n  \nSecond one.\n\t\nThird one.\r\n \r\nFourth.")
        #expect(blocks.map(\.text) == ["First one.", "Second one.", "Third one.", "Fourth."])
        #expect(blocks.map(\.pauseAfter) == [0.6, 0.6, 0.6, 0])
        // A single line break inside a paragraph is still a space.
        #expect(NaturalSpeechPlan.blocks("One line\nand the next.").map(\.text) == ["One line and the next."])
    }

    @Test func aLongUnbrokenTokenIsCutInOnePass() {
        let token = String(repeating: "ab", count: 100_000)
        let cuts = NaturalSpeechPlan.split(token, maximumLength: 1_000)
        #expect(cuts.count == 200)
        #expect(cuts.allSatisfy { $0.count == 1_000 })
        #expect(cuts.joined() == token)
    }
}

@Suite struct NaturalVoiceRevisionTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-revision-\(UUID().uuidString)")

    @Test func everyAddressNamesThePinnedCommit() throws {
        #expect(NaturalVoiceModels.revision.count == 40)
        let hex = NaturalVoiceModels.revision.allSatisfy { $0.isHexDigit }
        #expect(hex)
        let listing = try #require(NaturalVoicePackFiles.listingURL(path: "v2.1/english"))
        #expect(listing.absoluteString == "https://huggingface.co/api/models/FluidInference/pocket-tts-coreml/tree/"
            + NaturalVoiceModels.revision + "/v2.1/english?recursive=1")
        let rootListing = try #require(NaturalVoicePackFiles.listingURL(path: "", recursive: false))
        #expect(rootListing.absoluteString.hasSuffix("/tree/" + NaturalVoiceModels.revision))
        let file = try #require(NaturalVoicePackFiles.fileURL(path: "encoder_recover_pinv.bin"))
        #expect(file.absoluteString.contains("/resolve/" + NaturalVoiceModels.revision + "/"))
        #expect(![listing, rootListing, file].contains { $0.absoluteString.contains("/main") })
        #expect(NaturalVoicePackFiles.rootFiles(for: .french) == ["encoder_recover_pinv.bin"])
        #expect(NaturalVoicePackFiles.rootFiles(for: .english).isEmpty)
    }

    @Test func aPackFromAnotherCommitIsCheckedAndUpdatedNotKept() async throws {
        let calls = Mutex<[String]>([])
        let download: NaturalVoiceModels.Download = { _, base, _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.sorted() ?? []
            calls.withLock { $0.append("download sees \(names)") }
        }
        let warmUp: NaturalVoiceModels.WarmUp = { _, _ in calls.withLock { $0.append("warm up") } }
        // A pack installed from an older commit.
        let directory = NaturalVoiceModels.directory(root: root, pack: .english)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: directory.appendingPathComponent("Models"))
        let old = NaturalVoiceModels.Marker(pack: .english, repository: NaturalVoiceModels.repository,
                                            revision: "0000000000000000000000000000000000000000", installedAt: Date())
        try HolosJSON.encoder().encode(old).write(to: directory.appendingPathComponent("installed.json"))
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
        // One whose marker names no commit (written before it was recorded) is not installed either.
        let unrecorded = NaturalVoiceModels.Marker(pack: .english, repository: NaturalVoiceModels.repository,
                                                   revision: nil, installedAt: Date())
        try HolosJSON.encoder().encode(unrecorded).write(to: directory.appendingPathComponent("installed.json"))
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
        try HolosJSON.encoder().encode(old).write(to: directory.appendingPathComponent("installed.json"))
        // The setup checks its files against the pinned commit (the download sees them), then installs it.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download,
                                           warmUp: warmUp, notice: { _ in }, progress: { _ in })
        #expect(calls.withLock { $0 } == ["download sees [\"Models\"]", "warm up"])
        let marker = try #require(NaturalVoiceModels.marker(root: root, pack: .english))
        #expect(marker.revision == NaturalVoiceModels.revision)
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
    }
}

@Suite struct NaturalVoiceUnmarkedPackTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-unmarked-\(UUID().uuidString)")
    private let weights = "Models/pocket-tts/v2.1/english/flowlm_step.mlmodelc/weights/weight.bin"

    /// A pack left in place, without a marker, by an interrupted (maybe older) setup.
    private func leaveUnmarkedPack(_ content: String) throws {
        let file = NaturalVoiceModels.directory(root: root, pack: .english).appendingPathComponent(weights)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }

    /// Checks the pack as the real one does: its files against the pinned listing's sizes and SHA-256s.
    private func verify(expecting content: String) throws -> NaturalVoiceModels.Verify {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reference = folder.appendingPathComponent("weight.bin")
        try Data(content.utf8).write(to: reference)
        let expected = [NaturalVoicePackFiles.Expected(
            path: "v2.1/english/flowlm_step.mlmodelc/weights/weight.bin", size: Int64(content.utf8.count),
            sha256: try NaturalVoicePackFiles.sha256(of: reference))]
        return { _, base in
            NaturalVoicePackFiles.problems(expected, in: base.appendingPathComponent("Models/pocket-tts")).isEmpty
        }
    }

    private final class Calls: Sendable {
        let events = Mutex<[String]>([])
    }

    private func setUp(_ calls: Calls, verify: @escaping NaturalVoiceModels.Verify) async throws {
        try await NaturalVoiceModels.setUp(
            root: root, pack: .english, force: false,
            download: { _, _, _ in calls.events.withLock { $0.append("download") } },
            warmUp: { _, base in
                let staged = base.lastPathComponent.hasSuffix(".download") ? "staging" : "place"
                calls.events.withLock { $0.append("warm up in \(staged)") }
            },
            verify: verify, notice: { _ in }, progress: { _ in })
    }

    @Test func aStaleUnmarkedPackIsDownloadedAgain() async throws {
        try leaveUnmarkedPack("older weights")
        let calls = Calls()
        try await setUp(calls, verify: try verify(expecting: "pinned weights"))
        // Not warmed up as it was: back to staging, through the pinned download, then warmed up in place.
        #expect(calls.events.withLock { $0 } == ["download", "warm up in place"])
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
    }

    @Test func anUnmarkedPackThatCannotBeCheckedIsDownloadedAgain() async throws {
        try leaveUnmarkedPack("pinned weights")
        let calls = Calls()
        try await setUp(calls, verify: { _, _ in throw URLError(.notConnectedToInternet) })
        #expect(calls.events.withLock { $0 } == ["download", "warm up in place"])
    }

    @Test func aMatchingUnmarkedPackIsWarmedUpWhereItIs() async throws {
        try leaveUnmarkedPack("pinned weights")
        let calls = Calls()
        try await setUp(calls, verify: try verify(expecting: "pinned weights"))
        #expect(calls.events.withLock { $0 } == ["warm up in place"])
        let marker = try #require(NaturalVoiceModels.marker(root: root, pack: .english))
        #expect(marker.revision == NaturalVoiceModels.revision)
    }
}

@MainActor @Suite struct NaturalSpeechUncheckableTests {
    /// Says no recognizer is installed, counting how often it is asked.
    private final class NoRecognizer: SpeechChunkChecker, Sendable {
        let asked = Mutex(0)
        func transcript(of samples: [Float], sampleRate: Double, language: String) async throws -> String? {
            asked.withLock { $0 += 1 }
            return nil
        }
    }

    @Test func aMissingRecognizerIsFoundAndSaidOnceForAllParts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let checker = NoRecognizer()
        let renderer = NaturalSpeechRenderer(backend: CountingBackend(), checker: checker, fallback: NoFallback(),
                                             installedPacks: { [.english] })
        var events: [NaturalSpeechEvent] = []
        renderer.onEvent = { events.append($0) }
        // A reading's parts, one renderer (as `voiceislocal read` renders them).
        for part in 1...5 {
            _ = try await renderer.render(text: "Part \(part).\n\nMore words here.", voiceIdentifier: "pocket:en:alba",
                                          rate: nil, to: folder.appendingPathComponent("part\(part).caf"))
        }
        #expect(checker.asked.withLock { $0 } == 1)
        #expect(events == [.checkUnavailable(language: "en")])
    }
}

