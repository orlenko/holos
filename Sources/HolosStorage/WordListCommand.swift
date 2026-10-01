import Foundation
import HolosCore

/// What `voiceislocal words` does (docs/design.md "Word list"), as library calls: the CLI parses its arguments and
/// prints the report. Results go to stdout (`output`), notes and problems to stderr (`errors`).
public enum WordListCommand {
    public struct Report: Sendable, Equatable {
        public var output: [String] = []
        public var errors: [String] = []
        /// 0 done; 1 some term could not be added or removed (the rest were).
        public var exitCode: Int32 = 0

        public init(output: [String] = [], errors: [String] = [], exitCode: Int32 = 0) {
            self.output = output; self.errors = errors; self.exitCode = exitCode
        }
    }

    /// Largest file `import` reads.
    public static let maxImportBytes = 1 << 20

    /// The terms, oldest first, one per line.
    public static func list(store: WordListStore) throws -> [String] {
        try store.load().terms
    }

    /// Adds each of `terms` (a term may be several words: "Urban Sky"). A term the list has already, in any case, is
    /// noted and left as it is. `heardAs` ("cloud", "clot") become the "often heard as" phrases of each term, added to
    /// those a listed term has already (the CLI allows them with one term only).
    public static func add(_ terms: [String], heardAs: [String] = [], store: WordListStore,
                           source: WordListSource = .user, at date: Date = Date()) throws -> Report {
        let (list, result, _) = try store.update { list in
            let outcomes = terms.map { list.add($0, source: source, at: date) }
            let changes: [WordList.HeardAsChange] = heardAs.isEmpty ? [] : zip(terms, outcomes).compactMap { term, outcome in
                switch outcome {
                case .added(let added): list.addHeardAs(heardAs, to: added)
                case .duplicate(let existing): list.addHeardAs(heardAs, to: existing)
                case .empty, .tooLong, .full: nil
                }
            }
            return (outcomes, changes)
        }
        var summary = Self.report(result.0, count: list.count)
        for change in result.1 { add(change, to: &summary) }
        return summary
    }

    /// The "often heard as" phrases of `term`, or of every term that has some (nil), one term per line:
    /// "Claude: cloud, clot, clod". A term the list does not have makes the exit code 1.
    public static func heardAs(of term: String?, store: WordListStore) throws -> Report {
        let list = try store.load()
        var report = Report()
        if let term {
            guard let phrases = list.heardAs(of: term) else {
                report.errors.append("Not in the word list: \(WordList.cleaned(term) ?? term)")
                report.exitCode = 1
                return report
            }
            let spelled = list.terms.first { $0.lowercased() == WordList.cleaned(term)?.lowercased() } ?? term
            report.output.append(phrases.isEmpty ? "\(spelled) has no often-heard-as phrases."
                : "\(spelled): \(phrases.joined(separator: ", "))")
            return report
        }
        for entry in list.entries {
            guard let phrases = entry.heardAs, !phrases.isEmpty else { continue }
            report.output.append("\(entry.text): \(phrases.joined(separator: ", "))")
        }
        if report.output.isEmpty { report.errors.append("No term has often-heard-as phrases.") }
        return report
    }

    /// Adds `adding` to the "often heard as" phrases of `term`, then removes `removing`. A term the list does not have,
    /// a phrase refused, or one to remove that the term does not have makes the exit code 1.
    public static func changeHeardAs(of term: String, adding: [String], removing: [String],
                                     store: WordListStore) throws -> Report {
        let (_, result, _) = try store.update { list -> (WordList.HeardAsChange?, WordList.HeardAsChange?) in
            let added = adding.isEmpty ? nil : list.addHeardAs(adding, to: term)
            let removed = removing.isEmpty ? nil : list.removeHeardAs(removing, from: term)
            return (added, removed)
        }
        var report = Report()
        guard result.0 != nil || result.1 != nil else {
            report.errors.append("Not in the word list: \(WordList.cleaned(term) ?? term). Add it first: "
                + "voiceislocal words add \"\(WordList.cleaned(term) ?? term)\" --heard-as …")
            report.exitCode = 1
            return report
        }
        if let added = result.0 { add(added, to: &report) }
        if let removed = result.1 {
            if !removed.removed.isEmpty { report.output.append("Removed: \(removed.removed.joined(separator: ", ")).") }
            for phrase in removed.unchanged {
                report.errors.append("\(removed.term) is not listed as heard as: \(phrase)")
                report.exitCode = 1
            }
            report.output.append(phrasesLine(removed))
        }
        return report
    }

