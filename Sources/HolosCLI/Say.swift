import ArgumentParser
import Foundation
import HolosContent
import HolosCore
import HolosStorage
import HolosSynthesis

struct Voices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect speech voices.", subcommands: [List.self], defaultSubcommand: List.self)
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List voices: name, language, quality (natural, premium, enhanced, default), identifier.",
            discussion: """
                Natural voices (Kyutai Pocket TTS, quality "natural") are listed once their language is installed \
                with voiceislocal setup --natural-voices; Apple's voices follow.
                """)
        @Option(help: "Filter by language prefix, such as en.") var language: String?
        @Flag(help: "Print JSON.") var json = false
        @MainActor mutating func run() async throws {
            let installed = NativeSpeechRenderer.voices()
            let names = VoiceSelection.displayNames(installed)
            let natural = NaturalVoiceCatalog.voices(installed: NaturalVoiceModels.installedPacks()).map(\.descriptor)
            let apple = installed.sorted { lhs, rhs in
                    if lhs.language != rhs.language { return lhs.language < rhs.language }
                    let lhsRank = VoiceSelection.qualityRank(lhs.quality), rhsRank = VoiceSelection.qualityRank(rhs.quality)
                    if lhsRank != rhsRank { return lhsRank > rhsRank }
                    return (names[lhs.id] ?? lhs.name) < (names[rhs.id] ?? rhs.name)
                }
            let voices = (natural + apple).filter { language == nil || $0.language.hasPrefix(language!) }
            if json { try Console.json(voices); return }
            for voice in voices {
                Console.output("\(names[voice.id] ?? voice.name)\t\(voice.language)\t\(voice.quality)\t\(voice.id)")
            }
            if natural.isEmpty {
                Console.error("Natural voices: voiceislocal setup --natural-voices (English, about "
                    + "\(NaturalVoicePack.english.downloadSize)); add --language fr for French.")
            }
            if !voices.contains(where: { $0.quality == "premium" }) {
                Console.error(VoiceSelection.premiumVoicesHint)
            }
        }
    }
}

struct Say: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Speak text locally, or save speech to an audio file.",
        discussion: """
            A natural voice (voiceislocal voices list, quality "natural") reads one paragraph at a time; each \
            paragraph is heard back by Apple's on-device recognizer and rendered again, or read by an Apple voice, \
            when it does not match the text (HOLOS_NATURAL_CHECK=0 turns the check off).
            """)
    @Argument(help: "Text to speak; reads UTF-8 stdin when omitted.") var text: [String] = []
    @Option(name: .shortAndLong, help: "Save to .m4a, .wav, or .caf instead of playing.") var output: String?
    @Option(name: .shortAndLong, help: ArgumentHelp(
        "Voice name as `voiceislocal voices list` prints it, such as \"Ava (Premium)\" or \"Alba (Natural)\", or its identifier.",
        valueName: "name")) var voice: String?
    @Option(parsing: .unconditional, help: speechRateHelp, transform: parseSpeechRate) var rate: Float?
    @Option(help: "Read the text from this UTF-8 file instead of the arguments or stdin.") var textFile: String?
    @Option(help: ArgumentHelp("An existing folder for a natural voice's temporary files (the app passes one).",
                               visibility: .hidden))
    var scratchDirectory: String?
    @Option(help: ArgumentHelp("A natural voice: the system voice a paragraph it fails is read with (a reading saves it).",
                               visibility: .hidden))
    var fallbackVoice: String?
    @Option(help: ArgumentHelp("A natural voice: on or off, whether paragraphs are heard back (a reading saves it).",
                               visibility: .hidden))
    var check: String?
    @Option(help: ArgumentHelp("The app that started this: when it ends, the render stops and cleans up; another one "
                               + "still writing the same output is waited for.", visibility: .hidden))
    var parentPid: Int32?
    @Option(help: "Maximum seconds to wait for another Voice is Local playback.") var maxWait: Double = 10

    func validate() throws {
        if textFile != nil && !text.isEmpty { throw ValidationError("Give the text or --text-file, not both.") }
        if let check, !["on", "off"].contains(check) { throw ValidationError("--check must be on or off.") }
    }

    @MainActor mutating func run() async throws {
        let input: String
        if let textFile {
            input = try DocumentText.readTextFile(fileURL(textFile), maximumBytes: 16 << 20)
        } else {
            input = try readText(arguments: text)
        }
        let voice = try self.voice.map { try resolveVoice($0, language: nil, explainDefault: false).id }
        let render: (URL) async throws -> RenderedAudio
        if let voice, NaturalVoiceCatalog.isNatural(voice) {
            let scratch = try scratchDirectory.map { path -> URL in
                let url = fileURL(path)
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
                    throw HolosError.invalidInput("--scratch-directory must be an existing folder: \(path)")
                }
                return url
            }
            let renderer = NaturalVoicesCLI.renderer(scratch: scratch)
            let rate = self.rate
            // A reading's part renders with the settings the reading saved when it started.
            var settings = renderer.settings(for: voice)
            if let fallbackVoice { settings?.fallbackVoice = fallbackVoice }
            if let check { settings?.checked = check == "on" }
            let pinned = settings
            render = {
                let result = try await renderer.render(text: input, voiceIdentifier: voice, rate: rate,
                                                       settings: pinned, to: $0)
                if ProcessInfo.processInfo.environment["HOLOS_NATURAL_STATS"] == "1" {
                    let stats = renderer.lastStats
                    Console.error(String(format: "Natural voice: %d paragraphs, %.2f s of audio, %.2f s speaking, "
                        + "%.2f s checking, %d re-rendered, %d read by a system voice", stats.paragraphs,
                        stats.audioSeconds, stats.synthesisSeconds, stats.checkSeconds, stats.rerenders,
                        stats.fallbacks))
                }
                return result
            }
        } else {
            let renderer = NativeSpeechRenderer()
            let rate = self.rate
            render = { try await renderer.render(text: input, voiceIdentifier: voice, rate: rate, to: $0) }
        }
        if let output {
            let url = fileURL(output)
            let result: RenderedAudio
            if let parentPid {
                // The app's helper: it waits for an earlier one still writing this part (left by an app that
                // ended), and stops when the app ends, removing the app's folder for it.
                let scratch = scratchDirectory.map(fileURL)
                result = try await NaturalHelperRun.whileParentRuns(
                    parentPid, isAlive: { getppid() == parentPid }, output: url,
                    waiting: { Console.error("Waiting for an earlier render of \(url.lastPathComponent) to stop.") },
                    parentEnded: {
                        guard let scratch else { return }
                        _ = try? AtomicFile.removeTree([scratch.lastPathComponent],
                                                       in: scratch.deletingLastPathComponent())
                    }) { try await render(url) }
            } else {
                result = try await render(url)
            }
            Console.output(result.url.path)
        } else {
            // The folder is created here (exclusively, 0700) and removed with `AtomicFile.removeTree`, which opens
            // the temporary folder with O_NOFOLLOW and never follows a link inside it.
            let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let temporary = parent.appendingPathComponent("holos-say-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { _ = try? AtomicFile.removeTree([temporary.lastPathComponent], in: parent) }
            let result = try await render(temporary.appendingPathComponent("speech.m4a"))
            if try await !SpeechPlayback.play(file: result.url, maxWait: maxWait) {
                Console.error("Skipped speech because it waited longer than \(maxWait) seconds in the playback queue.")
            }
        }
    }
}
