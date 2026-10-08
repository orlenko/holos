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

    /// Downloads the pack into the base folder `base` (FluidAudio resumes partial files there).
    public static let download: NaturalVoiceModels.Download = { pack, base, progress in
        _ = try await PocketTtsResourceDownloader.ensureModels(
            language: try language(pack), directory: base,
            progressHandler: { update in progress(update.fractionCompleted) })
    }

    /// Removes the voices the app does not offer from the pack (the non-commercial ones, and the other languages'
    /// native voices), loads the pack (compiling it for this Mac), and speaks a short sentence with its default voice.
    public static let warmUp: NaturalVoiceModels.WarmUp = { pack, base in
        let languageRoot = try await PocketTtsResourceDownloader.ensureModels(language: try language(pack),
                                                                             directory: base)
        pruneVoices(pack, languageRoot: languageRoot)
        let backend = PocketSpeechBackend(root: base.deletingLastPathComponent())
        let sentence = pack == .french ? "Bonjour, ceci est un essai." : "Hello, this is a test."
        let samples = try await backend.synthesize(sentence, voice: NaturalVoiceCatalog.defaultVoice(for: pack),
                                                   seed: NaturalSpeechRenderer.seed)
        guard samples.count > Int(NaturalSpeechRenderer.sampleRate / 4) else {
            throw HolosError.incomplete("The natural voice made no sound.")
        }
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
