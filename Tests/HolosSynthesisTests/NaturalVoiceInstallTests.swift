import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

// Natural voices: the catalog and its licences, and the install of a pack (pinned commit, checks, staging).

/// Writes a small pack under `base` as a download leaves it: the models, the constants the loader reads (tokenizer,
/// embeddings, Mimi state), every voice offered, and a voice that is not offered (removed once installed).
func fillPack(_ base: URL, _ pack: NaturalVoicePack) throws {
    let folder = NaturalVoicePackFiles.languageFolder(base: base, pack: pack)
    let files = NaturalVoicePackFiles.requiredModels.flatMap { model in
        ["coremldata.bin", "model.mil", "weights/weight.bin"].map { "\(model)/\($0)" }
    } + ["constants_bin/tokenizer.model", "constants_bin/bos_emb.bin", "constants_bin/text_embed_table.bin",
         "constants_bin/mimi_init_state/state_0.bin", "constants_bin/cosette.safetensors", "manifest.json"]
        + NaturalVoiceCatalog.offered.filter { $0.pack == pack }.map { "constants_bin/\($0.name).safetensors" }
    for path in files {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x\(path.count)".utf8).write(to: url)
    }
}

@Suite struct NaturalVoiceCatalogTests {
    @Test func onlyVoicesThatAllowCommercialUseAreOffered() {
        let offered = NaturalVoiceCatalog.offered.map(\.id)
        #expect(!offered.contains("pocket:en:cosette"))
        #expect(!offered.contains("pocket:en:jean"))
        #expect(offered.contains("pocket:en:alba"))
        #expect(offered.contains("pocket:fr:estelle"))
        #expect(NaturalVoiceCatalog.offered.allSatisfy { $0.license != .ccByNC4 })
        #expect(NaturalVoiceCatalog.all.filter { $0.license == .ccByNC4 }.map(\.name).sorted() == ["cosette", "jean"])
        #expect(Set(NaturalVoiceCatalog.all.map(\.id)).count == NaturalVoiceCatalog.all.count)
        #expect(NaturalVoiceCatalog.voice(id: "pocket:en:cosette") == nil)
        #expect(NaturalVoiceCatalog.voice(id: "pocket:en:jean") == nil)
    }

    @Test func identifiersParseStrictly() {
        #expect(NaturalVoiceCatalog.parse("pocket:en:alba")?.pack == .english)
        #expect(NaturalVoiceCatalog.parse("pocket:fr:estelle")?.name == "estelle")
        #expect(NaturalVoiceCatalog.parse("pocket:en:peter_yearsley")?.name == "peter_yearsley")
        for bad in ["pocket:EN:alba", "pocket:de:juergen", "pocket:en:", "pocket:en:a:b", "apple:en:alba",
                    "pocket:en:al-ba", "pocket:en:Alba", "pocket::alba", "pocket", ""] {
            #expect(NaturalVoiceCatalog.parse(bad) == nil, "\(bad)")
        }
        #expect(NaturalVoiceCatalog.isNatural("pocket:anything"))
        #expect(!NaturalVoiceCatalog.isNatural("com.apple.voice.premium.en-US.Ava"))
    }

