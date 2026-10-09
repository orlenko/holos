import FluidAudio
import Foundation
import HolosCore
import HolosSynthesis

/// Kyutai Pocket TTS through FluidAudio (docs/design.md "Natural voices"): the natural voices' backend in the
/// `voiceislocal` tool. One `PocketTtsManager` per language pack, loaded on first use from the pack's folder under
/// `NaturalVoiceModels.root` and kept for the process. Each paragraph is one fresh session with the given seed, so
/// the same paragraph and seed give the same take (Pocket TTS draws its noise from a seeded generator).
public actor PocketSpeechBackend: NaturalSpeechBackend {
    private let root: URL
    private var managers: [NaturalVoicePack: PocketTtsManager] = [:]

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
        if let manager = managers[pack] { return manager }
        let manager = PocketTtsManager(defaultVoice: NaturalVoiceCatalog.defaultVoice(for: pack).name,
                                       language: try Self.language(pack),
                                       directory: NaturalVoiceModels.directory(root: root, pack: pack))
        try await manager.initialize()
        managers[pack] = manager
        return manager
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
        AudioPostProcessor.applyTtsPostProcessing(&samples, sampleRate: Float(NaturalSpeechRenderer.sampleRate),
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
        let expected = try await listing(subdirectory)
        let folder = repositoryFolder(base: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ModelHub.download(.pocketTts, subdirectory: subdirectory, to: folder,
                                    progressHandler: { update in progress(update.fractionCompleted) },
                                    shouldSkip: { !NaturalVoicePackFiles.wanted($0) })
        try Task.checkCancellation()
        let problems = NaturalVoicePackFiles.problems(expected, in: folder)
        guard problems.isEmpty else {
            for path in problems { try? FileManager.default.removeItem(at: folder.appendingPathComponent(path)) }
            throw HolosError.incomplete("\(problems.count) of the natural voices' files did not download completely "
                + "(\(problems.prefix(3).joined(separator: ", ")))")
        }
    }

    /// The files of `subdirectory` the voices need, with their sizes and checksums, from Hugging Face.
    static func listing(_ subdirectory: String) async throws -> [NaturalVoicePackFiles.Expected] {
        let address = "https://huggingface.co/api/models/\(Repo.pocketTts.remotePath)/tree/main/\(subdirectory)"
            + "?recursive=1"
        guard var next = URL(string: address) else { throw HolosError.invalidInput("Bad listing address.") }
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
                                                   seed: NaturalSpeechRenderer.seed)
        guard samples.count > Int(NaturalSpeechRenderer.sampleRate / 4) else {
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
        let kept = Set(NaturalVoiceCatalog.offered.filter { $0.pack == pack }.map { $0.name + ".safetensors" })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".safetensors") && !kept.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
