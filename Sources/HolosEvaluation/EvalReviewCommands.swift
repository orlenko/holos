import Foundation
import HolosCore
import HolosStorage

/// `voiceislocal eval compare` as a library call: under the session's processing lease, compares a transcript with a
/// cloud run, writes the report, and says its summary.
public enum EvalCompareCommand {
    public struct Request: Sendable {
        public var session: URL
        /// The cloud run (nil: the newest finished one).
        public var runID: String?
        /// "current" (the current transcript), "latest" (the newest finished local run), or a local run ID.
        public var local: String
        /// Count every word difference (no normalizing).
        public var raw: Bool
        public var files: EvalUserFiles

        public init(session: URL, runID: String? = nil, local: String = "current", raw: Bool = false,
                    files: EvalUserFiles = EvalUserFiles()) {
            self.session = session; self.runID = runID; self.local = local; self.raw = raw; self.files = files
        }
    }

    /// Notes about unreadable vocabulary files and the summary lines go to `report` as notes, then the report's
    /// Markdown path as output. Throws when another process holds the lease, a run cannot be resolved, or the
    /// comparison fails. Returns where the report was written.
    @discardableResult
    public static func run(_ request: Request,
                           report: (EvalCommandMessage) -> Void) throws -> (markdown: URL, json: URL) {
        let directory = request.session
        let lease = try SessionArchive.acquireProcessingLease(at: directory)
        defer { lease.release() }
        let record = try EvalStore.resolveRun(request.runID, in: directory)
        let choice: EvalCompare.LocalChoice = request.local == "current" ? .current
            : .candidate(try EvalLocal.resolve(request.local, in: directory))
        let compared = try EvalCompare.compare(session: directory, run: record, local: choice,
                                               normalize: !request.raw,
                                               terms: request.files.vocabularyTerms(report: report))
        let written = try EvalCompare.write(compared, session: directory)
        for line in EvalCompare.summaryLines(compared) { report(.note(line)) }
        report(.output(written.markdown.path))
        return written
    }
}

/// `voiceislocal eval review` as a library call: under the session's processing lease, compares again when there is
/// no comparison of the current transcript, builds the review page through the caller's interruption, says how many
/// passages it has, and hands the page to `open` (still under the lease).
public enum EvalReviewCommand {
    public struct Request: Sendable {
        public var session: URL
        /// The cloud run (nil: the newest finished one).
        public var runID: String?
        public var files: EvalUserFiles

        public init(session: URL, runID: String? = nil, files: EvalUserFiles = EvalUserFiles()) {
            self.session = session; self.runID = runID; self.files = files
        }
    }

    /// Returns the page, or nil when there is no comparison to show. `open` (nil: the page is not opened) runs after
    /// the page's path is reported.
    @discardableResult
    public static func run(_ request: Request, interruption: any EvalInterruption,
                           open: ((URL) throws -> Void)?,
                           report: @escaping @Sendable (EvalCommandMessage) -> Void) async throws -> URL? {
        let directory = request.session
        let lease = try SessionArchive.acquireProcessingLease(at: directory)
        defer { lease.release() }
        let record = try EvalStore.resolveRun(request.runID, in: directory)
        let currentID = try SessionArchive.currentTranscriptID(at: directory)
        var compared = try EvalCompare.readReport(run: record.id, session: directory)
        if !EvalCompare.isCurrent(compared, transcriptID: currentID) {
            report(.note("Comparing with the current transcript first…"))
            let fresh = try EvalCompare.compare(session: directory, run: record,
                                                terms: request.files.vocabularyTerms(report: report))
            try EvalCompare.write(fresh, session: directory)
            compared = fresh
        }
        guard let compared else { return nil }
        let page = try await interruption.run { () async throws in
            try EvalReview.build(session: directory, run: record, report: compared,
                                 progress: { report(.note($0)) })
        }
        let count = compared.passages.filter(\.needsReview).count
        let formatting = compared.passages.filter(\.formattingOnly).count
        report(.note("\(count) passages to review"
            + (formatting > 0 ? " (\(formatting) formatting-only ones hidden; the page can show them)." : ".")))
        report(.output(page.path))
        try open?(page)
        return page
    }
}

/// `voiceislocal eval apply` as a library call: makes the gold transcript from review decisions and proposes (and,
/// when asked, adds) corrections, word-list terms and often-heard-as words.
public enum EvalApplyCommand {
    public struct Request: Sendable {
        public var session: URL
        /// decisions.json as exported by the review page.
        public var decisions: URL
        public var addCorrections: Bool
        public var addVocabulary: Bool
        public var files: EvalUserFiles

