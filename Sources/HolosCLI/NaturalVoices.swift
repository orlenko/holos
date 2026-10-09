import Foundation
import HolosContent
import HolosCore
import HolosPocket
import HolosSpeech
import HolosSynthesis
import Synchronization

/// The natural voices in the `voiceislocal` tool (Sources/HolosSynthesis/README.md): Pocket TTS rendering with the
/// per-paragraph check through Apple's on-device recognizer, and the setup of the language packs.
enum NaturalVoicesCLI {
    /// Installed on stderr the first time a natural renderer is made, for the rest of the process: the lines left are
    /// copied out before it exits.
    private static let logFilter: FluidAudioLogFilter? = {
        let filter = FluidAudioLogFilter.install(on: STDERR_FILENO)
        if filter != nil { atexit { NaturalVoicesCLI.logFilter?.finish() } }
        return filter
    }()

    /// The renderer `say` and `read` use for natural voices. The check runs unless `HOLOS_NATURAL_CHECK=0`, or a reading
    /// saved its policy when it started (its resume follows that policy either way: the checker is always made). What it
    /// finds (a re-render, a paragraph read by a system voice) is said on stderr.
    /// `scratch`: the folder its temporary files go in (the app gives each part one, and deletes it when it stops the
    /// tool); nil for the system's temporary folder.
    @MainActor static func renderer(log: Bool = true, scratch: URL? = nil) -> NaturalSpeechRenderer {
        // FluidAudio's own log of the text it speaks stays off stderr from now on (`FluidAudioLogFilter`).
        _ = logFilter
        let root = scratch ?? FileManager.default.temporaryDirectory
        // Folders a killed run of the tool left behind, a day old (never one in use), go off the main actor.
        Task.detached(priority: .utility) { _ = NaturalVoiceTemporaries.sweep() }
        let renderer = NaturalSpeechRenderer(
            backend: PocketSpeechBackend(), checker: AppleSpeechChunkChecker(temporaryRoot: root),
            checksByDefault: ProcessInfo.processInfo.environment["HOLOS_NATURAL_CHECK"] != "0",
            fallback: NativeParagraphFallback(temporaryRoot: root))
        renderer.onEvent = { event in
            guard log else { return }
            switch event {
            case .checked(let paragraph, let take, let verdict, _) where !verdict.passed:
                Console.error(String(format: "Paragraph %d did not sound right (take %d, %.0f%% of its words heard "
                    + "wrong); %@", paragraph, take, verdict.wordErrorRate * 100,
                    take == 1 ? "rendering it again." : "reading it with a system voice."))
            case .checked:
                break
            case .checkUnavailable(let language):
                Console.error("Note: no on-device recognizer for \(language) is installed, so paragraphs are not "
                    + "checked. Install one with voiceislocal setup --locale \(language).")
            case .checkFailed(let paragraph, let reason):
                Console.error("Note: paragraph \(paragraph) could not be checked: \(reason)")
            case .fellBack(let paragraph, let voice, let reason):
                Console.error("Paragraph \(paragraph) is read by \(voice): \(reason).")
            }
        }
        return renderer
    }

    /// `--voice` for `read` and `say`: a natural voice ("pocket:en:alba", "Alba (Natural)"), installed. Nil when the
    /// query names no natural voice (an Apple voice is looked for then).
    @MainActor static func resolve(_ query: String) throws -> NaturalVoice? {
        guard let voice = NaturalVoiceCatalog.match(query) else {
            if NaturalVoiceCatalog.isNatural(query) {
                throw HolosError.unavailable("No natural voice is named \"\(query)\". See: voiceislocal voices list")
            }
            return nil
        }
        guard NaturalVoiceModels.installedPacks().contains(voice.pack) else {
            throw HolosError.unavailable("The \(voice.pack.languageName) natural voices are not installed. Run "
                + "voiceislocal setup --natural-voices\(voice.pack == .english ? "" : " --language fr") (about "
                + "\(voice.pack.downloadSize)).")
        }
        return voice
    }
}

