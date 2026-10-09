import ArgumentParser
import Foundation
import HolosCore
import HolosEvaluation
import HolosMeeting
import HolosStorage

/// `voiceislocal eval` (docs/reference-evaluation.md, "Cloud reference"): a developer tool that compares the local
/// transcript with a cloud model's. Nothing here runs in the app, and nothing leaves the Mac except through
/// `eval cloud`, after the user says yes.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare a session's transcript with a cloud model's, and review the differences (developer tool).",
        discussion: """
            eval cloud uploads the session's audio to OpenAI: the meeting leaves this Mac. Use it only with the \
            consent of everyone who was recorded. Results stay in the session folder under eval/; the app and the \
            exports never read them.
            """,
        subcommands: [Cloud.self, Local.self, Compare.self, Review.self, Apply.self, List.self, Delete.self])

    struct Cloud: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a session's audio to OpenAI for a reference transcript (the audio leaves this Mac).",
            discussion: """
                Renders each track, cuts it at pauses into segments of at most 5 minutes, shows what will be sent \
                and what it costs, and asks before uploading (--yes skips the question; without a terminal, --yes \
                is required). Each answer is saved as it arrives, in eval/cloud/<run>/; Ctrl-C stops, and running \
                the same command again resumes the unfinished run. Reads the key from OPENAI_API_KEY; the key is \
                never saved or printed. With --vocabulary, your word list, people's names, and the words of your \
                corrections are sent too (as keywords and a prompt, in that order, as the recognizer gets them). With --timestamps, each segment is also sent to whisper-1 for \
                word times (twice the uploads and about twice the cost).
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Option(help: "OpenAI transcription model.") var model = CloudModels.defaultModel
        @Option(help: "Tracks to send, comma-separated (default: every track).") var tracks: String?
        @Flag(help: "Also send your word list, people's names, and your correction words as hints.")
        var vocabulary = false
        @Flag(help: "Also send each segment to whisper-1 for word timestamps.") var timestamps = false
        @Option(name: .customLong("run"),
                help: "Resume this unfinished run (default: the newest unfinished run with the same settings).")
        var runID: String?
        @Flag(help: "Upload without asking.") var yes = false

        mutating func run() async throws {
            let directory = try SessionLocator.resolve(session)
            let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { throw HolosError.invalidInput("Set OPENAI_API_KEY to your OpenAI API key.") }
            let trackList = tracks.map {
                $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let options = CloudEvaluation.Options(model: model, tracks: trackList, vocabulary: vocabulary,
                                                  timestamps: timestamps, runID: runID)
            let request = EvalCloudCommand.Request(
                session: directory, sessionArgument: session, options: options,
                vocabulary: EvalUserFiles().cloudVocabulary, client: CloudTranscriptionClient(apiKey: key))
            let assumeYes = yes
            let outcome = try await EvalCloudCommand.run(
                request, interruption: Eval.interruption,
                consent: {
                    ConsentGate.decide(assumeYes: assumeYes, isTerminal: isatty(STDIN_FILENO) != 0, readAnswer: {
                        FileHandle.standardError.write(Data("Upload to OpenAI? [y/N] ".utf8))
                        return readLine()
                    })
                },
                report: Eval.printMessage)
            switch outcome {
            case .uploaded: break
            case .declined, .noTerminal, .failed: throw ExitCode(1)
            case .cancelled: throw ExitCode(EvalInterrupt.lastExitCode)
            }
        }
    }

    struct Compare: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare the local transcript with a cloud run, per track and time window.",
            discussion: """
                Writes eval/compare/<run>/report.md and report.json (for a local candidate, in \
                eval/compare/<run>/<local run>/): word error rates against each transcript (neither is taken as \
                the truth), normalized by default (numbers written in digits or words, fillers, and compounds are \
                not errors; --raw counts them), how often your word-list terms and corrections' meant phrases are \
                found where the cloud has them, and the passages where the transcripts differ, grouped as names and \
                terms, numbers, dropped or added words, other words, formatting only, and case or punctuation only. \
                Microphone words that are echo of the system track are left out, as in the exports.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Option(name: .customLong("run"), help: "The cloud run (default: the newest finished one).") var runID: String?
        @Option(help: "The local transcript: current (default), latest (the newest finished eval local run), or a local run ID.")
        var local = "current"
        @Flag(help: "Count every word difference (numbers, fillers, compounds too) and review every passage.")
        var raw = false

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            try EvalCompareCommand.run(
                EvalCompareCommand.Request(session: directory, runID: runID, local: local, raw: raw),
                report: Eval.printMessage)
        }
    }

    /// Prints what an eval command reports: content on stdout, notes on stderr.
    static let printMessage: @Sendable (EvalCommandMessage) -> Void = { message in
        switch message {
        case .output(let text): Console.output(text)
        case .note(let text): Console.error(text)
        }
    }

    /// Ctrl-C or SIGTERM stops an eval command's long steps (`EvalInterrupt`).
    static let interruption: any EvalInterruption = SignalInterruption()

    private struct SignalInterruption: EvalInterruption {
        func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
            try await EvalInterrupt.run(operation)
        }
    }

    struct Local: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Transcribe all of a session's saved audio again, as a candidate to compare (nothing leaves this Mac).",
            discussion: """
                Transcribes every track of the saved audio with Apple's speech recognition as the post-processing \
                languages stage does (final results only), in the meeting's languages (or --language), with \
                today's vocabulary: your word list, then people's names, then the words of your corrections, as a \
                meeting starting now would get it (--no-vocabulary: none). Several languages are merged as the \
                languages stage merges them. Meeting word fixes follow unless --no-word-fixes. Saves the result as \
                eval/local/<run>/ (run.json with the exact \
                vocabulary and settings, each track's transcription as it is done, transcript.json); the meeting's \
                transcript, speaker labels, exports, and vocabulary.json are never changed. Ctrl-C stops; running \
                the same command again resumes. Then: voiceislocal eval compare <session> --local latest. \
                --backend whisper transcribes with the deep transcription model instead (voiceislocal setup \
                --whisper), exactly as voiceislocal session deep-transcribe does: one language, prompted with the \
                meeting's name, the word list, and people's names (the meeting's vocabulary.json first), with \
                passages over silence and repetition loops left out.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Option(help: "Transcribe in this language only (like en-CA), instead of the meeting's.") var language: String?
        @Flag(help: "Transcribe without any vocabulary.") var noVocabulary = false
        @Flag(help: "Keep the recognized words without applying meeting word fixes.") var noWordFixes = false
        @Option(name: .customLong("run"), help: "Resume this unfinished local run.") var runID: String?
        @Option(help: "What transcribes: apple (Apple's speech recognition) or whisper (the deep transcription model).")
        var backend: EvalLocal.Backend = .apple

        mutating func run() async throws {
            let directory = try SessionLocator.resolve(session)
            let request = EvalLocalCommand.Request(
                session: directory, sessionArgument: session, language: language, noVocabulary: noVocabulary,
                wordFixes: !noWordFixes, runID: runID, backend: backend)
            let dependencies = EvalLocalCommand.Dependencies(wordFixes: makeWordFixDependencies(),
                                                             deepTranscription: makeDeepTranscriptionDependencies())
            do {
                try await EvalLocalCommand.run(request, dependencies: dependencies, interruption: Eval.interruption,
                                               report: Eval.printMessage)
            } catch let unreadable as EvalLocalCommand.VocabularyUnreadable {
                throw ValidationError(unreadable.message)
            } catch is CancellationError {
                throw ExitCode(EvalInterrupt.lastExitCode)
            }
        }
    }

    struct Review: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write and open a page to review the differing passages with the audio.",
            discussion: """
                Writes eval/review/<run>/review.html and review-audio/<track>.m4a next to it (a copy of the \
                session's audio, removed by Delete Audio), then opens the page. The page works offline; your \
                decisions are kept in the browser and exported as decisions.json for voiceislocal eval apply. \
                Compares again first when there is no comparison of the current transcript.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Option(name: .customLong("run"), help: "The cloud run (default: the newest finished one).") var runID: String?
        @Flag(help: "Write the page without opening it.") var noOpen = false

        mutating func run() async throws {
            let directory = try SessionLocator.resolve(session)
            try await EvalReviewCommand.run(
                EvalReviewCommand.Request(session: directory, runID: runID), interruption: Eval.interruption,
                open: noOpen ? nil : Self.open, report: Eval.printMessage)
        }

        /// Opens the page in the default browser.
        static func open(_ page: URL) throws {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [page.path]
            try open.run()
            open.waitUntilExit()
        }
    }

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make a reference transcript from review decisions, and propose corrections and word-list terms.",
            discussion: """
                Writes eval/gold/<run>.json: the local transcript with each reviewed passage replaced by its \
                decided text. Prints the heard → meant pairs (word substitutions of at most 3 words) and the \
                terms you marked. Where real words were replaced by a term of your word list or a marked term \
                (local "cloud", cloud "Claude"), the pair is proposed as an often-heard-as word of that term \
                instead of a correction, since those words are often meant as they are; a pair with a word that is \
                not a real word stays a correction. Nothing is added unless you pass --add-corrections (the \
                corrections, to your corrections) or --add-vocabulary (the marked terms, to your word list, as \
                voiceislocal words add does, then the often-heard-as words, to their terms). Each addition is made \
                under that file's lock; a running Voice is Local picks it up and never saves over it.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "decisions.json exported by the review page.") var decisions: String
        @Flag(help: "Add the proposed heard → meant pairs to your corrections.") var addCorrections = false
        @Flag(help: "Add the marked terms to your word list, and the proposed often-heard-as words to their terms.")
        var addVocabulary = false

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            let request = EvalApplyCommand.Request(
                session: directory, decisions: fileURL(decisions).resolvingSymlinksInPath(),
                addCorrections: addCorrections, addVocabulary: addVocabulary)
            let outcome = try EvalApplyCommand.run(request, report: Eval.printMessage)
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a session's evaluation runs.")
        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            let ids = EvalStore.runIDs(in: directory)
            let locals = EvalLocal.runIDs(in: directory)
            if ids.isEmpty && locals.isEmpty { Console.output("No evaluation runs."); return }
            for id in locals {
                guard let record = try? EvalLocal.record(id, in: directory) else {
                    Console.output("\(id)  (unreadable)")
                    continue
                }
                let status = record.completedAt == nil
                    ? "unfinished, \(EvalLocal.savedParts(record, in: directory)) of \(record.partCount) tracks"
                    : "complete"
                let vocabulary = record.vocabularySource == "none" ? "no vocabulary"
                    : "vocabulary \(record.vocabulary.count)"
                let wordFixes = record.textSteps.contains(PostProcessingStage.wordFixes.rawValue)
                    ? "word fixes" : "no word fixes"
                let compared = ids.contains { cloud in
                    FileManager.default.fileExists(atPath: EvalPaths.compare(cloud, local: id, in: directory).path)
                }
                let minutes = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), record.seconds / 60)
                Console.output("\(id)  local  \(record.languages.joined(separator: ","))  "
                    + "\(record.tracks.map(\.track).joined(separator: ","))  \(minutes) min  \(status)  \(vocabulary)  "
                    + wordFixes
                    + (compared ? "  compared" : ""))
            }
            for id in ids {
                guard let record = try? EvalStore.runRecord(id, in: directory) else {
                    Console.output("\(id)  (unreadable)")
                    continue
                }
                let saved = EvalStore.savedSegments(record, in: directory)
                let status = record.completedAt == nil ? "unfinished, \(saved) of \(record.uploadCount) segments"
                    : "complete"
                var extras: [String] = []
                let fm = FileManager.default
                if fm.fileExists(atPath: EvalPaths.compare(id, in: directory).path) { extras.append("compared") }
                if fm.fileExists(atPath: EvalPaths.review(id, in: directory).path) { extras.append("review page") }
                if fm.fileExists(atPath: EvalPaths.gold(id, in: directory).path) { extras.append("gold") }
                let minutes = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"),
                                     record.uploadSeconds / 60)
                Console.output("\(id)  \(record.model)  \(record.tracks.map(\.track).joined(separator: ","))  "
                    + "\(minutes) min  \(status)" + (record.vocabulary ? "  vocabulary" : "")
                    + (extras.isEmpty ? "" : "  " + extras.joined(separator: ", ")))
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete an evaluation run (a cloud run's results, comparison, review page, and gold; a local run "
                + "and its comparisons), or all.")
        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The run to delete.") var runID: String?
        @Flag(help: "Delete every evaluation file of the session.") var all = false

        func validate() throws {
            if all == (runID != nil) { throw ValidationError("Name one run, or pass --all.") }
        }

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            let outcome = try EvalDeleteCommand.run(EvalDeleteCommand.Request(session: directory, runID: runID))
            Console.output(outcome.message)
        }
    }
}

/// Runs work so that Ctrl-C (or SIGTERM) cancels it, and a second one quits at once.
enum EvalInterrupt {
    nonisolated(unsafe) static var lastExitCode: Int32 = 130

    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let work = CancellableStart<T>()
        let interrupt = InterruptCancellation(notice: {
            Console.error("Stopping… (press Ctrl-C again to quit at once)")
        }) { work.cancel() }
        defer { interrupt.restore() }
        do {
            let value = try await work.start(operation).value
            // An interrupt that came while the work was finishing anyway still stops the command: a preparation
            // that returned is never followed by an upload after "Stopping…".
            if interrupt.signal != nil { throw CancellationError() }
            return value
        } catch {
            if let signal = interrupt.signal { lastExitCode = InterruptLatch.exitCode(for: signal) }
            throw error
        }
    }
}

extension EvalLocal.Backend: ExpressibleByArgument {}
