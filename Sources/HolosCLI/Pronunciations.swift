import ArgumentParser
import Foundation
import HolosCore
import HolosStorage

/// `voiceislocal pronunciations`: the pronunciation list (docs/design.md "Pronunciations"), the spellings every reading
/// voice says words by.
struct Pronunciations: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, set, or remove how the reading voices say a word.",
        discussion: """
            Names and jargon no voice knows how to say: voiceislocal pronunciations set XIMEA "zai mee ah". Every \
            voice (natural and Apple) of readings, voiceislocal say and voiceislocal read says the word by its \
            spelling, from the next part rendered. A word written in lower case matches in any case; one with a \
            capital matches only as written. Only whole words match ("XIMEAs" does not). The list is Application \
            Support/Holos/pronunciations.json; Settings › Reading edits it too.
            """,
        subcommands: [List.self, SetEntry.self, Remove.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the entries, oldest first: XIMEA → zai mee ah.")

        @Flag(help: "Print the entries (written, say as, when added) as JSON.")
        var json = false

        func run() throws {
            let store = PronunciationStore()
            if json {
                try Console.json(try store.load().entries)
            } else {
                for line in try PronunciationCommand.list(store: store) { Console.output(line) }
            }
        }
    }

    struct SetEntry: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Say a word or phrase by a spelling.",
            discussion: "Quote either side of several words. A listed word gets the new spelling.")

        @Argument(help: "The word or phrase as documents write it.") var written: String
        @Argument(help: "How to say it, spelled as it sounds.") var sayAs: String

        func validate() throws {
            if WordList.cleaned(written) == nil || WordList.cleaned(sayAs) == nil {
                throw ValidationError("Give the word as written and how to say it.")
            }
        }

        func run() throws {
            try Words.print(PronunciationCommand.set(written, sayAs: sayAs, store: PronunciationStore()))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove entries.", discussion: "A word matches as written (case counts). Exits 1 when one is not listed.")

        @Argument(help: "The words to remove, as written.") var written: [String]

        func validate() throws {
            if written.allSatisfy({ WordList.cleaned($0) == nil }) { throw ValidationError("Give at least one word.") }
        }

        func run() throws {
            try Words.print(PronunciationCommand.remove(written, store: PronunciationStore()))
        }
    }
}
