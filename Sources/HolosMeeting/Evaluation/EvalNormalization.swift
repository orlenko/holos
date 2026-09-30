import Foundation

/// What the normalized comparison takes as the same words (docs/reference-evaluation.md, "Fair comparison"): a number
/// written in digits or in words, fillers, and a compound written as one word or as several. Only the alignment and
/// the scores use it; passages, the review page, and the gold keep the words as written.
public enum EvalNormalization {
    // MARK: - Fillers

    /// Hesitation sounds left out of the normalized scores on both sides, per language, as their letters with each
    /// run of one letter written once ("ummm" is "um", "hmm" is "hm", "mm" is "m").
    public static let englishFillers: Set<String> = ["um", "uh", "uhm", "er", "erm", "hm", "m", "ah"]
    public static let frenchFillers: Set<String> = ["euh", "heu", "bah", "hein"]
    public static let allFillers = englishFillers.union(frenchFillers)

    /// The fillers of a meeting in `languages` (BCP 47): English's and French's; none for another language, where
    /// "er" or "um" are words.
    public static func fillers(languages: [String]) -> Set<String> {
        var set = Set<String>()
        for language in languages {
            let code = language.lowercased().prefix(2)
            if code == "en" { set.formUnion(englishFillers) }
            if code == "fr" { set.formUnion(frenchFillers) }
        }
        return set
    }

    /// Words that would read as a drawn-out filler but are words: "err" (to make a mistake).
    static let fillerLookalikes: Set<String> = ["err"]

    /// Whether `text` is one of `fillers`, in any case, with the sentence's punctuation around it ("Um,") and letters
    /// drawn out ("ummm", "euhhh"). A mark inside ("H&M") makes it no filler.
    public static func isFiller(_ text: String, fillers: Set<String> = allFillers) -> Bool {
        let word = cleaned(text)
        // A lone "m" is a letter ("M dash"), not "mm".
        guard word.count >= 2, word.allSatisfy({ $0.isLetter }), !fillerLookalikes.contains(word) else { return false }
        var collapsed = ""
        for character in word where collapsed.last != character { collapsed.append(character) }
        return fillers.contains(collapsed)
    }

    /// `isFiller` for each of `words`, except "mm" right after a number, which is millimetres ("5 mm", "five mm");
    /// `previous` is the word before the first.
    public static func fillerFlags(_ words: [String], previous: String? = nil,
                                   fillers: Set<String> = allFillers) -> [Bool] {
        words.indices.map { index in
            guard isFiller(words[index], fillers: fillers) else { return false }
            let before = index > 0 ? words[index - 1] : previous
            if EvalText.key(words[index]) == "mm", let before,
               before.contains(where: \.isNumber) || number([before]) != nil {
                return false
            }
            return true
        }
    }

    // MARK: - Numbers

    /// A number as the normalized comparison compares it: "+21", "3.5", "1º" (an ordinal), "30%". `hasDigit` says
    /// whether it was written with digits: a spelled number is only ever taken as equal to one written with digits,
    /// never to another spelled one ("one" and "un" stay different words).
    public struct NumberForm: Sendable, Equatable {
        public var canonical: String
        public var hasDigit: Bool
    }

    /// The number `words` spell together, or nil: digits ("21", "1,000", "3.5", "+30", "30%", "1st", "1er", "2e"), or
    /// English or French words ("twenty one", "twenty-one", "a hundred", "one hundred and five", "nineteen eighty
    /// four", "three point five", "first", "vingt et un", "quatre-vingt-dix", "deuxième", "trois virgule cinq"), with
    /// "plus" before and "percent", "per cent", "pour cent" or "pourcent" after. A digit form and words never mix,
    /// except with "plus" and "percent" ("plus 30", "30 percent").
    public static func number(_ raw: [String]) -> NumberForm? {
        var words = raw.map(cleaned)
        guard !words.isEmpty, !words.contains(where: \.isEmpty) else { return nil }
        if words.count == 1, let form = digitForm(words[0]) { return form.form }
        var plus = false
        var percent = false
        if words.first == "plus" { plus = true; words.removeFirst() }
        if let last = words.last, last == "percent" || last == "pourcent" {
            percent = true; words.removeLast()
        } else if words.count >= 2, words.suffix(2) == ["per", "cent"] || words.suffix(2) == ["pour", "cent"] {
            percent = true; words.removeLast(2)
        }
        guard !words.isEmpty else { return nil }
        if words.count == 1, let digits = digitForm(words[0]) {
            guard !(plus && digits.plus), !(percent && digits.percent), !(percent && digits.ordinal) else { return nil }
            return NumberForm(canonical: canonical(plus: plus || digits.plus, integer: digits.integer,
                                                   fraction: digits.fraction, ordinal: digits.ordinal,
                                                   percent: percent || digits.percent),
                              hasDigit: true)
        }
        guard words.allSatisfy({ !$0.contains(where: isDigit) }) else { return nil }
        let parts = words.flatMap { $0.split(whereSeparator: { "-‑".contains($0) }).map(String.init) }
        guard !parts.isEmpty, let spoken = spokenNumber(parts), !(percent && spoken.ordinal) else { return nil }
        return NumberForm(canonical: canonical(plus: plus, integer: String(spoken.integer), fraction: spoken.fraction,
                                               ordinal: spoken.ordinal, percent: percent),
                          hasDigit: false)
    }