        public init(session: URL, decisions: URL, addCorrections: Bool = false, addVocabulary: Bool = false,
                    files: EvalUserFiles = EvalUserFiles()) {
            self.session = session; self.decisions = decisions; self.addCorrections = addCorrections
            self.addVocabulary = addVocabulary; self.files = files
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var gold: URL
        /// 0, or the word-list additions' exit code (`WordListCommand.Report.exitCode`) when one did not fit.
        public var exitCode: Int32
    }

    /// The decisions are read and checked before the processing lease is taken; the gold transcript and the
    /// additions are written under it, each addition under its file's lock. What it proposes and adds goes to
    /// `report` as notes, the gold transcript's path as output. `isDictionaryWord` tells real words (nil: the system
    /// dictionary's, `Lexicon`, made once the comparison is found).
    public static func run(_ request: Request, isDictionaryWord: ((String) -> Bool)? = nil,
                           report: (EvalCommandMessage) -> Void) throws -> Outcome {
        let directory = request.session
        let url = request.decisions
        guard let data = try AtomicFile.readIfPresent(url, maxBytes: 16 << 20) else {
            throw HolosError.invalidInput("There is no file at \(url.path).")
        }
        let parsed = try ReviewDecisions.parse(data)
        let lease = try SessionArchive.acquireProcessingLease(at: directory)
        defer { lease.release() }
        guard let compared = try EvalCompare.readReport(run: parsed.run, session: directory) else {
            throw HolosError.invalidInput("This session has no comparison for run \(parsed.run).")
        }
        let isWord = isDictionaryWord ?? {
            let lexicon = Lexicon(language: nil)
            return { lexicon.isWord($0.lowercased()) }
        }()
        let store = request.files.wordList
        let knownTerms: [String]
        do {
            knownTerms = try store.load().terms
        } catch {
            if request.addVocabulary {
                throw HolosError.invalidInput("Could not read the word list: \(error.localizedDescription)")
            }
            report(.note("Could not read the word list, so only marked terms count as terms: "
                + error.localizedDescription))
            knownTerms = []
        }
        let result = try EvalApply.build(session: directory, report: compared, decisions: parsed,
                                         knownTerms: knownTerms, isDictionaryWord: isWord)
        let gold = EvalPaths.gold(parsed.run, in: directory)
        try EvalStore.write(result.gold, to: gold)
        report(.note("Reference transcript: \(result.gold.reviewedPassages) reviewed passages."))
        if result.ignoredFormatting > 0 {
            report(.note("Ignored \(result.ignoredFormatting) decisions on formatting-only passages."))
        }
        report(.output(gold.path))
        report(.note(result.corrections.isEmpty ? "No heard → meant pairs to propose."
            : "Proposed corrections (heard → meant):"))
        for pair in result.corrections { report(.note("  \(pair.heard) → \(pair.meant)")) }
        if !result.terms.isEmpty { report(.note("Marked terms: " + result.terms.joined(separator: ", "))) }
        if !result.heardAs.isEmpty {
            report(.note("Proposed often-heard-as words (real words replaced by a term; Apple Intelligence "
                + "decides from the context, so they are not corrections):"))
            for pair in result.heardAs { report(.note("  \(pair.meant) ← \(pair.heard)")) }
        }
        if request.addCorrections {
            let added = try EvalApply.addToCorrections(result.corrections, at: request.files.corrections)
            report(.note("Added \(added.count) corrections to \(request.files.corrections.path); Voice is Local's "
                + "Corrections pane shows them."))
        }
        var exitCode: Int32 = 0
        if request.addVocabulary {
            if result.terms.isEmpty {
                report(.note("No marked terms to add to the word list."))
            } else {
                let added = try EvalApply.addToWordList(result.terms, store: store)
                // stdout carries only the gold transcript's path.
                for line in added.output + added.errors { report(.note(line)) }
                exitCode = max(exitCode, added.exitCode)
            }
            if !result.heardAs.isEmpty {
                let added = try EvalApply.addToHeardAs(result.heardAs, store: store)
                for line in added.output + added.errors { report(.note(line)) }
                exitCode = max(exitCode, added.exitCode)
            }
        }
        return Outcome(gold: gold, exitCode: exitCode)
    }
}