    /// The lines for one `addHeardAs`: what was added, what the term had already, what was refused, and its phrases.
    public static func add(_ change: WordList.HeardAsChange, to report: inout Report) {
        for phrase in change.unchanged { report.errors.append("Already listed for \(change.term): \(phrase)") }
        for phrase in change.refused {
            report.errors.append("Not added for \(change.term): \(phrase) (the term itself, longer than "
                + "\(WordList.maximumLength) characters, without a letter, or past \(WordList.maximumHeardAs) phrases).")
            report.exitCode = 1
        }
        report.output.append(phrasesLine(change))
    }

    /// "Claude is often heard as: cloud, clot." or "Claude has no often-heard-as phrases."
    public static func phrasesLine(_ change: WordList.HeardAsChange) -> String {
        change.phrases.isEmpty ? "\(change.term) has no often-heard-as phrases."
            : "\(change.term) is often heard as: \(change.phrases.joined(separator: ", "))."
    }

    /// Removes each of `terms`, matched in any case or spacing. A term the list does not have makes the exit code 1.
    public static func remove(_ terms: [String], store: WordListStore) throws -> Report {
        let (list, removed, _) = try store.update { list in terms.map { list.remove($0) } }
        var report = Report()
        let gone = removed.compactMap { $0 }
        if !gone.isEmpty { report.output.append("Removed: \(gone.joined(separator: ", ")).") }
        for (term, found) in zip(terms, removed) where found == nil {
            report.errors.append("Not in the word list: \(WordList.cleaned(term) ?? term)")
            report.exitCode = 1
        }
        report.output.append(countLine(list.count))
        return report
    }

    /// Adds the terms of a text file, one per line (blank lines skipped). Throws when the file cannot be read, is
    /// larger than `maxImportBytes`, or is not UTF-8 text.
    public static func importFile(_ url: URL, store: WordListStore, at date: Date = Date()) throws -> Report {
        try add(terms(inFile: url), store: store, at: date)
    }

    /// The terms of a text file, one per line.
    public static func terms(inFile url: URL) throws -> [String] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw HolosError.invalidInput("Cannot read \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxImportBytes + 1) ?? Data()
        guard data.count <= maxImportBytes else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is larger than \(maxImportBytes >> 20) MB.")
        }
        return try terms(in: data, name: url.lastPathComponent)
    }

    /// The terms of UTF-8 text, one per line (standard input for `import -`).
    public static func terms(in data: Data, name: String) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HolosError.invalidInput("\(name) is not UTF-8 text.")
        }
        return WordList.lines(in: text)
    }

    static func report(_ outcomes: [WordList.AddOutcome], count: Int) -> Report {
        var report = Report()
        var added: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .added(let term): added.append(term)
            case .duplicate(let existing): report.errors.append("Already in the word list: \(existing)")
            case .empty: break
            case .tooLong:
                report.errors.append("Not added: a term longer than \(WordList.maximumLength) characters.")
                report.exitCode = 1
            case .full:
                report.errors.append("Not added: the word list is full (\(WordList.maximumTerms) terms).")
                report.exitCode = 1
            }
        }
        if !added.isEmpty { report.output.append("Added: \(added.joined(separator: ", ")).") }
        report.output.append(countLine(count))
        return report
    }

    static func countLine(_ count: Int) -> String {
        let terms = count == 1 ? "1 term" : "\(count) terms"
        guard count > RecognizerVocabulary.maximumStrings else { return "The word list has \(terms)." }
        return "The word list has \(terms); the recognizer gets the first \(RecognizerVocabulary.maximumStrings)."
    }
}