    private static func canonical(plus: Bool, integer: String, fraction: String?, ordinal: Bool,
                                  percent: Bool) -> String {
        (plus ? "+" : "") + integer + (fraction.map { "." + $0 } ?? "") + (ordinal ? "º" : "") + (percent ? "%" : "")
    }

    private static func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }

    /// Lowercased, whitespace removed, the sentence's punctuation around it dropped ("Thirty," → "thirty").
    static func cleaned(_ word: String) -> String {
        var characters = Array(word.lowercased().filter { !$0.isWhitespace })
        let opening: Set<Character> = ["\"", "'", "“", "‘", "«", "(", "[", "{", "¿", "¡"]
        let closing: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}", ".", ",", ";", ":", "!", "?", "…"]
        while let first = characters.first, opening.contains(first) { characters.removeFirst() }
        while let last = characters.last, closing.contains(last) { characters.removeLast() }
        return String(characters)
    }

    struct DigitForm {
        var plus: Bool
        var integer: String
        var fraction: String?
        var ordinal: Bool
        var percent: Bool
        var form: NumberForm {
            NumberForm(canonical: canonical(plus: plus, integer: integer, fraction: fraction, ordinal: ordinal,
                                            percent: percent), hasDigit: true)
        }
    }

    static let ordinalSuffixes: Set<String> = ["st", "nd", "rd", "th", "er", "re", "ère", "ere", "e", "ème", "eme",
                                               "nde"]

    /// "21", "+30", "1,000", "3.5", "3,5", "30%", "1st", "1er", "2e": digits with at most a plus before them, groups of
    /// three after commas, one decimal part, and an ordinal suffix or a percent sign. Anything else (a minus, a
    /// currency, a time, a range) is nil: it is compared as written.
    static func digitForm(_ word: String) -> DigitForm? {
        var rest = Substring(word)
        var plus = false
        if rest.first == "+" { plus = true; rest.removeFirst() }
        var percent = false
        if rest.last == "%" || rest.last == "٪" { percent = true; rest.removeLast() }
        let digitsEnd = rest.firstIndex(where: { !(isDigit($0) || $0 == "," || $0 == ".") }) ?? rest.endIndex
        let number = rest[..<digitsEnd]
        let suffix = String(rest[digitsEnd...])
        guard let first = number.first, isDigit(first), let last = number.last, isDigit(last) else { return nil }
        let ordinal = !suffix.isEmpty
        if ordinal { guard ordinalSuffixes.contains(suffix), !percent else { return nil } }
        var integer = ""
        var fraction: String?
        let groups = number.split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 1, groups.dropFirst().allSatisfy({ group in
            // "1,000" and "1,000.5": groups of three digits, the last one maybe followed by a decimal part.
            let whole = group.split(separator: ".", omittingEmptySubsequences: false)
            return whole[0].count == 3 && whole[0].allSatisfy(isDigit)
        }), groups[0].count <= 3, groups[0].allSatisfy(isDigit),
           groups.dropLast().allSatisfy({ !$0.contains(".") }) {
            let joined = groups.joined()
            let parts = joined.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            integer = String(parts[0])
            fraction = parts.count == 2 ? String(parts[1]) : nil
        } else {
            // One decimal separator at most: "3.5" or "3,5".
            let parts = number.split(whereSeparator: { $0 == "," || $0 == "." })
            guard parts.count <= 2, number.filter({ $0 == "," || $0 == "." }).count == parts.count - 1,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }) else { return nil }
            integer = String(parts[0])
            fraction = parts.count == 2 ? String(parts[1]) : nil
        }
        guard !(ordinal && fraction != nil), fraction?.isEmpty != true, !integer.isEmpty else { return nil }
        let trimmed = integer.drop(while: { $0 == "0" })
        return DigitForm(plus: plus, integer: trimmed.isEmpty ? "0" : String(trimmed), fraction: fraction,
                         ordinal: ordinal, percent: percent)
    }

    struct Spoken: Equatable {
        var integer: Int
        var fraction: String?
        var ordinal: Bool
    }

    /// Words (hyphens already split) that spell one number in English or in French.
    static func spokenNumber(_ words: [String]) -> Spoken? {
        var words = words
        var ordinal = false
        if let last = words.last, let cardinal = englishCardinal(ofOrdinal: last) ?? frenchCardinal(ofOrdinal: last) {
            ordinal = true
            words[words.count - 1] = cardinal
        }
        for language in [Language.english, .french] {
            if let value = decimal(words, language: language) {
                guard !(ordinal && value.fraction != nil) else { return nil }
                return Spoken(integer: value.integer, fraction: value.fraction, ordinal: ordinal)
            }
        }
        return nil
    }

    enum Language { case english, french }

    /// An integer, or an integer, "point" or "virgule", and the digits after it.
    private static func decimal(_ words: [String], language: Language) -> (integer: Int, fraction: String?)? {
        let separator = language == .english ? "point" : "virgule"
        guard let index = words.firstIndex(of: separator) else {
            return integer(words, language: language).map { ($0, nil) }
        }
        guard index > 0, index + 1 < words.count, let whole = integer(Array(words[..<index]), language: language)
        else { return nil }
        let after = Array(words[(index + 1)...])
        let digits = after.compactMap { digitWord($0, language: language) }
        if digits.count == after.count { return (whole, digits.map(String.init).joined()) }
        // French reads the decimals as a number: "trois virgule vingt-cinq" is 3.25.
        guard language == .french, let number = integer(after, language: .french) else { return nil }
        return (whole, String(number))
    }

    private static func digitWord(_ word: String, language: Language) -> Int? {
        switch language {
        case .english: word == "oh" ? 0 : englishUnits[word]
        case .french: frenchUnits[word]
        }
    }

    private static func integer(_ words: [String], language: Language) -> Int? {
        switch language {
        case .english: englishInteger(words) ?? englishYear(words)
        case .french: frenchInteger(words)
        }
    }

    // MARK: English

    static let englishUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let englishTeens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let englishTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let englishScales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    static let englishIrregularOrdinals: [String: String] = [
        "first": "one", "second": "two", "third": "three", "fifth": "five", "eighth": "eight", "ninth": "nine",
        "twelfth": "twelve",
    ]

    /// "fourth" → "four", "twentieth" → "twenty", "hundredth" → "hundred"; nil for a word that is no ordinal.
    static func englishCardinal(ofOrdinal word: String) -> String? {
        if let cardinal = englishIrregularOrdinals[word] { return cardinal }
        let isNumberWord = { (w: String) in
            englishUnits[w] != nil || englishTeens[w] != nil || englishTens[w] != nil || englishScales[w] != nil
                || w == "hundred"
        }
        if word.hasSuffix("ieth") {
            let cardinal = String(word.dropLast(4)) + "y"
            return englishTens[cardinal] != nil ? cardinal : nil
        }
        if word.hasSuffix("th") {
            let cardinal = String(word.dropLast(2))
            return isNumberWord(cardinal) && cardinal != "zero" ? cardinal : nil
        }
        return nil
    }

    private enum Previous { case start, unit, teen, tens, hundred, scale, and }

    /// Standard English cardinals below a trillion: "twenty one", "a hundred", "one hundred and five", "fifteen
    /// hundred", "two thousand twenty six". Two units in a row, or tens after tens, are no number.
    static func englishInteger(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        if words == ["zero"] { return 0 }
        var total = 0, current = 0
        var lastScale = Int.max
        var previous = Previous.start
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : nil
            if word == "a", index == 0, let next, next == "hundred" || englishScales[next] != nil {
                current = 1; previous = .unit
            } else if word == "and" {
                guard previous == .hundred || previous == .scale, let next,
                      englishUnits[next] != nil || englishTeens[next] != nil || englishTens[next] != nil
                else { return nil }
                previous = .and
            } else if let unit = englishUnits[word], unit > 0 {
                guard [.start, .tens, .hundred, .scale, .and].contains(previous) else { return nil }
                current += unit; previous = .unit
            } else if let teen = englishTeens[word] {
                guard [.start, .hundred, .scale, .and].contains(previous) else { return nil }
                current += teen; previous = .teen
            } else if let tens = englishTens[word] {
                guard [.start, .hundred, .scale, .and].contains(previous) else { return nil }
                current += tens; previous = .tens
            } else if word == "hundred" {
                guard [.unit, .teen, .tens].contains(previous), (1...99).contains(current) else { return nil }
                current *= 100; previous = .hundred
            } else if let scale = englishScales[word] {
                guard current > 0, current < 1_000, scale < lastScale, previous != .and else { return nil }
                total += current * scale; current = 0; lastScale = scale; previous = .scale
            } else {
                return nil
            }
        }
        guard previous != .and else { return nil }
        return total + current
    }

    /// A year said in two halves: "nineteen eighty four" (1984), "twenty twenty six" (2026), "twenty oh five" (2005).
    static func englishYear(_ words: [String]) -> Int? {
        guard words.count >= 2 else { return nil }
        for split in 1..<words.count {
            guard let high = englishInteger(Array(words[..<split])), (10...99).contains(high) else { continue }
            let rest = Array(words[split...])
            if rest.count == 2, rest[0] == "oh", let unit = englishUnits[rest[1]], unit > 0 {
                return high * 100 + unit
            }
            if let low = englishInteger(rest), (10...99).contains(low) { return high * 100 + low }
        }
        return nil
    }

    // MARK: French

    static let frenchUnits: [String: Int] = [
        "zéro": 0, "zero": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7,
        "huit": 8, "neuf": 9,
    ]
    static let frenchTeens: [String: Int] = [
        "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16,
    ]
    static let frenchTens: [String: Int] = [
        "vingt": 20, "vingts": 20, "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60, "septante": 70,
        "huitante": 80, "octante": 80, "nonante": 90,
    ]
    static let frenchScales: [String: Int] = [
        "mille": 1_000, "mil": 1_000, "million": 1_000_000, "millions": 1_000_000, "milliard": 1_000_000_000,
        "milliards": 1_000_000_000,
    ]

    /// "premier" → "un", "deuxième" → "deux", "cinquième" → "cinq", "neuvième" → "neuf", "vingt et unième" → "un".
    static func frenchCardinal(ofOrdinal word: String) -> String? {
        if word == "premier" || word == "première" || word == "premiere" { return "un" }
        let stem: String
        if word.hasSuffix("ième") || word.hasSuffix("ieme") {
            stem = String(word.dropLast(4))
        } else {
            return nil
        }
        let isNumberWord = { (w: String) in
            frenchUnits[w] != nil || frenchTeens[w] != nil || frenchTens[w] != nil || frenchScales[w] != nil
                || w == "cent"
        }
        if stem == "cinqu" { return "cinq" }
        if stem == "neuv" { return "neuf" }
        if isNumberWord(stem) { return stem }
        if isNumberWord(stem + "e") { return stem + "e" }
        return nil
    }

    /// French cardinals: "vingt et un", "soixante-dix-sept", "quatre-vingts", "quatre-vingt-dix", "deux cents",
    /// "mille", "deux mille vingt-six", "trois millions".
    static func frenchInteger(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        if words.count == 1, words[0] == "zéro" || words[0] == "zero" { return 0 }
        var total = 0, current = 0
        var lastScale = Int.max
        var previous = Previous.start
        var lastWord = ""
        for (index, word) in words.enumerated() {
            defer { lastWord = word }
            let next = index + 1 < words.count ? words[index + 1] : nil
            if word == "et" {
                guard previous == .tens, let next, next == "un" || next == "une" || next == "onze" else { return nil }
                previous = .and
            } else if let unit = frenchUnits[word], unit > 0 {
                // After "dix" only in "dix-sept", "soixante-dix-neuf".
                let afterTen = previous == .teen && lastWord == "dix"
                guard [.start, .tens, .hundred, .scale, .and].contains(previous) || afterTen else { return nil }
                current += unit; previous = .unit
            } else if let teen = frenchTeens[word] {
                let rest = current % 100
                let afterTens = (previous == .tens || previous == .and) && (rest == 60 || rest == 80)
                guard [.start, .hundred, .scale].contains(previous) || afterTens else { return nil }
                current += teen; previous = .teen
            } else if let tens = frenchTens[word] {
                if tens == 20, previous == .unit, lastWord == "quatre" {
                    current += 76  // "quatre-vingts": 4 × 20
                } else {
                    guard [.start, .hundred, .scale].contains(previous) else { return nil }
                    current += tens
                }
                previous = .tens
            } else if word == "cent" || word == "cents" {
                if previous == .start || previous == .scale {
                    current += 100
                } else {
                    guard previous == .unit, (2...9).contains(current % 1_000) else { return nil }
                    current *= 100
                }
                previous = .hundred
            } else if let scale = frenchScales[word] {
                guard scale < lastScale, previous != .and else { return nil }
                if scale == 1_000, current == 0 {
                    current = 1  // "mille" alone
                }
                guard current > 0, current < 1_000 else { return nil }
                total += current * scale; current = 0; lastScale = scale; previous = .scale
            } else {
                return nil
            }
        }
        guard previous != .and else { return nil }
        return total + current
    }
}

