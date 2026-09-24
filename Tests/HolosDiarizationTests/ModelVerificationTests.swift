import CryptoKit
import Foundation
import Synchronization
import Testing
import HolosCore
@testable import HolosDiarization

@Suite struct ModelVerificationTests {
    // MARK: - Status

    @Test func modelStatusDetectsMissingCorruptAndWrongRevision() throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("speaker-diarization-coreml@test")
        let pinned = try modelWriteFakeModels(in: directory)

        let repo = FluidModels.repoFolder(in: directory)
        try FileManager.default.removeItem(at: repo)
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .notInstalled)

        let reinstalled = try modelWriteFakeModels(in: directory)
        #expect(reinstalled == pinned)
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)

        // One changed byte, same size.
        let weights = repo.appendingPathComponent("Embedding.mlmodelc/weights/weight.bin")
        var bytes = try Data(contentsOf: weights)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: weights)
        #expect(FluidModels.status(directory: directory, pinned: pinned)
            == .corrupt(files: ["Embedding.mlmodelc/weights/weight.bin"]))
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: weights)
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)

        // Another revision's marker.
        let marker = repo.appendingPathComponent(".fluidaudio-revision")
        try Data("0000000000000000000000000000000000000000\n".utf8).write(to: marker)
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .corrupt(files: [".fluidaudio-revision"]))
        try Data((FluidModels.revision + "\n").utf8).write(to: marker)
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)
    }

    @Test func missingTruncatedAndLinkedFilesAreCorrupt() throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("models")
        let pinned = try modelWriteFakeModels(in: directory)
        let repo = FluidModels.repoFolder(in: directory)

        try FileManager.default.removeItem(at: repo.appendingPathComponent("config.json"))
        let plda = repo.appendingPathComponent("plda-parameters.json")
        try Data("{}".utf8).write(to: plda)
        let metadata = repo.appendingPathComponent("Embedding.mlmodelc/metadata.json")
        let elsewhere = folder.appendingPathComponent("metadata-copy.json")
        try FileManager.default.moveItem(at: metadata, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: elsewhere)
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".fluidaudio-revision"))

        #expect(FluidModels.status(directory: directory, pinned: pinned) == .corrupt(files: [
            ".fluidaudio-revision", "Embedding.mlmodelc/metadata.json", "config.json", "plda-parameters.json",
        ]))
        // Files nobody pinned are ignored.
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.moveItem(at: elsewhere, to: metadata)
        try Data((FluidModels.revision + "\n").utf8).write(to: repo.appendingPathComponent(".fluidaudio-revision"))
        _ = try modelWriteFakeModels(in: directory)
        try Data("extra".utf8).write(to: repo.appendingPathComponent(".DS_Store"))
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)
    }

    @Test func linkedFoldersAndShadowingFilesAreCorrupt() throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("models")
        let pinned = try modelWriteFakeModels(in: directory)
        let repo = FluidModels.repoFolder(in: directory)
        let bundle = repo.appendingPathComponent("Embedding.mlmodelc")
        let bundleFiles = pinned.map(\.relativePath).filter { $0.hasPrefix("Embedding.mlmodelc/") }

        // A linked bundle folder with intact files inside.
        let elsewhere = folder.appendingPathComponent("Embedding-elsewhere.mlmodelc")
        try FileManager.default.moveItem(at: bundle, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: bundle, withDestinationURL: elsewhere)
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .corrupt(files: bundleFiles))
        try FileManager.default.removeItem(at: bundle)
        try FileManager.default.moveItem(at: elsewhere, to: bundle)
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)

        // A linked marker.
        let marker = repo.appendingPathComponent(".fluidaudio-revision")
        let markerCopy = folder.appendingPathComponent("marker")
        try FileManager.default.moveItem(at: marker, to: markerCopy)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: markerCopy)
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .corrupt(files: [".fluidaudio-revision"]))
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.moveItem(at: markerCopy, to: marker)

        // FluidAudio reads <directory>/plda-parameters.json before the pinned copy.
        let shadow = directory.appendingPathComponent("plda-parameters.json")
        try Data("garbage".utf8).write(to: shadow)
        #expect(FluidModels.status(directory: directory, pinned: pinned)
            == .corrupt(files: ["../plda-parameters.json"]))
        try FileManager.default.removeItem(at: shadow)
        // Its later fallbacks are never read while the pinned file exists.
        try modelWrite("{}", to: directory.appendingPathComponent("speaker-diarization-offline/plda-parameters.json"))
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)
    }

    @Test func unsafePinnedPathsAndAnEmptyListNeverVerify() throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("models")
        var pinned = try modelWriteFakeModels(in: directory)
        #expect(FluidModels.status(directory: directory, pinned: []) == .corrupt(files: []))
        pinned.append(PinnedFile(relativePath: "../outside.bin", size: 0, sha256: String(repeating: "0", count: 64)))
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .corrupt(files: ["../outside.bin"]))
        #expect(!FluidModels.isSafeRelativePath("/absolute"))
        #expect(!FluidModels.isSafeRelativePath("a//b"))
        #expect(!FluidModels.isSafeRelativePath("a/./b"))
        #expect(FluidModels.isSafeRelativePath("Embedding.mlmodelc/weights/weight.bin"))
    }

    @Test func pinnedManifestCoversTheOfflineModelFiles() {
        let files = PinnedModels.files
        #expect(files.count == 24)
        #expect(Set(files.map(\.relativePath)).count == files.count)
        for bundle in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
            for file in ["coremldata.bin", "analytics/coremldata.bin", "metadata.json", "model.mil",
                         "weights/weight.bin"] {
                #expect(files.contains { $0.relativePath == "\(bundle).mlmodelc/\(file)" })
            }
        }
        for file in ["plda-parameters.json", "xvector-transform.json", "config.json", "provenance.json"] {
            #expect(files.contains { $0.relativePath == file })
        }
        let hex = Set("0123456789abcdef")
        for file in files {
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy(hex.contains))
            #expect(file.size > 0)
            #expect(FluidModels.isSafeRelativePath(file.relativePath))
        }
        #expect(files.reduce(0) { $0 + $1.size } == 21_786_966)
        #expect(ModelTreeDigest.digest(of: files) == PinnedModels.treeDigest)
    }

    // MARK: - Tree digest

    @Test func treeDigestIsOrderIndependent() throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents: [(String, String)] = [
            ("b/model.mil", "program"), ("a.json", "{}"), ("b/weights/weight.bin", "weights"), ("c.json", "[1]"),
        ]
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        for (path, text) in contents { try modelWrite(text, to: first.appendingPathComponent(path)) }
        for (path, text) in contents.reversed() { try modelWrite(text, to: second.appendingPathComponent(path)) }
        try modelWrite(FluidModels.revision + "\n", to: second.appendingPathComponent(".fluidaudio-revision"))

        let firstFiles = try ModelTreeDigest.manifest(of: first)
        let secondFiles = try ModelTreeDigest.manifest(of: second)
        #expect(firstFiles == secondFiles)
        #expect(firstFiles.map(\.relativePath) == ["a.json", "b/model.mil", "b/weights/weight.bin", "c.json"])
        #expect(firstFiles.first == PinnedFile(
            relativePath: "a.json", size: 2,
            sha256: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"))
        let digest = ModelTreeDigest.digest(of: firstFiles)
        #expect(digest == ModelTreeDigest.digest(of: secondFiles))
        #expect(digest == ModelTreeDigest.digest(of: firstFiles.reversed()))
        #expect(digest.count == 64)

        try modelWrite("changed", to: second.appendingPathComponent("b/model.mil"))
        #expect(ModelTreeDigest.digest(of: try ModelTreeDigest.manifest(of: second)) != digest)
    }

    @Test func treeDigestHashesSortedLines() {
        let files = [
            PinnedFile(relativePath: "b", size: 1, sha256: String(repeating: "b", count: 64)),
            PinnedFile(relativePath: "a", size: 2, sha256: String(repeating: "A", count: 64)),
        ]
        let text = "a\t2\t\(String(repeating: "a", count: 64))\nb\t1\t\(String(repeating: "b", count: 64))\n"
        #expect(ModelTreeDigest.digest(of: files) == modelSHA256(Data(text.utf8)))
    }

    @Test func manifestRefusesSymbolicLinks() throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try modelWrite("x", to: folder.appendingPathComponent("repo/a.bin"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("repo/link"),
                                                   withDestinationURL: folder.appendingPathComponent("repo/a.bin"))
        #expect(throws: HolosError.self) { try ModelTreeDigest.manifest(of: folder.appendingPathComponent("repo")) }
    }

    // MARK: - Install

    @Test func installNeverLeavesPartialFolder() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("Models/speaker-diarization-coreml@test")
        let pinned = try modelFakePinnedFiles()
        let downloadedInto = Mutex<URL?>(nil)
        let checked = Mutex(false)

        await #expect(throws: HolosError.self) {
            try await FluidModels.install(
                directory: directory, pinned: pinned,
                download: { partial, progress in
                    downloadedInto.withLock { $0 = partial }
                    progress(0.3)
                    let repo = FluidModels.repoFolder(in: partial)
                    try modelWrite(FluidModels.revision + "\n", to: repo.appendingPathComponent(".fluidaudio-revision"))
                    try modelWrite(modelFakeContents[0].1, to: repo.appendingPathComponent(modelFakeContents[0].0))
                    throw HolosError.unavailable("The network went away.")
                },
                check: { _ in checked.withLock { $0 = true } },
                progress: { _ in })
        }

        let partial = try #require(downloadedInto.withLock { $0 })
        #expect(partial.deletingLastPathComponent().standardizedFileURL.path
            == directory.deletingLastPathComponent().standardizedFileURL.path)
        #expect(partial.lastPathComponent.hasPrefix("speaker-diarization-coreml@test.partial-"))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!checked.withLock { $0 })
        #expect(try modelSiblings(of: directory).isEmpty)
    }

    @Test func installVerifiesBeforeItPublishes() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("Models/speaker-diarization-coreml@test")
        let pinned = try modelFakePinnedFiles()
        let checked = Mutex(false)

        let error = await #expect(throws: HolosError.self) {
            try await FluidModels.install(
                directory: directory, pinned: pinned,
                download: { partial, _ in
                    _ = try modelWriteFakeModels(in: partial, tamperingWith: "PldaRho.mlmodelc/model.mil")
                },
                check: { _ in checked.withLock { $0 = true } },
                progress: { _ in })
        }
        if case .incomplete(let message) = error {
            #expect(message.contains("failed verification"))
        } else {
            Issue.record("Expected an incomplete error, got \(String(describing: error))")
        }
        #expect(!checked.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try modelSiblings(of: directory).isEmpty)
    }

    @Test func installReplacesADamagedInstallAndCleansUp() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("Models/speaker-diarization-coreml@test")
        let pinned = try modelWriteFakeModels(in: directory, tamperingWith: "config.json")
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .corrupt(files: ["config.json"]))
        // A partial folder left by a killed install.
        let stale = directory.deletingLastPathComponent()
            .appendingPathComponent("speaker-diarization-coreml@test.partial-\(UUID().uuidString)")
        try modelWrite("stale", to: stale.appendingPathComponent("speaker-diarization/x"))
        let checkedFolder = Mutex<URL?>(nil)
        let fractions = Mutex<[Double]>([])

        try await FluidModels.install(
            directory: directory, pinned: pinned,
            download: { partial, progress in
                progress(0.5)
                _ = try modelWriteFakeModels(in: partial)
                progress(1)
            },
            check: { partial in
                #expect(FluidModels.status(directory: partial, pinned: pinned) == .verified)
                checkedFolder.withLock { $0 = partial }
            },
            progress: { fraction in fractions.withLock { $0.append(fraction) } })

        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)
        #expect(checkedFolder.withLock { $0 } != nil)
        #expect(try modelSiblings(of: directory).isEmpty)
        let reported = fractions.withLock { $0 }
        #expect(reported == reported.sorted())
        #expect(reported.last == 1)
    }

    @Test func installRefusesWhileAnotherInstallRuns() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("Models/speaker-diarization-coreml@test")
        let pinned = try modelFakePinnedFiles()
        let refusal = Mutex<HolosError?>(nil)

        try await FluidModels.install(
            directory: directory, pinned: pinned,
            download: { partial, _ in
                // A second install for the same folder while this one holds the lock.
                do {
                    try await FluidModels.install(directory: directory, pinned: pinned,
                                                  download: { _, _ in }, check: { _ in }, progress: { _ in })
                } catch let error as HolosError {
                    refusal.withLock { $0 = error }
                }
                _ = try modelWriteFakeModels(in: partial)
            },
            check: { _ in },
            progress: { _ in })

        guard case .unavailable(let message) = try #require(refusal.withLock { $0 }) else {
            Issue.record("Expected the second install to be refused as unavailable")
            return
        }
        #expect(message.contains("another holos setup --speakers"))
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)
    }

    @Test func setUpKeepsModelsThatLoadAndReinstallsModelsThatDoNot() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("Models/speaker-diarization-coreml@test")
        let pinned = try modelWriteFakeModels(in: directory)
        // Marks the installed copy, so a reinstall (which replaces the whole folder) is visible.
        let sentinel = directory.appendingPathComponent("installed-copy")
        try modelWrite("old", to: sentinel)
        let downloads = Mutex(0)
        let checked = Mutex<[String]>([])
        let notices = Mutex<[String]>([])
        let download: FluidModels.Download = { partial, _ in
            downloads.withLock { $0 += 1 }
            _ = try modelWriteFakeModels(in: partial)
        }
        func setUp(force: Bool, loads: @escaping @Sendable (URL) -> Bool) async throws {
            try await FluidModels.setUp(
                directory: directory, pinned: pinned, force: force, download: download,
                check: { folder in
                    checked.withLock { $0.append(folder.lastPathComponent) }
                    if !loads(folder) { throw HolosError.unavailable("Core ML refused the model.") }
                },
                notice: { line in notices.withLock { $0.append(line) } },
                progress: { _ in })
        }

        // Verified and loads: kept, nothing downloaded.
        try await setUp(force: false, loads: { _ in true })
        #expect(downloads.withLock { $0 } == 0)
        #expect(checked.withLock { $0 } == [directory.lastPathComponent])
        #expect(notices.withLock { $0.last }?.contains("already installed") == true)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))

        // Verified but fails to load in place: downloaded again, and the fresh copy passes its own load check.
        try await setUp(force: false, loads: { $0.lastPathComponent != directory.lastPathComponent })
        #expect(downloads.withLock { $0 } == 1)
        #expect(notices.withLock { $0.last }?.contains("could not be loaded") == true)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)

        // --force: downloaded again without a load check of the installed copy.
        try modelWrite("old", to: sentinel)
        checked.withLock { $0 = [] }
        try await setUp(force: true, loads: { _ in true })
        #expect(downloads.withLock { $0 } == 2)
        #expect(checked.withLock { $0 }.allSatisfy { $0.hasPrefix(directory.lastPathComponent + ".partial-") })
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))

        // A shadowing file makes the install damaged; setup replaces the folder and the file goes with it.
        let shadow = directory.appendingPathComponent("plda-parameters.json")
        try modelWrite("garbage", to: shadow)
        try await setUp(force: false, loads: { _ in true })
        #expect(downloads.withLock { $0 } == 3)
        #expect(!FileManager.default.fileExists(atPath: shadow.path))
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .verified)
        #expect(try modelSiblings(of: directory).isEmpty)
    }

    @Test func recordManifestInstallsNothing() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("Models/speaker-diarization-coreml@test")
        let pinned = try modelFakePinnedFiles()

        let files = try await FluidModels.recordManifest(
            directory: directory, download: { partial, _ in _ = try modelWriteFakeModels(in: partial) },
            progress: { _ in })

        #expect(files == pinned)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try modelSiblings(of: directory).isEmpty)
    }

    // MARK: - Diarizer without models, settings, doctor

    @Test func diarizerRefusesUnverifiedModels() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let diarizer = FluidDiarizer(modelsDirectory: folder.appendingPathComponent("missing"),
                                     configuration: .default)
        let infoError = await #expect(throws: HolosError.self) { _ = try await diarizer.engineInfo() }
        let diarizeError = await #expect(throws: HolosError.self) {
            _ = try await diarizer.diarize(DiarizationRequest(audio: folder.appendingPathComponent("x.caf"),
                                                              track: "mic"),
                                           progress: { _ in })
        }
        for error in [infoError, diarizeError] {
            guard case .unavailable(let message) = error else {
                Issue.record("Expected unavailable, got \(String(describing: error))")
                continue
            }
            #expect(message == FluidModels.missingModelsMessage)
        }
    }

    @Test func engineInfoRecordsTheTreeDigestAndSettings() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("models")
        let pinned = try modelWriteFakeModels(in: directory)
        let diarizer = FluidDiarizer(modelsDirectory: directory,
                                     configuration: FluidDiarizerConfiguration(exclusiveSegments: true),
                                     pinned: pinned)

        let info = try await diarizer.engineInfo()

        #expect(info.engine == "FluidAudio.OfflineDiarizerManager")
        #expect(info.engineVersion == "0.17.1")
        #expect(info.models == [ModelDescriptor(id: "FluidInference/speaker-diarization-coreml",
                                                revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
                                                sha256: ModelTreeDigest.digest(of: pinned))])
        #expect(info.embeddingModel == EmbeddingModelID(
            id: "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
            revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232"))
        #expect(info.embeddingDimension == 256)
        #expect(info.configuration["exclusiveSegments"] == "true")
        #expect(info.configuration["exposeChunkEmbeddings"] == "true")
        #expect(info.configuration["clusteringThreshold"] == "0.6")
        #expect(info.configuration["computeUnits"] == "all")
        #expect(info.configuration["fbankComputeUnits"] == "cpuOnly")
    }

    @Test func configurationOverridesParse() throws {
        let applied = try FluidDiarizerConfiguration.default.overridden(by: [
            "exclusiveSegments": "true", "clusteringThreshold": "0.7",
        ])
        #expect(applied == FluidDiarizerConfiguration(exclusiveSegments: true, clusteringThreshold: 0.7))
        #expect(applied.flattened["exclusiveSegments"] == "true")
        #expect(applied.flattened["clusteringThreshold"] == "0.7")
        #expect(try FluidDiarizerConfiguration.default.overridden(by: [:]) == .default)
        #expect(FluidDiarizerConfiguration.default
            == FluidDiarizerConfiguration(exclusiveSegments: false, clusteringThreshold: nil))
        #expect(try applied.overridden(by: ["exclusiveSegments": "false"]).exclusiveSegments == false)

        #expect(throws: HolosError.self) { try FluidDiarizerConfiguration.default.overridden(by: ["x": "1"]) }
        #expect(throws: HolosError.self) {
            try FluidDiarizerConfiguration.default.overridden(by: ["exclusiveSegments": "yes"])
        }
        for value in ["0", "2.5", "nan", "abc", ""] {
            #expect(throws: HolosError.self) {
                try FluidDiarizerConfiguration.default.overridden(by: ["clusteringThreshold": value])
            }
        }
    }

    @Test func speakerHintsDropValuesBelowOne() {
        typealias Hint = SpeakerCountHint
        #expect(FluidDiarizerConfiguration.resolved(nil) == nil)
        #expect(FluidDiarizerConfiguration.resolved(Hint()) == nil)
        #expect(FluidDiarizerConfiguration.resolved(Hint(minimum: 0, maximum: 2)) == Hint(maximum: 2))
        #expect(FluidDiarizerConfiguration.resolved(Hint(minimum: 2, maximum: 4)) == Hint(minimum: 2, maximum: 4))
        #expect(FluidDiarizerConfiguration.resolved(Hint(minimum: 2, exactly: 3)) == Hint(exactly: 3))
        #expect(FluidDiarizerConfiguration.resolved(Hint(minimum: 2, exactly: 0)) == Hint(minimum: 2))
        #expect(FluidDiarizerConfiguration.resolved(Hint(minimum: -1, maximum: 0)) == nil)
    }

    @Test func doctorJSONReportsSpeakerModels() throws {
        let support = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let directory = FluidModels.defaultDirectory(supportRoot: support)
        #expect(directory.path == support.path + "/Models/speaker-diarization-coreml@df2625ac79a7")
        // `holos doctor` reads the default folder, which follows HOLOS_SUPPORT_DIR (scripts/test.sh sets it).
        #expect(FluidModels.defaultDirectory == FluidModels.defaultDirectory(supportRoot: HolosPaths.supportRoot))
        #expect(HolosPaths.models == HolosPaths.supportRoot.appendingPathComponent("Models", isDirectory: true))

        let status = FluidModels.status(directory: directory)
        #expect(status == .notInstalled)
        // `DoctorReport.speakerModels` holds the status itself, so this is the encoding `holos doctor --json` writes.
        let json = String(decoding: try HolosJSON.encoder().encode(["speakerModels": status]), as: UTF8.self)
        #expect(json.contains(#""speakerModels" : "notInstalled""#))
        for (value, text) in [(ModelInstallStatus.verified, "verified"), (.corrupt(files: ["a"]), "damaged")] {
            #expect(String(decoding: try HolosJSON.encoder().encode([value]), as: UTF8.self)
                .contains("\"\(text)\""))
        }
        #expect(status.summary == "not installed")
        #expect(ModelInstallStatus.verified.doctorValue == "verified")
        #expect(ModelInstallStatus.corrupt(files: ["a"]).doctorValue == "damaged")
        #expect(ModelInstallStatus.corrupt(files: ["a"]).summary == "damaged (1 file)")
        #expect(ModelInstallStatus.corrupt(files: ["a", "b"]).summary == "damaged (2 files)")
    }

    /// Only models that are not installed give no diarizer (post-processing's "not set up", exit 0 for
    /// `holos session import`). Damaged models give one that fails with "missing or damaged", so labelling is
    /// recorded as failed (exit 3). Before, the CLI gave nil for every status but verified, so a damaged install
    /// was reported as not installed and the import exited 0.
    @Test func onlyUninstalledModelsGiveNoDiarizer() async throws {
        let folder = try modelTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("models")
        let pinned = try modelWriteFakeModels(in: directory)
        func diarizer() -> FluidDiarizer? {
            FluidDiarizer.forInstalledModels(modelsDirectory: directory, configuration: .default, pinned: pinned)
        }

        let verified = try #require(diarizer())
        #expect(try await verified.engineInfo().engine == FluidDiarizer.engineName)

        let weights = FluidModels.repoFolder(in: directory).appendingPathComponent("Embedding.mlmodelc/weights/weight.bin")
        var bytes = try Data(contentsOf: weights)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: weights)
        #expect(FluidModels.status(directory: directory, pinned: pinned)
            == .corrupt(files: ["Embedding.mlmodelc/weights/weight.bin"]))
        let damaged = try #require(diarizer())
        do {
            _ = try await damaged.engineInfo()
            Issue.record("A diarizer over damaged models reported its engine")
        } catch HolosError.unavailable(let message) {
            #expect(message == FluidModels.missingModelsMessage)
        }

        try FileManager.default.removeItem(at: FluidModels.repoFolder(in: directory))
        #expect(FluidModels.status(directory: directory, pinned: pinned) == .notInstalled)
        #expect(diarizer() == nil)
    }
}

