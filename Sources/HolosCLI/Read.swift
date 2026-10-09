import ArgumentParser
import Foundation
import HolosContent
import HolosCore
import HolosMeeting
import HolosSynthesis

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read a document or a web article aloud into one .m4a audio file.",
        discussion: """
        Reads .txt, .md, .html, .pdf, .rtf, .rtfd, .docx, .doc, and .odt files, UTF-8 text on \
        stdin (-), or an https:// web address. Markdown is read as text: headings, emphasis, and \
        links read naturally; code blocks and images are skipped.

        A web address is loaded in an offscreen web view (no cookies or history are kept) and \
        reduced to its article with Mozilla Readability: title, byline (the file's author), \
        headings, paragraphs, and list items. Code blocks, tables, figures, and captions are \
        skipped. Pages behind a sign-in or paywall usually fail; save their text to a file instead.

        Writes one AAC .m4a (mono, 22.05 kHz, about 32 kbit/s, about 14 MB per hour) named after \
        the document's title, with a chapter at each heading. It plays on iPhone, Android, Windows, \
        and in browsers; share it with AirDrop, Messages, or Mail. Prints the file's path.

        Without --output the file goes in Application Support/Holos/Readings/<UUID>/. The voice is \
        the best installed one (Premium, then Enhanced) for the text's language unless --voice says \
        otherwise; `voiceislocal voices list` shows each voice's quality.

        An interrupted reading continues where it stopped: run the same command with --resume. A \
        reading made without --output resumes with --output set to its Readings folder. A web page \
        is loaded again; if its text changed since, the reading is refused.

        While a reading runs, a hidden .holos-output-<hash>.lock file beside --output reserves the \
        file, so a second reading of it is refused before it renders. It is removed when the \
        reading ends, and one a killed reading left behind is taken over once that process is \
        gone. If a reading is refused over one made on another computer or one it cannot remove, \
        the message names the file: delete it when no reading of that file is running.
        """
    )
    @Argument(help: "An https:// web address, a local file path, or - for UTF-8 text on stdin.")
    var source: String
    @Option(name: .shortAndLong, help: "A .m4a file path, or an existing directory to write <Title>.m4a in.")
    var output: String?
    @Option(name: .shortAndLong, help: ArgumentHelp(
        "Voice name as `say -v '?'` or `voiceislocal voices list` prints it, such as \"Ava (Premium)\", or its identifier.",
        valueName: "name"))
    var voice: String?
    @Option(parsing: .unconditional, help: speechRateHelp, transform: parseSpeechRate)
    var rate: Float?
    @Option(help: "Title for the file name and the audio's metadata, instead of the document's own.")
    var title: String?
    @Flag(help: "Continue an interrupted reading after verifying its source, settings, and rendered parts.")
    var resume = false
    @Flag(help: "Play the finished file.")
    var play = false
    @Flag(help: "Print the title, voice, output file, chapters, and text that would be read, without rendering.")
    var printText = false

    /// Settings are checked before anything is loaded or created (`--rate` as it is parsed).
    func validate() throws {
        if let title, AudioBookMetadata.usableTitle(title) == nil {
            throw ValidationError("--title has no readable text.")
        }
    }

    @MainActor mutating func run() async throws {
        let address = try webAddress(source)
        guard !resume || output != nil else {
            throw HolosError.invalidInput("--resume needs --output: the same .m4a path or directory as before, or the Readings folder of a reading made without --output.")
        }
        // A local file or stdin is read before the interrupt handling below, so Ctrl-C while
        // stdin is read ends the process as usual; a web page is loaded under it.
        let pending: PendingSource
        if let address {
            pending = .web(address)
        } else if source == "-" {
            pending = .loaded(LoadedDocument(document: PlainTextReader.document(from: try readText(arguments: [])),
                                             fallbackName: nil))
        } else {
            let input = fileURL(source)
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw HolosError.invalidInput("Reading source does not exist: \(input.path)")
            }
            pending = .loaded(LoadedDocument(document: try DocumentLoader.load(input),
                                             fallbackName: input.deletingPathExtension().lastPathComponent))
        }
        let request = ReadRequest(output: output, voice: voice, rate: rate, title: title, resume: resume,
                                  printText: printText)
        // Ctrl-C (or SIGTERM) cancels the page load or the render, so its cleanup runs (the partly
        // joined file is removed; rendered parts are kept for --resume), then the command exits
        // 130 (143). A second one ends the process at once; the next run removes what that leaves
        // behind. The handling is installed before the work starts, so a signal in between
        // cancels it too.
        let progress = ReadProgress()
        let work = CancellableStart<URL?>()
        let interrupt = InterruptCancellation(notice: {
            Console.error("Stopping… (press Ctrl-C again to quit at once)")
        }) { work.cancel() }
        defer { interrupt.restore() }
        let finished: URL?
        do {
            finished = try await work.start { @MainActor in
                let document: LoadedDocument
                switch pending {
                case .loaded(let loaded): document = loaded
                case .web(let address): document = try await Self.load(address)
                }
                return try await Self.read(document, request: request, progress: progress)
            }.value
        } catch {
            interrupt.restore()
            if let signal = interrupt.signal {
                Console.error(progress.resumeHint.map { "Reading interrupted. \($0)" } ?? "Reading interrupted.")
                throw ExitCode(InterruptLatch.exitCode(for: signal))
            }
            if case HolosError.incomplete(let message) = error, let hint = progress.resumeHint {
                throw HolosError.incomplete(message + "\n" + hint)
            }
            throw error
        }
        // Playback is not part of the render: Ctrl-C there ends the process as usual.
        interrupt.restore()
        guard let finished else { return }
        Console.output(finished.path)
        if play {
            guard try await SpeechPlayback.play(file: finished) else {
                throw HolosError.incomplete("Playback skipped: another Voice is Local playback kept it waiting. The reading is saved at \(finished.path).")
            }
        }
    }

    /// Loads the page at `address` and reduces it to its article, as a document to read.
    @MainActor private static func load(_ address: URL) async throws -> LoadedDocument {
        // Every text in a WebArticle is already sanitized (no control or format characters), so the
        // page's title and address are safe to print.
        let article = try await WebArticleExtractor().extract(from: address)
        Console.error("\(article.title) (\(article.wordCount) words, \(article.address))")
        return LoadedDocument(document: article.document, fallbackName: article.url.host())
    }

    /// Prints the reading (`--print-text`) and returns nil, or renders it and returns the finished file.
    @MainActor private static func read(_ loaded: LoadedDocument, request: ReadRequest,
                                        progress: ReadProgress) async throws -> URL? {
        let document = loaded.document, fallbackName = loaded.fallbackName
        let script = ReadingScript(document: document)
        // A declared language that is not a usable tag ("english") is ignored, not trusted.
        let language = AudioBookMetadata.languageTag(document.language) ?? ReadingLanguage.detect(script.text)
        // The first title with readable text: `--title` (checked in `validate`), the document's,
        // then the file's name.
        let metadata = AudioBookMetadata(
            title: [request.title, document.title, fallbackName].lazy.compactMap(AudioBookMetadata.usableTitle).first,
            author: document.author, language: language)
        let name = ReadingOutput.fileName(title: metadata.title, fallback: fallbackName)
        // The support folder as configured, checked against the spelling the caches use.
        let readings = try ReadingOutput.readingsRoot(support: HolosPaths.supportRoot,
                                                      configured: ProcessInfo.processInfo.environment["HOLOS_SUPPORT_DIR"],
                                                      create: !request.printText)
        func cacheIdentity(_ voice: String) -> String {
            ReadingPipeline.identity(script: script, voiceIdentifier: voice, rate: request.rate, metadata: metadata)
        }
        // A resume without --voice keeps the voice the reading was started with, which the default may no longer be
        // (natural voices installed since).
        let saved = request.resume && request.voice == nil
            ? try ReadingResumeVoice.saved(output: request.output, name: name, readingsRoot: readings,
                                           candidates: defaultVoiceCandidates(language: language),
                                           identity: cacheIdentity)
            : nil
        let selected = try saved.map(savedVoice) ?? resolveVoice(request.voice, language: language, explainDefault: true)
        let identity = cacheIdentity(selected.id)
        if request.printText {
            let voiceName = NaturalVoiceCatalog.voice(id: selected.id)?.title
                ?? VoiceSelection.displayNames(NativeSpeechRenderer.voices())[selected.id] ?? selected.name
            // The file this command would write, resolved as below but with nothing created.
            Console.output(try ReadingPreview.printed(
                script: script, metadata: metadata, voiceName: voiceName, voiceID: selected.id,
                output: request.output, fileName: name, identity: identity, readingsRoot: readings))
            return nil
        }

        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
        let location = try ReadingOutput.locate(output: request.output, name: name, identity: identity,
                                                readingsRoot: readings, resume: request.resume)
        if try request.resume && !ReadingOutput.exists(location.workDirectory) {
            // With an explicit output the cache is keyed by the text and settings, so a changed
            // source (a web page that was edited since) or setting finds no reading here.
            throw HolosError.invalidInput("No reading to resume for \(location.output.path): none was started with this output, or its source, voice, rate, or title has changed since.")
        }
        progress.resumeHint = "To continue, run the same command with --resume --output \"\(request.output ?? location.workDirectory.path)\"."
        let renderer = RoutingSpeechRenderer(natural: NaturalVoicesCLI.renderer())
        let result = try await ReadingPipeline(renderer: renderer).render(
            script: script, voiceIdentifier: selected.id, rate: request.rate, metadata: metadata,
            location: location, resume: request.resume)
        // The file is published: bookkeeping that failed after that is a warning, not a failure.
        for warning in result.warnings { Console.error("Warning: \(warning)") }
        return result.output
    }
}

