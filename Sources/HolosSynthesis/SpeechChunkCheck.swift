import Foundation

/// The check of a rendered paragraph against its text: the words a recognizer hears compared with the words written,
/// case, accents, and punctuation ignored, and numbers left out on both sides, whichever way they are written: digits
/// ("2015", "3.5", "2nd", "1er") and number words ("twenty fifteen", "three point five", "second", "deux mille
/// quinze", "trois virgule cinq", "deuxième"). A voice reads "2015" as words that a recognizer may write as digits or
/// spell out, so neither side's numbers are compared. It fails when the edits needed exceed 15 % of the paragraph's
/// words (at least 2), or when the lengths differ by more than 8 words (a cut-off or a run-on take). A paragraph of
/// numbers alone is compared by value instead (`SpokenNumbers`): "2015" passes as "two thousand and fifteen",
/// "twenty fifteen", or "deux mille quinze", and fails as "twenty" or as nothing.
public enum SpeechChunkCheck {
    public struct Verdict: Sendable, Equatable {
        public let passed: Bool
        /// Word edits (substitutions, insertions, deletions) over the written words.
        public let wordErrorRate: Double
        public let expectedWords: Int
        public let heardWords: Int
    }

    public static let maximumWordErrorRate = 0.15
    public static let minimumAllowedEdits = 2
    public static let maximumLengthDifference = 8

    public static func evaluate(expected: String, heard: String) -> Verdict {
        let reference = words(expected), hypothesis = words(heard)
        // A paragraph of numbers alone leaves no words once numbers are left out: its numbers are compared by value,
        // and at most `minimumAllowedEdits` other words may be heard. An empty or cut-off take hears other numbers.
        if reference.isEmpty {
            let written = SpokenNumbers.values(in: expected), said = SpokenNumbers.values(in: heard)
            let passed = written.isEmpty
                || (SpokenNumbers.same(written, said) && hypothesis.count <= minimumAllowedEdits)
            return Verdict(passed: passed, wordErrorRate: passed ? 0 : 1, expectedWords: written.count,
                           heardWords: said.count)
        }
        let edits = editDistance(reference, hypothesis)
        let rate = reference.isEmpty ? (hypothesis.isEmpty ? 0 : 1) : Double(edits) / Double(reference.count)
        let allowed = max(minimumAllowedEdits, Int((maximumWordErrorRate * Double(reference.count)).rounded(.down)))
        let passed = edits <= allowed && abs(reference.count - hypothesis.count) <= maximumLengthDifference
            && !(hypothesis.isEmpty && !reference.isEmpty)
        return Verdict(passed: passed, wordErrorRate: rate, expectedWords: reference.count,
                       heardWords: hypothesis.count)
    }

    /// Lowercased, accent-free words of letters and digits, numbers left out: every word with a digit, every number
    /// word (English and French cardinals, ordinals, and their parts), and a joining word between two of them ("and",
    /// "point", "et", "pour" in "cinquante pour cent").
    static func words(_ text: String) -> [String] {
        let tokens = tokens(text)
        let numeric = tokens.map { $0.rangeOfCharacter(from: .decimalDigits) != nil || numberWords.contains($0) }
        return tokens.indices.compactMap { index in
            if numeric[index] { return nil }
            if numberJoiners.contains(tokens[index]), index > 0, index + 1 < tokens.count,
               numeric[index - 1], numeric[index + 1] { return nil }
            return tokens[index]
        }
    }

    /// Every word of `text`, folded, numbers included.
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Number words, folded (no accents).
    static let numberWords: Set<String> = Set([
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "hundreds", "thousand", "thousands",
        "million", "millions", "billion", "billions", "first", "second", "third", "fourth", "fifth", "sixth",
        "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth",
        "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth",
        "sixtieth", "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth", "millionth", "percent", "un",
        "une", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "treize",
        "quatorze", "quinze", "seize", "vingt", "vingts", "trente", "quarante", "cinquante", "soixante", "cent",
        "cents", "mille", "million", "milliard", "milliards", "virgule", "premier", "premiere", "premiers",
        "premieres", "seconde", "deuxieme", "troisieme", "quatrieme", "cinquieme", "sixieme", "septieme", "huitieme",
        "neuvieme", "dixieme", "onzieme", "douzieme", "treizieme", "quatorzieme", "quinzieme", "seizieme",
        "vingtieme", "trentieme", "centieme", "millieme",
    ])

    /// Words that join the parts of a number.
    static let numberJoiners: Set<String> = ["and", "point", "dot", "et", "pour"]

    static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                current[j] = lhs[i - 1] == rhs[j - 1] ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