/// How many differences the normalized comparison took as the same words.
public struct NormalizationCounts: Codable, Sendable, Equatable {
    /// Fillers left out, per side.
    public var fillersLocal = 0
    public var fillersCloud = 0
    /// Numbers written in digits on one side and in words on the other ("3"/"three", "+30"/"plus 30").
    public var numbers = 0
    /// Compounds written as one word on one side and as two or three on the other ("TestFlight"/"test flight").
    public var compounds = 0

    public init() {}

    public mutating func add(_ other: NormalizationCounts) {
        fillersLocal += other.fillersLocal; fillersCloud += other.fillersCloud
        numbers += other.numbers; compounds += other.compounds
    }
}

/// One step of a normalized alignment of local words (`a`) with cloud words (`b`), by index.
public enum NormalizedOp: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case same, number, compound }
    /// One word each side, the same (`same`: by key) or the same number (`number`: "3" and "three").
    case equal(Int, Int, Kind)
    /// Several words on one side for one on the other: a number ("twenty one"/"21") or a compound.
    case join(local: Range<Int>, cloud: Range<Int>, Kind)
    /// A filler, left out.
    case fillerLocal(Int)
    case fillerCloud(Int)
    case substitute(Int, Int)
    case localOnly(Int)
    case cloudOnly(Int)

    /// Whether this step is an edit (counts in the normalized WER).
    public var isEdit: Bool {
        switch self {
        case .substitute, .localOnly, .cloudOnly: true
        default: false
        }
    }
}

