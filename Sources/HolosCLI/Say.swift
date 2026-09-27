import ArgumentParser
import Foundation
import HolosCore
import HolosStorage
import HolosSynthesis

struct Voices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect native speech voices.", subcommands: [List.self], defaultSubcommand: List.self)
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List installed voices: name, language, quality (premium, enhanced, default), identifier.")
        @Option(help: "Filter by language prefix, such as en.") var language: String?
        @Flag(help: "Print JSON.") var json = false
        @MainActor mutating func run() async throws {
            let installed = NativeSpeechRenderer.voices()
            let names = VoiceSelection.displayNames(installed)
            let voices = installed.filter { language == nil || $0.language.hasPrefix(language!) }
                .sorted { lhs, rhs in
                    if lhs.language != rhs.language { return lhs.language < rhs.language }
                    let lhsRank = VoiceSelection.qualityRank(lhs.quality), rhsRank = VoiceSelection.qualityRank(rhs.quality)
                    if lhsRank != rhsRank { return lhsRank > rhsRank }
                    return (names[lhs.id] ?? lhs.name) < (names[rhs.id] ?? rhs.name)
                }
            if json { try Console.json(voices); return }
            for voice in voices {
                Console.output("\(names[voice.id] ?? voice.name)\t\(voice.language)\t\(voice.quality)\t\(voice.id)")
            }
            if !voices.contains(where: { $0.quality == "premium" }) {
                Console.error(VoiceSelection.premiumVoicesHint)
            }
        }
    }
}

struct Say: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Speak text locally, or save native speech to an audio file.")
    @Argument(help: "Text to speak; reads UTF-8 stdin when omitted.") var text: [String] = []
    @Option(name: .shortAndLong, help: "Save to .m4a, .wav, or .caf instead of playing.") var output: String?
    @Option(name: .shortAndLong, help: ArgumentHelp(
        "Voice name as `voiceislocal voices list` prints it, such as \"Ava (Premium)\", or its identifier.",
        valueName: "name")) var voice: String?
    @Option(help: "Native AVSpeechUtterance rate, from 0 to 1 (default: system rate).") var rate: Float?
    @Option(help: "Maximum seconds to wait for another Voice is Local playback.") var maxWait: Double = 10

    @MainActor mutating func run() async throws {
        let input = try readText(arguments: text)
        let renderer = NativeSpeechRenderer()
        let voice = try self.voice.map { try resolveVoice($0, language: nil, explainDefault: false).id }
        if let output {
            let result = try await renderer.render(text: input, voiceIdentifier: voice, rate: rate, to: fileURL(output))
            Console.output(result.url.path)
        } else {
            // The folder is created here (exclusively, 0700) and removed with `AtomicFile.removeTree`, which opens
            // the temporary folder with O_NOFOLLOW and never follows a link inside it.
            let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let temporary = parent.appendingPathComponent("holos-say-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { _ = try? AtomicFile.removeTree([temporary.lastPathComponent], in: parent) }
            let result = try await renderer.render(text: input, voiceIdentifier: voice, rate: rate, to: temporary.appendingPathComponent("speech.m4a"))
            if try await !SpeechPlayback.play(file: result.url, maxWait: maxWait) {
                Console.error("Skipped speech because it waited longer than \(maxWait) seconds in the playback queue.")
            }
        }
    }
}
