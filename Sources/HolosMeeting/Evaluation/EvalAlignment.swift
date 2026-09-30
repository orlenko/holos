import Foundation

/// One word of a transcript as the evaluation compares it (docs/reference-evaluation.md, "Cloud reference").
public struct EvalToken: Codable, Sendable, Equatable {
    /// The word as written, with its punctuation ("Kubernetes,").
    public var text: String
    /// Session time; nil for a cloud word (the cloud model returns no timestamps).
    public var start: Double?
    public var end: Double?
    /// A microphone word that is echo of the system track (`EchoFilter`): left out of scores and passages.
    public var echo: Bool
    /// Whether the word was written after whitespace in its transcript. False for the second and later characters
    /// of a run of a script written without spaces (Chinese, Japanese, Thai…), which are compared one by one.
    public var spaceBefore: Bool

    public init(text: String, start: Double? = nil, end: Double? = nil, echo: Bool = false, spaceBefore: Bool = true) {
        self.text = text; self.start = start; self.end = end; self.echo = echo; self.spaceBefore = spaceBefore
    }

    /// Lowercased letters and digits, with the punctuation that changes a number's value: what is compared.
    /// "Vote," and "vote" match; "don't" is "dont"; "1.5" and "15", or "-5" and "5", do not.
    public var key: String { EvalText.key(text) }
}

public enum EvalText {
    /// Lowercased letters and digits of `text`, plus the marks that change a number: a decimal or group separator,
    /// colon, or slash between two digits ("1.5", "1,000", "3:30", "1/2"), a leading decimal separator that follows no
    /// letter (".5", "-.5"), a dash between two digits ("1-2"), a
    /// minus sign before a digit that follows no letter or digit ("-5", "−5"; "COVID-19" stays "covid19") or is an
    /// exponent's ("1e-5"), a percent
    /// sign after a digit ("5%"), a currency sign next to one, spaces between allowed ("$50", "50 €"), and a minus
    /// sign before an amount ("-$50"). So a
    /// difference in a number is a word difference, shown for review, never case or punctuation only.
    public static func key(_ text: String) -> String {
        let lowered = text.lowercased()
        // A word with a digit is a number, an amount, a time, a version or a code: every mark inside it counts
        // ("$-50" is not "-50", ".5" is not "5", "1e-5" is not "1e5", "50 %" is "50%"), only the sentence's
        // punctuation around it does not. Any other word is compared by its letters and digits alone.
        guard lowered.contains(where: isDigit) else {
            return String(lowered.filter { $0.isLetter || $0.isNumber })
        }
        var characters = Array(lowered.filter { !$0.isWhitespace })
        let opening: Set<Character> = ["\"", "'", "“", "‘", "«", "(", "[", "{", "¿", "¡"]
        let closing: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}", ".", ",", ";", ":", "!", "?", "…"]
        while let first = characters.first, opening.contains(first) { characters.removeFirst() }
        while let last = characters.last, closing.contains(last) { characters.removeLast() }
        // A mark between a letter and a digit only joins a name to its number ("COVID-19", "v.2", "type-2").
        characters = characters.indices.compactMap { index in
            let character = characters[index]
            guard !character.isLetter, !character.isNumber, index > 0, index + 1 < characters.count else {
                return character
            }
            let (before, after) = (characters[index - 1], characters[index + 1])
            // Not an exponent's sign ("1e-5").
            let exponent = before == "e" && index >= 2 && isDigit(characters[index - 2])
            let joinsNameAndNumber = !exponent
                && ((before.isLetter && isDigit(after)) || (isDigit(before) && after.isLetter))
            return joinsNameAndNumber ? nil : character
        }
        return String(characters.map { $0 == "٪" ? "%" : ($0 == "\u{2212}" || $0 == "\u{2013}" ? "-" : $0) })
    }

    private static func isDigit(_ character: Character) -> Bool { character.isNumber && character.isWholeNumber }

    private static func isCurrency(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.generalCategory == .currencySymbol
    }

    /// A sign a number can carry: a minus (hyphen, minus sign, en dash) or a plus.
    private static func isSign(_ character: Character) -> Bool { "-+\u{2212}\u{2013}".contains(character) }

    /// A word of signs and currency signs only ("-", "$", "-$", "+ €"): it belongs to an amount after it.
    static func isAmountPrefix(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { isCurrency($0) || isSign($0) || $0.isWhitespace }
    }

    /// Whether `text` starts an amount: after any signs and currency signs, a digit, or a decimal or group separator
    /// then a digit ("50", "-50", "$50", ".5", "-,5").
    static func startsAmount(_ text: String) -> Bool {
        var rest = Substring(text)
        while let first = rest.first, isCurrency(first) || isSign(first) { rest.removeFirst() }
        if let first = rest.first, ".,".contains(first) { rest.removeFirst() }
        return rest.first.map(isDigit) == true
    }

    /// One word of a text: its characters, where they are (UTF-16), and whether whitespace came before it.
    public struct Piece: Sendable, Equatable {
        public var text: String
        public var utf16Start: Int
        public var utf16End: Int
        public var spaceBefore: Bool
    }

    /// The words of `text` as the evaluation compares them, the same way for the local and the cloud transcript:
    /// split at whitespace, and each character of a script written without spaces (Han, kana, Thai, Lao, Khmer,
    /// Myanmar, Tibetan) a word of its own, so "你好世界" is four words however a recognizer grouped them. A piece
    /// without letters or digits (a lone "—", "?" or "。") joins the word before, with the space it had, so every
    /// piece has a key; one before any word is dropped. A run of lone signs and currency signs ("-", "+", "$",
    /// "- $") joins the amount after it instead (`startsAmount`), so "$ 50" is one word, as "$50" is, and "- 5" keeps
    /// its sign; before any other word, the run joins the word before as punctuation does.
    public static func pieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var current: Piece?
        var prefix: Piece?  // a run of lone signs and currency signs waiting for the word after it
        var space = false
        var offset = 0
        func attach(_ piece: Piece) {
            guard !pieces.isEmpty else { return }
            let last = pieces.count - 1
            pieces[last].text += (piece.spaceBefore ? " " : "") + piece.text
            pieces[last].utf16End = piece.utf16End
        }
        /// `first`, then `second` after the space it had.
        func joined(_ first: Piece, _ second: Piece) -> Piece {
            Piece(text: first.text + (second.spaceBefore ? " " : "") + second.text, utf16Start: first.utf16Start,
                  utf16End: second.utf16End, spaceBefore: first.spaceBefore)
        }
        func finish() {
            guard var piece = current else { return }
            current = nil
            if isAmountPrefix(piece.text) {
                prefix = prefix.map { joined($0, piece) } ?? piece
                return
            }
            if let waiting = prefix {
                prefix = nil
                if startsAmount(piece.text) { piece = joined(waiting, piece) } else { attach(waiting) }
            }
            if key(piece.text).isEmpty {
                attach(piece)
            } else {
                pieces.append(piece)
            }
        }
        for character in text {
            let length = character.utf16.count
            defer { offset += length }
            if character.isWhitespace {
                finish()
                space = true
                continue
            }
            let standalone = isUnspacedScript(character) && !key(String(character)).isEmpty
            if standalone || current == nil {
                finish()
                current = Piece(text: String(character), utf16Start: offset, utf16End: offset + length,
                                spaceBefore: space || pieces.isEmpty)
                space = false
                if standalone { finish() }
            } else {
                current?.text.append(character)
                current?.utf16End = offset + length
            }
        }
        finish()
        if let waiting = prefix { attach(waiting) }
        return pieces
    }

    /// The words of `text` (`pieces`).
    public static func tokens(_ text: String) -> [String] { pieces(text).map(\.text) }

    /// Whether `character` belongs to a script written without spaces between words.
    static func isUnspacedScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x0E00...0x0EFF,  // Thai, Lao
             0x0F00...0x0FFF,  // Tibetan
             0x1000...0x109F,  // Myanmar
             0x1780...0x17FF,  // Khmer
             0x2E80...0x2FDF,  // CJK radicals
             0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303B,
             0x3040...0x30FF,  // Hiragana, Katakana
             0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // Han
             0xFF66...0xFF9F,  // halfwidth Katakana
             0x20000...0x3134F:
            return true
        default:
            return false
        }
    }

    /// `tokens` written back as text: a space before each one that had whitespace before it (none before the first).
    public static func join(_ tokens: [EvalToken]) -> String {
        join(tokens.map(\.text), spaceBefore: tokens.map(\.spaceBefore))
    }

    /// `words` with a space before each whose flag is set (none before the first; all spaced when the counts differ).
    public static func join(_ words: [String], spaceBefore: [Bool]) -> String {
        var out = ""
        for (index, word) in words.enumerated() {
            if index > 0, spaceBefore.count != words.count || spaceBefore[index] { out += " " }
            out += word
        }
        return out
    }
}

