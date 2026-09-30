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

    static func joinedKey(_ text: String) -> String { EvalText.tokens(text).map(EvalText.key).joined() }

    /// Where `term` (its keys joined) is written in `keys`, as whole words: runs of words whose keys joined are the
    /// term's, so "TestFlight" is found in "Test Flight" and "test flight" in "TestFlight". Runs do not overlap.
    static func occurrences(of term: String, in keys: [String]) -> [Range<Int>] {
        occurrences(of: [term], words: keys, keys: keys, numbers: nil)
    }

    /// Longest run of cloud words a spelled number may take when read against a shorter written form.
    static let maxOccurrenceWords = 8

    /// Where any of `forms` is written in the words, as whole words: their keys joined, or (with `numbers`, the
    /// words' spelled-number runs, for a run holding one) the run's `NormalizedAlignment.compoundForms` ("GPT four"
    /// for "GPT-4"). With `numbers`, an occurrence never starts or ends inside a spelled number: "V one hundred" of
    /// "V one hundred five" is not "V100".
    static func occurrences(of forms: Set<String>, words: [String], keys: [String],
                            numbers: EvalNormalization.SpelledRuns?) -> [Range<Int>] {
        let forms = forms.filter { !$0.isEmpty }
        guard !forms.isEmpty else { return [] }
        let longestForm = forms.map(\.count).max() ?? 0
        var found: [Range<Int>] = []
        var start = 0
        while start < keys.count {
            var joined = ""
            var hasSpelled = false
            var end = start
            var match: Int?
            // As long as the longest form (a term may have many words), or up to `maxOccurrenceWords` words for a
            // spelled number read against a shorter written form ("GPT four" for "GPT-4").
            while end < keys.count, joined.count < longestForm || (hasSpelled && end - start < maxOccurrenceWords) {
                joined += keys[end]
                hasSpelled = hasSpelled || numbers?.run(at: end) != nil
                end += 1
                if numbers?.cuts(start..<end) == true { continue }
                if forms.contains(joined) { match = end; break }
                if hasSpelled, !Set(NormalizedAlignment.compoundForms(Array(words[start..<end]))).isDisjoint(with: forms) {
                    match = end
                    break
                }
                if !hasSpelled, !forms.contains(where: { $0.hasPrefix(joined) }) { break }
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

        public init(track: String, words: [String], covered: [Bool?], spans: [Range<Int>?] = [],
                    ignorable: [Bool] = []) {
            self.track = track; self.words = words; self.covered = covered; self.spans = spans
            self.ignorable = ignorable
        }
    }

    /// Whether the local words standing for cloud words `range` are one unbroken run: each next word's local words
    /// follow the one before's (or are the same joined run), with only ignorable words between.
    static func contiguous(_ range: Range<Int>, in track: Track) -> Bool {
        guard !track.spans.isEmpty else { return true }
        var previous: Range<Int>?
        for index in range {
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
    /// the occurrence's words covered, as one unbroken run of local words (`contiguous`). An occurrence that touches
    /// echo is not counted. Terms the cloud never has are left out. Sorted by misses, then by count, then by term.
    /// With `normalized`, a term is also found written with its numbers spelled the other way ("GPT four" for the
    /// term "GPT-4", "GPT-4" for "GPT four").
    public static func count(_ terms: [Term], tracks: [Track], normalized: Bool = false) -> [TermStat] {
        let keyed = tracks.map { track in
            (keys: track.words.map(EvalText.key),
             numbers: normalized ? EvalNormalization.SpelledRuns(track.words, fillers: []) : nil, track: track)
        }
        var stats: [TermStat] = []
        for term in terms {
            var stat = TermStat(term: term.text, source: term.source, cloud: 0, hits: 0)
            var forms: Set<String> = [joinedKey(term.text)]
            if normalized { forms.formUnion(NormalizedAlignment.compoundForms(EvalText.tokens(term.text))) }
            for (keys, numbers, track) in keyed {
                var count = TermStat.TrackCount(track: track.track, cloud: 0, hits: 0)
                for range in occurrences(of: forms, words: track.words, keys: keys, numbers: numbers) {
                    let flags = range.map { $0 < track.covered.count ? track.covered[$0] : nil }
                    guard !flags.contains(where: { $0 == nil }) else { continue }
                    count.cloud += 1
                    if flags.allSatisfy({ $0 == true }), contiguous(range, in: track) { count.hits += 1 }
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