    @Test func labelsAndDescriptors() {
        let alba = NaturalVoiceCatalog.defaultVoice(for: .english)
        #expect(alba.id == "pocket:en:alba")
        #expect(alba.title == "Natural — Alba (English)")
        #expect(alba.descriptor == VoiceDescriptor(id: "pocket:en:alba", name: "Alba (Natural)", language: "en",
                                                   quality: "natural"))
        #expect(NaturalVoiceCatalog.defaultVoice(for: .french).title == "Natural — Estelle (French)")
    }

    @Test func voicesOfInstalledPacksDefaultFirst() {
        #expect(NaturalVoiceCatalog.voices(installed: []).isEmpty)
        let english = NaturalVoiceCatalog.voices(installed: [.english])
        #expect(english.first?.name == "alba")
        #expect(english.allSatisfy { $0.pack == .english })
        #expect(english.count == 19)
        #expect(Array(english.dropFirst().map(\.displayName)) == english.dropFirst().map(\.displayName).sorted())
        #expect(NaturalVoiceCatalog.voices(installed: [.french]).map(\.id) == ["pocket:fr:estelle"])
        #expect(NaturalVoiceCatalog.voices(installed: [.french, .english]).last?.id == "pocket:fr:estelle")
    }

    @Test func defaultsSwitchOnceAPackIsInstalled() {
        #expect(NaturalVoiceCatalog.defaultVoice(language: "en-US", installed: []) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: "en-GB", installed: [.english])?.id == "pocket:en:alba")
        #expect(NaturalVoiceCatalog.defaultVoice(language: "fr-CA", installed: [.english]) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: "fr-CA", installed: [.english, .french])?.id
            == "pocket:fr:estelle")
        #expect(NaturalVoiceCatalog.defaultVoice(language: "de", installed: [.english, .french]) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: nil, installed: [.english]) == nil)
    }

    @Test func queriesMatchOfferedVoicesOnly() {
        for query in ["Alba", "alba", "Alba (Natural)", "pocket:en:alba", "POCKET:EN:ALBA", "Natural — Alba (English)"] {
            #expect(NaturalVoiceCatalog.match(query)?.id == "pocket:en:alba", "\(query)")
        }
        #expect(NaturalVoiceCatalog.match("Peter Yearsley")?.id == "pocket:en:peter_yearsley")
        #expect(NaturalVoiceCatalog.match("cosette") == nil)
        #expect(NaturalVoiceCatalog.match("Ava") == nil)
        #expect(NaturalVoiceCatalog.match("  ") == nil)
    }

    @Test func packSizes() {
        #expect(NaturalVoicePack.english.downloadSize == "530 MB")
        #expect(NaturalVoicePack.french.downloadSize == "1.9 GB")
        #expect(NaturalVoicePack.forLanguage("fr-FR") == .french)
        #expect(NaturalVoicePack.forLanguage("it") == nil)
        #expect(NaturalVoicePack.english.fluidLanguage == "english")
        #expect(NaturalVoicePack.french.fluidLanguage == "french_24l")
    }
}

// MARK: - Install