// MARK: - Helpers (prefixed: other test files in this target may declare their own)

/// Stand-ins for the model files: the real layout with small contents.
private let modelFakeContents: [(String, String)] = {
    var files: [(String, String)] = []
    for bundle in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
        files.append(("\(bundle).mlmodelc/coremldata.bin", "\(bundle) coremldata"))
        files.append(("\(bundle).mlmodelc/analytics/coremldata.bin", "\(bundle) analytics"))
        files.append(("\(bundle).mlmodelc/metadata.json", "{\"name\": \"\(bundle)\"}"))
        files.append(("\(bundle).mlmodelc/model.mil", "program \(bundle)"))
        files.append(("\(bundle).mlmodelc/weights/weight.bin", String(repeating: "\(bundle) weights ", count: 64)))
    }
    files.append(("plda-parameters.json", "{\"tensors\": {}}"))
    files.append(("xvector-transform.json", "{\"transform\": []}"))
    files.append(("config.json", "{}"))
    files.append(("provenance.json", "{\"artifacts\": []}"))
    return files
}()

private func modelTemporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("holos-models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func modelWrite(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func modelSHA256(_ data: Data) -> String {
    FileDigest.hex(SHA256.hash(data: data))
}

/// The pinned list for `modelFakeContents`.
private func modelFakePinnedFiles() throws -> [PinnedFile] {
    modelFakeContents.map { path, text in
        PinnedFile(relativePath: path, size: text.utf8.count, sha256: modelSHA256(Data(text.utf8)))
    }.sorted { $0.relativePath < $1.relativePath }
}

/// Writes the fake models and the revision marker under `directory` (FluidAudio's layout) and returns their pinned
/// list; the file at `tamperingWith` gets a different first byte (same size) than the list says.
@discardableResult
private func modelWriteFakeModels(in directory: URL, tamperingWith tampered: String? = nil) throws -> [PinnedFile] {
    let repo = FluidModels.repoFolder(in: directory)
    for (path, text) in modelFakeContents {
        let written = path == tampered ? (text.hasPrefix("X") ? "Y" : "X") + text.dropFirst() : text
        try modelWrite(written, to: repo.appendingPathComponent(path))
    }
    try modelWrite(FluidModels.revision + "\n", to: repo.appendingPathComponent(".fluidaudio-revision"))
    return try modelFakePinnedFiles()
}

/// Entries next to `directory` other than `directory` itself and its install lock.
private func modelSiblings(of directory: URL) throws -> [String] {
    let parent = directory.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
        $0 != directory.lastPathComponent && $0 != "." + directory.lastPathComponent + ".install.lock"
    }
}
