import ArgumentParser
import Darwin
import Dispatch
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import Synchronization

extension Session {
    /// `holos session import` (docs/meeting-design.md §5.5 PR7c).
    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a session from an audio file, transcribe it, and label its speakers.",
            discussion: """
                The audio becomes the session's microphone track (channels mixed to mono) of an in-person meeting. \
                Prints the new session's path on stdout once speaker labelling has ended. Exits 0 when the session \
                was imported and labelled (or labelling was skipped because the speaker models are not installed), \
                3 when it was imported but speaker labelling failed, was skipped for another reason, or was \
                cancelled (printed on stderr), and 1 when nothing was imported. The session appears in the sessions \
                folder only once it is complete; Ctrl-C during the import cancels it and removes its partial files.
                """)

        @Argument(help: "Path to an audio file (WAV, CAF, AIFF, M4A, MP3, or another format macOS reads).")
        var audioFile: String
        @Option(help: "Session display name (default: the file name without its extension).") var name: String?
        @Option(help: "Session output root (default: HOLOS_DATA_DIR or Application Support/Holos/Sessions).")
        var directory: String?
        @OptionGroup var recognition: RecognitionOptions
        @Option(help: "A JSON file of names and terms to recognize ({\"schemaVersion\": 1, \"strings\": [...]}).")
        var vocabularyFile: String?
        @Flag(help: "Import the audio without transcribing it (and without labelling speakers).")
        var noTranscribe = false
        @Flag(help: "Skip speaker labelling after the import.") var noPostprocess = false

        func validate() throws {
            if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--name must not be empty.")
            }
        }

        mutating func run() async throws {
            let file = fileURL(audioFile)
            let fallbackName = file.deletingPathExtension().lastPathComponent
            let request = SessionImportCommand.Request(
                file: file, name: name ?? (fallbackName.isEmpty ? "Imported meeting" : fallbackName),
                root: directory.map(fileURL) ?? HolosPaths.sessions, locale: recognition.locale,
                backend: recognition.backend, vocabulary: try readVocabulary(), transcribe: !noTranscribe,
                postprocess: !noTranscribe && !noPostprocess)
            let work = Task { try await Self.perform(request) }
            // Ctrl-C (or SIGTERM) cancels the work, so a partial import is removed; a second one ends the process.
            let interrupt = InterruptCancellation { work.cancel() }
            defer { interrupt.restore() }
            let code = try await work.value
            if code != 0 { throw ExitCode(code) }
        }

        /// The import, then speaker labelling (`SessionImportCommand`). Returns the exit code for a session that was
        /// imported; throws when nothing was imported.
        private static func perform(_ request: SessionImportCommand.Request) async throws -> Int32 {
            Console.error("Importing \(request.file.lastPathComponent)…")
            let labels = request.transcribe && request.postprocess
            let outcome = try await SessionImportCommand.run(
                request, diarizer: labels ? makeDiarizer(engineOverrides: [:]) : nil, profiles: SpeakerProfileStore(),
                importProgress: importProgressPrinter(), labellingProgress: labellingProgressPrinter())
            if let summary = outcome.summary { Console.error(summary) }
            Console.output(outcome.session.path)
            return outcome.exitCode
        }

        /// The vocabulary file, in the format `holos record start --vocabulary-file` takes. It is only read, so a
        /// symbolic link to it is followed (the no-link rule is for files inside sessions).
        private func readVocabulary() throws -> [String] {
            guard let vocabularyFile else { return [] }
            let url = fileURL(vocabularyFile).resolvingSymlinksInPath()
            guard let data = try AtomicFile.readIfPresent(url, maxBytes: 1 << 20) else {
                throw ValidationError("The vocabulary file \(url.path) does not exist.")
            }
            guard let vocabulary = try? HolosJSON.decoder().decode(MeetingVocabulary.self, from: data),
                  vocabulary.schemaVersion == 1 else {
                throw ValidationError("The vocabulary file is not a Holos vocabulary (schemaVersion 1 with strings).")
            }
            return vocabulary.strings
        }

        /// "Importing: 40 %" on stderr at every tenth.
        private static func importProgressPrinter() -> @Sendable (Double) -> Void {
            let shown = Mutex(-1)
            return { fraction in
                let step = Int((min(1, max(0, fraction)) * 10).rounded(.down))
                let isNew = shown.withLock { previous in
                    guard step > previous else { return false }
                    previous = step
                    return true
                }
                if isNew, step > 0 { Console.error("Importing: \(step * 10) %") }
            }
        }

        /// Each new post-processing message once, on stderr.
        private static func labellingProgressPrinter() -> @Sendable (PostProcessingProgress) -> Void {
            let last = Mutex<String?>(nil)
            return { progress in
                let isNew = last.withLock { previous in
                    guard previous != progress.message else { return false }
                    previous = progress.message
                    return true
                }
                if isNew { Console.error(progress.message) }
            }
        }
    }
}

/// While it exists, SIGINT and SIGTERM call `cancel` once instead of ending the process; after that first signal (or
/// `restore()`) they end it as usual.
private final class InterruptCancellation: Sendable {
    private let sources: [any DispatchSourceSignal]

    init(_ cancel: @escaping @Sendable () -> Void) {
        let fired = Mutex(false)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                let first = fired.withLock { value -> Bool in
                    defer { value = true }
                    return !value
                }
                guard first else { return }
                Console.error("Cancelling… (press Ctrl-C again to quit at once)")
                signal(SIGINT, SIG_DFL)
                signal(SIGTERM, SIG_DFL)
                cancel()
            }
            source.resume()
            return source
        }
    }

    func restore() {
        for source in sources { source.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    deinit { for source in sources { source.cancel() } }
}