@Suite struct NaturalVoiceModelsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pocket-\(UUID().uuidString)")

    private final class Calls: Sendable {
        let downloads = Mutex(0)
        let warmUps = Mutex(0)
    }

    private func download(_ calls: Calls, failing: (any Error)? = nil) -> NaturalVoiceModels.Download {
        { pack, base, progress in
            calls.downloads.withLock { $0 += 1 }
            try fillPack(base, pack)
            progress(0.5)
            if let failing { throw failing }
            progress(1)
        }
    }

    private func warmUp(_ calls: Calls, failing: Bool = false) -> NaturalVoiceModels.WarmUp {
        { _, base in
            calls.warmUps.withLock { $0 += 1 }
            #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Models").path))
            if failing { throw HolosError.io("did not load") }
        }
    }

    @Test func installsDownloadsThenWarmsUpInPlaceAndMarksLast() async throws {
        let calls = Calls()
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
        let progress = Mutex<[Double]>([])
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(calls),
                                           warmUp: warmUp(calls), notice: { _ in },
                                           progress: { value in progress.withLock { $0.append(value) } })
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
        #expect(NaturalVoiceModels.installedPacks(root: root) == [.english])
        #expect(progress.withLock { $0.last } == 1)
        #expect(!FileManager.default.fileExists(atPath: NaturalVoiceModels.stagingFolder(root: root, pack: .english).path))
        // Installed: nothing is downloaded again.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(calls),
                                           warmUp: warmUp(calls), notice: { _ in }, progress: { _ in })
        #expect(calls.downloads.withLock { $0 } == 1)
        #expect(calls.warmUps.withLock { $0 } == 1)
        try NaturalVoiceModels.remove(root: root, pack: .english)
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
    }

    @Test func aFailedDownloadKeepsWhatItGotAndInstallsNothing() async throws {
        let calls = Calls()
        await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false,
                                               download: download(calls, failing: URLError(.notConnectedToInternet)),
                                               warmUp: warmUp(calls), notice: { _ in }, progress: { _ in })
        }
        #expect(NaturalVoiceModels.status(root: root, pack: .french) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: NaturalVoiceModels.stagingFolder(root: root, pack: .french).path))
        #expect(calls.warmUps.withLock { $0 } == 0)
        // The next try resumes (the staging folder is kept) and installs.
        let lines = Mutex<[String]>([])
        try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false, download: download(calls),
                                           warmUp: warmUp(calls), notice: { line in lines.withLock { $0.append(line) } },
                                           progress: { _ in })
        let notices = lines.withLock { $0 }
        #expect(notices.first?.hasPrefix("Resuming") == true)
        #expect(NaturalVoiceModels.status(root: root, pack: .french) == .installed)
    }

    @Test func aCancelledDownloadIsACancellation() async throws {
        let calls = Calls()
        await #expect(throws: CancellationError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false,
                                               download: download(calls, failing: CancellationError()),
                                               warmUp: warmUp(calls), notice: { _ in }, progress: { _ in })
        }
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
    }

    @Test func aWarmUpCutOffIsRetriedInPlaceAndOneThatFailsThereDownloadsAgain() async throws {
        let calls = Calls()
        // Downloaded, but the warm-up fails: in place, not installed.
        await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(calls),
                                               warmUp: warmUp(calls, failing: true), notice: { _ in },
                                               progress: { _ in })
        }
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: NaturalVoiceModels.directory(root: root, pack: .english).path))
        // The next setup finds its files are the pinned commit's and warms it up where it is, without a download.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(calls),
                                           warmUp: warmUp(calls), verify: { _, _ in true }, notice: { _ in },
                                           progress: { _ in })
        #expect(calls.downloads.withLock { $0 } == 1)
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
        // Forced: downloaded again.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: true, download: download(calls),
                                           warmUp: warmUp(calls), notice: { _ in }, progress: { _ in })
        #expect(calls.downloads.withLock { $0 } == 2)
    }

    @Test func theRootFollowsTheEnvironment() {
        #expect(NaturalVoiceModels.root(environment: ["HOLOS_POCKET_MODELS_DIR": "/tmp/pocket"]).path == "/tmp/pocket")
        #expect(NaturalVoiceModels.root(environment: ["HOLOS_SUPPORT_DIR": "/tmp/support"]).path
            == "/tmp/support/Models/pocket-tts")
    }
}

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
            // Not in LFS: its Git blob SHA-1, the listing's `oid`.
            .init(path: "v2.1/english/cond_prefill.mlmodelc/model.mil", size: 228_662, gitBlobSHA1: "b"),
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
        // Files outside LFS, checked by their Git blob SHA-1 (of "mil!" and "alb").
        let mil = NaturalVoicePackFiles.Expected(path: "v2.1/english/flowlm_step.mlmodelc/model.mil", size: 4,
                                                 gitBlobSHA1: "93a183fb2d02058ba563d6df6a48719377599bce")
        let voice = NaturalVoicePackFiles.Expected(path: "v2.1/english/constants_bin/alba.safetensors", size: 3,
                                                   gitBlobSHA1: "44db1c1bcac6aef83c0c654e8c1572f1f5184d7a")
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

    @Test func aFileOutsideLFSIsCheckedByContentNotJustSize() throws {
        let mil = NaturalVoicePackFiles.Expected(path: "v2.1/english/mimi_decoder.mlmodelc/model.mil", size: 4,
                                                 gitBlobSHA1: "93a183fb2d02058ba563d6df6a48719377599bce")
        // The same size, other bytes.
        try write(mil.path, "mil?")
        #expect(NaturalVoicePackFiles.problems([mil], in: folder) == [mil.path])
        try write(mil.path, "mil!")
        #expect(NaturalVoicePackFiles.problems([mil], in: folder).isEmpty)
        // Listed without any digest: nothing proves its content, so it is not taken as verified.
        let unknown = NaturalVoicePackFiles.Expected(path: mil.path, size: 4)
        #expect(NaturalVoicePackFiles.problems([unknown], in: folder) == [mil.path])
    }
}

@Suite struct NaturalVoiceInstallLockTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-lock-\(UUID().uuidString)")

    @Test func anInstalledPackIsNotReportedWhileAnotherInstallHoldsTheLock() async throws {
        // Installed.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: { pack, base, _ in try fillPack(base, pack) },
                                           warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
        // Another process starts a forced reinstall (it holds the lock and may remove the pack).
        let fd = open(NaturalVoiceModels.lockPath(root: root, pack: .english), O_RDWR | O_CREAT, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let finished = Mutex(false)
        await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: { pack, base, _ in try fillPack(base, pack) },
                                               warmUp: { _, _ in }, finish: { _, _ in finished.withLock { $0 = true } },
                                               notice: { _ in }, progress: { _ in })
        }
        #expect(!finished.withLock { $0 })
        // While it runs, the pack is being installed, not installed: nothing offers its voices.
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .downloading)
        #expect(NaturalVoiceModels.installedPacks(root: root).isEmpty)
        flock(fd, LOCK_UN)
        #expect(NaturalVoiceModels.installedPacks(root: root) == [.english])
        // Once it is done, the pack is reported installed again.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: { pack, base, _ in try fillPack(base, pack) },
                                           warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
    }

    @Test func theReadinessIsReadUnderTheInstallLock() async throws {
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false,
                                           download: { pack, base, _ in try fillPack(base, pack) },
                                           warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        // While the files are looked at, no install can take the lock (it would wait for the look to end).
        let excluded = NaturalVoiceModels.whileNoInstall(root: root, pack: .english) { () -> Bool in
            let fd = open(NaturalVoiceModels.lockPath(root: root, pack: .english), O_RDWR)
            defer { close(fd) }
            return flock(fd, LOCK_EX | LOCK_NB) != 0
        }
        #expect(excluded == true)
    }

    @Test func theInventoryCoversEveryFileTheLoaderReadsAndNoUnofferedVoice() async throws {
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false,
                                           download: { pack, base, _ in try fillPack(base, pack) },
                                           warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        let files = try #require(NaturalVoiceModels.marker(root: root, pack: .english)?.files)
        #expect(files["constants_bin/tokenizer.model"] != nil)
        #expect(files["constants_bin/mimi_init_state/state_0.bin"] != nil)
        #expect(files["constants_bin/alba.safetensors"] != nil)
        #expect(files["constants_bin/cosette.safetensors"] == nil)
        #expect(NaturalVoicePackFiles.isUnofferedVoice("constants_bin/cosette.safetensors", pack: .english))
        #expect(!NaturalVoicePackFiles.isUnofferedVoice("constants_bin/alba.safetensors", pack: .english))
        #expect(NaturalVoicePackFiles.isUnofferedVoice("constants_bin/alba.safetensors", pack: .french))
        #expect(!NaturalVoicePackFiles.isUnofferedVoice("constants_bin/tokenizer.model", pack: .english))
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
        // The tokenizer deleted (a file no voice list names): not installed.
        let folder = NaturalVoicePackFiles.languageFolder(base: NaturalVoiceModels.directory(root: root, pack: .english),
                                                          pack: .english)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("constants_bin/tokenizer.model"))
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
        // A marker written before the files were recorded is not taken for an installed pack either.
        try fillPack(NaturalVoiceModels.directory(root: root, pack: .english), .english)
        let unrecorded = NaturalVoiceModels.Marker(pack: .english, repository: NaturalVoiceModels.repository,
                                                   revision: NaturalVoiceModels.revision, installedAt: Date())
        try HolosJSON.encoder().encode(unrecorded).write(
            to: NaturalVoiceModels.directory(root: root, pack: .english).appendingPathComponent("installed.json"))
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
    }

    @Test func aMarkedPackWithFilesMissingIsNotInstalledAndIsRepaired() async throws {
        let downloads = Mutex(0)
        let download: NaturalVoiceModels.Download = { pack, base, _ in
            downloads.withLock { $0 += 1 }
            try fillPack(base, pack)
        }
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download,
                                           warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
        // A voice deleted since (or a model cut): marked, but not usable.
        let voice = NaturalVoiceModels.directory(root: root, pack: .english)
            .appendingPathComponent(NaturalVoicePackFiles.repositoryPath)
            .appendingPathComponent("v2.1/english/constants_bin/alba.safetensors")
        try FileManager.default.removeItem(at: voice)
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
        #expect(NaturalVoiceModels.installedPacks(root: root).isEmpty)
        // The next setup does not take it for installed: it goes through the download, which repairs it.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download,
                                           warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        #expect(downloads.withLock { $0 } == 2)
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
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

@Suite struct NaturalVoiceRevisionTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-revision-\(UUID().uuidString)")

    @Test func everyAddressNamesThePinnedCommit() throws {
        #expect(NaturalVoiceModels.revision.count == 40)
        let hex = NaturalVoiceModels.revision.allSatisfy { $0.isHexDigit }
        #expect(hex)
        // The addresses built from it: HolosPocketTests (they go through FluidAudio's registry).
        #expect(NaturalVoicePackFiles.rootFiles(for: .french) == ["encoder_recover_pinv.bin"])
        #expect(NaturalVoicePackFiles.rootFiles(for: .english).isEmpty)
    }

    @Test func aPackFromAnotherCommitIsCheckedAndUpdatedNotKept() async throws {
        let calls = Mutex<[String]>([])
        let download: NaturalVoiceModels.Download = { _, base, _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.sorted() ?? []
            calls.withLock { $0.append("download sees \(names)") }
            try fillPack(base, .english)
        }
        let warmUp: NaturalVoiceModels.WarmUp = { _, _ in calls.withLock { $0.append("warm up") } }
        // A pack installed from an older commit.
        let directory = NaturalVoiceModels.directory(root: root, pack: .english)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fillPack(directory, .english)
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
            download: { pack, base, _ in
                calls.events.withLock { $0.append("download") }
                try fillPack(base, pack)
            },
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