public enum NormalizedAlignment {
    /// Most words (fillers not counted) a number may take on one side ("one hundred and twenty five").
    static let maxNumberWords = 5
    /// Most words (fillers not counted) a compound may take on one side.
    static let maxCompoundWords = 3
    /// Most fillers inside a joined run ("twenty um one"); a run never starts or ends with one.
    static let maxInnerFillers = 2
    /// Longest run of words, fillers included, one side of a join may take.
    static let maxJoinRun = maxNumberWords + maxInnerFillers
    /// Above this many cells a passage is not aligned again: each of its words counts as the raw alignment has it.
    public static let maxCells = 16_000_000

    /// How a word written as one shows that it joins several ("TestFlight", "follow-up", "v1", "API"); a plain word
    /// ("nowhere") shows nothing, so "now here" stays two other words.
    enum CompoundMark { case none, acronym, joined }

    static func compoundMark(_ text: String) -> CompoundMark {
        let characters = Array(text)
        let letters = characters.filter(\.isLetter)
        guard !letters.isEmpty else { return .none }
        if characters.contains(where: \.isNumber) { return .joined }
        for index in characters.indices.dropFirst() {
            let (before, here) = (characters[index - 1], characters[index])
            // camelCase: a capital after a small letter.
            if here.isUppercase, before.isLowercase { return .joined }
            // A mark between two letters: a hyphen, a dash, a slash, a dot, an underscore.
            if !here.isLetter, !here.isNumber, !here.isWhitespace, before.isLetter,
               index + 1 < characters.count, characters[index + 1].isLetter, !"'’".contains(here) {
                return .joined
            }
        }
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase) ? .acronym : .none
    }

    /// The ways `words` are written as one word: their keys joined ("test flight": "testflight"), and joined with
    /// each run of spelled numbers in digits ("V one": "v1", "V twenty one": "v21", never "v201"). Only forms that
    /// keep a letter.
    static func compoundForms(_ words: [String]) -> [String] {
        let keys = words.map(EvalText.key)
        var forms = [keys.joined()]
        var digits = ""
        var group: [String] = []
        var valid = true
        var spelledAny = false
        func flush() {
            guard !group.isEmpty else { return }
            if let form = EvalNormalization.number(group), !form.hasDigit, form.canonical.allSatisfy(\.isNumber) {
                digits += form.canonical
            } else {
                valid = false
            }
            group.removeAll()
        }
        for (word, key) in zip(words, keys) {
            if isSpelledCardinal(word) {
                group.append(word)
                spelledAny = true
            } else {
                flush()
                digits += key
            }
        }
        flush()
        if valid, spelledAny { forms.append(digits) }
        return Array(Set(forms)).filter { $0.contains(where: \.isLetter) }.sorted()
    }

    /// A spelled cardinal word ("one", "twenty", "cent").
    static func isSpelledCardinal(_ word: String) -> Bool {
        guard let form = EvalNormalization.number([word]) else { return false }
        return !form.hasDigit && form.canonical.allSatisfy(\.isNumber)
    }

    struct Side {
        var words: [String]
        var keys: [String]
        var fillers: [Bool]
        var marks: [CompoundMark]
        /// [length - 1][start]: the number the run spells, its fillers left out (length 1 is the word alone); nil for
        /// a run that starts or ends with a filler, and for a spelled run that is only part of a longer spelled
        /// number ("twenty" in "twenty one", which is 21, never 20 and 1).
        var numbers: [[EvalNormalization.NumberForm?]]
        /// [length - 1][start]: `compoundForms` of the run (2...maxCompoundWords words, fillers left out).
        var compounds: [[[String]]]
        /// [length - 1][start]: whether each of the run's words (fillers left out) has at most two letters or
        /// digits, as the letters of an acronym ("A P I").
        var short: [[Bool]]

        init(_ words: [String], previous: String? = nil, fillers fillerSet: Set<String> = EvalNormalization.allFillers) {
            let keys = words.map(EvalText.key)
            let fillers = EvalNormalization.fillerFlags(words, previous: previous, fillers: fillerSet)
            self.words = words
            self.keys = keys
            self.fillers = fillers
            marks = words.map(NormalizedAlignment.compoundMark)
            let count = words.count
            /// The run's words without its fillers, when it neither starts nor ends with one and has few inside.
            func kept(_ start: Int, _ length: Int) -> [Int]? {
                guard start + length <= count, !fillers[start], !fillers[start + length - 1] else { return nil }
                let run = Array(start..<(start + length))
                let words = run.filter { !fillers[$0] }
                return run.count - words.count <= NormalizedAlignment.maxInnerFillers ? words : nil
            }
            let wordsBefore = { (index: Int, count: Int) -> [String] in
                Array((0..<index).filter { !fillers[$0] }.suffix(count).map { words[$0] })
            }
            let wordsAfter = { (index: Int, count: Int) -> [String] in
                Array((index..<words.count).filter { !fillers[$0] }.prefix(count).map { words[$0] })
            }
            numbers = (1...NormalizedAlignment.maxJoinRun).map { length in
                (0..<count).map { start in
                    guard let indices = kept(start, length), indices.count <= NormalizedAlignment.maxNumberWords,
                          let form = EvalNormalization.number(indices.map { words[$0] }) else { return nil }
                    guard !form.hasDigit else { return form }
                    // A spelled run the words around it extend ("twenty" before "one", "one hundred" before
                    // "and five") is not a number of its own.
                    let run = indices.map { words[$0] }
                    for extra in 1...2 {
                        let before = wordsBefore(start, extra), after = wordsAfter(start + length, extra)
                        for extended in [before + run, run + after] where extended.count == run.count + extra {
                            if let longer = EvalNormalization.number(extended), !longer.hasDigit { return nil }
                        }
                    }
                    return form
                }
            }
            compounds = (1...NormalizedAlignment.maxJoinRun).map { length in
                (0..<count).map { start in
                    guard length > 1, let indices = kept(start, length),
                          (2...NormalizedAlignment.maxCompoundWords).contains(indices.count) else { return [] }
                    return NormalizedAlignment.compoundForms(indices.map { words[$0] })
                }
            }
            short = (1...NormalizedAlignment.maxJoinRun).map { length in
                (0..<count).map { start in
                    guard let indices = kept(start, length) else { return false }
                    return indices.allSatisfy { keys[$0].count <= 2 }
                }
            }
        }

        func number(_ start: Int, _ length: Int) -> EvalNormalization.NumberForm? { numbers[length - 1][start] }
        func compound(_ start: Int, _ length: Int) -> [String] { compounds[length - 1][start] }
    }

    /// Numbers are the same when their canonical forms are and at least one was written with digits.
    static func sameNumber(_ x: EvalNormalization.NumberForm?, _ y: EvalNormalization.NumberForm?) -> Bool {
        guard let x, let y else { return false }
        return x.canonical == y.canonical && (x.hasDigit || y.hasDigit)
    }

    /// One word against one word: nil when they differ.
    static func equal(_ a: Side, _ i: Int, _ b: Side, _ j: Int) -> NormalizedOp.Kind? {
        guard !a.fillers[i], !b.fillers[j] else { return nil }
        if a.keys[i] == b.keys[j] { return .same }
        return sameNumber(a.number(i, 1), b.number(j, 1)) ? .number : nil
    }

    /// `length` words of `many` from `start` against word `one` of `single`: nil when they differ. A compound needs
    /// the one word to show that it joins words (`compoundMark`; an acronym only against letters one or two at a
    /// time).
    static func joined(_ many: Side, _ start: Int, _ length: Int, _ single: Side, _ one: Int) -> NormalizedOp.Kind? {
        guard !single.fillers[one] else { return nil }
        let marked = switch single.marks[one] {
        case .joined: true
        case .acronym: many.short[length - 1][start]
        case .none: false
        }
        if marked, many.compound(start, length).contains(single.keys[one]) {
            return .compound
        }
        return sameNumber(many.number(start, length), single.number(one, 1)) ? .number : nil
    }

    /// A minimum-edit alignment where fillers cost nothing to leave out, a number matches its other spelling, and a run
    /// of words matches the one word it is written as on the other side. Substitution, insertion, and deletion cost
    /// 1; a filler is never substituted. On a tie: a match, a join, a filler, a substitution, then a local-only word.
    public static func align(_ a: [String], _ b: [String],
                             before: (local: String?, cloud: String?) = (nil, nil),
                             cellLimit: Int = maxCells,
                             fillers: Set<String> = EvalNormalization.allFillers) -> [NormalizedOp] {
        let n = a.count, m = b.count
        if (n + 1) * (m + 1) > cellLimit {
            // Too large to align again (a long stretch without a shared word): words paired in order, as a raw
            // alignment without matches counts them, fillers left out; no matrix is allocated.
            let fillersA = EvalNormalization.fillerFlags(a, previous: before.local, fillers: fillers)
            let fillersB = EvalNormalization.fillerFlags(b, previous: before.cloud, fillers: fillers)
            let wordsA = a.indices.filter { !fillersA[$0] }, wordsB = b.indices.filter { !fillersB[$0] }
            var ops: [NormalizedOp] = a.indices.filter { fillersA[$0] }.map { .fillerLocal($0) }
            ops += b.indices.filter { fillersB[$0] }.map { .fillerCloud($0) }
            for index in 0..<max(wordsA.count, wordsB.count) {
                switch (index < wordsA.count ? wordsA[index] : nil, index < wordsB.count ? wordsB[index] : nil) {
                case (let i?, let j?): ops.append(EvalText.key(a[i]) == EvalText.key(b[j]) ? .equal(i, j, .same)
                                                  : .substitute(i, j))
                case (let i?, nil): ops.append(.localOnly(i))
                case (nil, let j?): ops.append(.cloudOnly(j))
                case (nil, nil): break
                }
            }
            return ops
        }
        let left = Side(a, previous: before.local, fillers: fillers),
            right = Side(b, previous: before.cloud, fillers: fillers)
        let width = m + 1
        let infinity = Int32.max / 2
        var cost = [Int32](repeating: infinity, count: (n + 1) * width)
        cost[0] = 0
        for i in 0...n {
            for j in 0...m where i > 0 || j > 0 {
                var best = infinity
                if i > 0, j > 0 {
                    let diagonal = cost[(i - 1) * width + j - 1]
                    if equal(left, i - 1, right, j - 1) != nil {
                        best = min(best, diagonal)
                    } else if !left.fillers[i - 1], !right.fillers[j - 1] {
                        best = min(best, diagonal + 1)
                    }
                }
                if i > 0 { best = min(best, cost[(i - 1) * width + j] + (left.fillers[i - 1] ? 0 : 1)) }
                if j > 0 { best = min(best, cost[i * width + j - 1] + (right.fillers[j - 1] ? 0 : 1)) }
                if j > 0 {
                    for length in 2...maxJoinRun where i >= length
                        && joined(left, i - length, length, right, j - 1) != nil {
                        best = min(best, cost[(i - length) * width + j - 1])
                    }
                }
                if i > 0 {
                    for length in 2...maxJoinRun where j >= length
                        && joined(right, j - length, length, left, i - 1) != nil {
                        best = min(best, cost[(i - 1) * width + j - length])
                    }
                }
                cost[i * width + j] = best
            }
        }
        var ops: [NormalizedOp] = []
        var i = n, j = m
        traceback: while i > 0 || j > 0 {
            let here = cost[i * width + j]
            if i > 0, j > 0, let kind = equal(left, i - 1, right, j - 1), cost[(i - 1) * width + j - 1] == here {
                ops.append(.equal(i - 1, j - 1, kind)); i -= 1; j -= 1
                continue
            }
            if j > 0 {
                for length in 2...maxJoinRun where i >= length {
                    if let kind = joined(left, i - length, length, right, j - 1),
                       cost[(i - length) * width + j - 1] == here {
                        ops.append(.join(local: (i - length)..<i, cloud: (j - 1)..<j, kind))
                        i -= length; j -= 1
                        continue traceback
                    }
                }
            }
            if i > 0 {
                for length in 2...maxJoinRun where j >= length {
                    if let kind = joined(right, j - length, length, left, i - 1),
                       cost[(i - 1) * width + j - length] == here {
                        ops.append(.join(local: (i - 1)..<i, cloud: (j - length)..<j, kind))
                        i -= 1; j -= length
                        continue traceback
                    }
                }
            }
            if i > 0, left.fillers[i - 1], cost[(i - 1) * width + j] == here {
                ops.append(.fillerLocal(i - 1)); i -= 1
                continue
            }
            if j > 0, right.fillers[j - 1], cost[i * width + j - 1] == here {
                ops.append(.fillerCloud(j - 1)); j -= 1
                continue
            }
            if i > 0, j > 0, !left.fillers[i - 1], !right.fillers[j - 1],
               cost[(i - 1) * width + j - 1] + 1 == here {
                ops.append(.substitute(i - 1, j - 1)); i -= 1; j -= 1
                continue
            }
            if i > 0, cost[(i - 1) * width + j] + 1 == here {
                ops.append(.localOnly(i - 1)); i -= 1
            } else {
                ops.append(.cloudOnly(j - 1)); j -= 1
            }
        }
        return ops.reversed()
    }

    /// The scores of a normalized alignment `ops` of `a` with `b`: words (fillers left out), edits, and what was taken
    /// as the same.
    static func score(_ ops: [NormalizedOp], a: [String], b: [String],
                      before: (local: String?, cloud: String?) = (nil, nil),
                      fillers: Set<String> = EvalNormalization.allFillers)
        -> (score: EvalScore, counts: NormalizationCounts) {
        let fillersA = EvalNormalization.fillerFlags(a, previous: before.local, fillers: fillers)
        let fillersB = EvalNormalization.fillerFlags(b, previous: before.cloud, fillers: fillers)
        var score = EvalScore()
        var counts = NormalizationCounts()
        for op in ops {
            switch op {
            case .equal(let i, let j, let kind):
                score.localWords += 1; score.cloudWords += 1; score.matches += 1
                if kind == .number { counts.numbers += 1 } else if a[i] != b[j] { score.caseOrPunctuationOnly += 1 }
            case .join(let local, let cloud, let kind):
                // Fillers inside the run ("twenty um one") are left out as fillers.
                let localFillers = local.filter { fillersA[$0] }.count
                let cloudFillers = cloud.filter { fillersB[$0] }.count
                counts.fillersLocal += localFillers; counts.fillersCloud += cloudFillers
                score.localWords += local.count - localFillers; score.cloudWords += cloud.count - cloudFillers
                score.matches += 1
                if kind == .number { counts.numbers += 1 } else { counts.compounds += 1 }
            case .fillerLocal: counts.fillersLocal += 1
            case .fillerCloud: counts.fillersCloud += 1
            case .substitute: score.localWords += 1; score.cloudWords += 1; score.substitutions += 1
            case .localOnly: score.localWords += 1; score.localOnly += 1
            case .cloudOnly: score.cloudWords += 1; score.cloudOnly += 1
            }
        }
        return (score, counts)
    }
}