/// Hears a rendered paragraph with Apple's on-device speech recognizer (SpeechAnalyzer): already on the Mac for
/// dictation, no model to download, and quick on a paragraph. Nil (no check) when no recognizer for the language is
/// installed.
///
/// Invariants:
/// 1. `locales` holds, per language, the recognizer locale found the first time the language is checked, or nil when
///    none has its assets installed; it is kept for the checker's life, which is its renderer's.
/// 2. A language found without a recognizer is not asked about again by this checker (the renderer stops checking it
///    too, `uncheckable`); installing one takes effect in the next run of the tool.
/// 3. Each paragraph's audio goes in a folder of its own under `temporaryRoot`, removed before the call returns.
actor AppleSpeechChunkChecker: SpeechChunkChecker {
    private var locales: [String: String?] = [:]
    private let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
    }

    func transcript(of samples: [Float], sampleRate: Double, language: String) async throws -> String? {
        guard let locale = await locale(for: language) else { return nil }
        let folder = temporaryRoot.appendingPathComponent("holos-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("paragraph.caf")
        try NaturalSpeechFile.write(samples, sampleRate: sampleRate, to: file)
        let transcript = try await AppleSpeechEngine.transcribe(file: file, locale: locale, backend: .speech) { _ in }
        return transcript.segments.map(\.text).joined(separator: " ")
    }

    /// A recognizer locale for `language` whose assets are installed, the user's own regions first. The inventory's
    /// locales of a language are not all usable: their assets are per region ("fr_FR" can be missing while "fr_CA"
    /// is installed), so each is asked.
    private func locale(for language: String) async -> String? {
        if let known = locales[language] { return known }
        let listed = await AppleSpeechEngine.capabilities(backend: .speech).installedLocales.filter {
            Locale(identifier: $0).language.languageCode?.identifier.lowercased() == language
        }
        let key = { (tag: String) in tag.replacingOccurrences(of: "-", with: "_").lowercased() }
        let preferred = Locale.preferredLanguages.map(key)
        let ordered = listed.sorted { lhs, rhs in
            (preferred.firstIndex(of: key(lhs)) ?? Int.max) < (preferred.firstIndex(of: key(rhs)) ?? Int.max)
        }
        var chosen: String?
        for candidate in ordered
        where (try? await AppleSpeechEngine.assetStatus(locale: candidate, backend: .speech)) == "installed" {
            chosen = candidate
            break
        }
        locales[language] = chosen
        return chosen
    }
}

/// `voiceislocal setup --natural-voices`.
enum NaturalVoiceSetup {
    static func run(pack: NaturalVoicePack, force: Bool) async throws {
        let progress = NaturalProgressPrinter(label: "Natural voices (\(pack.languageName))")
        try await NaturalVoiceModels.setUp(pack: pack, force: force, download: PocketSpeechBackend.download,
                                           warmUp: PocketSpeechBackend.warmUp, finish: PocketSpeechBackend.finish,
                                           verify: PocketSpeechBackend.verify,
                                           notice: { Console.error($0) },
                                           progress: progress.report)
        Console.output(NaturalVoiceModels.readyMessage(pack))
        Console.output(NaturalVoiceModels.creditsLine)
    }
}

/// Prints "<label>: N%" to stderr at each new 5 % step (the app's Settings row shows the last line).
private final class NaturalProgressPrinter: Sendable {
    private let lastStep = Mutex(-1)
    private let label: String

    init(label: String) { self.label = label }

    var report: @Sendable (Double) -> Void {
        { [self] fraction in
            guard fraction.isFinite else { return }
            let step = Int(min(1, max(0, fraction)) * 20)
            let isNew = lastStep.withLock { last in
                guard step > last else { return false }
                last = step
                return true
            }
            if isNew { Console.error("\(label): \(step * 5)%") }
        }
    }
}
