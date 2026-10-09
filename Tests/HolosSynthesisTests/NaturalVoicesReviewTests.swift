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
