import Foundation
import Testing
@testable import HolosCore

// Numbers written out in words, so a text and what a recognizer heard compare alike however each writes them.

@Suite struct SpelledNumbersTests {
    /// The words of `text` once its numbers are spelled out, folded as a comparison would fold them.
    private func words(_ text: String, _ language: String = "en") -> [String] {
        SpelledNumbers.spellingOut(text, language: language)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    @Test func digitsAndWordsReadAlike() {
        let same: [(String, String, String)] = [
            ("3.05", "three point zero five", "en"), ("0.125", "zero point one two five", "en"),
            ("1.5 million", "one point five million", "en"), ("50 cents", "fifty cents", "en"),
            ("-5", "minus five", "en"), ("3.50", "3.5", "en"), ("50 and 60", "fifty and sixty", "en"),
            ("1,500", "one thousand five hundred", "en"), ("2015", "two thousand fifteen", "en"),
            ("3.141", "three point one four one", "en"), ("0.001", "zero point zero zero one", "en"),
            ("3,5", "trois virgule cinq", "fr"), ("1\u{202F}500", "mille cinq cents", "fr"),
            ("97", "quatre-vingt-dix-sept", "fr"), ("71", "soixante et onze", "fr"), ("-5", "moins cinq", "fr"),
            ("3,05", "trois virgule zéro cinq", "fr"),
        ]
        for (written, said, language) in same {
            #expect(words(written, language) == words(said, language), "\(written) / \(said)")
        }
        #expect(SpelledNumbers.spellingOut("It cost 3.50 today.", language: "en").contains("three point five"))
    }

    @Test func aWrongReadingNeverReadsAlike() {
        let different: [(String, String, String)] = [
            ("3.05", "three point five", "en"), ("-5", "five", "en"), ("1.5 million", "one million", "en"),
            ("50 cents", "five thousand", "en"), ("2015", "twenty", "en"), ("0.125", "one two five", "en"),
            ("1ère", "deuxième", "fr"), ("1ère", "un", "fr"), ("1990-2000", "minus two thousand", "en"),
        ]
        for (written, said, language) in different {
            #expect(words(written, language) != words(said, language), "\(written) / \(said)")
        }
    }

    @Test func frenchGroupsWithAnySpaceAreOneNumber() {
        let million = "un million deux cent trente-quatre mille cinq cent soixante-sept"
        for spaced in ["1 234 567", "1\u{00A0}234\u{00A0}567", "1\u{202F}234\u{202F}567"] {
            #expect(words(spaced, "fr") == words(million, "fr"), "\(spaced)")
        }
        #expect(words("1 500 visiteurs", "fr") == words("mille cinq cents visiteurs", "fr"))
        // Not French groups: a year then a number, a first group of four digits, or English.
        #expect(words("en 2015 500 visiteurs", "fr") == words("en deux mille quinze cinq cents visiteurs", "fr"))
        #expect(words("1 234", "en") == ["one", "two", "hundred", "thirty", "four"])
    }

    @Test func whatTheFormatterCannotParseIsSpelledByGroup() {
        #expect(words("1,2,3") == ["one", "two", "three"])
        #expect(words("1.500", "fr") == ["un", "cinq", "cents"])
        #expect(words("Chapter 1990-2000") == ["chapter", "one", "thousand", "nine", "hundred", "ninety", "two",
                                               "thousand"])
        // Text without digits is unchanged.
        #expect(SpelledNumbers.spellingOut("No numbers here.", language: "en") == "No numbers here.")
    }
}