/// One step of an alignment between local words (`a`) and cloud words (`b`), by index.
public enum AlignmentOp: Sendable, Equatable {
    /// Same key; `exact` when the written words are equal too (else they differ only in case or punctuation).
    case match(Int, Int, exact: Bool)
    case substitute(Int, Int)
    /// A local word with no cloud counterpart.
    case localOnly(Int)
    /// A cloud word with no local counterpart.
    case cloudOnly(Int)
}

public enum EvalAlignment {
    /// A minimum-edit alignment of `a` and `b` by key (substitution, insertion, and deletion each cost 1). On a tie a
    /// match or substitution is preferred, then a local-only word, so the result is deterministic. Memory is
    /// proportional to `a.count × b.count`; callers align one segment (a few minutes of speech) at a time.
    public static func align(_ a: [String], _ b: [String]) -> [AlignmentOp] {
        let keysA = a.map(EvalText.key)
        let keysB = b.map(EvalText.key)
        let n = keysA.count, m = keysB.count
        if n == 0 { return (0..<m).map { .cloudOnly($0) } }
        if m == 0 { return (0..<n).map { .localOnly($0) } }
        let width = m + 1
        var cost = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 0...n { cost[i * width] = Int32(i) }
        for j in 0...m { cost[j] = Int32(j) }
        for i in 1...n {
            for j in 1...m {
                let diagonal = cost[(i - 1) * width + j - 1] + (keysA[i - 1] == keysB[j - 1] ? 0 : 1)
                let up = cost[(i - 1) * width + j] + 1
                let left = cost[i * width + j - 1] + 1
                cost[i * width + j] = min(diagonal, up, left)
            }
        }
        var ops: [AlignmentOp] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let here = cost[i * width + j]
            if i > 0, j > 0 {
                let same = keysA[i - 1] == keysB[j - 1]
                if cost[(i - 1) * width + j - 1] + (same ? 0 : 1) == here {
                    ops.append(same ? .match(i - 1, j - 1, exact: a[i - 1] == b[j - 1]) : .substitute(i - 1, j - 1))
                    i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, cost[(i - 1) * width + j] + 1 == here {
                ops.append(.localOnly(i - 1))
                i -= 1
            } else {
                ops.append(.cloudOnly(j - 1))
                j -= 1
            }
        }
        return ops.reversed()
    }
}

/// Word error counts between the two transcripts. Neither is taken as the truth: `werAgainstLocal` divides the
/// edits by the local word count, `werAgainstCloud` by the cloud word count.
public struct EvalScore: Codable, Sendable, Equatable {
    public var localWords = 0
    public var cloudWords = 0
    public var matches = 0
    /// Matched words that differ only in case or punctuation (counted in `matches`).
    public var caseOrPunctuationOnly = 0
    public var substitutions = 0
    public var localOnly = 0
    public var cloudOnly = 0
    /// Microphone words left out as echo of the system track, and cloud words aligned inside echo.
    public var echoLocalWords = 0
    public var echoCloudWords = 0

