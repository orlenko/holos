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

    public init(text: String, start: Double? = nil, end: Double? = nil, echo: Bool = false) {
        self.text = text; self.start = start; self.end = end; self.echo = echo
    }

    /// Lowercased letters and digits: what is compared. "Vote," and "vote" match; "don't" is "dont".
    public var key: String { EvalText.key(text) }
}

public enum EvalText {
    /// Lowercased letters and digits of `text`.
    public static func key(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// `text` split at whitespace; a token without letters or digits (a lone "—" or "?") is joined to the one before,
    /// so every token has a key.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        for piece in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if key(piece).isEmpty {
                if tokens.isEmpty { continue }
                tokens[tokens.count - 1] += piece
            } else {
                tokens.append(piece)
            }
        }
        return tokens
    }

    /// Words of `tokens` joined with single spaces.
    public static func join(_ tokens: [EvalToken]) -> String { tokens.map(\.text).joined(separator: " ") }
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

    public init(id: String, track: String, start: Double, end: Double, local: String, cloud: String,
                group: PassageGroup, before: String, after: String, cloudBefore: String? = nil,
                cloudAfter: String? = nil, localFirst: Int, localEnd: Int) {
        self.id = id; self.track = track; self.start = start; self.end = end; self.local = local; self.cloud = cloud
        self.group = group; self.before = before; self.after = after
        self.cloudBefore = cloudBefore ?? before; self.cloudAfter = cloudAfter ?? after
        self.localFirst = localFirst; self.localEnd = localEnd
    }
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
}

public enum WindowComparer {
    /// Words of context shown around a passage.
    static let contextWords = 4

    /// Compares `local` (timed; echo marked) with `cloud` (untimed) over the window [start, end) of `track`.
    /// `localOffset` is the position of `local[0]` among the track's compared local words.
    ///
    /// - Echo: an operation on a local echo word is left out, and so is a run of cloud-only words between two echo
    ///   words, or of at most `echoNeighbourWords` next to one: the cloud transcript hears the echo too, and its
    ///   alignment with the echo words around it is arbitrary. A longer run beside echo is kept.
    /// - Passages: maximal runs of consecutive edits (substitutions and one-side-only words); a run of matched
    ///   words that differ only in case or punctuation is a `caseOrPunctuation` passage of its own.
    /// - Time: a passage takes the times of its local words (and of its cloud words when they are timed); a
    ///   cloud-only passage lies between the local words around it (or reaches the window edge).
    public static func compare(track: String, local: [EvalToken], cloud: [EvalToken], start: Double, end: Double,
                               localOffset: Int = 0) -> WindowComparison {
        evaluate(track: track, ops: EvalAlignment.align(local.map(\.text), cloud.map(\.text)), local: local,
                 cloud: cloud, start: start, end: end, localOffset: localOffset)
    }

    /// Cloud-only words beside a single echo word that still count as echo.
    static let echoNeighbourWords = 3

    /// Scores and passages of an alignment `ops` of `local` with `cloud` (see `compare`).
    static func evaluate(track: String, ops: [AlignmentOp], local: [EvalToken], cloud: [EvalToken], start: Double,
                         end: Double, localOffset: Int = 0) -> WindowComparison {
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
            let before = previousLocalIndex[position].map { local[$0].echo } == true
            let after = nextLocalIndex[position].map { local[$0].echo } == true
            return (before && after) || ((before || after) && cloudRun[position] <= echoNeighbourWords)
        }

        var run: [Int] = []  // op positions of the current edit run
        var punctuationRun: [Int] = []
        func flush(_ positions: inout [Int], caseOnly: Bool) {
            guard !positions.isEmpty else { return }
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
            case .match(_, _, let exact):
                result.score.localWords += 1; result.score.cloudWords += 1; result.score.matches += 1
                flush(&run, caseOnly: false)
                if exact {
                    flush(&punctuationRun, caseOnly: true)
                } else {
                    result.score.caseOrPunctuationOnly += 1
                    punctuationRun.append(position)
                }
            case .substitute:
                result.score.localWords += 1; result.score.cloudWords += 1; result.score.substitutions += 1
                flush(&punctuationRun, caseOnly: true)
                run.append(position)
            case .localOnly:
                result.score.localWords += 1; result.score.localOnly += 1
                flush(&punctuationRun, caseOnly: true)
                run.append(position)
            case .cloudOnly:
                result.score.cloudWords += 1; result.score.cloudOnly += 1
                flush(&punctuationRun, caseOnly: true)
                run.append(position)
            }
        }
        flush(&run, caseOnly: false)
        flush(&punctuationRun, caseOnly: true)
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
        let localContext = local.map { $0.echo ? nil : $0.text }
        let cloudContext = cloud.map { Optional($0.text) }
        return EvalPassage(id: "", track: track, start: start, end: end, local: localWords.joined(separator: " "),
                           cloud: cloudWords.joined(separator: " "), group: group,
                           before: context(localContext, before: localPoint),
                           after: context(localContext, after: localEndPoint),
                           cloudBefore: context(cloudContext, before: cloudPoint),
                           cloudAfter: context(cloudContext, after: cloudEndPoint),
                           localFirst: localOffset + localPoint, localEnd: localOffset + localEndPoint)
    }

    /// Up to `contextWords` words of `words` (nil: left out) before position `point`.
    private static func context(_ words: [String?], before point: Int) -> String {
        words[..<min(point, words.count)].compactMap { $0 }.suffix(contextWords).joined(separator: " ")
    }

    /// Up to `contextWords` words of `words` from position `point` on.
    private static func context(_ words: [String?], after point: Int) -> String {
        words[min(point, words.count)...].compactMap { $0 }.prefix(contextWords).joined(separator: " ")
    }
}
