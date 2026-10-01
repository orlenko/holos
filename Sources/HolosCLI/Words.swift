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
            recorded with (vocabulary.json). A term may list real words the recognizer often writes for it \
            ("often heard as": voiceislocal words add Claude --heard-as cloud,clot,clod); Apple Intelligence's fix \
            replaces such a word by the term only where the context says it was meant, in dictation and in \
            meetings (voiceislocal session fix-words), never on its own.
            """,
        subcommands: [List.self, Add.self, Remove.self, Import.self, HeardAs.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the terms, oldest first, one per line.")

        @Flag(help: "Print the entries (term, when added, by what, and what it is often heard as) as JSON.")
        var json = false

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
                (in any case) is left as it is. --heard-as cloud,clot,clod lists real words the recognizer often \
                writes for the term (with one term only; added to those a listed term has).
                """)

        @Argument(help: "The terms to add.") var terms: [String]
        @Option(help: "Comma-separated words the recognizer often writes for the term (for example cloud,clot).")
        var heardAs: String?

        func validate() throws {
            if terms.allSatisfy({ WordList.cleaned($0) == nil }) { throw ValidationError("Give at least one term.") }
            if let heardAs {
                if terms.compactMap(WordList.cleaned).count != 1 {
                    throw ValidationError("--heard-as goes with one term.")
                }
                if WordList.heardAsList(heardAs).isEmpty { throw ValidationError("--heard-as needs a word.") }
            }
        }

        func run() throws {
            try Words.print(WordListCommand.add(terms, heardAs: heardAs.map(WordList.heardAsList) ?? [],
                                                store: WordListStore()))
        }
    }

    struct HeardAs: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "heard-as",
            abstract: "List, add, or remove the words a term is often heard as.",
            discussion: """
                Without options, prints the term's often-heard-as words (every term's, without a term): \
                "Claude: cloud, clot, clod". --add and --remove take comma-separated words: voiceislocal words \
                heard-as Claude --add clawed --remove clod. The term must be in the word list. These words are never \
                replaced on their own: Apple Intelligence's fix (on in Settings) replaces one by the term only where \
                the context says it was meant, in dictation and in meetings.
                """)

        @Argument(help: "The term (any case).") var term: String?
        @Option(help: "Comma-separated words to add.") var add: String?
        @Option(help: "Comma-separated words to remove.") var remove: String?

        func validate() throws {
            if term == nil, add != nil || remove != nil { throw ValidationError("Name the term to change.") }
            if let term, WordList.cleaned(term) == nil { throw ValidationError("Give a term.") }
            for value in [add, remove].compactMap({ $0 }) where WordList.heardAsList(value).isEmpty {
                throw ValidationError("--add and --remove need a word.")
            }
        }

        func run() throws {
            let store = WordListStore()
            if let term, add != nil || remove != nil {
                try Words.print(WordListCommand.changeHeardAs(of: term, adding: add.map(WordList.heardAsList) ?? [],
                                                              removing: remove.map(WordList.heardAsList) ?? [],
                                                              store: store))
            } else {
                try Words.print(WordListCommand.heardAs(of: term, store: store))
            }
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