    public init() {}

    public var edits: Int { substitutions + localOnly + cloudOnly }
    public var werAgainstLocal: Double? { localWords > 0 ? Double(edits) / Double(localWords) : nil }
    public var werAgainstCloud: Double? { cloudWords > 0 ? Double(edits) / Double(cloudWords) : nil }

    public mutating func add(_ other: EvalScore) {
        localWords += other.localWords; cloudWords += other.cloudWords; matches += other.matches
        caseOrPunctuationOnly += other.caseOrPunctuationOnly; substitutions += other.substitutions
        localOnly += other.localOnly; cloudOnly += other.cloudOnly
        echoLocalWords += other.echoLocalWords; echoCloudWords += other.echoCloudWords
    }

    enum CodingKeys: String, CodingKey {
        case localWords, cloudWords, matches, caseOrPunctuationOnly, substitutions, localOnly, cloudOnly
        case echoLocalWords, echoCloudWords, werAgainstLocal, werAgainstCloud
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localWords = try c.decode(Int.self, forKey: .localWords)
        cloudWords = try c.decode(Int.self, forKey: .cloudWords)
        matches = try c.decode(Int.self, forKey: .matches)
        caseOrPunctuationOnly = try c.decode(Int.self, forKey: .caseOrPunctuationOnly)
        substitutions = try c.decode(Int.self, forKey: .substitutions)
        localOnly = try c.decode(Int.self, forKey: .localOnly)
        cloudOnly = try c.decode(Int.self, forKey: .cloudOnly)
        echoLocalWords = try c.decodeIfPresent(Int.self, forKey: .echoLocalWords) ?? 0
        echoCloudWords = try c.decodeIfPresent(Int.self, forKey: .echoCloudWords) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(localWords, forKey: .localWords); try c.encode(cloudWords, forKey: .cloudWords)
        try c.encode(matches, forKey: .matches); try c.encode(caseOrPunctuationOnly, forKey: .caseOrPunctuationOnly)
        try c.encode(substitutions, forKey: .substitutions); try c.encode(localOnly, forKey: .localOnly)
        try c.encode(cloudOnly, forKey: .cloudOnly); try c.encode(echoLocalWords, forKey: .echoLocalWords)
        try c.encode(echoCloudWords, forKey: .echoCloudWords)
        try c.encodeIfPresent(werAgainstLocal, forKey: .werAgainstLocal)
        try c.encodeIfPresent(werAgainstCloud, forKey: .werAgainstCloud)
    }
}

/// What kind of difference a passage is, for grouping in the report.
public enum PassageGroup: String, Codable, Sendable, CaseIterable {
    /// A number or a digit on either side.
    case numbers
    /// A capitalized word (not at the start of a sentence), an acronym, or a word mixing letters and digits.
    case namesAndTerms = "names-terms"
    /// Words only one side has.
    case droppedOrAdded = "dropped-added"
    /// Other word changes.
    case otherWords = "other-words"
    /// The same words written with other case or punctuation.
    case caseOrPunctuation = "case-punctuation"

    public var title: String {
        switch self {
        case .numbers: "Numbers"
        case .namesAndTerms: "Names and terms"
        case .droppedOrAdded: "Dropped or added words"
        case .otherWords: "Other word changes"
        case .caseOrPunctuation: "Case or punctuation only"
        }
    }
}

/// A stretch where the local and cloud transcripts differ.
public struct EvalPassage: Codable, Sendable, Equatable {
    /// "<track>-<n>", n counting the track's passages from 1 in time order. Stable for one compare report.
    public var id: String
    public var track: String
    /// Session time of the passage (from its local words, else from the words around it).
    public var start: Double
    public var end: Double
    public var local: String
    public var cloud: String
    public var group: PassageGroup
    /// Up to four local words before and after the passage, for context (echo left out).
    public var before: String
    public var after: String
    /// The same from the cloud transcript.
    public var cloudBefore: String
    public var cloudAfter: String
    /// Local word positions [first, end) in the track's compared local words; first == end when local has none.
    public var localFirst: Int
    public var localEnd: Int
    /// A word passage whose sides are the same words under the normalized comparison (numbers written in digits or
    /// words, fillers, compounds; `NormalizedAlignment`): hidden on the review page by default and ignored by apply.
    /// Always false in a raw comparison.
    public var formattingOnly: Bool

    public init(id: String, track: String, start: Double, end: Double, local: String, cloud: String,
                group: PassageGroup, before: String, after: String, cloudBefore: String? = nil,
                cloudAfter: String? = nil, localFirst: Int, localEnd: Int, formattingOnly: Bool = false) {
        self.id = id; self.track = track; self.start = start; self.end = end; self.local = local; self.cloud = cloud
        self.group = group; self.before = before; self.after = after
        self.cloudBefore = cloudBefore ?? before; self.cloudAfter = cloudAfter ?? after
        self.localFirst = localFirst; self.localEnd = localEnd; self.formattingOnly = formattingOnly
    }

