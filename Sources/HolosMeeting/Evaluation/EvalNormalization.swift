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

    /// `isFiller` for each of `words`, except "mm" right after a number, which is millimetres ("5 mm", "five mm",
    /// "one hundred mm"); `previousWords` are the words before the first, in order.
    public static func fillerFlags(_ words: [String], previousWords: [String] = [],
                                   fillers: Set<String> = allFillers) -> [Bool] {
        fillerFlags(words, runs: SpelledRuns(previousWords + words, fillers: fillers), offset: previousWords.count,
                    previous: previousWords.last, fillers: fillers)
    }

    /// `fillerFlags` of `words`, found at `offset` in the words whose spelled-number runs are `runs`; `previous` is
    /// the word before the first. "mm" is millimetres after a word with a digit or one that ends a run.
    public static func fillerFlags(_ words: [String], runs: SpelledRuns, offset: Int, previous: String?,
                                   fillers: Set<String>) -> [Bool] {
        words.indices.map { index in
            guard isFiller(words[index], fillers: fillers) else { return false }
            guard isMillimetres(words[index]), let before = index > 0 ? words[index - 1] : previous else { return true }
            return !(before.contains(where: \.isNumber) || runs.endsRun(at: offset + index - 1))
        }
    }

    /// "mm": a filler, or millimetres after a number.
    static func isMillimetres(_ word: String) -> Bool { EvalText.key(word) == "mm" }

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

    static let openingMarks: Set<Character> = ["\"", "'", "“", "‘", "«", "(", "[", "{", "¿", "¡"]
    static let closingMarks: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}", ".", ",", ";", ":", "!", "?",
                                               "…"]

    /// Whether `words[range]` goes past a mark that ends a clause ("plus. 30") or into one that opens one, as a
    /// spelled-number run never does.
    static func crossesClause(_ words: [String], _ range: Range<Int>) -> Bool {
        range.dropLast().contains { index in
            words[index].trimmingCharacters(in: .whitespaces).last.map(closingMarks.contains) == true
        } || range.dropFirst().contains { index in
            words[index].trimmingCharacters(in: .whitespaces).first.map(openingMarks.contains) == true
        }
    }

    /// Lowercased, whitespace removed, the sentence's punctuation around it dropped ("Thirty," → "thirty").
    static func cleaned(_ word: String) -> String {
        var characters = Array(word.lowercased().filter { !$0.isWhitespace })
        while let first = characters.first, openingMarks.contains(first) { characters.removeFirst() }
        while let last = characters.last, closingMarks.contains(last) { characters.removeLast() }
        return String(characters)
    }

    // MARK: - Spelled-number runs

    /// Words that may be part of a spelled number `number` reads, besides the numbers themselves and ordinals.
    static let numberJoiners: Set<String> = ["a", "and", "oh", "point", "hundred", "plus", "percent", "per", "et",
                                             "virgule", "cent", "cents", "pour", "pourcent"]

    /// Whether `word` may be part of a spelled number: a number word ("twenty", "vingt", "hundred"), an ordinal
    /// ("first", "deuxième"), a joiner ("and", "et", "point", "plus"), or hyphenated ones ("quatre-vingt-dix").
    static func isNumberWord(_ word: String) -> Bool {
        let word = cleaned(word)
        guard !word.isEmpty, !word.contains(where: isDigit) else { return false }
        let parts = word.split(whereSeparator: { "-‑".contains($0) }).map(String.init)
        return !parts.isEmpty && parts.allSatisfy { part in
            numberJoiners.contains(part) || englishUnits[part] != nil || englishTeens[part] != nil
                || englishTens[part] != nil || englishScales[part] != nil || frenchUnits[part] != nil
                || frenchTeens[part] != nil || frenchTens[part] != nil || frenchScales[part] != nil
                || englishCardinal(ofOrdinal: part) != nil || frenchCardinal(ofOrdinal: part) != nil
        }
    }

    /// Most number words in a row a run may take that `number` does not read as one number with the words before
    /// them: in every form it reads, at most two words in a row leave it unread until the next one ("plus a" of
    /// "plus a hundred"; "and" of "one hundred and five", "per" of "thirty per cent", "point" of "three point five",
    /// "et" of "vingt et un", "oh" of "twenty oh five"). A run is read on while this allows, with no limit on its
    /// length.
    static let maxUnreadWords = 2

    /// The maximal spelled-number runs of a sequence of words: from the left, each run is the longest one `number`
    /// reads as a spelled number ("one hundred and twenty", "V one hundred five", "quatre-vingt-dix-sept", "trois
    /// virgule cinq", "twenty first", "plus thirty percent"), of any length, fillers inside left out ("twenty um
    /// one"). A run never starts or ends with a filler, and never goes past a mark that ends a clause ("twenty.
    /// One") or into one that opens one. Every decision about a spelled number takes a run whole: a spelled number is
    /// the digits it stands for only as a whole run, never as the start, end, or middle of a longer one ("twenty" of
    /// "one hundred and twenty" is not 20, "twenty" of "twenty one" is not 20). Found once over all the words of a
    /// window or track, so a number at a passage's edge is seen whole.
    public struct SpelledRuns: Sendable {
        public let runs: [Range<Int>]
        /// Per run, its number without a "plus" before it or a "percent" after it ("thirty" of "thirty percent"),
        /// which is also whole: "thirty percent" is "30 percent" as well as "30%".
        public let cores: [Range<Int>]
        /// Per word, the index in `runs` of the run it is in (fillers inside a run included).
        private let owner: [Int?]

        /// `fillers` are skipped inside a run; "mm" never is (after a number it is millimetres).
        public init(_ words: [String], fillers: Set<String> = allFillers) {
            let skippable = words.map { !isMillimetres($0) && isFiller($0, fillers: fillers) }
            var runs: [Range<Int>] = []
            var start = 0
            while start < words.count {
                guard !skippable[start], isNumberWord(words[start]) else { start += 1; continue }
                var kept: [String] = []
                var end: Int?
                var unread = 0
                var index = start
                while index < words.count {
                    let word = words[index]
                    let trimmed = word.trimmingCharacters(in: .whitespaces)
                    if index > start, let first = trimmed.first, openingMarks.contains(first) { break }
                    if !skippable[index] {
                        guard isNumberWord(word) else { break }
                        kept.append(word)
                        if let form = number(kept), !form.hasDigit {
                            end = index + 1; unread = 0
                        } else {
                            unread += 1
                            if unread > maxUnreadWords { break }
                        }
                    }
                    if let last = trimmed.last, closingMarks.contains(last) { break }
                    index += 1
                }
                if let end {
                    runs.append(start..<end)
                    start = end
                } else {
                    start += 1
                }
            }
            var owner = [Int?](repeating: nil, count: words.count)
            for (number, run) in runs.enumerated() {
                for index in run { owner[index] = number }
            }
            self.runs = runs
            self.owner = owner
            cores = runs.map { run in
                var kept = run.filter { !skippable[$0] }
                if kept.count > 1, cleaned(words[kept[0]]) == "plus" { kept.removeFirst() }
                let last = kept.suffix(2).map { cleaned(words[$0]) }
                if kept.count > 1, last.last == "percent" || last.last == "pourcent" {
                    kept.removeLast()
                } else if kept.count > 2, last == ["per", "cent"] || last == ["pour", "cent"] {
                    kept.removeLast(2)
                }
                guard let first = kept.first, let end = kept.last,
                      let form = number(kept.map { words[$0] }), !form.hasDigit else { return run }
                return first..<(end + 1)
            }
        }

        /// The run word `index` is in.
        public func run(at index: Int) -> Range<Int>? {
            guard owner.indices.contains(index), let number = owner[index] else { return nil }
            return runs[number]
        }

        /// The number without "plus" or "percent" (`cores`) of the run word `index` is in.
        public func core(at index: Int) -> Range<Int>? {
            guard owner.indices.contains(index), let number = owner[index] else { return nil }
            return cores[number]
        }

        /// Whether `range` is exactly one run, or its number without "plus" or "percent" (`cores`).
        public func isRun(_ range: Range<Int>) -> Bool {
            guard !range.isEmpty, let run = run(at: range.lowerBound) else { return false }
            return run == range || core(at: range.lowerBound) == range
        }

        /// Whether word `index` is the last of a run.
        public func endsRun(at index: Int) -> Bool { run(at: index)?.upperBound == index + 1 }

        /// Whether `range` holds part of a run's number and not all of it: it starts or ends inside a longer spelled
        /// number ("V one hundred" of "V one hundred five").
        public func cuts(_ range: Range<Int>) -> Bool {
            guard !range.isEmpty else { return false }
            for index in [range.lowerBound, range.upperBound - 1] {
                guard let core = core(at: index), core.overlaps(range) else { continue }
                if core.lowerBound < range.lowerBound || core.upperBound > range.upperBound { return true }
            }
            return false
        }

        /// Whether `range` starts or ends inside a run, its "plus" and "percent" included: "thirty" of "plus thirty"
        /// or of "thirty percent" (which `cuts` takes as whole, as the alignment reads "thirty percent" against "30
        /// percent").
        public func cutsRun(_ range: Range<Int>) -> Bool {
            guard !range.isEmpty else { return false }
            return [range.lowerBound, range.upperBound - 1].contains { index in
                run(at: index).map { $0.lowerBound < range.lowerBound || $0.upperBound > range.upperBound } == true
            }
        }
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
        }), groups[0].count <= 3, groups[0].allSatisfy(isDigit), groups[0].first != "0",
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
                let afterTen = previous == .teen && lastWord == "dix" && (7...9).contains(unit)
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
    /// Most words (fillers not counted) a compound may take on one side. A spelled number takes its whole run,
    /// however long.
    static let maxCompoundWords = 3
    /// Most words (fillers not counted) of a number written with digits `EvalNormalization.number` reads: "plus",
    /// the digits, "per cent".
    static let maxDigitNumberWords = 4
    /// Most fillers inside a joined run ("twenty um one"); a run never starts or ends with one.
    static let maxInnerFillers = 2
    /// Longest run of words, fillers included, a compound may take on one side.
    static let maxCompoundRun = maxCompoundWords + maxInnerFillers

    /// Where a passage's words are among all the words of their window: the spelled-number runs of all of them (a
    /// number at the passage's edge may go on past it), the passage's first word's index there, and the word just
    /// before it (after a number, "mm" is millimetres).
    public struct Surroundings: Sendable {
        public var runs: EvalNormalization.SpelledRuns
        public var offset: Int
        public var previous: String?

        public init(runs: EvalNormalization.SpelledRuns, offset: Int, previous: String?) {
            self.runs = runs; self.offset = offset; self.previous = previous
        }

        /// A passage's words with the words `before` and `after` them.
        public init(_ words: [String], before: [String] = [], after: [String] = [],
                    fillers: Set<String> = EvalNormalization.allFillers) {
            self.init(runs: EvalNormalization.SpelledRuns(before + words + after, fillers: fillers),
                      offset: before.count, previous: before.last)
        }
    }
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
    /// each spelled-number run (`EvalNormalization.SpelledRuns`) in digits ("V one": "v1", "V twenty one": "v21",
    /// never "v201"; "V one hundred": "v100"). No digit form when a run is not a whole number ("three point five"),
    /// or touches another number ("V one two", "V2 one"), or with `numbers` false. Only forms that keep a letter.
    static func compoundForms(_ words: [String], numbers: Bool = true) -> [String] {
        Array(Set(compoundReadings(words, numbers: numbers).map(\.text))).sorted()
    }

    /// One of `compoundForms`, with where its spelled numbers stand in it: "V one" is "v1", with "one" written as
    /// the "1" at characters 1..<2.
    struct CompoundForm: Sendable, Equatable {
        struct Spelled: Sendable, Equatable {
            /// The characters of the form's text the number's digits are.
            var range: Range<Int>
            /// Its words' keys joined ("one").
            var key: String
        }

        var text: String
        var spelled: [Spelled] = []

        /// The same words, as `sameNumber` takes numbers: a number both forms spell is the same only in the same
        /// words, even when its digits are ("version one" and "version un" are both "version1"; "version 1" is
        /// both, and so is "version one").
        func matches(_ other: CompoundForm) -> Bool {
            text == other.text && !spelled.contains { mine in
                other.spelled.contains { $0.range.overlaps(mine.range) && $0 != mine }
            }
        }
    }

    /// Where a digit ends one word and a digit starts the next, the words stay two numbers once joined: "1 2" is
    /// never "12", nor "v1 2" "v12" (as "one two" is never "12").
    static let numberSeam = "\u{2}"

    /// `joined` and `key` as one, with `numberSeam` between them where two digits meet.
    static func joining(_ joined: String, _ key: String) -> String {
        joined.last?.isNumber == true && key.first?.isNumber == true ? joined + numberSeam + key : joined + key
    }

    /// `compoundForms` with where each form's spelled numbers are.
    static func compoundReadings(_ words: [String], numbers: Bool = true) -> [CompoundForm] {
        let keys = words.map(EvalText.key)
        var forms = [CompoundForm(text: keys.reduce("", joining))]
        let runs = numbers ? EvalNormalization.SpelledRuns(words, fillers: []).runs : []
        if !runs.isEmpty {
            var digits = ""
            var spelled: [CompoundForm.Spelled] = []
            var valid = true
            var index = 0
            var runIndex = 0
            while index < words.count {
                guard runIndex < runs.count, runs[runIndex].lowerBound == index else {
                    digits = joining(digits, keys[index]); index += 1
                    continue
                }
                let run = runs[runIndex]
                if let form = EvalNormalization.number(Array(words[run])), form.canonical.allSatisfy(\.isNumber),
                   index == 0 || keys[index - 1].last?.isNumber != true,
                   run.upperBound == words.count || keys[run.upperBound].first?.isNumber != true {
                    spelled.append(.init(range: digits.count..<(digits.count + form.canonical.count),
                                         key: words[run].map(EvalText.key).joined()))
                    digits += form.canonical
                } else {
                    valid = false
                }
                index = run.upperBound; runIndex += 1
            }
            // Runs next to each other ("one two") are two numbers, never "12".
            let adjacent = zip(runs, runs.dropFirst()).contains { $0.upperBound == $1.lowerBound }
            if valid, !adjacent, digits != forms[0].text { forms.append(CompoundForm(text: digits, spelled: spelled)) }
        }
        return forms.filter { $0.text.contains(where: \.isLetter) }
    }

    struct Side {
        var words: [String]
        var keys: [String]
        var fillers: [Bool]
        var marks: [CompoundMark]
        /// The numbers runs of the words spell, by range (a word alone is `i..<i + 1`), their fillers left out: a
        /// whole spelled-number run of the window (`EvalNormalization.SpelledRuns`) inside the words, never a part of
        /// one ("twenty" of "twenty one", which is 21, never 20 and 1; of "one hundred and twenty"), or digits ("3",
        /// "plus 30", "30 percent"). None starts or ends with a filler.
        var numbers: [Range<Int>: EvalNormalization.NumberForm] = [:]
        /// [length - 1][start]: `compoundForms` of the run (2...maxCompoundWords words, fillers left out), with no
        /// digit form when the run cuts a spelled number ("V one" of "V one hundred").
        var compounds: [[[String]]]
        /// [length - 1][start]: whether each of the run's words (fillers left out) has at most two letters or
        /// digits, as the letters of an acronym ("A P I").
        var short: [[Bool]]
        /// [end]: the lengths (2 or more) of the runs ending just before word `end` that may join one word of the
        /// other side, as a number or a compound; the alignment tries only those.
        var joinLengths: [[Int]]
        /// [end]: the lengths (2 or more) of the numbers (`numbers`) ending just before word `end`, which may also
        /// join several words of the other side ("thirty per cent"/"30 percent").
        var numberLengths: [[Int]]

        init(_ words: [String], surroundings: Surroundings,
             fillers fillerSet: Set<String> = EvalNormalization.allFillers) {
            let keys = words.map(EvalText.key)
            let runs = surroundings.runs, offset = surroundings.offset
            let fillers = EvalNormalization.fillerFlags(words, runs: runs, offset: offset,
                                                        previous: surroundings.previous, fillers: fillerSet)
            self.words = words
            self.keys = keys
            self.fillers = fillers
            marks = words.map(NormalizedAlignment.compoundMark)
            let count = words.count
            /// The run's words without its fillers, when it neither starts nor ends with one and has at most
            /// `limit` inside (a whole spelled number takes all its fillers: `SpelledRuns` already skipped them).
            func kept(_ start: Int, _ length: Int, innerFillers limit: Int = NormalizedAlignment.maxInnerFillers) -> [Int]? {
                guard start >= 0, length > 0, start + length <= count, !fillers[start], !fillers[start + length - 1]
                else { return nil }
                let run = Array(start..<(start + length))
                let words = run.filter { !fillers[$0] }
                return run.count - words.count <= limit ? words : nil
            }
            var numbers: [Range<Int>: EvalNormalization.NumberForm] = [:]
            // Spelled: each whole run inside the words, and its number without "plus" or "percent".
            let window = offset..<(offset + count)
            for (run, core) in zip(runs.runs, runs.cores) where run.overlaps(window) {
                for range in Set([run, core]) where window.contains(range.lowerBound)
                    && window.contains(range.upperBound - 1) {
                    let local = (range.lowerBound - offset)..<(range.upperBound - offset)
                    guard let indices = kept(local.lowerBound, local.count, innerFillers: .max),
                          let form = EvalNormalization.number(indices.map { words[$0] }), !form.hasDigit
                    else { continue }
                    numbers[local] = form
                }
            }
            // With digits: a few words at most, as written.
            let digitRun = NormalizedAlignment.maxDigitNumberWords + NormalizedAlignment.maxInnerFillers
            for start in 0..<count {
                for length in 1...digitRun where start + length <= count {
                    guard let indices = kept(start, length), indices.count <= NormalizedAlignment.maxDigitNumberWords,
                          !EvalNormalization.crossesClause(words, start..<(start + length)),
                          indices.contains(where: { words[$0].contains(where: \.isNumber) }),
                          let form = EvalNormalization.number(indices.map { words[$0] }), form.hasDigit
                    else { continue }
                    numbers[start..<(start + length)] = form
                }
            }
            self.numbers = numbers
            compounds = (1...NormalizedAlignment.maxCompoundRun).map { length in
                (0..<count).map { start in
                    guard length > 1, let indices = kept(start, length),
                          (2...NormalizedAlignment.maxCompoundWords).contains(indices.count),
                          !EvalNormalization.crossesClause(words, start..<(start + length)) else { return [] }
                    let whole = !runs.cuts((offset + start)..<(offset + start + length))
                    return NormalizedAlignment.compoundForms(indices.map { words[$0] }, numbers: whole)
                }
            }
            short = (1...NormalizedAlignment.maxCompoundRun).map { length in
                (0..<count).map { start in
                    guard let indices = kept(start, length) else { return false }
                    return indices.allSatisfy { keys[$0].count <= 2 }
                }
            }
            var joinLengths = [Set<Int>](repeating: [], count: count + 1)
            for range in numbers.keys where range.count > 1 { joinLengths[range.upperBound].insert(range.count) }
            numberLengths = joinLengths.map { $0.sorted() }
            for (index, row) in compounds.enumerated() {
                for (start, forms) in row.enumerated() where !forms.isEmpty {
                    joinLengths[start + index + 1].insert(index + 1)
                }
            }
            self.joinLengths = joinLengths.map { $0.sorted() }
        }

        func number(_ start: Int, _ length: Int) -> EvalNormalization.NumberForm? {
            numbers[start..<(start + length)]
        }

        func compound(_ start: Int, _ length: Int) -> [String] {
            length <= compounds.count ? compounds[length - 1][start] : []
        }

        func isShort(_ start: Int, _ length: Int) -> Bool { length <= short.count && short[length - 1][start] }
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
        case .acronym: many.isShort(start, length)
        case .none: false
        }
        if marked, many.compound(start, length).contains(single.keys[one]) {
            return .compound
        }
        return sameNumber(many.number(start, length), single.number(one, 1)) ? .number : nil
    }

    /// The lengths of the numbers of several words each ending just before local word `i` and cloud word `j` that are
    /// the same number ("thirty per cent" and "30 percent"): each side's number is one it reads whole
    /// (`Side.numbers`), so a spelled number is still only ever a whole run.
    static func numberPairs(_ a: Side, _ i: Int, _ b: Side, _ j: Int) -> [(Int, Int)] {
        guard i < a.numberLengths.count, j < b.numberLengths.count, !a.numberLengths[i].isEmpty,
              !b.numberLengths[j].isEmpty else { return [] }
        return a.numberLengths[i].flatMap { localLength in
            b.numberLengths[j].compactMap { cloudLength in
                sameNumber(a.number(i - localLength, localLength), b.number(j - cloudLength, cloudLength))
                    ? (localLength, cloudLength) : nil
            }
        }
    }

    /// A minimum-edit alignment where fillers cost nothing to leave out, a number matches its other spelling (also
    /// several words against several: "thirty per cent"/"30 percent"), and a run of words matches the one word it is
    /// written as on the other side. Substitution, insertion, and deletion cost
    /// 1; a filler is never substituted. On a tie: a match, a join, a filler, a substitution, then a local-only word.
    /// `before` and `after` are each side's words around `a` and `b`: a spelled number there may extend one at an
    /// edge, and "mm" after a number is millimetres.
    public static func align(_ a: [String], _ b: [String],
                             before: (local: [String], cloud: [String]) = ([], []),
                             after: (local: [String], cloud: [String]) = ([], []),
                             cellLimit: Int = maxCells,
                             fillers: Set<String> = EvalNormalization.allFillers) -> [NormalizedOp] {
        align(a, b, surroundings: (Surroundings(a, before: before.local, after: after.local, fillers: fillers),
                                   Surroundings(b, before: before.cloud, after: after.cloud, fillers: fillers)),
              cellLimit: cellLimit, fillers: fillers)
    }

    /// `align` with each side's `Surroundings` (the spelled-number runs of its whole window).
    public static func align(_ a: [String], _ b: [String],
                             surroundings: (local: Surroundings, cloud: Surroundings),
                             cellLimit: Int = maxCells,
                             fillers: Set<String> = EvalNormalization.allFillers) -> [NormalizedOp] {
        let n = a.count, m = b.count
        if (n + 1) * (m + 1) > cellLimit {
            // Too large to align again (a long stretch without a shared word): words paired in order, as a raw
            // alignment without matches counts them, fillers left out; no matrix is allocated.
            let fillersA = flags(a, surroundings.local, fillers), fillersB = flags(b, surroundings.cloud, fillers)
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
        let left = Side(a, surroundings: surroundings.local, fillers: fillers),
            right = Side(b, surroundings: surroundings.cloud, fillers: fillers)
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
                    for length in left.joinLengths[i] where joined(left, i - length, length, right, j - 1) != nil {
                        best = min(best, cost[(i - length) * width + j - 1])
                    }
                }
                if i > 0 {
                    for length in right.joinLengths[j] where joined(right, j - length, length, left, i - 1) != nil {
                        best = min(best, cost[(i - 1) * width + j - length])
                    }
                }
                for (localLength, cloudLength) in numberPairs(left, i, right, j) {
                    best = min(best, cost[(i - localLength) * width + j - cloudLength])
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
                for length in left.joinLengths[i] {
                    if let kind = joined(left, i - length, length, right, j - 1),
                       cost[(i - length) * width + j - 1] == here {
                        ops.append(.join(local: (i - length)..<i, cloud: (j - 1)..<j, kind))
                        i -= length; j -= 1
                        continue traceback
                    }
                }
            }
            if i > 0 {
                for length in right.joinLengths[j] {
                    if let kind = joined(right, j - length, length, left, i - 1),
                       cost[(i - 1) * width + j - length] == here {
                        ops.append(.join(local: (i - 1)..<i, cloud: (j - length)..<j, kind))
                        i -= 1; j -= length
                        continue traceback
                    }
                }
            }
            for (localLength, cloudLength) in numberPairs(left, i, right, j)
            where cost[(i - localLength) * width + j - cloudLength] == here {
                ops.append(.join(local: (i - localLength)..<i, cloud: (j - cloudLength)..<j, .number))
                i -= localLength; j -= cloudLength
                continue traceback
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
                      before: (local: [String], cloud: [String]) = ([], []),
                      fillers: Set<String> = EvalNormalization.allFillers)
        -> (score: EvalScore, counts: NormalizationCounts) {
        score(ops, a: a, b: b, surroundings: (Surroundings(a, before: before.local, fillers: fillers),
                                              Surroundings(b, before: before.cloud, fillers: fillers)),
              fillers: fillers)
    }

    /// The fillers of `words` in their `surroundings`.
    private static func flags(_ words: [String], _ surroundings: Surroundings, _ fillers: Set<String>) -> [Bool] {
        EvalNormalization.fillerFlags(words, runs: surroundings.runs, offset: surroundings.offset,
                                      previous: surroundings.previous, fillers: fillers)
    }

    /// `score` with each side's `Surroundings`.
    static func score(_ ops: [NormalizedOp], a: [String], b: [String],
                      surroundings: (local: Surroundings, cloud: Surroundings),
                      fillers: Set<String> = EvalNormalization.allFillers)
        -> (score: EvalScore, counts: NormalizationCounts) {
        let fillersA = flags(a, surroundings.local, fillers), fillersB = flags(b, surroundings.cloud, fillers)
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
