import Foundation

/// The numbers a text says, each as its value in digits ("2015", "3.5"), so a paragraph of numbers can be compared
/// with what a recognizer heard (`SpeechChunkCheck`). Digits are read as written: thousands separators ("2,015",
/// "1 500" with a no-break space, "1.500"), a decimal point or comma, ordinal suffixes ("2nd", "1er", "3e"). English
/// and French number words are read as one number each: "two thousand and fifteen", "fifteen hundred", "twenty
/// fifteen" (a year), "deux mille quinze", "quatre-vingt-dix-sept", "vingt et un", "three point five", "trois virgule
/// cinq". A word that cannot continue a number ends it; other words are skipped.
enum SpokenNumbers {
    static func values(in text: String) -> [String] {
        let words = SpeechChunkCheck.tokens(prepared(text))
        var values: [String] = []
        var index = 0
        while index < words.count {
            var reader = Reader()
            index = reader.read(words, from: index)
            guard var value = reader.value else { continue }
            if index < words.count, decimalWords.contains(words[index]),
               let (digits, after) = fraction(words, from: index + 1) {
                value += "." + digits
                index = after
            }
            values.append(value)
        }
        return values
    }

    /// Whether two lists of numbers are the same.
    static func same(_ lhs: [String], _ rhs: [String]) -> Bool { lhs == rhs }