    enum CodingKeys: String, CodingKey {
        case id, track, start, end, local, cloud, group, before, after, cloudBefore, cloudAfter, localFirst, localEnd
        case formattingOnly
    }

    /// A report written before the normalized comparison has no `formattingOnly`: every passage is a word passage.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        track = try c.decode(String.self, forKey: .track)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        local = try c.decode(String.self, forKey: .local)
        cloud = try c.decode(String.self, forKey: .cloud)
        group = try c.decode(PassageGroup.self, forKey: .group)
        before = try c.decode(String.self, forKey: .before)
        after = try c.decode(String.self, forKey: .after)
        cloudBefore = try c.decode(String.self, forKey: .cloudBefore)
        cloudAfter = try c.decode(String.self, forKey: .cloudAfter)
        localFirst = try c.decode(Int.self, forKey: .localFirst)
        localEnd = try c.decode(Int.self, forKey: .localEnd)
        formattingOnly = try c.decodeIfPresent(Bool.self, forKey: .formattingOnly) ?? false
    }

    /// A passage the review page shows by default: words differ, and not only in formatting.
    public var needsReview: Bool { group != .caseOrPunctuation && !formattingOnly }
}

public enum PassageGrouping {
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "percent", "first", "second", "third", "half",
        "zéro", "un", "une", "deux", "trois", "quatre", "cinq", "sept", "huit", "neuf", "dix", "onze", "douze",
        "treize", "quatorze", "quinze", "seize", "vingt", "trente", "quarante", "cinquante", "soixante", "cent",
        "mille", "million", "milliard", "pourcent",
    ]

    /// The group of a word-level passage. `localWords` and `cloudWords` are the passage's own words;
    /// `sentenceStart` says, per word, whether it opens a sentence on its side (a capital there means nothing).
    public static func group(local: [String], cloud: [String], localSentenceStart: [Bool] = [],
                             cloudSentenceStart: [Bool] = []) -> PassageGroup {
        let all = local + cloud
        if all.contains(where: isNumber) { return .numbers }
        let starts = padded(localSentenceStart, local.count) + padded(cloudSentenceStart, cloud.count)
        for (index, word) in all.enumerated() where isTerm(word, sentenceStart: starts[index]) {
            return .namesAndTerms
        }
        if local.isEmpty || cloud.isEmpty { return .droppedOrAdded }
        return .otherWords
    }

    static func isNumber(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || numberWords.contains(EvalText.key(word))
    }

    static func isTerm(_ word: String, sentenceStart: Bool) -> Bool {
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        if word.contains(where: \.isNumber) { return true }
        let uppercase = letters.filter(\.isUppercase).count
        if letters.count >= 2, uppercase == letters.count { return true }  // acronym
        if uppercase > 1 { return true }  // "iPhone", "McDonald"
        guard let first = letters.first, first.isUppercase else { return false }
        if EvalText.key(word) == "i" { return false }
        return !sentenceStart
    }

    private static func padded(_ flags: [Bool], _ count: Int) -> [Bool] {
        flags.count == count ? flags : [Bool](repeating: false, count: count)
    }

    /// Whether the word after `previous` opens a sentence: nothing before it, or `previous` ends with . ! ? or ….
    static func opensSentence(after previous: String?) -> Bool {
        guard let previous else { return true }
        guard let last = previous.last(where: { !"\"'»”’)".contains($0) }) else { return false }
        return ".!?…".contains(last)
    }
}

/// The comparison of one track over one time window (a cloud segment).
public struct WindowComparison: Sendable, Equatable {
    public var score = EvalScore()
    /// Word passages and case/punctuation-only passages, in order; ids are left empty for the caller to number.
    public var passages: [EvalPassage] = []
    /// The same comparison with fillers left out and numbers and compounds taken as the same words
    /// (`NormalizedAlignment`, run on each word passage): its words exclude fillers; echo counts are the raw ones.
    public var normalized = EvalScore()
    public var normalization = NormalizationCounts()
    /// Per cloud word: nil when it was left out as echo; else whether the local transcript has the same word there,
    /// by key (`cloudMatched`) or under the normalized comparison (`cloudEquivalent`).
    public var cloudMatched: [Bool?] = []
    public var cloudEquivalent: [Bool?] = []
    /// Per cloud word the local transcript has: the local words (indices into the compared local words) it stands
    /// for, by key (`cloudMatchedSpans`) or under the normalized comparison (a joined run for a compound or number).
    public var cloudMatchedSpans: [Range<Int>?] = []
    public var cloudEquivalentSpans: [Range<Int>?] = []
}

public enum WindowComparer {
    /// Words of context shown around a passage.
    static let contextWords = 4

    /// Compares `local` (timed; echo marked) with `cloud` (untimed) over the window [start, end) of `track`.
    /// `localOffset` is the position of `local[0]` among the track's compared local words.
    ///
    /// - Echo: an operation on a local echo word is left out, and so is a run of cloud-only words between two echo
    ///   words, or of at most `echoNeighbourWords` next to one: the cloud transcript hears the echo too, and its
    ///   alignment with the echo words around it is arbitrary. A longer run beside echo is kept, and so is a timed
    ///   cloud word (timestamp pass) said more than `echoTimeSlack` away from the echo words beside it, even one the
    ///   alignment paired with an echo word (`separatingDistantEchoPairs`).
    /// - Passages: maximal runs of consecutive edits (substitutions and one-side-only words); a run of matched
    ///   words that differ only in case or punctuation is a `caseOrPunctuation` passage of its own.
    /// - Time: a passage takes the times of its local words (and of its cloud words when they are timed); a
    ///   cloud-only passage lies between the local words around it (or reaches the window edge).
    public static func compare(track: String, local: [EvalToken], cloud: [EvalToken], start: Double, end: Double,
                               localOffset: Int = 0,
                               fillers: Set<String> = EvalNormalization.allFillers) -> WindowComparison {
        evaluate(track: track, ops: EvalAlignment.align(local.map(\.text), cloud.map(\.text)), local: local,
                 cloud: cloud, start: start, end: end, localOffset: localOffset, fillers: fillers)
    }

