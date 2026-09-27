import ArgumentParser
import Foundation
import HolosContent
import HolosCore
import HolosSynthesis

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render a web article, or a local UTF-8 text or Markdown file, as an ordered AAC playlist.",
        discussion: """
            An https:// address is loaded in an offscreen web view (no cookies or history are kept) and reduced \
            to its article with Mozilla Readability: title, byline, headings, paragraphs, and list items. Code \
            blocks, tables, figures, and captions are skipped. Pages behind a sign-in or paywall usually fail; \
            save their text to a file instead. Markdown files are read verbatim.
            """
    )
    @Argument(help: "An https:// web address, a local UTF-8 file path, or - for stdin.")
    var source: String
    @Option(help: "Reading directory. Defaults to Application Support/Holos/Readings/<UUID>.")
    var output: String?
    @Option(name: .shortAndLong, help: "Exact identifier from voiceislocal voices list.")
    var voice: String?
    @Option(help: "Native AVSpeechUtterance rate, from 0 to 1 (default: system rate).")
    var rate: Float?
    @Flag(help: "Resume an existing reading after verifying source, settings, and part checksums.")
    var resume = false
    @Flag(help: "Play completed parts in playlist order.")
    var play = false
    @Flag(help: "Print the text that would be read, and exit without rendering.")
    var printText = false

    @MainActor mutating func run() async throws {
        guard !resume || output != nil else {
            throw HolosError.invalidInput("--resume requires --output with the existing reading directory.")
        }
        let text: String
        if let address = try webAddress(source) {
            // Every text in a WebArticle is already sanitized (no control or format characters), so the page's
            // title, address, and paragraphs are safe to print.
            let article = try await WebArticleExtractor().extract(from: address)
            Console.error("\(article.title) (\(article.wordCount) words, \(article.address))")
            text = article.spokenText
        } else if source == "-" {
            text = try readText(arguments: [])
        } else {
            let input = fileURL(source)
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw HolosError.invalidInput("Reading source does not exist: \(input.path)")
            }
            text = try String(contentsOf: input, encoding: .utf8)
        }
        if printText {
            Console.output(text)
            return
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

/// The web address in a `read` source, or nil for a file path. Only https is read; http is refused with a hint.
private func webAddress(_ source: String) throws -> URL? {
    let lowered = source.lowercased()
    if lowered.hasPrefix("http://") {
        throw HolosError.invalidInput("Only https:// addresses can be read. Try the https:// form of \(source).")
    }
    guard lowered.hasPrefix("https://") else { return nil }
    guard let url = URL(string: source), url.host() != nil else {
        throw HolosError.invalidInput("Not a valid web address: \(source)")
    }
    return url
}