    /// `text` with thousands separators removed and a decimal mark between digits written as " point ".
    static func prepared(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<=\d)[,.   ](?=\d{3}(?!\d))"#, with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\d)[.,](?=\d)"#, with: " point ", options: .regularExpression)
    }

    /// The digits of a token written with digits ("2015", "21st", "1er", "3eme"), leading zeros dropped.
    static func digits(_ word: String) -> String? {
        let number = word.prefix { $0.isASCII && $0.isNumber }
        guard !number.isEmpty, ordinalSuffixes.contains(String(word.dropFirst(number.count))) else { return nil }
        let trimmed = number.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    static func isNumberWord(_ word: String) -> Bool {
        digits(word) != nil || small[word] != nil || multipliers[word] != nil
    }

    /// The digits after a decimal mark: digits as written, a run of digit words ("point one four"), or one number
    /// ("virgule vingt-cinq").
    private static func fraction(_ words: [String], from start: Int) -> (String, Int)? {
        guard start < words.count else { return nil }
        if let written = digits(words[start]), words[start].allSatisfy(\.isNumber) { return (written, start + 1) }
        var run = "", index = start
        while index < words.count, let value = small[words[index]], value < 10, !ordinals.contains(words[index]) {
            run += String(value)
            index += 1
        }
        if run.count > 1 || (run.count == 1 && !(index < words.count && isNumberWord(words[index]))) {
            return (run, index)
        }
        var reader = Reader()
        let after = reader.read(words, from: start, skipping: false)
        return reader.value.map { ($0, after) }
    }

    /// Reads one number from a list of words.
    private struct Reader {
        private enum Kind { case none, literal, unit, teen, tens, multiplier }

        private var total = 0, current = 0, started = false
        private var kind = Kind.none
        private var largest = Int.max
        private var literal: String?
        private var previous = ""

        var value: String? {
            if let literal { return literal }
            return started ? String(total + current) : nil
        }

        /// Reads the number that starts at `start` (after any words that are not numbers, when `skipping`); returns
        /// the index of the first word it did not take.
        mutating func read(_ words: [String], from start: Int, skipping: Bool = true) -> Int {
            var index = start
            while index < words.count {
                let word = words[index], next = index + 1 < words.count ? words[index + 1] : nil
                if !started {
                    if SpokenNumbers.isNumberWord(word), !(word.hasPrefix("cent") && previous == "pour") {
                        guard take(word) else { return index }
                    } else if !skipping {
                        return index
                    }
                    previous = word
                    index += 1
                    continue
                }
                if joiners.contains(word), let next, SpokenNumbers.isNumberWord(next) {
                    index += 1
                    continue
                }
                guard take(word) else { return index }
                previous = word
                index += 1
            }
            return index
        }

        /// Adds `word` to the number; false when it cannot continue it.
        private mutating func take(_ word: String) -> Bool {
            if literal != nil { return false }
            if let written = SpokenNumbers.digits(word) {
                guard !started else { return false }
                started = true
                kind = .literal
                if written.count > 15 { literal = written } else { current = Int(written) ?? 0 }
                return true
            }
            if let factor = multipliers[word] { return multiply(by: factor) }
            guard let value = small[word] else { return false }
            guard started else {
                (current, started, kind) = (value, true, Self.kind(of: value))
                return true
            }
            if kind == .literal { return false }
            let low = current % 100
            let afterMultiplier = kind == .multiplier
            if word.hasPrefix("vingt"), previous == "quatre", kind == .unit {
                current += 76  // quatre-vingt(s): 4 × 20
            } else if value < 10 && ((low >= 20 && low % 10 == 0) || (low == 0 && afterMultiplier)
                                     || (low == 10 && value >= 7 && previous == "dix")) {
                current += value  // twenty-one, hundred five, dix-sept
            } else if value >= 10 && low == 0 && afterMultiplier {
                current += value  // hundred fifteen, mille vingt
            } else if (10...19).contains(value) && (low == 60 || low == 80) && kind == .tens {
                current += value  // soixante-dix, quatre-vingt-onze
            } else if value >= 10 && total == 0 && (10...99).contains(current) && (kind == .teen || kind == .tens) {
                current = current * 100 + value  // a year: twenty fifteen, nineteen eighty
            } else {
                return false
            }
            kind = Self.kind(of: value)
            return true
        }

        private mutating func multiply(by factor: Int) -> Bool {
            if factor == 100 {
                if started && current >= 100 { return false }
                current = started && current > 0 ? current * 100 : 100
            } else {
                guard factor < largest else { return false }
                total += (started && current > 0 ? current : 1) * factor
                current = 0
                largest = factor
            }
            started = true
            kind = .multiplier
            return true
        }

        private static func kind(of value: Int) -> Kind {
            value < 10 ? .unit : value < 20 ? .teen : .tens
        }
    }

    private static let decimalWords: Set<String> = ["point", "dot", "virgule"]
    private static let joiners: Set<String> = ["and", "et"]
    private static let ordinalSuffixes: Set<String> = ["", "st", "nd", "rd", "th", "er", "re", "e", "eme", "ieme"]

    /// Number words below a hundred, ordinals included, folded (no accents).
    private static let small: [String: Int] = {
        var table: [String: Int] = [:]
        let english = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                       "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let french = ["zero", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze",
                      "douze", "treize", "quatorze", "quinze", "seize"]
        for (value, word) in english.enumerated() { table[word] = value }
        for (value, word) in french.enumerated() { table[word] = value }
        for (index, word) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() {
            table[word] = (index + 2) * 10
        }
        for (index, word) in ["vingt", "trente", "quarante", "cinquante", "soixante"].enumerated() {
            table[word] = (index + 2) * 10
        }
        table["une"] = 1
        table["vingts"] = 20
        for (word, value) in ordinalValues { table[word] = value }
        return table
    }()

    private static let ordinalValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
        "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "premier": 1, "premiere": 1, "premiers": 1, "premieres": 1, "unieme": 1, "deuxieme": 2, "seconde": 2,
        "troisieme": 3, "quatrieme": 4, "cinquieme": 5, "sixieme": 6, "septieme": 7, "huitieme": 8, "neuvieme": 9,
        "dixieme": 10, "onzieme": 11, "douzieme": 12, "treizieme": 13, "quatorzieme": 14, "quinzieme": 15,
        "seizieme": 16, "vingtieme": 20, "trentieme": 30, "quarantieme": 40, "cinquantieme": 50, "soixantieme": 60,
    ]
    private static let ordinals = Set(ordinalValues.keys)

    private static let multipliers: [String: Int] = [
        "hundred": 100, "hundreds": 100, "hundredth": 100, "cent": 100, "cents": 100, "centieme": 100,
        "thousand": 1_000, "thousands": 1_000, "thousandth": 1_000, "mille": 1_000, "mil": 1_000, "millieme": 1_000,
        "million": 1_000_000, "millions": 1_000_000, "millionth": 1_000_000, "millionieme": 1_000_000,
        "billion": 1_000_000_000, "billions": 1_000_000_000, "billionth": 1_000_000_000,
        "milliard": 1_000_000_000, "milliards": 1_000_000_000, "milliardieme": 1_000_000_000,
    ]
}