    /// Cloud-only words beside a single echo word that still count as echo.
    static let echoNeighbourWords = 3

    /// How far (seconds) outside the echo words' time a timed cloud word beside them still counts as echo.
    static let echoTimeSlack = 1.0

    /// Scores and passages of an alignment `ops` of `local` with `cloud` (see `compare`).
    static func evaluate(track: String, ops alignment: [AlignmentOp], local: [EvalToken], cloud: [EvalToken],
                         start: Double, end: Double, localOffset: Int = 0,
                         fillers: Set<String> = EvalNormalization.allFillers) -> WindowComparison {
        let ops = realigningAroundEcho(separatingDistantEchoPairs(alignment, local: local, cloud: cloud),
                                       local: local, cloud: cloud)
        var result = WindowComparison()
        // Per op: excluded as echo?
        var lastLocal: Int?
        var previousLocalIndex: [Int?] = []
        for op in ops {
            previousLocalIndex.append(lastLocal)
            if let i = localIndex(op) { lastLocal = i }
        }
        var nextLocal: Int?
        var nextLocalIndex = [Int?](repeating: nil, count: ops.count)
        for (position, op) in ops.enumerated().reversed() {
            nextLocalIndex[position] = nextLocal
            if let i = localIndex(op) { nextLocal = i }
        }
        // Length of the run of cloud-only ops each cloud-only op belongs to.
        var cloudRun = [Int](repeating: 0, count: ops.count)
        var runStart = 0
        for position in 0...ops.count {
            let isCloudOnly = position < ops.count && localIndex(ops[position]) == nil
            if isCloudOnly { continue }
            for inside in runStart..<position { cloudRun[inside] = position - runStart }
            runStart = position + 1
        }
        let excluded: [Bool] = ops.enumerated().map { position, op in
            if let i = localIndex(op) { return local[i].echo }
            let previousEcho = previousLocalIndex[position].flatMap { local[$0].echo ? local[$0] : nil }
            let nextEcho = nextLocalIndex[position].flatMap { local[$0].echo ? local[$0] : nil }
            let before = previousEcho != nil, after = nextEcho != nil
            guard (before && after) || ((before || after) && cloudRun[position] <= echoNeighbourWords) else {
                return false
            }
            // A timed cloud word (the timestamp pass) is echo only when it was said while an echo word beside it
            // was (not merely somewhere in the gap between two echo words).
            let neighbours = [previousEcho, nextEcho].compactMap { $0 }
            guard let j = cloudIndex(op), let wordStart = cloud[j].start,
                  neighbours.allSatisfy({ $0.start != nil }) else {
                return true
            }
            let wordEnd = cloud[j].end ?? wordStart
            return neighbours.contains { echo in
                let echoStart = echo.start ?? 0, echoEnd = echo.end ?? echo.start ?? 0
                return wordStart <= echoEnd + echoTimeSlack && wordEnd >= echoStart - echoTimeSlack
            }
        }

        var run: [Int] = []  // op positions of the current edit run
        var punctuationRun: [Int] = []
        var wordRuns: [(passage: Int, positions: [Int])] = []
        result.cloudMatched = [Bool?](repeating: nil, count: cloud.count)
        result.cloudEquivalent = [Bool?](repeating: nil, count: cloud.count)
        result.cloudMatchedSpans = [Range<Int>?](repeating: nil, count: cloud.count)
        result.cloudEquivalentSpans = [Range<Int>?](repeating: nil, count: cloud.count)
        func flush(_ positions: inout [Int], caseOnly: Bool) {
            guard !positions.isEmpty else { return }
            if !caseOnly { wordRuns.append((result.passages.count, positions)) }
            result.passages.append(passage(track: track, ops: ops, positions: positions, local: local, cloud: cloud,
                                           windowStart: start, windowEnd: end, previousLocal: previousLocalIndex,
                                           nextLocal: nextLocalIndex, caseOnly: caseOnly,
                                           localOffset: localOffset))
            positions.removeAll()
        }
        for (position, op) in ops.enumerated() {
            if excluded[position] {
                switch op {
                case .cloudOnly: result.score.echoCloudWords += 1
                case .localOnly: result.score.echoLocalWords += 1
                case .match, .substitute: result.score.echoLocalWords += 1; result.score.echoCloudWords += 1
                }
                flush(&run, caseOnly: false)
                flush(&punctuationRun, caseOnly: true)
                continue
            }
            switch op {
            case .match(let i, let j, let exact):
                result.score.localWords += 1; result.score.cloudWords += 1; result.score.matches += 1
                result.cloudMatched[j] = true
                result.cloudMatchedSpans[j] = i..<(i + 1)
                flush(&run, caseOnly: false)
                if exact {
                    flush(&punctuationRun, caseOnly: true)
                } else {
                    result.score.caseOrPunctuationOnly += 1
                    punctuationRun.append(position)
                }
            case .substitute(_, let j):
                result.score.localWords += 1; result.score.cloudWords += 1; result.score.substitutions += 1
                result.cloudMatched[j] = false
                flush(&punctuationRun, caseOnly: true)
                run.append(position)
            case .localOnly:
                result.score.localWords += 1; result.score.localOnly += 1
                flush(&punctuationRun, caseOnly: true)
                run.append(position)
            case .cloudOnly(let j):
                result.score.cloudWords += 1; result.score.cloudOnly += 1
                result.cloudMatched[j] = false
                flush(&punctuationRun, caseOnly: true)
                run.append(position)
            }
        }
        flush(&run, caseOnly: false)
        flush(&punctuationRun, caseOnly: true)
        normalize(&result, ops: ops, excluded: excluded, wordRuns: wordRuns, local: local, cloud: cloud,
                  previousLocal: previousLocalIndex, fillers: fillers)
        return result
    }

