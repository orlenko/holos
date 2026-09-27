import ArgumentParser
import Foundation
import HolosContent
import HolosCore
import HolosSynthesis

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read a document aloud into one .m4a audio file.",
        discussion: """
        Reads .txt, .md, .html, .pdf, .rtf, .rtfd, .docx, .doc, and .odt files, or UTF-8 text on \
        stdin (-). Markdown is read as text: headings, emphasis, and links read naturally; code \
        blocks and images are skipped.

        Writes one AAC .m4a (mono, 22.05 kHz, about 32 kbit/s, about 14 MB per hour) named after \
        the document's title, with a chapter at each heading. It plays on iPhone, Android, Windows, \
        and in browsers; share it with AirDrop, Messages, or Mail. Prints the file's path.

        Without --output the file goes in Application Support/Holos/Readings/<UUID>/. The voice is \
        the best installed one (Premium, then Enhanced) for the text's language unless --voice says \
        otherwise; `voiceislocal voices list` shows each voice's quality.

        An interrupted reading continues where it stopped: run the same command with --resume. A \
        reading made without --output resumes with --output set to its Readings folder.
        """
    )
    @Argument(help: "Local file path, or - for UTF-8 text on stdin. Web addresses are not supported yet.")
    var source: String
    @Option(name: .shortAndLong, help: "A .m4a file path, or an existing directory to write <Title>.m4a in.")
    var output: String?
    @Option(name: .shortAndLong, help: ArgumentHelp(
        "Voice name as `say -v '?'` or `voiceislocal voices list` prints it, such as \"Ava (Premium)\", or its identifier.",
        valueName: "name"))
    var voice: String?
    @Option(help: "Native AVSpeechUtterance rate, from 0 to 1 (default: system rate).")
    var rate: Float?
    @Option(help: "Title for the file name and the audio's metadata, instead of the document's own.")
    var title: String?
    @Flag(help: "Continue an interrupted reading after verifying its source, settings, and rendered parts.")
    var resume = false
    @Flag(help: "Play the finished file.")
    var play = false
    @Flag(help: "Print the title, voice, chapters, and text that would be read, without rendering.")
    var printText = false

    @MainActor mutating func run() async throws {
        guard !source.hasPrefix("http://"), !source.hasPrefix("https://") else {
            throw HolosError.unavailable("Reading web addresses is not available yet. Save the page (.html) or its text and pass the file path.")
        }
        guard !resume || output != nil else {
            throw HolosError.invalidInput("--resume needs --output: the same .m4a path or directory as before, or the Readings folder of a reading made without --output.")
        }
        let document: ReadableDocument
        let fallbackName: String?
        if source == "-" {
            document = PlainTextReader.document(from: try readText(arguments: []))
            fallbackName = nil
        } else {
            let input = fileURL(source)
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw HolosError.invalidInput("Reading source does not exist: \(input.path)")
            }
            document = try DocumentLoader.load(input)
            fallbackName = input.deletingPathExtension().lastPathComponent
        }
        let script = ReadingScript(document: document)
        let language = document.language ?? ReadingLanguage.detect(script.text)
        let selected = try resolveVoice(voice, language: language, explainDefault: true)
        let metadata = AudioBookMetadata(
            title: title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? document.title ?? fallbackName,
            author: document.author, language: language)
        if printText {
            Console.output("Title: \(metadata.title ?? "-")")
            if let author = metadata.author { Console.output("Author: \(author)") }
            Console.output("Language: \(language ?? "unknown")")
            Console.output("Voice: \(VoiceSelection.displayNames(NativeSpeechRenderer.voices())[selected.id] ?? selected.name) (\(selected.id))")
            Console.output("File: \(ReadingOutput.fileName(title: metadata.title, fallback: fallbackName))")
            Console.output("Chapters: \(script.segments.compactMap(\.chapter).joined(separator: " | "))")
            Console.output("")
            Console.output(script.text)
            return
        }

        let readings = HolosPaths.supportRoot.appendingPathComponent("Readings", isDirectory: true)
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
        let identity = [selected.id, rate.map { "\($0)" } ?? "", metadata.title ?? "", metadata.author ?? "", script.text]
            .joined(separator: "\u{1}")
        let location = try ReadingOutput.locate(
            output: output, name: ReadingOutput.fileName(title: metadata.title, fallback: fallbackName),
            identity: identity, readingsRoot: readings)
        let result: ReadingResult
        do {
            result = try await ReadingPipeline().render(script: script, voiceIdentifier: selected.id, rate: rate,
                                                        metadata: metadata, location: location, resume: resume)
        } catch HolosError.incomplete(let message) {
            throw HolosError.incomplete(message + "\nTo continue, run the same command with --resume --output \"\(output ?? location.workDirectory.path)\".")
        }
        Console.output(result.output.path)
        if play {
            guard try await SpeechPlayback.play(file: result.output) else {
                throw HolosError.incomplete("Playback skipped: another Voice is Local playback kept it waiting. The reading is saved at \(result.output.path).")
            }
        }
    }
}

/// `--voice` by name or identifier; without it, the best installed voice for `language`.
@MainActor func resolveVoice(_ query: String?, language: String?, explainDefault: Bool) throws -> VoiceDescriptor {
    let voices = NativeSpeechRenderer.voices()
    if let query {
        guard let match = VoiceSelection.match(query, in: voices, language: language) else {
            throw HolosError.unavailable("No installed voice is named \"\(query)\". See: voiceislocal voices list")
        }
        return match
    }
    let wanted = language ?? Locale.preferredLanguages.first ?? "en-US"
    let chosen: VoiceDescriptor
    if let best = NativeSpeechRenderer.bestVoice(language: wanted) {
        chosen = best
    } else {
        let fallback = try NativeSpeechRenderer.defaultVoiceIdentifier()
        guard let voice = voices.first(where: { $0.id == fallback }) else {
            throw HolosError.unavailable("Speech voice is unavailable: \(fallback)")
        }
        if explainDefault { Console.error("No installed voice speaks \(wanted); reading with \(voice.name).") }
        chosen = voice
    }
    if explainDefault && chosen.quality != "premium" { Console.error(VoiceSelection.premiumVoicesHint) }
    return chosen
}
