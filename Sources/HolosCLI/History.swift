import ArgumentParser
import Foundation
import HolosCore
import HolosDictation
import HolosStorage

/// `voiceislocal history`: the dictation history the app keeps on this Mac (docs/design.md "Dictation history").
struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, clear, or run again the dictation history kept on this Mac.",
        discussion: """
            The app records each finished dictation (the text, the text as heard, the app, the language, and what \
            happened to it) in Application Support/Holos/History/dictations.jsonl, for as long as its History \
            setting says (30 days unless changed), with its audio in History/audio unless Settings says not to keep \
            it. Nothing is sent anywhere.
            """,
        subcommands: [List.self, Clear.self, Rerun.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List dictations, newest first.")

        @Flag(help: "Print the dictations as JSON.") var json = false
        @Option(help: "Show at most this many dictations.") var limit: Int?

        mutating func validate() throws {
            if let limit, limit < 1 { throw ValidationError("--limit must be at least 1.") }
        }

        mutating func run() throws {
            let contents = try DictationHistoryStore().load()
            var records = Array(contents.records.reversed())
            if let limit { records = Array(records.prefix(limit)) }
            if json {
                try Console.json(records)
            } else if records.isEmpty {
                Console.output("No dictations in the history.")
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                let rows = records.map { record in
                    [formatter.string(from: record.date), Self.oneLine(record.app ?? "—"), record.outcome.kind.rawValue,
                     record.language, Self.preview(record.text)]
                }
                for line in TextTable.render(header: ["DATE", "APP", "RESULT", "LANGUAGE", "TEXT"], rows: rows,
                                             alignments: [.left, .left, .left, .left, .left]) {
                    Console.output(line)
                }
            }
            if contents.newerLines > 0 {
                Console.error("Note: \(contents.newerLines) \(contents.newerLines == 1 ? "dictation was" : "dictations were") recorded by a newer Voice is Local and \(contents.newerLines == 1 ? "is" : "are") not shown.")
            }
            if contents.skippedLines > 0 {
                Console.error("Note: \(contents.skippedLines) unreadable \(contents.skippedLines == 1 ? "line was" : "lines were") skipped.")
            }
        }

        static func oneLine(_ text: String) -> String {
            text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
        }

        static func preview(_ text: String, limit: Int = 60) -> String {
            let line = oneLine(text)
            return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete every dictation in the history.")

        @Flag(help: "Confirm deleting the history.") var yes = false

        mutating func validate() throws {
            guard yes else {
                throw ValidationError("Clearing deletes every dictation in the history; pass --yes to confirm.")
            }
        }

        mutating func run() throws {
            let removed = try DictationHistoryStore().clear()
            Console.output("Cleared \(removed) \(removed == 1 ? "dictation" : "dictations") and their audio.")
        }
    }

    /// `voiceislocal history rerun`: Run Again from Terminal (docs/design.md "Dictation audio and Run Again").
    struct Rerun: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Recognize a dictation's saved audio again with today's settings, and compare.",
            discussion: """
                Runs the audio History kept through the recognizer and the text steps live dictation uses now: the \
                dictation language, the learned corrections (Application Support/Holos/corrections.json, as \
                vocabulary and as replacements), filler removal, spoken paths and commands written as code, and \
                Apple Intelligence's fix, as set in the app's \
                Settings. Prints the text as heard and as written, then and now, what each step did, and which steps \
                behaved differently from then. Nothing is typed, copied, or changed in the history. --all runs every \
                dictation with audio (or those from --since ago) for a report on a change to the corrections or the fix.
                """)

        @Argument(help: "A dictation's ID (or its first characters), or latest.") var dictation: String?
        @Flag(help: "Run every dictation that kept its audio.") var all = false
        @Option(help: "With --all, only dictations from this long ago: 90m, 12h, 7d, 2w.") var since: String?
        @Flag(help: "Print JSON.") var json = false
        @Flag(name: .customLong("no-ai-fix"), help: "Leave out Apple Intelligence's fix even when Settings has it on.")
        var noAIFix = false
        @Flag(name: .customLong("no-spoken-code"),
              help: "Leave spoken paths and commands as said even when Settings writes them as code.")
        var noSpokenCode = false
        @Option(help: "Recognize in this language (for example en-US) instead of the one chosen in Settings.")
        var language: String?

        mutating func validate() throws {
            if all, dictation != nil { throw ValidationError("Give a dictation or --all, not both.") }
            if !all, dictation == nil { throw ValidationError("Give a dictation's ID, latest, or --all.") }
            if let since {
                guard all else { throw ValidationError("--since goes with --all.") }
                guard HistorySince.interval(since) != nil else {
                    throw ValidationError("--since takes a number and m, h, d, or w: 90m, 12h, 7d, 2w.")
                }
            }
            if let language, language.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ValidationError("--language must not be empty.")
            }
        }

        mutating func run() async throws {
            let store = DictationHistoryStore()
            let records = try store.load().records
            let preferences = DictationPreferences.saved(in: UserDefaults(suiteName: DictationPreferences.appDomain))
            let corrections: CorrectionList
            do {
                corrections = try CorrectionList.load(from: CorrectionList.defaultURL)
            } catch {
                throw HolosError.invalidInput("Could not read corrections.json: \(error.localizedDescription)")
            }
            var chosen = language ?? preferences.language
            if chosen == nil { chosen = await RecognitionOptions.defaultLocale(backend: .speech) }
            let locale = chosen ?? DictationLanguage.standard
            let (pipeline, note) = DictationRerun.pipeline(language: locale, removeFillers: preferences.removeFillers,
                                                           corrections: corrections,
                                                           aiFix: preferences.aiFix && !noAIFix,
                                                           spokenCode: preferences.spokenCode && !noSpokenCode,
                                                           backticks: preferences.spokenCodeBackticks)
            if all {
                try await runAll(records, store: store, pipeline: pipeline, note: note,
                                 aiFix: preferences.aiFix && !noAIFix)
                return
            }
            let record = try HistoryLookup.find(dictation ?? "latest", in: records)
            guard record.audio != nil, FileManager.default.isReadableFile(atPath: store.audioURL(for: record.id).path)
            else {
                throw HolosError.unavailable(record.audio == nil
                    ? "No audio was kept for this dictation."
                    : "The audio of this dictation is no longer on this Mac.")
            }
            let report = try await DictationRerun.run(record, audio: store.audioURL(for: record.id),
                                                      pipeline: pipeline, aiNote: note)
            if json {
                try Console.json(report)
            } else {
                for line in Self.lines(report) { Console.output(line) }
            }
        }

        private func runAll(_ records: [DictationRecord], store: DictationHistoryStore, pipeline: DictationTextPipeline,
                            note: String?, aiFix: Bool) async throws {
            let cutoff = since.flatMap(HistorySince.interval).map { Date().addingTimeInterval(-$0) }
            let chosen = records.reversed().filter { record in cutoff.map { record.date >= $0 } ?? true }
            var items: [DictationRerunBatch.Item] = []
            for record in chosen {
                let url = store.audioURL(for: record.id)
                guard record.audio != nil, FileManager.default.isReadableFile(atPath: url.path) else {
                    items.append(.init(record: record, skipped: record.audio == nil ? "no audio kept"
                                                                                    : "audio no longer on this Mac"))
                    continue
                }
                do {
                    let report = try await DictationRerun.run(record, audio: url, pipeline: pipeline, aiNote: note)
                    items.append(.init(report: report))
                } catch {
                    items.append(.init(record: record, error: error.localizedDescription))
                }
                if !json { Console.error("Ran \(items.count) of \(chosen.count)…") }
            }
            let batch = DictationRerunBatch(
                settings: .init(language: pipeline.language, removeFillers: pipeline.removeFillers, aiFix: aiFix,
                                aiFixUnavailable: note, corrections: pipeline.corrections.entries.count,
                                spokenCode: pipeline.coder != nil),
                dictations: items)
            if json {
                try Console.json(batch)
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let rows = items.map { item in
                [formatter.string(from: item.date), List.oneLine(item.app ?? "—"),
                 item.changed.map { $0 ? "changed" : "same" } ?? (item.skipped ?? "failed"),
                 item.changedBy.map(\.rawValue).joined(separator: ","),
                 List.preview(item.writtenNow ?? item.error ?? item.writtenThen)]
            }
            for line in TextTable.render(header: ["DATE", "APP", "RESULT", "STEPS", "TEXT NOW"], rows: rows,
                                         alignments: [.left, .left, .left, .left, .left]) {
                Console.output(line)
            }
            let summary = batch.summary
            Console.output("\(summary.rerun) run again, \(summary.changed) written differently, "
                + "\(summary.skipped) without audio, \(summary.failed) failed.")
        }

        /// The comparison as text.
        static func lines(_ report: DictationRerunReport) -> [String] {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            var head = "Dictation \(report.id.uuidString) · \(formatter.string(from: report.date))"
            if let app = report.app { head += " · \(List.oneLine(app))" }
            head += " · \(report.languageNow)"
            if report.languageNow != report.languageThen { head += " (then \(report.languageThen))" }
            if let seconds = report.audioSeconds { head += String(format: " · %.1f s of audio", seconds) }
            var lines = [head, ""]
            for (title, comparison) in [("As heard", report.heard), ("As written", report.written)] {
                lines.append(title)
                lines.append("  then: \(List.oneLine(comparison.then))")
                lines.append("  now:  \(List.oneLine(comparison.now))")
                lines.append(comparison.changed ? "  changes: \(WordDiff.describe(comparison.changes, limit: 20))"
                                                : "  same words")
            }
            lines.append("Steps now")
            lines.append(contentsOf: report.steps.map { "  " + $0.summary })
            lines.append(report.changedBy.isEmpty
                ? "No step behaved differently from then."
                : "Different from then: " + report.changedBy.map(\.title).joined(separator: ", "))
            return lines
        }
    }
}