    /// Matched words between two word passages that are still aligned again with them for the normalized comparison
    /// ("we test test flight" against "we test TestFlight": the raw alignment matched the second "test").
    static let normalizationGap = 2
    /// Most operations one stretch aligned again for the normalized comparison takes; a longer chain of passages is
    /// cut there.
    static let normalizationStretch = 400

    /// The normalized comparison (`NormalizedAlignment`) of an evaluated alignment: each stretch of word passages
    /// (with at most `normalizationGap` matched words between two of them) is aligned again; matched words outside
    /// such stretches count as matches (a filler as a filler). A passage none of whose words an edit of its stretch
    /// touches is formatting only. Echo is left out as in the raw scores.
    private static func normalize(_ result: inout WindowComparison, ops: [AlignmentOp], excluded: [Bool],
                                  wordRuns: [(passage: Int, positions: [Int])], local: [EvalToken],
                                  cloud: [EvalToken], previousLocal: [Int?], fillers: Set<String>) {
        func isGapMatch(_ position: Int) -> Bool {
            if excluded[position] { return false }
            if case .match = ops[position] { return true }
            return false
        }
        var stretches: [[Int]] = []  // indices into wordRuns
        for (index, run) in wordRuns.enumerated() {
            if let current = stretches.last, let last = current.last, let lastPosition = wordRuns[last].positions.last,
               let firstPosition = run.positions.first, let stretchStart = wordRuns[current[0]].positions.first,
               firstPosition - lastPosition - 1 <= normalizationGap,
               ((lastPosition + 1)..<firstPosition).allSatisfy(isGapMatch),
               run.positions.last! - stretchStart < normalizationStretch {
                stretches[stretches.count - 1].append(index)
            } else {
                stretches.append([index])
            }
        }
        var inStretch = [Bool](repeating: false, count: ops.count)
        for stretch in stretches {
            let first = wordRuns[stretch[0]].positions[0], last = wordRuns[stretch[stretch.count - 1]].positions.last!
            for position in first...last { inStretch[position] = true }
        }
        for (position, op) in ops.enumerated() where !excluded[position] && !inStretch[position] {
            guard case .match(let i, let j, let exact) = op else { continue }
            result.cloudEquivalent[j] = true
            result.cloudEquivalentSpans[j] = i..<(i + 1)
            // Each side's word is a filler or not by its own context ("5 mm" is millimetres, "well mm" a filler).
            let localFiller = EvalNormalization.fillerFlags([local[i].text], previous: i > 0 ? local[i - 1].text : nil,
                                                            fillers: fillers)[0]
            let cloudFiller = EvalNormalization.fillerFlags([cloud[j].text], previous: j > 0 ? cloud[j - 1].text : nil,
                                                            fillers: fillers)[0]
            switch (localFiller, cloudFiller) {
            case (true, true):
                result.normalization.fillersLocal += 1; result.normalization.fillersCloud += 1
            case (false, false):
                result.normalized.localWords += 1; result.normalized.cloudWords += 1
                result.normalized.matches += 1
                if !exact { result.normalized.caseOrPunctuationOnly += 1 }
            case (true, false):
                // Only the local word is a filler: the cloud's word has no counterpart.
                result.normalization.fillersLocal += 1
                result.normalized.cloudWords += 1; result.normalized.cloudOnly += 1
            case (false, true):
                result.normalization.fillersCloud += 1
                result.normalized.localWords += 1; result.normalized.localOnly += 1
            }
        }
        for stretch in stretches {
            let first = wordRuns[stretch[0]].positions[0], last = wordRuns[stretch[stretch.count - 1]].positions.last!
            let positions = Array(first...last)
            let localIndices = positions.compactMap { localIndex(ops[$0]) }
            let cloudIndices = positions.compactMap { cloudIndex(ops[$0]) }
            let a = localIndices.map { local[$0].text }, b = cloudIndices.map { cloud[$0].text }
            // The words just before, for context ("mm" after "5" is millimetres, not a filler).
            let before = (local: previousLocal[first].map { local[$0].text },
                          cloud: cloudIndices.first.flatMap { $0 > 0 ? cloud[$0 - 1].text : nil })
            let normalizedOps = NormalizedAlignment.align(a, b, before: before, fillers: fillers)
            let scored = NormalizedAlignment.score(normalizedOps, a: a, b: b, before: before, fillers: fillers)
            result.normalized.add(scored.score)
            result.normalization.add(scored.counts)
            var touchedLocal = Set<Int>(), touchedCloud = Set<Int>()
            for op in normalizedOps {
                switch op {
                case .equal(let i, let j, _):
                    result.cloudEquivalent[cloudIndices[j]] = true
                    result.cloudEquivalentSpans[cloudIndices[j]] = localIndices[i]..<(localIndices[i] + 1)
                case .join(let locals, let range, _):
                    let span = localIndices[locals.lowerBound]..<(localIndices[locals.upperBound - 1] + 1)
                    for j in range {
                        result.cloudEquivalent[cloudIndices[j]] = true
                        result.cloudEquivalentSpans[cloudIndices[j]] = span
                    }
                case .fillerCloud(let j): result.cloudEquivalent[cloudIndices[j]] = true
                case .fillerLocal: break
                case .substitute(let i, let j):
                    result.cloudEquivalent[cloudIndices[j]] = false
                    touchedLocal.insert(localIndices[i]); touchedCloud.insert(cloudIndices[j])
                case .cloudOnly(let j):
                    result.cloudEquivalent[cloudIndices[j]] = false
                    touchedCloud.insert(cloudIndices[j])
                case .localOnly(let i): touchedLocal.insert(localIndices[i])
                }
            }
            // An edit on a word the raw alignment matched between two passages ("TestFlight test" against "test
            // flight") belongs to no passage: then none of the stretch's passages is formatting only, so the edit
            // stays in front of the reviewer.
            let passagePositions = Set(stretch.flatMap { wordRuns[$0].positions })
            let gapLocal = Set(positions.filter { !passagePositions.contains($0) }.compactMap { localIndex(ops[$0]) })
            let gapCloud = Set(positions.filter { !passagePositions.contains($0) }.compactMap { cloudIndex(ops[$0]) })
            let gapTouched = !touchedLocal.isDisjoint(with: gapLocal) || !touchedCloud.isDisjoint(with: gapCloud)
            for index in stretch {
                let run = wordRuns[index]
                let touched = run.positions.contains { position in
                    localIndex(ops[position]).map(touchedLocal.contains) == true
                        || cloudIndex(ops[position]).map(touchedCloud.contains) == true
                }
                result.passages[run.passage].formattingOnly = !touched && !gapTouched
            }
        }
        result.normalized.echoLocalWords = result.score.echoLocalWords
        result.normalized.echoCloudWords = result.score.echoCloudWords
    }

