import ArgumentParser
import Foundation
import HolosContent
import HolosCore
import HolosSynthesis

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render a local UTF-8 text or Markdown file as an ordered AAC playlist. Markdown is read verbatim."
    )
    @Argument(help: "Local UTF-8 file path, or - for stdin. URL extraction is not available yet.")
    var source: String
    @Option(help: "Reading directory. Defaults to Application Support/Holos/Readings/<UUID>.")
    var output: String?
    @Option(name: .shortAndLong, help: "Exact identifier from holos voices list.")
    var voice: String?
    @Option(help: "Native AVSpeechUtterance rate, from 0 to 1 (default: system rate).")
    var rate: Float?
    @Flag(help: "Resume an existing reading after verifying source, settings, and part checksums.")
    var resume = false
    @Flag(help: "Play completed parts in playlist order.")
    var play = false

    @MainActor mutating func run() async throws {
        guard !source.hasPrefix("http://"), !source.hasPrefix("https://") else {
            throw HolosError.unavailable("URL extraction is not available yet. Save the article as UTF-8 text or Markdown and pass its file path.")
        }
        guard !resume || output != nil else {
            throw HolosError.invalidInput("--resume requires --output with the existing reading directory.")
        }
        let text: String
        if source == "-" {
            text = try readText(arguments: [])
        } else {
            let input = fileURL(source)
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw HolosError.invalidInput("Reading source does not exist: \(input.path)")
            }
            text = try String(contentsOf: input, encoding: .utf8)
        }
        let directory: URL
        if let output { directory = fileURL(output) }
        else {
            let parent = HolosPaths.applicationSupport.appendingPathComponent("Readings", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        }
        let manifest = try await ReadingPipeline().render(text: text, voiceIdentifier: voice,
                                                           rate: rate, to: directory, resume: resume)
        Console.output(directory.appendingPathComponent("playlist.m3u8").path)
        if play {
            for part in manifest.parts {
                let audio = directory.appendingPathComponent(part.relativeAudioPath)
                guard try await SpeechPlayback.play(file: audio) else {
                    throw HolosError.incomplete("Playback skipped stale part \(part.index + 1). Rendered playlist is saved at \(directory.path).")
                }
            }
        }
    }
}
