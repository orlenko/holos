import Foundation

/// One entry of the pronunciation list: a word or phrase as documents write it, and a spelling that sounds right.
public struct Pronunciation: Codable, Sendable, Equatable {
    /// As documents write it ("XIMEA"), whitespace collapsed to single spaces.
    public var written: String
    /// What the voices say in its place ("zai mee ah"), whitespace collapsed.
    public var sayAs: String
    public var addedAt: Date

    public init(written: String, sayAs: String, addedAt: Date) {
        self.written = written; self.sayAs = sayAs; self.addedAt = addedAt
    }

    /// Smart case: written in lower case it matches in any case ("gz-link", "GZ-Link"); with a capital, only as
    /// written ("XIMEA", and "US" never matches "us").
    public var matchesAnyCase: Bool { written == written.lowercased() }
}

/// The user's pronunciation list (`pronunciations.json`, docs/design.md "Pronunciations"): words and phrases every
/// reading voice says by a spelling the user gave, natural and Apple voices alike, because no rule can know how a
/// name is said. Entries are kept in the order added; two whose written forms differ only in spacing are one entry
/// (case counts: "US" and "us" are two).
public struct PronunciationList: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    /// Longest written form or spelling, in characters.
    public static let maximumLength = 100
    public static let maximumEntries = 1_000

    public private(set) var schemaVersion: Int = PronunciationList.currentSchemaVersion
    public private(set) var entries: [Pronunciation] = []

    public init(entries: [Pronunciation] = []) {
        for entry in entries { set(entry.written, sayAs: entry.sayAs, at: entry.addedAt) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public enum SetOutcome: Sendable, Equatable {
        case added(Pronunciation)
        /// The entry had another spelling, `previous`.
        case changed(Pronunciation, previous: String)
        /// The entry had this spelling already.
        case unchanged(Pronunciation)
        /// The written form or the spelling is blank.
        case empty
        /// One of them is longer than `maximumLength` characters.
        case tooLong
        /// The list holds `maximumEntries` entries.
        case full
    }

    /// Says `written` as `sayAs` from now on: adds the entry, or changes the spelling of the one written so (its place
    /// and date kept).
    @discardableResult
    public mutating func set(_ written: String, sayAs: String, at date: Date = Date()) -> SetOutcome {
        guard let written = WordList.cleaned(written), let sayAs = WordList.cleaned(sayAs) else { return .empty }
        guard written.count <= Self.maximumLength, sayAs.count <= Self.maximumLength else { return .tooLong }
        if let index = entries.firstIndex(where: { $0.written == written }) {
            let previous = entries[index].sayAs
            guard previous != sayAs else { return .unchanged(entries[index]) }
            entries[index].sayAs = sayAs
            return .changed(entries[index], previous: previous)
        }
        guard entries.count < Self.maximumEntries else { return .full }
        let entry = Pronunciation(written: written, sayAs: sayAs, addedAt: date)
        entries.append(entry)
        return .added(entry)
    }

    /// Removes the entry written exactly so (spacing aside); returns it, or nil when the list does not have it.
    @discardableResult
    public mutating func remove(_ written: String) -> Pronunciation? {
        guard let written = WordList.cleaned(written),
              let index = entries.firstIndex(where: { $0.written == written }) else { return nil }
        return entries.remove(at: index)
    }

    public func entry(written: String) -> Pronunciation? {
        guard let written = WordList.cleaned(written) else { return nil }
        return entries.first { $0.written == written }
    }

    // MARK: - Respelling

    /// Text with its listed words replaced by their spellings, and the spellings used (for the check, which cannot
    /// hold a made-up spelling against what it hears).
    public struct Respelling: Sendable, Equatable {
        public var text: String
        public var spellings: [String]
    }

    /// Replaces each whole-word occurrence of an entry (not inside a longer word: "XIMEAs" is left) by its spelling, in
    /// one pass over `text`, so a spelling is never respelled. Where two entries overlap, the one starting first wins,
    /// then the longer, then the one written exactly as the text has it.
    public func respelled(_ text: String) -> Respelling {
        guard !entries.isEmpty, !text.isEmpty else { return Respelling(text: text, spellings: []) }
        let source = text as NSString
        var found: [(range: NSRange, entry: Pronunciation, exact: Bool)] = []
        for entry in entries {
            guard let expression = Self.expression(for: entry) else { continue }
            for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                found.append((match.range, entry, source.substring(with: match.range) == entry.written))
            }
        }
        found.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.exact && !$1.exact
        }
        var result = "", spellings: [String] = [], end = 0
        for item in found where item.range.location >= end {
            result += source.substring(with: NSRange(location: end, length: item.range.location - end))
            result += item.entry.sayAs
            if !spellings.contains(item.entry.sayAs) { spellings.append(item.entry.sayAs) }
            end = NSMaxRange(item.range)
        }
        result += source.substring(from: end)
        return Respelling(text: result, spellings: spellings)
    }

    /// The entry's written form between word boundaries (no letter or digit on either side), spaces matching any run
    /// of whitespace.
    private static func expression(for entry: Pronunciation) -> NSRegularExpression? {
        let words = entry.written.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
        return try? NSRegularExpression(pattern: pattern, options: entry.matchesAnyCase ? [.caseInsensitive] : [])
    }
}

/// Where a renderer gets the pronunciation list when a render starts (the store in the app and the tool; an empty
/// list by default, and for a system voice reading a natural voice's paragraph, whose text is respelled already).
public typealias PronunciationSource = @Sendable () throws -> PronunciationList