    /// A timed cloud word (the timestamp pass) aligned with a timed local echo word but said more than
    /// `echoTimeSlack` away from it is not the echo: the pair becomes the echo word alone and the cloud word alone
    /// (and a stretch of such pairs, lone echo words, and cloud-only words is laid out again: the echo words in their
    /// order and the cloud words in theirs, merged by time), so the echo is left out and the cloud words are judged
    /// as cloud-only words, still in the order they were said. Without times the alignment stands.
    /// Between two matches, the words left on both sides once echo is set aside are aligned again with each other:
    /// a cloud word freed from a distant echo pair (`separatingDistantEchoPairs`) then pairs with the local word it
    /// stands for (one substitution) instead of counting as a deletion and an insertion. Echo words keep their place
    /// among the local words.
    static func realigningAroundEcho(_ ops: [AlignmentOp], local: [EvalToken], cloud: [EvalToken]) -> [AlignmentOp] {
        var result: [AlignmentOp] = []
        result.reserveCapacity(ops.count)
        var segment: [AlignmentOp] = []
        func flush() {
            defer { segment.removeAll() }
            // Ops on echo words stay as they are (with any cloud word the alignment paired them with).
            let isEchoOp = { (op: AlignmentOp) in localIndex(op).map { local[$0].echo } ?? false }
            let spoken = segment.compactMap(localIndex).filter { !local[$0].echo }
            let heard = segment.filter { !isEchoOp($0) }.compactMap(cloudIndex)
            let freeLocal = segment.contains { if case .localOnly(let i) = $0 { !local[i].echo } else { false } }
            let freeCloud = segment.contains { if case .cloudOnly = $0 { true } else { false } }
            guard freeLocal, freeCloud, segment.contains(where: isEchoOp) else {
                result += segment
                return
            }
            let realigned: [AlignmentOp] = EvalAlignment.align(spoken.map { local[$0].text },
                                                               heard.map { cloud[$0].text }).map {
                switch $0 {
                case .match(let i, let j, let exact): .match(spoken[i], heard[j], exact: exact)
                case .substitute(let i, let j): .substitute(spoken[i], heard[j])
                case .localOnly(let i): .localOnly(spoken[i])
                case .cloudOnly(let j): .cloudOnly(heard[j])
                }
            }
            // Echo ops go back before the first realigned op on a later local word.
            var echoes = segment.filter(isEchoOp)
            for op in realigned {
                if let i = localIndex(op) {
                    while let first = echoes.first, let e = localIndex(first), e < i {
                        result.append(first); echoes.removeFirst()
                    }
                }
                result.append(op)
            }
            result += echoes
        }
        for op in ops {
            if case .match(let i, _, _) = op, !local[i].echo {
                flush()
                result.append(op)
            } else {
                segment.append(op)
            }
        }
        flush()
        return result
    }

