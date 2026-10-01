import Foundation

/// How often the local transcript has a vocabulary term where the cloud transcript has it (docs/reference-evaluation.md,
/// "Terms"): the number to follow from one iteration of the vocabulary to the next.
public struct TermStat: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// The word list (words.json).
        case wordList = "word-list"
        /// A correction's meant phrase (corrections.json).
        case correction
    }

    /// One track's share: the microphone's count depends on the echo left out, which a local candidate can change,
    /// so each track is given too.
    public struct TrackCount: Codable, Sendable, Equatable {
        public var track: String
        public var cloud: Int
        public var hits: Int

        public init(track: String, cloud: Int, hits: Int) { self.track = track; self.cloud = cloud; self.hits = hits }
    }

    public var term: String
    public var source: Source
    /// Times the cloud transcript has the term (echo left out).
    public var cloud: Int
    /// Of those, times the local transcript has the same words at the aligned position.
    public var hits: Int
    public var misses: Int { cloud - hits }
    /// Per track (tracks where the cloud never has it left out).
    public var tracks: [TrackCount]

    public init(term: String, source: Source, cloud: Int, hits: Int, tracks: [TrackCount] = []) {
        self.term = term; self.source = source; self.cloud = cloud; self.hits = hits; self.tracks = tracks
    }

    enum CodingKeys: String, CodingKey { case term, source, cloud, hits, misses, tracks }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decode(String.self, forKey: .term)
        source = try c.decode(Source.self, forKey: .source)
        cloud = try c.decode(Int.self, forKey: .cloud)
        hits = try c.decode(Int.self, forKey: .hits)
        tracks = try c.decodeIfPresent([TrackCount].self, forKey: .tracks) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(term, forKey: .term); try c.encode(source, forKey: .source)
        try c.encode(cloud, forKey: .cloud); try c.encode(hits, forKey: .hits); try c.encode(misses, forKey: .misses)
        try c.encode(tracks, forKey: .tracks)
    }
}

public enum EvalTerms {
    public struct Term: Sendable, Equatable {
        public var text: String
        public var source: TermStat.Source

        public init(_ text: String, source: TermStat.Source) { self.text = text; self.source = source }
    }

