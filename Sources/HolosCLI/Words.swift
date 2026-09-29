import ArgumentParser
import Foundation
import HolosCore
import HolosStorage

/// `voiceislocal words`: the word list (docs/design.md "Word list"), the terms the recognizer should expect.
struct Words: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, add, remove, or import the terms the recognizer should expect.",
        discussion: """
            Words the recognizer should expect: names, products, jargon. Dictation and new meetings give the \
            recognizer the word list first (at most \(RecognizerVocabulary.maximumStrings) terms in all), then the \
            words of learned corrections (and, for a meeting, people's names), and Apple Intelligence's fix counts \
            their words as real words. A term keeps the case you write it in and may be several words; one that \
            differs only in case from a listed term is the same term. The list is Application Support/Holos/\
            words.json; the app picks up a change at the next dictation. A meeting keeps the vocabulary it was \
            recorded with (vocabulary.json).
            """,
        subcommands: [List.self, Add.self, Remove.self, Import.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the terms, oldest first, one per line.")

        @Flag(help: "Print the entries (term, when added, and by what) as JSON.") var json = false

        func run() throws {
            let store = WordListStore()
            if json {
                try Console.json(try store.load().entries)
            } else {
                for term in try WordListCommand.list(store: store) { Console.output(term) }
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add terms.",
            discussion: """
                Quote a term of several words: voiceislocal words add "Urban Sky" Keycloak. A term already listed \
                (in any case) is left as it is.
                """)

        @Argument(help: "The terms to add.") var terms: [String]

        func validate() throws {
            if terms.allSatisfy({ WordList.cleaned($0) == nil }) { throw ValidationError("Give at least one term.") }
        }

        func run() throws {
            try Words.print(WordListCommand.add(terms, store: WordListStore()))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove terms.", discussion: "A term matches in any case. Exits 1 when one is not listed.")

        @Argument(help: "The terms to remove.") var terms: [String]

        func validate() throws {
            if terms.allSatisfy({ WordList.cleaned($0) == nil }) { throw ValidationError("Give at least one term.") }
        }

        func run() throws {
            try Words.print(WordListCommand.remove(terms, store: WordListStore()))
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add the terms of a text file, one per line.",
            discussion: "Blank lines are skipped, and terms already listed are left as they are. - reads standard input.")

        @Argument(help: "A UTF-8 text file, or - for standard input.") var file: String

        func run() throws {
            let store = WordListStore()
            if file == "-" {
                let data = try FileHandle.standardInput.read(upToCount: WordListCommand.maxImportBytes + 1) ?? Data()
                guard data.count <= WordListCommand.maxImportBytes else {
                    throw ValidationError("Standard input is larger than 1 MB.")
                }
                try Words.print(WordListCommand.add(WordListCommand.terms(in: data, name: "Standard input"), store: store))
            } else {
                try Words.print(WordListCommand.importFile(fileURL(file), store: store))
            }
        }
    }

    /// Prints `report` and exits with its code.
    static func print(_ report: WordListCommand.Report) throws {
        for line in report.output { Console.output(line) }
        for line in report.errors { Console.error(line) }
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }
}