    static func separatingDistantEchoPairs(_ ops: [AlignmentOp], local: [EvalToken],
                                           cloud: [EvalToken]) -> [AlignmentOp] {
        var result: [AlignmentOp] = []
        result.reserveCapacity(ops.count)
        var stretch: [AlignmentOp] = [], echoes: [Int] = [], clouds: [Int] = []
        var separated = false
        /// Each time, or the one before it in the same sequence when missing.
        func times(_ values: [Double?]) -> [Double] {
            var last = -Double.infinity
            return values.map { value in
                if let value { last = value }
                return last
            }
        }
        func flush() {
            defer { stretch.removeAll(); echoes.removeAll(); clouds.removeAll(); separated = false }
            guard separated else { result += stretch; return }
            let echoTimes = times(echoes.map { local[$0].start }), cloudTimes = times(clouds.map { cloud[$0].start })
            var e = 0, c = 0
            while e < echoes.count || c < clouds.count {
                if c == clouds.count || (e < echoes.count && echoTimes[e] <= cloudTimes[c]) {
                    result.append(.localOnly(echoes[e])); e += 1
                } else {
                    result.append(.cloudOnly(clouds[c])); c += 1
                }
            }
        }
        for op in ops {
            switch op {
            case .match(let i, let j, _), .substitute(let i, let j):
                if local[i].echo, let echoStart = local[i].start, let wordStart = cloud[j].start {
                    let echoEnd = local[i].end ?? echoStart
                    let wordEnd = cloud[j].end ?? wordStart
                    if wordStart > echoEnd + echoTimeSlack || wordEnd < echoStart - echoTimeSlack {
                        stretch.append(op); echoes.append(i); clouds.append(j)
                        separated = true
                        continue
                    }
                }
            case .localOnly(let i):
                if local[i].echo { stretch.append(op); echoes.append(i); continue }
            case .cloudOnly(let j):
                stretch.append(op); clouds.append(j)
                continue
            }
            flush()
            result.append(op)
        }
        flush()
        return result
    }

    static func localIndex(_ op: AlignmentOp) -> Int? {
        switch op {
        case .match(let i, _, _), .substitute(let i, _), .localOnly(let i): i
        case .cloudOnly: nil
        }
    }

    static func cloudIndex(_ op: AlignmentOp) -> Int? {
        switch op {
        case .match(_, let j, _), .substitute(_, let j), .cloudOnly(let j): j
        case .localOnly: nil
        }
    }

    private static func passage(track: String, ops: [AlignmentOp], positions: [Int], local: [EvalToken],
                                cloud: [EvalToken], windowStart: Double, windowEnd: Double,
                                previousLocal: [Int?], nextLocal: [Int?], caseOnly: Bool,
                                localOffset: Int) -> EvalPassage {
        let localIndices = positions.compactMap { localIndex(ops[$0]) }
        let cloudIndices = positions.compactMap { cloudIndex(ops[$0]) }
        let localWords = localIndices.map { local[$0].text }
        let cloudWords = cloudIndices.map { cloud[$0].text }
        var start: Double
        var end: Double
        let cloudStarts = cloudIndices.compactMap { cloud[$0].start }
        let cloudEnds = cloudIndices.compactMap { cloud[$0].end ?? cloud[$0].start }
        if let first = localIndices.first, let last = localIndices.last {
            start = local[first].start ?? windowStart
            end = local[last].end ?? local[last].start ?? start
            if let timed = cloudStarts.min() { start = min(start, timed) }
            if let timed = cloudEnds.max() { end = max(end, timed) }
        } else if let timedStart = cloudStarts.min(), let timedEnd = cloudEnds.max() {
            start = timedStart
            end = timedEnd
        } else {
            // Untimed cloud-only words: somewhere between the local words around them.
            let before = previousLocal[positions[0]].flatMap { local[$0].end ?? local[$0].start }
            let after = nextLocal[positions[positions.count - 1]].flatMap { local[$0].start }
            start = before ?? windowStart
            end = after ?? windowEnd
        }
        if end < start { end = start }
        let group: PassageGroup
        if caseOnly {
            group = .caseOrPunctuation
        } else {
            let localStarts = localIndices.map { PassageGrouping.opensSentence(after: $0 > 0 ? local[$0 - 1].text : nil) }
            let cloudStarts = cloudIndices.map { PassageGrouping.opensSentence(after: $0 > 0 ? cloud[$0 - 1].text : nil) }
            group = PassageGrouping.group(local: localWords, cloud: cloudWords, localSentenceStart: localStarts,
                                          cloudSentenceStart: cloudStarts)
        }
        let firstPosition = positions[0]
        let localPoint = localIndices.first ?? (previousLocal[firstPosition].map { $0 + 1 } ?? 0)
        let localEndPoint = localIndices.last.map { $0 + 1 } ?? localPoint
        let cloudPoint = cloudIndices.first
            ?? (ops[..<firstPosition].last(where: { cloudIndex($0) != nil }).flatMap(cloudIndex).map { $0 + 1 } ?? 0)
        let cloudEndPoint = cloudIndices.last.map { $0 + 1 } ?? cloudPoint
        let localContext = local.map { $0.echo ? nil : $0 }
        let cloudContext = cloud.map { Optional($0) }
        return EvalPassage(id: "", track: track, start: start, end: end,
                           local: EvalText.join(localIndices.map { local[$0] }),
                           cloud: EvalText.join(cloudIndices.map { cloud[$0] }), group: group,
                           before: context(localContext, before: localPoint),
                           after: context(localContext, after: localEndPoint),
                           cloudBefore: context(cloudContext, before: cloudPoint),
                           cloudAfter: context(cloudContext, after: cloudEndPoint),
                           localFirst: localOffset + localPoint, localEnd: localOffset + localEndPoint)
    }

    /// Up to `contextWords` words of `words` (nil: left out) before position `point`.
    private static func context(_ words: [EvalToken?], before point: Int) -> String {
        EvalText.join(Array(words[..<min(point, words.count)].compactMap { $0 }.suffix(contextWords)))
    }

    /// Up to `contextWords` words of `words` from position `point` on.
    private static func context(_ words: [EvalToken?], after point: Int) -> String {
        EvalText.join(Array(words[min(point, words.count)...].compactMap { $0 }.prefix(contextWords)))
    }
}
