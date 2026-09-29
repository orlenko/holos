import Foundation

/// Who put a term in the word list: `user` (the Corrections section, `voiceislocal words`) or `review` (a meeting's
/// Review). A value written by a newer Voice is Local decodes as itself and compares unequal to both.
public struct WordListSource: OpenStringCode {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let user = WordListSource("user")
    public static let review = WordListSource("review")
}

public struct WordListEntry: Codable, Sendable, Equatable {
    /// The term as the user wrote it (case kept), whitespace collapsed to single spaces.
    public var text: String
    public var addedAt: Date
    public var source: WordListSource

    public init(text: String, addedAt: Date, source: WordListSource) {
        self.text = text; self.addedAt = addedAt; self.source = source
    }
}

/// The user's word list (`words.json`, docs/design.md "Word list"): terms the recognizer should expect (names,
/// products, jargon) that no correction teaches, because a correction needs a misheard side. Terms keep the case they
/// were written in and may be several words ("Urban Sky"); two terms that differ only in case or spacing are one term,
/// spelled as it was first added. The recognizer gets the terms as contextual strings, first
/// (`RecognizerVocabulary`), and Apple Intelligence's fix counts their words as real words (`Lexicon`).
public struct WordList: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    /// Longest term, in characters: the longest string a meeting's vocabulary keeps (§4.12).
    public static let maximumLength = 100
    /// Most terms kept. The recognizer gets at most `RecognizerVocabulary.maximumStrings` of them.
    public static let maximumTerms = 1_000

    public private(set) var schemaVersion: Int = WordList.currentSchemaVersion
    public private(set) var entries: [WordListEntry] = []

    public init(entries: [WordListEntry] = []) {
        for entry in entries { insert(entry) }
    }

    /// The terms, oldest first.
    public var terms: [String] { entries.map(\.text) }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public enum AddOutcome: Sendable, Equatable {
        case added(String)
        /// The list has the term already, spelled `existing`.
        case duplicate(existing: String)
        /// Blank after trimming.
        case empty
        /// Longer than `maximumLength` characters.
        case tooLong
        /// The list holds `maximumTerms` terms.
        case full
    }

    /// Adds `text` (trimmed, whitespace collapsed) unless the list has it already in any case.
    @discardableResult
    public mutating func add(_ text: String, source: WordListSource = .user, at date: Date = Date()) -> AddOutcome {
        guard let term = Self.cleaned(text) else { return .empty }
        guard term.count <= Self.maximumLength else { return .tooLong }
        if let existing = entry(matching: term) { return .duplicate(existing: existing.text) }
        guard entries.count < Self.maximumTerms else { return .full }
        entries.append(WordListEntry(text: term, addedAt: date, source: source))
        return .added(term)
    }

    /// Removes the term matching `text` in any case or spacing; returns it as it was spelled, or nil when the list
    /// does not have it.
    @discardableResult
    public mutating func remove(_ text: String) -> String? {
        guard let term = Self.cleaned(text), let index = entries.firstIndex(where: { Self.key($0.text) == Self.key(term) })
        else { return nil }
        return entries.remove(at: index).text
    }

    public func contains(_ text: String) -> Bool {
        Self.cleaned(text).map { entry(matching: $0) != nil } ?? false
    }

    /// `text` trimmed, with each run of whitespace (line breaks too) made one space; nil when nothing is left.
    public static func cleaned(_ text: String) -> String? {
        let term = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return term.isEmpty ? nil : term
    }

    /// The terms of a file or a paste: one per line, trimmed, blank lines skipped.
    public static func lines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { cleaned(String($0)) }
    }

    /// What two spellings of one term share: the term lowercased, whitespace collapsed.
    static func key(_ term: String) -> String {
        (cleaned(term) ?? "").lowercased()
    }

    private func entry(matching term: String) -> WordListEntry? {
        let key = Self.key(term)
        return entries.first { Self.key($0.text) == key }
    }

    /// Keeps a decoded entry the way `add` would: cleaned, not too long, not a duplicate, within the limit.
    private mutating func insert(_ entry: WordListEntry) {
        guard let term = Self.cleaned(entry.text), term.count <= Self.maximumLength, self.entry(matching: term) == nil,
              entries.count < Self.maximumTerms else { return }
        entries.append(WordListEntry(text: term, addedAt: entry.addedAt, source: entry.source))
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey { case schemaVersion, entries }

    /// Refuses a list written by a newer Voice is Local (a higher `schemaVersion`), so it is never overwritten with
    /// less than it holds. Entries are cleaned and deduplicated as `add` does.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version <= Self.currentSchemaVersion else {
            throw HolosError.unavailable("words.json was written by a newer Voice is Local (schema \(version)).")
        }
        self.init(entries: try container.decode([WordListEntry].self, forKey: .entries))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(entries, forKey: .entries)
    }
}

/// The recognizer's contextual strings: the word list first, then the other sources, each string once whatever its
/// case or spacing, at most `maximumStrings`.
public enum RecognizerVocabulary {
    /// Most contextual strings the recognizer is given. `AnalysisContext.contextualStrings` (SpeechAnalyzer,
    /// macOS 26) documents no limit; `SFSpeechRecognitionRequest.contextualStrings`, the same feature in the older
    /// API, says to "limit the total number of phrases to no more than 100". Past that the word list, which comes
    /// first, crowds out the rest.
    public static let maximumStrings = 100
    /// Longest string, in characters, as a meeting's vocabulary keeps (§4.12).
    public static let maximumLength = 100

    /// `groups` in order, each string trimmed with whitespace collapsed, blank and over-long ones dropped, the first
    /// spelling of each (ignoring case) kept, at most `limit`.
    public static func merged(_ groups: [[String]], limit: Int = maximumStrings) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for string in groups.joined() {
            guard result.count < limit else { break }
            guard let term = WordList.cleaned(string), term.count <= maximumLength,
                  seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
        }
        return result
    }

    /// Dictation in `language`: the word list, then the words of learned corrections
    /// (`CorrectionList.vocabulary(language:)`).
    public static func dictation(wordList: [String], corrections: CorrectionList, language: String?) -> [String] {
        merged([wordList, corrections.vocabulary(language: language)])
    }

    /// A meeting in `languages`: the word list, then people's names, then the words of learned corrections
    /// (`CorrectionList.vocabulary(languages:)`). Names come before the correction words, so a long correction list
    /// never pushes the people of the meeting out of the limit.
    public static func meeting(wordList: [String], names: [String], corrections: CorrectionList,
                               languages: [String]) -> [String] {
        merged([wordList, names, corrections.vocabulary(languages: languages)])
    }
}
