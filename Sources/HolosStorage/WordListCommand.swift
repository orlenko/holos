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
    }

    /// Largest file `import` reads.
    public static let maxImportBytes = 1 << 20

    /// The terms, oldest first, one per line.
    public static func list(store: WordListStore) throws -> [String] {
        try store.load().terms
    }

    /// Adds each of `terms` (a term may be several words: "Urban Sky"). A term the list has already, in any case, is
    /// noted and left as it is.
    public static func add(_ terms: [String], store: WordListStore, source: WordListSource = .user,
                           at date: Date = Date()) throws -> Report {
        let (list, outcomes) = try store.update { list in terms.map { list.add($0, source: source, at: date) } }
        return report(outcomes, count: list.count)
    }

    /// Removes each of `terms`, matched in any case or spacing. A term the list does not have makes the exit code 1.
    public static func remove(_ terms: [String], store: WordListStore) throws -> Report {
        let (list, removed) = try store.update { list in terms.map { list.remove($0) } }
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