/// A `read` source before the work starts: a local file or stdin is already loaded; a web page
/// is loaded by the work, under the interrupt handling.
private enum PendingSource: Sendable {
    case loaded(LoadedDocument)
    case web(URL)
}

/// A document to read and the file name to use when it has no title.
private struct LoadedDocument: Sendable {
    let document: ReadableDocument
    let fallbackName: String?
}

/// The options of one `read`, as the work task takes them.
private struct ReadRequest: Sendable {
    let output: String?
    let voice: String?
    let rate: Float?
    let title: String?
    let resume: Bool
    let printText: Bool
}

/// How far a `read` got: set once rendering starts, so an interruption or failure before that
/// suggests no `--resume`.
@MainActor private final class ReadProgress {
    var resumeHint: String?
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

let speechRateHelp = ArgumentHelp(
    "Native AVSpeechUtterance rate, from \(SpeechRate.range.lowerBound) to \(SpeechRate.range.upperBound) (default: system rate).",
    valueName: "rate")

/// `--rate` as typed: a finite number in `SpeechRate.range` ("nan", "inf", and "-1" are refused
/// with the range), checked while the command line is parsed, before anything is created.
@Sendable func parseSpeechRate(_ text: String) throws -> Float {
    do {
        return try SpeechRate.parse(text)
    } catch HolosError.invalidInput(let message) {
        throw ValidationError(message)
    }
}

/// The voices a reading in `language` may have been started with without `--voice` (see
/// `ReadingResumeVoice.candidates`).
@MainActor func defaultVoiceCandidates(language: String?) throws -> [String] {
    ReadingResumeVoice.candidates(
        language: language ?? Locale.preferredLanguages.first ?? "en-US",
        apple: try resolveVoice(nil, language: language, explainDefault: false, allowNatural: false).id)
}

/// The voice a reading being resumed was started with, by identifier; it must still be there.
@MainActor func savedVoice(_ id: String) throws -> VoiceDescriptor {
    if NaturalVoiceCatalog.isNatural(id) {
        // Found by its cache; whether its pack is still installed is told now, with how to get it back.
        guard let voice = NaturalVoiceCatalog.voice(id: id) else {
            throw HolosError.unavailable("The voice this reading was started with is not available: \(id)")
        }
        guard NaturalVoiceModels.installedPacks().contains(voice.pack) else {
            throw HolosError.unavailable("This reading was started with \(voice.title), and the \(voice.pack.languageName) "
                + "natural voices are no longer installed. Run voiceislocal setup --natural-voices"
                + (voice.pack == .english ? "" : " --language \(voice.pack.languageCode)") + ", then resume.")
        }
        return voice.descriptor
    }
    guard let voice = NativeSpeechRenderer.voices().first(where: { $0.id == id }) else {
        throw HolosError.unavailable("The voice this reading was started with is not installed any more: \(id)")
    }
    return voice
}

/// `--voice` by name or identifier (an Apple voice, or a natural voice such as "pocket:en:alba"); without it, the
/// natural voice for `language` once its pack is installed (`allowNatural`), else the best installed Apple voice.
@MainActor func resolveVoice(_ query: String?, language: String?, explainDefault: Bool,
                             allowNatural: Bool = true) throws -> VoiceDescriptor {
    let voices = NativeSpeechRenderer.voices()
    if let query {
        if NaturalVoiceCatalog.isNatural(query), !allowNatural {
            throw HolosError.unavailable("Natural voices cannot be used here: \(query)")
        }
        // An Apple voice of that name goes first ("Alba" could be both); then a natural one.
        if NaturalVoiceCatalog.isNatural(query) || VoiceSelection.match(query, in: voices, language: language) == nil,
           allowNatural, let natural = try NaturalVoicesCLI.resolve(query) {
            return natural.descriptor
        }
        guard let match = VoiceSelection.match(query, in: voices, language: language) else {
            throw HolosError.unavailable("No installed voice is named \"\(query)\". See: voiceislocal voices list")
        }
        return match
    }
    let wanted = language ?? Locale.preferredLanguages.first ?? "en-US"
    if allowNatural, let natural = NaturalVoiceCatalog.defaultVoice(language: wanted,
                                                                   installed: NaturalVoiceModels.installedPacks()) {
        return natural.descriptor
    }
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
