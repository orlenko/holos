import ArgumentParser
import Foundation
import HolosCore
import HolosSynthesis

struct Voices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect native speech voices.", subcommands: [List.self], defaultSubcommand: List.self)
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List available voice identifiers.")
        @Option(help: "Filter by language prefix, such as en.") var language: String?
        @Flag(help: "Print JSON.") var json = false
        @MainActor mutating func run() async throws {
            let voices = NativeSpeechRenderer.voices().filter { language == nil || $0.language.hasPrefix(language!) }
            if json { try Console.json(voices); return }
            for voice in voices { Console.output("\(voice.name)\t\(voice.language)\t\(voice.quality)\t\(voice.id)") }
        }
    }
}

struct Say: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Speak text locally, or save native speech to an audio file.")
    @Argument(help: "Text to speak; reads UTF-8 stdin when omitted.") var text: [String] = []
    @Option(name: .shortAndLong, help: "Save to .m4a, .wav, or .caf instead of playing.") var output: String?
    @Option(name: .shortAndLong, help: "Exact identifier from holos voices list.") var voice: String?
    @Option(help: "Native AVSpeechUtterance rate, from 0 to 1 (default: system rate).") var rate: Float?
    @Option(help: "Maximum seconds to wait for another Holos playback.") var maxWait: Double = 10

    @MainActor mutating func run() async throws {
        let input = try readText(arguments: text)
        let renderer = NativeSpeechRenderer()
        if let output {
            let result = try await renderer.render(text: input, voiceIdentifier: voice, rate: rate, to: fileURL(output))
            Console.output(result.url.path)
        } else {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("holos-say-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let result = try await renderer.render(text: input, voiceIdentifier: voice, rate: rate, to: temporary.appendingPathComponent("speech.m4a"))
            if try await !SpeechPlayback.play(file: result.url, maxWait: maxWait) {
                Console.error("Skipped speech because it waited longer than \(maxWait) seconds in the playback queue.")
            }
        }
    }
}
