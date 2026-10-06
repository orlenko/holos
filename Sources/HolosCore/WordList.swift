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
    /// "Often heard as": real words the recognizer writes for this term ("cloud", "clot" for "Claude"). They are never
    /// replaced on their own: Apple Intelligence decides from the context whether the term was meant there (docs/
    /// design.md "Word list"). Nil (left out of words.json) when there are none, so older lists read and write as
    /// before.
    public var heardAs: [String]?

    public init(text: String, addedAt: Date, source: WordListSource, heardAs: [String]? = nil) {
        self.text = text; self.addedAt = addedAt; self.source = source
        self.heardAs = heardAs?.isEmpty == true ? nil : heardAs
    }
}

/// The user's word list (`words.json`, docs/design.md "Word list"): terms the recognizer should expect (names,
/// products, jargon) that no correction teaches, because a correction needs a misheard side. Terms keep the case they
/// were written in and may be several words ("Urban Sky"); two terms that differ only in case or spacing are one term,
/// spelled as it was first added. The recognizer gets the terms as contextual strings, first
/// (`RecognizerVocabulary`), and Apple Intelligence's fix counts their words as real words (`Lexicon`). A term may list
/// real words it is often heard as ("cloud" for "Claude", `heardAsPairs`), which Apple Intelligence may replace by the
/// term where the context says it was meant, in dictation and in meetings.
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

    // MARK: - Often heard as

    /// Most "often heard as" phrases kept for one term.
    public static let maximumHeardAs = 20

    /// What a change of a term's "often heard as" phrases did.
    public struct HeardAsChange: Sendable, Equatable {
        /// The term, as the list spells it.
        public var term: String
        /// Phrases added, as kept (whitespace collapsed).
        public var added: [String] = []
        /// Phrases removed, as they were spelled.
        public var removed: [String] = []
        /// Phrases the term had already (in any case), or asked to be removed and not there.
        public var unchanged: [String] = []
        /// Phrases refused: the term itself, longer than `maximumLength`, without a letter or digit, or past
        /// `maximumHeardAs`.
        public var refused: [String] = []
        /// The term's phrases after the change.
        public var phrases: [String] = []
    }

    /// The "often heard as" phrases of the term matching `text` (any case or spacing); nil when the list does not have
    /// the term, empty when it has none.
    public func heardAs(of text: String) -> [String]? {
        guard let term = Self.cleaned(text), let entry = entry(matching: term) else { return nil }
        return entry.heardAs ?? []
    }

    /// Adds `phrases` (comma lists are not split here: see `heardAsList`) to the "often heard as" phrases of the term
    /// matching `text`; nil when the list does not have the term. A phrase the term has already, in any case, is left
    /// as it is; one that is the term itself, too long, without a letter or digit, or past `maximumHeardAs` is
    /// refused.
    @discardableResult
    public mutating func addHeardAs(_ phrases: [String], to text: String) -> HeardAsChange? {
        guard let term = Self.cleaned(text), let index = entries.firstIndex(where: { Self.key($0.text) == Self.key(term) })
        else { return nil }
        var current = entries[index].heardAs ?? []
        var change = HeardAsChange(term: entries[index].text)
        for raw in phrases {
            guard let phrase = Self.cleaned(raw) else { continue }
            if current.contains(where: { Self.key($0) == Self.key(phrase) }) {
                change.unchanged.append(phrase)
            } else if !Self.isHeardAs(phrase, of: entries[index].text) || current.count >= Self.maximumHeardAs {
                change.refused.append(phrase)
            } else {
                current.append(phrase)
                change.added.append(phrase)
            }
        }
        entries[index].heardAs = current.isEmpty ? nil : current
        change.phrases = current
        return change
    }

    /// Removes `phrases` (any case or spacing) from the "often heard as" phrases of the term matching `text`; nil when
    /// the list does not have the term.
    @discardableResult
    public mutating func removeHeardAs(_ phrases: [String], from text: String) -> HeardAsChange? {
        guard let term = Self.cleaned(text), let index = entries.firstIndex(where: { Self.key($0.text) == Self.key(term) })
        else { return nil }
        var current = entries[index].heardAs ?? []
        var change = HeardAsChange(term: entries[index].text)
        for raw in phrases {
            guard let phrase = Self.cleaned(raw) else { continue }
            if let at = current.firstIndex(where: { Self.key($0) == Self.key(phrase) }) {
                change.removed.append(current.remove(at: at))
            } else {
                change.unchanged.append(phrase)
            }
        }
        entries[index].heardAs = current.isEmpty ? nil : current
        change.phrases = current
        return change
    }

    /// Makes `phrases` the "often heard as" phrases of the term matching `text` (as `addHeardAs` keeps them, in order);
    /// nil when the list does not have the term. The Word list card's "Often heard as" column sets them this way.
    @discardableResult
    public mutating func setHeardAs(_ phrases: [String], for text: String) -> HeardAsChange? {
        guard let term = Self.cleaned(text), let index = entries.firstIndex(where: { Self.key($0.text) == Self.key(term) })
        else { return nil }
        let before = entries[index].heardAs ?? []
        entries[index].heardAs = nil
        guard var change = addHeardAs(phrases, to: term) else { return nil }
        change.removed = before.filter { old in !change.phrases.contains { Self.key($0) == Self.key(old) } }
        change.added = change.added.filter { new in !before.contains { Self.key($0) == Self.key(new) } }
        change.unchanged = []
        return change
    }

    /// Every term's "often heard as" phrases as pairs (heard phrase → term), in list order: what Apple Intelligence may
    /// swap where the context says the term was meant, never on its own. A phrase heard for two terms counts for the
    /// last one listed.
    public var heardAsPairs: [Correction] {
        entries.flatMap { entry in (entry.heardAs ?? []).map { Correction(heard: $0, meant: entry.text) } }
    }

    /// The phrases of a comma-separated list ("cloud, clot,clod"), trimmed, blanks skipped.
    public static func heardAsList(_ text: String) -> [String] {
        text.split(separator: ",").compactMap { cleaned(String($0)) }
    }

    /// Whether `phrase` (cleaned) may be an "often heard as" phrase of `term`: not the term itself in any case, at most
    /// `maximumLength` characters, with a letter or digit.
    static func isHeardAs(_ phrase: String, of term: String) -> Bool {
        key(phrase) != key(term) && phrase.count <= maximumLength && phrase.contains { $0.isLetter || $0.isNumber }
    }

    /// A term as typed in a sentence (a Review edit's text), each word without the sentence's punctuation around it:
    /// "GitHub," → "GitHub", "“Claude.”" → "Claude", while "C#", "C++", ".NET" and "Node.js" stay as they are
    /// (`termWord`). Nil when no letter or digit is left.
    public static func typedTerm(_ text: String) -> String? {
        let term = cleaned(text.split(whereSeparator: \.isWhitespace).map { termWord(String($0)) }.joined(separator: " "))
        return term?.contains { $0.isLetter || $0.isNumber } == true ? term : nil
    }

    /// One word of a typed term without the sentence's punctuation around it: opening and closing quotes and brackets,
    /// a trailing comma, semicolon or colon, and a trailing ".", "!", "?" or "…" only when the rest of the word is
    /// plain (letters, digits, apostrophes, hyphens: "Claude." but not "Node.js." nor "e.g."). What belongs to the word
    /// stays: "#", "+", a leading dot, punctuation inside it.
    public static func termWord(_ word: String) -> String {
        let opening: Set<Character> = ["\"", "'", "“", "‘", "«", "(", "[", "{", "¿", "¡"]
        let closing: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]
        let separating: Set<Character> = [",", ";", ":"]
        let ending: Set<Character> = [".", "!", "?", "…"]
        var characters = Substring(word)
        while let first = characters.first, opening.contains(first) { characters.removeFirst() }
        func plain(_ rest: Substring) -> Bool {
            !rest.isEmpty && rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-" }
        }
        while let last = characters.last {
            if closing.contains(last) || separating.contains(last) {
                characters.removeLast()
            } else if ending.contains(last) {
                var rest = characters.dropLast()
                while let previous = rest.last, ending.contains(previous) { rest = rest.dropLast() }
                guard plain(rest) else { break }
                characters = rest
            } else {
                break
            }
        }
        return String(characters)
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
    /// Its "often heard as" phrases are kept as `addHeardAs` keeps them.
    private mutating func insert(_ entry: WordListEntry) {
        guard let term = Self.cleaned(entry.text), term.count <= Self.maximumLength, self.entry(matching: term) == nil,
              entries.count < Self.maximumTerms else { return }
        entries.append(WordListEntry(text: term, addedAt: entry.addedAt, source: entry.source))
        if let heardAs = entry.heardAs { addHeardAs(heardAs, to: term) }
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
