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

    public var term: String
    public var source: Source
    /// Times the cloud transcript has the term (echo left out).
    public var cloud: Int
    /// Of those, times the local transcript has the same words at the aligned position.
    public var hits: Int
    public var misses: Int { cloud - hits }

    public init(term: String, source: Source, cloud: Int, hits: Int) {
        self.term = term; self.source = source; self.cloud = cloud; self.hits = hits
    }

    enum CodingKeys: String, CodingKey { case term, source, cloud, hits, misses }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decode(String.self, forKey: .term)
        source = try c.decode(Source.self, forKey: .source)
        cloud = try c.decode(Int.self, forKey: .cloud)
        hits = try c.decode(Int.self, forKey: .hits)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(term, forKey: .term); try c.encode(source, forKey: .source)
        try c.encode(cloud, forKey: .cloud); try c.encode(hits, forKey: .hits); try c.encode(misses, forKey: .misses)
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
        guard !term.isEmpty else { return [] }
        var found: [Range<Int>] = []
        var start = 0
        while start < keys.count {
            var joined = ""
            var end = start
            var match: Int?
            while end < keys.count, joined.count < term.count {
                joined += keys[end]
                end += 1
                if joined == term { match = end; break }
                if !term.hasPrefix(joined) { break }
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

    /// Each term's count in the cloud words of every track (`words`, with `covered` per word: nil for echo, else
    /// whether the local transcript has the same words there), and how many of those the local transcript has. An
    /// occurrence that touches echo is not counted. Terms the cloud never has are left out. Sorted by misses, then
    /// by count, then by term.
    public static func count(_ terms: [Term], tracks: [(words: [String], covered: [Bool?])]) -> [TermStat] {
        let keyed = tracks.map { track in (keys: track.words.map(EvalText.key), covered: track.covered) }
        var stats: [TermStat] = []
        for term in terms {
            var stat = TermStat(term: term.text, source: term.source, cloud: 0, hits: 0)
            for track in keyed {
                for range in occurrences(of: joinedKey(term.text), in: track.keys) {
                    let flags = range.map { $0 < track.covered.count ? track.covered[$0] : nil }
                    guard !flags.contains(where: { $0 == nil }) else { continue }
                    stat.cloud += 1
                    if flags.allSatisfy({ $0 == true }) { stat.hits += 1 }
                }
            }
            if stat.cloud > 0 { stats.append(stat) }
        }
        return stats.sorted {
            ($1.misses, $1.cloud, $0.term.lowercased()) < ($0.misses, $0.cloud, $1.term.lowercased())
        }
    }
}