    /// The word list's terms, then the corrections' meant phrases, each once (by its letters and digits, ignoring
    /// case, spacing, and punctuation).
    public static func terms(wordList: [String], corrections: [String]) -> [Term] {
        var seen = Set<String>()
        var out: [Term] = []
        for (text, source) in wordList.map({ ($0, TermStat.Source.wordList) })
            + corrections.map({ ($0, TermStat.Source.correction) }) {
            let key = joinedKey(text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(Term(text.trimmingCharacters(in: .whitespacesAndNewlines), source: source))
        }
        return out
    }

    static func joinedKey(_ text: String) -> String {
        EvalText.tokens(text).map(EvalText.key).reduce("", NormalizedAlignment.joining)
    }

    /// Where `term` (its keys joined) is written in `keys`, as whole words: runs of words whose keys joined are the
    /// term's, so "TestFlight" is found in "Test Flight" and "test flight" in "TestFlight". Runs do not overlap.
    static func occurrences(of term: String, in keys: [String]) -> [Range<Int>] {
        occurrences(of: Pattern(forms: [term]), words: keys, keys: keys, numbers: nil)
    }

    /// Words read as the normalized comparison reads numbers: each number one unit (a whole spelled-number run,
    /// `EvalNormalization.SpelledRuns`, or a number written with digits, "30%", "plus 30", "30 percent"), each other
    /// word its key. `text` joins them, a number as its canonical form between marks no key holds.
    struct NumberReading: Sendable, Equatable {
        var text: String
        var numbers: [EvalNormalization.NumberForm]
        /// Per number, its words' keys joined when it is spelled ("one"), nil when written with digits.
        var spelled: [String?]

        /// The reading of `words`, whose spelled-number runs are `runs` (ranges into `words`); nil without a number.
        init?(_ words: [String], runs: [Range<Int>]) {
            var text = ""
            var numbers: [EvalNormalization.NumberForm] = []
            var spelled: [String?] = []
            let starts = Dictionary(runs.map { ($0.lowerBound, $0) }, uniquingKeysWith: { first, _ in first })
            var index = 0
            reading: while index < words.count {
                // The longest number with digits from here, first: "30 per cent" is 30%, its "cent" no French 100.
                // It takes a spelled run's words only as the whole run, and never goes past a clause mark.
                let longest = min(NormalizedAlignment.maxDigitNumberWords, words.count - index)
                for length in stride(from: longest, through: 1, by: -1) {
                    let range = index..<(index + length)
                    guard !runs.contains(where: { $0.overlaps(range) && $0.clamped(to: range) != $0 }),
                          !EvalNormalization.crossesClause(words, range),
                          let form = EvalNormalization.number(Array(words[range])), form.hasDigit else { continue }
                    text += "\u{1}" + form.canonical + "\u{1}"; numbers.append(form); spelled.append(nil)
                    index += length
                    continue reading
                }
                if let run = starts[index], let form = EvalNormalization.number(Array(words[run])), !form.hasDigit {
                    text += "\u{1}" + form.canonical + "\u{1}"; numbers.append(form)
                    spelled.append(words[run].map(EvalText.key).joined())
                    index = run.upperBound
                    continue
                }
                text += EvalText.key(words[index])
                index += 1
            }
            guard !numbers.isEmpty else { return nil }
            self.text = text
            self.numbers = numbers
            self.spelled = spelled
        }

        /// The same words, each number the same number with at least one of the two written with digits (as
        /// `NormalizedAlignment.sameNumber`: "twenty one"/"21", never "twenty one"/"vingt et un"), or the same
        /// spelled words ("one"/"one").
        func matches(_ other: NumberReading) -> Bool {
            text == other.text && numbers.count == other.numbers.count
                && numbers.indices.allSatisfy { index in
                    NormalizedAlignment.sameNumber(numbers[index], other.numbers[index])
                        || (spelled[index] != nil && spelled[index] == other.spelled[index])
                }
        }
    }

    /// What a term is found as: its forms as joined keys, and (normalized) its `NormalizedAlignment.compoundReadings`
    /// and how it reads with its numbers.
    struct Pattern {
        var forms: Set<String>
        var compounds: [NormalizedAlignment.CompoundForm] = []
        var reading: NumberReading? = nil
    }

    /// Whether `range` starts or ends inside a number written with digits and words around it ("30" of "30 percent",
    /// of "plus 30"; "version 30" of "version 30 percent"; "cent" of "30 per cent"): the normalized comparison reads
    /// those phrases as other numbers ("30%", "+30"). Each edge is checked on its own, whatever words the range has
    /// past it. Only a phrase whose part inside the range holds a number counts: "Disney plus" of "Disney plus 30"
    /// ends at a word, not inside a number.
    static func cutsDigitNumber(_ words: [String], _ range: Range<Int>) -> Bool {
        let reach = NormalizedAlignment.maxDigitNumberWords
        for edge in [range.lowerBound, range.upperBound] where edge > 0 && edge < words.count {
            for lower in max(0, edge - reach + 1)..<edge {
                for upper in (edge + 1)...min(words.count, lower + reach) {
                    let phrase = lower..<upper
                    guard !EvalNormalization.crossesClause(words, phrase),
                          let form = EvalNormalization.number(Array(words[phrase])), form.hasDigit,
                          phrase.clamped(to: range).contains(where: { EvalNormalization.number([words[$0]]) != nil })
                    else { continue }
                    return true
                }
            }
        }
        return false
    }

    /// Longest run of cloud words a number may take when read against a shorter written form, past which only a
    /// spelled-number run already begun is read to its end.
    static let maxOccurrenceWords = 8

    /// Where `pattern` is written in the words, as whole words: its forms as their keys joined, or (with `numbers`,
    /// the words' spelled-number runs, for a run holding a number) as the run's `NormalizedAlignment.compoundForms`
    /// ("GPT four" for "GPT-4") or with the same numbers (`NumberReading`: "21" for "twenty one", "30%" for "thirty
    /// percent"). With `numbers`, an occurrence never starts or ends inside a spelled number: "V one hundred" of "V
    /// one hundred five" is not "V100".
    static func occurrences(of pattern: Pattern, words: [String], keys: [String],
                            numbers: EvalNormalization.SpelledRuns?) -> [Range<Int>] {
        let forms = pattern.forms.filter { !$0.isEmpty }
        guard !forms.isEmpty || pattern.reading != nil else { return [] }
        let longestForm = forms.map(\.count).max() ?? 0
        // Counted in units, a whole spelled-number run being one however long ("plus nine hundred … percent"):
        // room for each number of the term and `maxOccurrenceWords` more.
        // The whole reading: each of its numbers and each other word is one unit ("1 a b c … j" is eleven).
        let readingUnits = pattern.reading.map { reading in
            reading.numbers.count + reading.text.split(separator: "\u{1}", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 0 }.reduce(0) { $0 + $1.element.count }
        } ?? 0
        let unitCap = maxOccurrenceWords + readingUnits
        var found: [Range<Int>] = []
        var start = 0
        while start < keys.count {
            var joined = ""
            var hasSpelled = false
            var hasNumber = false
            var end = start
            var units = 0
            var match: Int?
            // As long as the longest form (a term may have many words), or up to `maxOccurrenceWords` words for a
            // number read against another written form ("GPT four" for "GPT-4"); a spelled-number run the window is
            // in is always read to its end ("V one thousand two hundred thirty four" for "V1234").
            while end < keys.count, joined.count < longestForm
                || (hasNumber && (units < unitCap
                                  || (end > start && numbers?.run(at: end)?.contains(end - 1) == true))) {
                joined = NormalizedAlignment.joining(joined, keys[end])
                // A new unit, unless this word goes on the spelled-number run of the one before.
                if end == start || numbers?.run(at: end)?.contains(end - 1) != true { units += 1 }
                if let numbers {
                    let spelled = numbers.run(at: end) != nil
                    hasSpelled = hasSpelled || spelled
                    hasNumber = hasNumber || spelled || words[end].contains(where: \.isNumber)
                }
                end += 1
                if numbers?.cuts(start..<end) == true { continue }
                if numbers != nil, cutsDigitNumber(words, start..<end) { continue }
                if forms.contains(joined) { match = end; break }
                // Only a form with a spelled number in digits: the words as written are `joined`.
                if hasSpelled, NormalizedAlignment.compoundReadings(Array(words[start..<end])).contains(where: { form in
                    !form.spelled.isEmpty && forms.contains(form.text) && pattern.compounds.contains { $0.matches(form) }
                }) {
                    match = end
                    break
                }
                if hasNumber, let reading = pattern.reading, let numbers {
                    // The window cuts no run's number: each run inside it whole, or its number when its "plus" or
                    // "percent" lies outside.
                    var runs: [Range<Int>] = []
                    for index in start..<end {
                        for run in [numbers.run(at: index), numbers.core(at: index)].compactMap({ $0 })
                        where run.lowerBound == index && run.upperBound <= end {
                            runs.append((run.lowerBound - start)..<(run.upperBound - start))
                            break
                        }
                    }
                    if let window = NumberReading(Array(words[start..<end]), runs: runs), window.matches(reading) {
                        match = end
                        break
                    }
                }
                if !hasNumber, !forms.contains(where: { $0.hasPrefix(joined) }) { break }
            }
            if let match {
                found.append(start..<match)
                start = match
            } else {
                start += 1
            }
        }
        return found
    }

    /// One track's cloud words and where the local transcript has them.
    public struct Track: Sendable {
        public var track: String
        public var words: [String]
        /// Per cloud word: nil for echo, else whether the local transcript has the same word there.
        public var covered: [Bool?]
        /// Per cloud word the local transcript has: the local words it stands for (one, or a joined run). Empty: not
        /// known, and a phrase is a hit when each of its words is.
        public var spans: [Range<Int>?]
        /// Per local word: whether it may stand between a phrase's words (a filler, or echo left out).
        public var ignorable: [Bool]
        /// Per cloud word: whether it is left out when finding terms, as echo is (a filler under the normalized
        /// comparison: "New um York" is "New York"). Empty: none.
        public var skipped: [Bool]

        public init(track: String, words: [String], covered: [Bool?], spans: [Range<Int>?] = [],
                    ignorable: [Bool] = [], skipped: [Bool] = []) {
            self.track = track; self.words = words; self.covered = covered; self.spans = spans
            self.ignorable = ignorable; self.skipped = skipped
        }

        /// The cloud words terms are found among, in order: all but echo and `skipped` words.
        var kept: [Int] {
            words.indices.filter { index in
                index < covered.count && covered[index] != nil && !(index < skipped.count && skipped[index])
            }
        }
    }

    /// Whether the local words standing for cloud words `indices` (in order) are one unbroken run: each next word's
    /// local words follow the one before's (or are the same joined run), with only ignorable words between.
    static func contiguous(_ indices: [Int], in track: Track) -> Bool {
        guard !track.spans.isEmpty else { return true }
        var previous: Range<Int>?
        for index in indices {
            guard index < track.spans.count, let span = track.spans[index] else { return false }
            if let before = previous, span != before {
                guard span.lowerBound >= before.upperBound,
                      (before.upperBound..<span.lowerBound).allSatisfy({ $0 < track.ignorable.count && track.ignorable[$0] })
                else { return false }
            }
            previous = span
        }
        return true
    }

    /// Each term's count in the cloud words of every track, and how many of those the local transcript has: each of
    /// the occurrence's words covered, as one unbroken run of local words (`contiguous`). Echo is left out: a term is
    /// found among the other cloud words, so an echo word between two of its words does not hide it (nor, under the
    /// normalized comparison, a filler). Terms the cloud never has are left out. Sorted by misses, then by count,
    /// then by term. With `normalized`, a term is also found written with its numbers spelled the other way ("GPT
    /// four" for the term "GPT-4", "GPT-4" for "GPT four").
    public static func count(_ terms: [Term], tracks: [Track], normalized: Bool = false) -> [TermStat] {
        let keyed = tracks.map { track in
            let kept = track.kept
            let words = kept.map { track.words[$0] }
            return (kept: kept, words: words, keys: words.map(EvalText.key),
                    numbers: normalized ? EvalNormalization.SpelledRuns(words, fillers: []) : nil, track: track)
        }
        var stats: [TermStat] = []
        for term in terms {
            var stat = TermStat(term: term.text, source: term.source, cloud: 0, hits: 0)
            var pattern = Pattern(forms: [joinedKey(term.text)])
            if normalized {
                let tokens = EvalText.tokens(term.text)
                pattern.compounds = [.init(text: pattern.forms.first ?? "")]
                    + NormalizedAlignment.compoundReadings(tokens).filter { !$0.spelled.isEmpty }
                pattern.forms.formUnion(pattern.compounds.map(\.text))
                pattern.reading = NumberReading(tokens, runs: EvalNormalization.SpelledRuns(tokens, fillers: []).runs)
            }
            for (kept, words, keys, numbers, track) in keyed {
                var count = TermStat.TrackCount(track: track.track, cloud: 0, hits: 0)
                for range in occurrences(of: pattern, words: words, keys: keys, numbers: numbers) {
                    let indices = range.map { kept[$0] }
                    count.cloud += 1
                    if indices.allSatisfy({ track.covered[$0] == true }), contiguous(indices, in: track) {
                        count.hits += 1
                    }
                }
                guard count.cloud > 0 else { continue }
                stat.cloud += count.cloud
                stat.hits += count.hits
                stat.tracks.append(count)
            }
            if stat.cloud > 0 { stats.append(stat) }
        }
        return stats.sorted {
            ($1.misses, $1.cloud, $0.term.lowercased()) < ($0.misses, $0.cloud, $1.term.lowercased())
        }
    }
}
