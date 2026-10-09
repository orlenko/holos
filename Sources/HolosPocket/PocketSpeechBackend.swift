import FluidAudio
import Foundation
import HolosCore
import HolosSynthesis

/// Kyutai Pocket TTS through FluidAudio (Sources/HolosPocket/README.md): the natural voices' backend in the
/// `voiceislocal` tool. One `PocketTtsManager` per language pack, loaded on first use from the pack's folder under
/// `NaturalVoiceModels.root` and kept for the process. Each paragraph is one fresh session with the given seed, so
/// the same paragraph and seed give the same take (Pocket TTS draws its noise from a seeded generator).
public actor PocketSpeechBackend: NaturalSpeechBackend {
    private let root: URL
    private let managers = PackLoads<PocketTtsManager>()

    public init(root: URL = NaturalVoiceModels.root) {
        self.root = root
    }

    static func language(_ pack: NaturalVoicePack) throws -> PocketTtsLanguage {
        guard let language = PocketTtsLanguage(rawValue: pack.fluidLanguage) else {
            throw HolosError.unavailable("FluidAudio has no \(pack.languageName) Pocket TTS pack.")
        }
        return language
    }

    private func manager(for pack: NaturalVoicePack) async throws -> PocketTtsManager {
        let voice = NaturalVoiceCatalog.defaultVoice(for: pack).name
        let language = try Self.language(pack)
        let directory = NaturalVoiceModels.directory(root: root, pack: pack)
        return try await managers.value(for: pack) {
            let manager = PocketTtsManager(defaultVoice: voice, language: language, directory: directory)
            try await manager.initialize()
            return manager
        }
    }

    /// Loads the pack now (the first load of a process takes a few seconds once the models are compiled).
    public func load(_ pack: NaturalVoicePack) async throws {
        _ = try await manager(for: pack)
    }

    public func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float] {
        let manager = try await manager(for: voice.pack)
        let session = try await manager.makeSession(voice: voice.name, seed: seed)
        session.enqueue(text)
        session.finish()
        var samples: [Float] = []
        do {
            for try await frame in session.frames {
                try Task.checkCancellation()
                samples.append(contentsOf: frame.samples)
            }
            try Task.checkCancellation()
        } catch {
            await session.cancel()
            throw error
        }
        // As FluidAudio's one-shot synthesis does: rumble removed, sibilants softened, levels kept.
        AudioPostProcessor.applyTtsPostProcessing(&samples, sampleRate: Float(NaturalSpeechFormat.sampleRate),
                                                  deEssAmount: -3.0, smoothing: false)
        return samples
    }

    // MARK: - Install seams (`NaturalVoiceModels.setUp`)

    /// The repository's folder under a pack's base folder, as FluidAudio lays it out (`<base>/Models/pocket-tts`).
    static func repositoryFolder(base: URL) -> URL {
        base.appendingPathComponent(PocketTtsConstants.defaultModelsSubdirectory, isDirectory: true)
            .appendingPathComponent(Repo.pocketTts.folderName, isDirectory: true)
    }

    /// Downloads the pack into the base folder `base`. Not through `PocketTtsResourceDownloader.ensureModels`, which
    /// skips the download once the pack's top-level folders exist (a download cancelled inside the last model's
    /// weights would pass): every file of the repository's listing is ensured (one already there is kept, a partial
    /// one resumed by FluidAudio), then checked against the listing's sizes and SHA-256s. A file that fails the check
    /// is removed, so the next download fetches it again, and the download fails.
    public static let download: NaturalVoiceModels.Download = { pack, base, progress in
        let subdirectory = try language(pack).repoSubdirectory
        // Every request names the reviewed commit, never `main`: the listing, FluidAudio's downloads (through its
        // revision override for the repository), and the root files.
        ModelRegistry.revisionOverrides[Repo.pocketTts.remotePath] = NaturalVoiceModels.revision
        let expected = try await expectedFiles(pack)
        let roots = NaturalVoicePackFiles.rootFiles(for: pack)
        let folder = repositoryFolder(base: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ModelHub.download(.pocketTts, subdirectory: subdirectory, to: folder,
                                    progressHandler: { update in progress(update.fractionCompleted) },
                                    shouldSkip: { !NaturalVoicePackFiles.wanted($0) })
        for path in roots where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) {
            let url = try fileURL(path)
            let data = try await ModelHub.fetchFile(from: url, description: path)
            try data.write(to: folder.appendingPathComponent(path), options: .atomic)
        }
        try Task.checkCancellation()
        let problems = NaturalVoicePackFiles.problems(expected, in: folder)
        guard problems.isEmpty else {
            // Removed so the next download fetches them again; one that cannot be removed is said, never retried.
            try NaturalVoicePackFiles.remove(problems, in: folder)
            throw HolosError.incomplete("\(problems.count) of the natural voices' files did not download completely "
                + "(\(problems.prefix(3).joined(separator: ", ")))")
        }
    }

    /// Whether the pack in `base` holds every file of the pinned commit's listing, complete (sizes and SHA-256s).
    public static let verify: NaturalVoiceModels.Verify = { pack, base in
        NaturalVoicePackFiles.problems(try await expectedFiles(pack), in: repositoryFolder(base: base)).isEmpty
    }

    /// The pack's files at the pinned commit: its language folder and the root files it needs.
    static func expectedFiles(_ pack: NaturalVoicePack) async throws -> [NaturalVoicePackFiles.Expected] {
        var expected = try await listing(try language(pack).repoSubdirectory)
        let roots = NaturalVoicePackFiles.rootFiles(for: pack)
        if !roots.isEmpty {
            expected += try await listing("", recursive: false).filter { roots.contains($0.path) }
        }
        return expected
    }

    /// The files of `subdirectory` the voices need, with their sizes and checksums, from Hugging Face, at the pinned
    /// commit.
    static func listing(_ subdirectory: String, recursive: Bool = true) async throws
        -> [NaturalVoicePackFiles.Expected] {
        var next = try listingURL(subdirectory, recursive: recursive)
        var files: [NaturalVoicePackFiles.Expected] = []
        // The listing comes in pages, linked by the response's `Link: <…>; rel="next"`.
        for _ in 0..<50 {
            let (data, response) = try await ModelHub.fetchWithAuth(from: next)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HolosError.unavailable("Hugging Face did not list the natural voices' files.")
            }
            files += try NaturalVoicePackFiles.files(fromListing: data)
            guard let link = http.value(forHTTPHeaderField: "Link"), let url = nextPage(link) else { break }
            next = url
        }
        guard !files.isEmpty else { throw HolosError.unavailable("Hugging Face listed no natural voice files.") }
        return files
    }

    /// The listing of `path` at the pinned commit, through FluidAudio's registry (its host and repository mirrors,
    /// as its downloads use them).
    static func listingURL(_ path: String, recursive: Bool) throws -> URL {
        try ModelRegistry.apiModels(Repo.pocketTts.remotePath,
                                    "tree/\(NaturalVoiceModels.revision)" + (path.isEmpty ? "" : "/\(path)")
                                        + (recursive ? "?recursive=1" : ""))
    }

    /// One file at the pinned commit, through FluidAudio's registry.
    static func fileURL(_ path: String) throws -> URL {
        try ModelRegistry.resolveModel(Repo.pocketTts.remotePath, path, revision: NaturalVoiceModels.revision)
    }

    /// The `rel="next"` address of a `Link` header.
    static func nextPage(_ link: String) -> URL? {
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close else {
                continue
            }
            return URL(string: String(part[part.index(after: open)..<close]))
        }
        return nil
    }

    /// Loads the pack (compiling it for this Mac) and speaks a short sentence with its default voice. Nothing is
    /// downloaded: the load only looks for the pack's folders, and the default voice is never removed.
    public static let warmUp: NaturalVoiceModels.WarmUp = { pack, base in
        let backend = PocketSpeechBackend(root: base.deletingLastPathComponent())
        let sentence = pack == .french ? "Bonjour, ceci est un essai." : "Hello, this is a test."
        let samples = try await backend.synthesize(sentence, voice: NaturalVoiceCatalog.defaultVoice(for: pack),
                                                   seed: NaturalSpeechFormat.seed)
        guard samples.count > Int(NaturalSpeechFormat.sampleRate / 4) else {
            throw HolosError.incomplete("The natural voice made no sound.")
        }
    }

    /// Once the pack is installed: removes the voices the app does not offer from it (the non-commercial ones, and
    /// the other languages' native voices).
    public static let finish: NaturalVoiceModels.Finish = { pack, base in
        guard let subdirectory = try? language(pack).repoSubdirectory else { return }
        pruneVoices(pack, languageRoot: repositoryFolder(base: base).appendingPathComponent(subdirectory))
    }

    /// Deletes `constants_bin/<voice>.safetensors` for every voice the pack's folder holds that is not offered in it.
    static func pruneVoices(_ pack: NaturalVoicePack, languageRoot: URL) {
        let folder = languageRoot.appendingPathComponent("constants_bin", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where NaturalVoicePackFiles.isUnofferedVoice("constants_bin/\(name)", pack: pack) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

/// One load per pack, kept once it succeeds: a caller that comes during a load (the backend actor is reentrant at its
/// awaits) waits for that load instead of starting another, so a pack's models are never loaded twice at once.
///
/// Invariants:
/// 1. `loads` holds at most one task per pack; every caller for that pack awaits it.
/// 2. A task that failed is removed by a caller that saw it fail (when it is still the stored one), so the next call
///    loads again.
actor PackLoads<Value: Sendable> {
    private var loads: [NaturalVoicePack: Task<Value, Error>] = [:]

    func value(for pack: NaturalVoicePack, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = loads[pack] ?? Task { try await load() }
        loads[pack] = task
        do {
            return try await task.value
        } catch {
            if loads[pack] == task { loads[pack] = nil }
            throw error
        }
    }
}
