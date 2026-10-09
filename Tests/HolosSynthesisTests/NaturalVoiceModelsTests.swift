import Foundation
import HolosCore
import HolosTestSupport
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

// MARK: - Install

@Suite final class NaturalVoiceModelsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pocket-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

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

@Suite(.timeLimit(.minutes(1))) final class NaturalVoiceInstallLockTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-lock-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

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

    /// An English install the test holds in its download, and what a French install started meanwhile did.
    private final class TwoInstalls: Sendable {
        let downloading = Mutex(false)
        let released = Mutex(false)
        let frenchSteps = Mutex(0)
    }

    @Test func anotherPacksInstallIsRefusedWhileOneRuns() async throws {
        let installs = TwoInstalls()
        let english = Task { [root] in
            try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: { pack, base, _ in
                installs.downloading.withLock { $0 = true }
                while !installs.released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
                try fillPack(base, pack)
            }, warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        }
        #expect(await eventually { installs.downloading.withLock { $0 } })
        // The French install (the app's Download, or a second Terminal) starts while English downloads: refused
        // before it downloads or warms up anything.
        let error = await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false, download: { pack, base, _ in
                installs.frenchSteps.withLock { $0 += 1 }
                try fillPack(base, pack)
            }, warmUp: { _, _ in installs.frenchSteps.withLock { $0 += 1 } }, notice: { _ in }, progress: { _ in })
        }
        #expect(error?.localizedDescription.contains("Other natural voices are being installed") == true)
        #expect(installs.frenchSteps.withLock { $0 } == 0)
        installs.released.withLock { $0 = true }
        try await english.value
        // Once English is done, French installs.
        try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false, download: { pack, base, _ in
            try fillPack(base, pack)
        }, warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        #expect(NaturalVoiceModels.installedPacks(root: root) == [.english, .french])
    }

    @Test func anInstalledPackIsStillReportedWhileAnotherPackInstalls() async throws {
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false,
                                           download: { pack, base, _ in try fillPack(base, pack) },
                                           warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        let fd = open(NaturalVoiceModels.anyInstallLockPath(root: root), O_RDWR | O_CREAT, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        // Another pack's install holds the shared lock: English is still installed, and its setup says so.
        #expect(NaturalVoiceModels.installedPacks(root: root) == [.english])
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false,
                                           download: { pack, base, _ in try fillPack(base, pack) },
                                           warmUp: { _, _ in }, notice: { _ in }, progress: { _ in })
        flock(fd, LOCK_UN)
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

@Suite final class NaturalVoiceInstallReviewTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pocket-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

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

@Suite final class NaturalVoiceRevisionTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-revision-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

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

@Suite final class NaturalVoiceUnmarkedPackTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-unmarked-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

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
        defer { try? FileManager.default.removeItem(at: folder) }
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
