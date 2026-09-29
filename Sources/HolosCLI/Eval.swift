import ArgumentParser
import Foundation
import HolosCore
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
        subcommands: [Cloud.self, Compare.self, Review.self, Apply.self, List.self, Delete.self])

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
            let lease = try SessionArchive.acquireProcessingLease(at: directory)
            defer { lease.release() }
            CloudEvaluation.removeStaleWork(session: directory)

            let prepared: CloudEvaluation.Prepared
            do {
                prepared = try await EvalInterrupt.run { () async throws in
                    try CloudEvaluation.prepare(session: directory, options: options,
                                                vocabulary: Self.vocabularySource, progress: { Console.error($0) })
                }
            } catch {
                CloudEvaluation.removeStaleWork(session: directory)
                throw error
            }
            if prepared.pendingCount == 0 {
                Console.error("Every segment of run \(prepared.record.id) is already saved; finishing it.")
            } else {
                for line in prepared.summaryLines { Console.error(line) }
                Console.error("The audio leaves this Mac: go ahead only if everyone recorded agreed to that.")
                let isTerminal = isatty(STDIN_FILENO) != 0
                switch ConsentGate.decide(assumeYes: yes, isTerminal: isTerminal, readAnswer: {
                    FileHandle.standardError.write(Data("Upload to OpenAI? [y/N] ".utf8))
                    return readLine()
                }) {
                case .proceed:
                    break
                case .declined:
                    CloudEvaluation.discard(prepared)
                    Console.error("Nothing was uploaded.")
                    throw ExitCode(1)
                case .noTerminal:
                    CloudEvaluation.discard(prepared)
                    Console.error("Nothing was uploaded: there is no terminal to confirm at. Pass --yes to upload "
                        + "without asking.")
                    throw ExitCode(1)
                }
            }
            let client = CloudTranscriptionClient(apiKey: key)
            do {
                let outcome = try await EvalInterrupt.run { () async throws in
                    try await CloudEvaluation.upload(prepared, client: client, progress: { Console.error($0) })
                }
                Console.error("Uploaded \(outcome.uploaded) segments. Next: voiceislocal eval compare \(session)")
                Console.output(EvalPaths.cloudRun(prepared.record.id, in: directory).path)
            } catch {
                let saved = EvalStore.savedSegments(prepared.record, in: directory)
                let total = prepared.record.tracks.reduce(0) { $0 + $1.segments.filter { !$0.silent }.count }
                let message = error is CancellationError ? "Cancelled." : CloudTranscriptionClient.redacted(
                    error.localizedDescription)
                Console.error("\(message) \(saved) of \(total) segments are saved; run the same command again to "
                    + "resume run \(prepared.record.id).")
                throw ExitCode(error is CancellationError ? EvalInterrupt.lastExitCode : 1)
            }
        }

        /// The sources of the meeting vocabulary the app gives the recorder (`RecognizerVocabulary.meeting`): the word
        /// list, people's names, and correction words for the meeting's languages. A damaged words.json or
        /// corrections.json stops the run rather than sending less than --vocabulary asked for.
        static let vocabularySource = CloudEvaluation.VocabularySource(
            wordList: {
                do { return try WordListStore().load().terms } catch {
                    throw HolosError.invalidInput("Could not read the word list for --vocabulary: "
                        + error.localizedDescription)
                }
            },
            names: { VoiceProfileService.profileNames().values.sorted() },
            terms: { languages in
                do { return try CorrectionList.load(from: CorrectionList.defaultURL).vocabulary(languages: languages) }
                catch {
                    throw HolosError.invalidInput("Could not read corrections.json for --vocabulary: "
                        + error.localizedDescription)
                }
            })
    }

    struct Compare: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare the local transcript with a cloud run, per track and time window.",
            discussion: """
                Writes eval/compare/<run>/report.md and report.json: word error rates against each transcript \
                (neither is taken as the truth) and the passages where they differ, grouped as names and terms, \
                numbers, dropped or added words, other words, and case or punctuation only. Microphone words that \
                are echo of the system track are left out, as in the exports.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Option(name: .customLong("run"), help: "The cloud run (default: the newest finished one).") var runID: String?

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            let lease = try SessionArchive.acquireProcessingLease(at: directory)
            defer { lease.release() }
            let record = try EvalStore.resolveRun(runID, in: directory)
            let report = try EvalCompare.compare(session: directory, run: record)
            let written = try EvalCompare.write(report, session: directory)
            for line in EvalCompare.summaryLines(report) { Console.error(line) }
            Console.output(written.markdown.path)
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
            let lease = try SessionArchive.acquireProcessingLease(at: directory)
            defer { lease.release() }
            let record = try EvalStore.resolveRun(runID, in: directory)
            let currentID = try SessionArchive.currentTranscriptID(at: directory)
            var report = try EvalCompare.readReport(run: record.id, session: directory)
            if report == nil || report?.transcriptID != currentID {
                Console.error("Comparing with the current transcript first…")
                let fresh = try EvalCompare.compare(session: directory, run: record)
                try EvalCompare.write(fresh, session: directory)
                report = fresh
            }
            guard let report else { return }
            let page = try await EvalInterrupt.run { () async throws in
                try EvalReview.build(session: directory, run: record, report: report,
                                     progress: { Console.error($0) })
            }
            let count = report.passages.filter { $0.group != .caseOrPunctuation }.count
            Console.error("\(count) passages to review.")
            Console.output(page.path)
            if !noOpen {
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [page.path]
                try open.run()
                open.waitUntilExit()
            }
        }
    }

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make a reference transcript from review decisions, and propose corrections and word-list terms.",
            discussion: """
                Writes eval/gold/<run>.json: the local transcript with each reviewed passage replaced by its \
                decided text. Prints the heard → meant pairs (word substitutions of at most 3 words) and the \
                terms you marked. Nothing is added unless you pass --add-corrections (those pairs, to your \
                corrections) or --add-vocabulary (the marked terms, to your word list, as voiceislocal words add \
                does). Each addition is made under that file's lock; a running Voice is Local picks it up and \
                never saves over it.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "decisions.json exported by the review page.") var decisions: String
        @Flag(help: "Add the proposed heard → meant pairs to your corrections.") var addCorrections = false
        @Flag(help: "Add the marked terms to your word list.") var addVocabulary = false

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            let url = fileURL(decisions).resolvingSymlinksInPath()
            guard let data = try AtomicFile.readIfPresent(url, maxBytes: 16 << 20) else {
                throw HolosError.invalidInput("There is no file at \(url.path).")
            }
            let parsed = try ReviewDecisions.parse(data)
            let lease = try SessionArchive.acquireProcessingLease(at: directory)
            defer { lease.release() }
            guard let report = try EvalCompare.readReport(run: parsed.run, session: directory) else {
                throw HolosError.invalidInput("This session has no comparison for run \(parsed.run).")
            }
            let lexicon = Lexicon(language: nil)
            let result = try EvalApply.build(session: directory, report: report, decisions: parsed,
                                             isDictionaryWord: { lexicon.isWord($0.lowercased()) })
            let gold = EvalPaths.gold(parsed.run, in: directory)
            try EvalStore.write(result.gold, to: gold)
            Console.error("Reference transcript: \(result.gold.reviewedPassages) reviewed passages.")
            Console.output(gold.path)
            Console.error(result.corrections.isEmpty ? "No heard → meant pairs to propose."
                : "Proposed corrections (heard → meant):")
            for pair in result.corrections { Console.error("  \(pair.heard) → \(pair.meant)") }
            if !result.terms.isEmpty { Console.error("Marked terms: " + result.terms.joined(separator: ", ")) }
            if addCorrections {
                let added = try EvalApply.addToCorrections(result.corrections, at: CorrectionList.defaultURL)
                Console.error("Added \(added.count) corrections to \(CorrectionList.defaultURL.path); Voice is Local's "
                    + "Corrections pane shows them.")
            }
            if addVocabulary {
                if result.terms.isEmpty {
                    Console.error("No marked terms to add to the word list.")
                } else {
                    let report = try EvalApply.addToWordList(result.terms, store: WordListStore())
                    // stdout carries only the gold transcript's path.
                    for line in report.output + report.errors { Console.error(line) }
                    if report.exitCode != 0 { throw ExitCode(report.exitCode) }
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a session's evaluation runs.")
        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            let ids = EvalStore.runIDs(in: directory)
            if ids.isEmpty { Console.output("No evaluation runs."); return }
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
            abstract: "Delete an evaluation run (its cloud results, comparison, review page, and gold), or all.")
        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The run to delete.") var runID: String?
        @Flag(help: "Delete every evaluation file of the session.") var all = false

        func validate() throws {
            if all == (runID != nil) { throw ValidationError("Name one run, or pass --all.") }
        }

        mutating func run() throws {
            let directory = try SessionLocator.resolve(session)
            let lease = try SessionArchive.acquireProcessingLease(at: directory)
            defer { lease.release() }
            let removed = try runID.map { try EvalStore.deleteRun($0, in: directory) } ?? EvalStore.deleteAll(in: directory)
            Console.output(removed ? "Deleted." : "Nothing to delete.")
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
