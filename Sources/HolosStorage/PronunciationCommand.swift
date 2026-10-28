import Foundation
import HolosCore

/// What `voiceislocal pronunciations` does (docs/design.md "Pronunciations"), as library calls: the CLI parses its
/// arguments and prints the report (`WordListCommand.Report`: stdout lines, stderr lines, exit code).
public enum PronunciationCommand {
    public typealias Report = WordListCommand.Report

    /// One line per entry, oldest first: "XIMEA → zai mee ah".
    public static func list(store: PronunciationStore) throws -> [String] {
        try store.load().entries.map(line)
    }

    /// Says `written` as `sayAs`: adds the entry, or changes its spelling.
    public static func set(_ written: String, sayAs: String, store: PronunciationStore,
                           at date: Date = Date()) throws -> Report {
        let (list, outcome) = try store.update { $0.set(written, sayAs: sayAs, at: date) }
        var report = Report()
        switch outcome {
        case .added(let entry): report.output.append("Added: \(line(entry)).")
        case .changed(let entry, let previous): report.output.append("Changed: \(line(entry)) (was \(previous)).")
        case .unchanged(let entry): report.errors.append("Already listed: \(line(entry)).")
        case .empty:
            report.errors.append("Give the word as written and how to say it.")
            report.exitCode = 1
        case .tooLong:
            report.errors.append("Not added: longer than \(PronunciationList.maximumLength) characters.")
            report.exitCode = 1
        case .full:
            report.errors.append("Not added: the pronunciation list is full "
                + "(\(PronunciationList.maximumEntries) entries).")
            report.exitCode = 1
        }
        report.output.append(countLine(list.entries.count))
        return report
    }

    /// Removes the entries written exactly so (case counts). One the list does not have makes the exit code 1.
    public static func remove(_ written: [String], store: PronunciationStore) throws -> Report {
        let (list, removed) = try store.update { list in written.map { list.remove($0) } }
        var report = Report()
        let gone = removed.compactMap { $0?.written }
        if !gone.isEmpty { report.output.append("Removed: \(gone.joined(separator: ", ")).") }
        for (word, found) in zip(written, removed) where found == nil {
            report.errors.append("Not in the pronunciation list: \(WordList.cleaned(word) ?? word)")
            report.exitCode = 1
        }
        report.output.append(countLine(list.entries.count))
        return report
    }

    static func line(_ entry: Pronunciation) -> String { "\(entry.written) → \(entry.sayAs)" }

    static func countLine(_ count: Int) -> String {
        "The pronunciation list has \(count == 1 ? "1 entry" : "\(count) entries")."
    }
}
