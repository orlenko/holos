import Foundation
import NaturalLanguage
import Synchronization

/// Joins the recognizer's results for dictation (docs/design.md "Pauses inside a sentence"). Apple's speech
/// transcriber gives one result per stretch of speech between pauses and writes each as a sentence of its own, with a
/// capital first word, so a pause in the middle of a sentence leaves a capital there ("we are cleaning up our big |
/// Pull request"). Where the text before a pause does not end a sentence (a closing mark, past closing quotes and
/// brackets, or a line break), the first word after it is lowered, unless the result opens with a quote or a bracket,
/// or the word keeps its capital anywhere: "I" and its contractions in English; a word with another capital, a digit
/// or a symbol ("PR", "macOS", "GPT-4"); a letter alone ("plan B"), but for the words of one letter ("A", French "À");
/// a word of a term of the word list, of a learned correction's meant phrase or of a person's
/// name (`terms`) written with a capital; a name the language tagger finds in the two results around the pause
/// (`NLTagger`, people, places and organizations: "with | Alice tomorrow"); and a word whose lowercase form the spell
/// checker of the dictation language does not know ("Kubernetes", "Monday" in English).
///
/// Only English and French dictation is changed: other languages capitalize other words (German nouns), and are joined
/// as before. Each decision depends only on the result before a pause and the one after it, and is kept for the
/// utterance, so text already committed stays a prefix of the text that follows.
public final class DictationSeams: Sendable {
    /// Whether the lowercase form of a word is a word of the language; nil when the spell checker did not answer in
    /// time (the capital stays).
    typealias WordCheck = @Sendable (String) -> Bool?
    /// Whether the word at a range of a text is a name.
    typealias NameCheck = @Sendable (String, Range<String.Index>) -> Bool

    public let language: String
    private let english: Bool
    private let applies: Bool
    /// Lowercased words written with a capital in `terms`.
    private let capitalized: Set<String>
    private let knowsWord: WordCheck
    private let isName: NameCheck
    /// Each pause's decision, by the results around it: true when the word after it is lowered.
    private let decisions = Mutex<[String: Bool]>([:])

    /// For dictation in `language` (a locale identifier). `terms`: the word list's terms, learned corrections' meant
    /// phrases, and people's names (`terms(wordList:corrections:names:)`). `spellingTimeout`: how long a pause waits for
    /// the spell checker, a service another process runs.
    public convenience init(language: String, terms: [String] = [],
                            spellingTimeout: Duration = .milliseconds(150)) {
        let tagger = NameTagger(language: language)
        self.init(language: language, terms: terms,
                  knowsWord: { SystemSpelling.knows($0, language: language, within: spellingTimeout) },
                  isName: { tagger.isName(in: $0, at: $1) })
    }

    init(language: String, terms: [String], knowsWord: @escaping WordCheck, isName: @escaping NameCheck) {
        self.language = language
        let code = DictationLanguage.languageCode(of: language)
        english = code == "en"
        applies = Self.languages.contains(code)
        capitalized = Set(terms.flatMap { term in
            term.split(whereSeparator: \.isWhitespace).map(Self.core).filter { $0.first?.isUppercase == true }
                .map { $0.lowercased() }
        })
        self.knowsWord = knowsWord
        self.isName = isName
    }

    /// The languages whose sentences keep capitals for names alone: English and French.
    static let languages: Set<String> = ["en", "fr"]

    /// The words whose capitals stay after a pause: the word list's terms, learned corrections' meant phrases, and
    /// people's names.
    public static func terms(wordList: [String], corrections: CorrectionList, names: [String] = []) -> [String] {
        wordList + corrections.entries.map(\.meant) + names
    }

    /// The results (`pieces`, in order) as one text: each trimmed, empty ones left out, one space between, and the
    /// first word after a pause inside a sentence lowered (see the type).
    public func join(_ pieces: [String]) -> String {
        var output = ""
        var previous: (raw: String, trimmed: String)?
        for raw in pieces {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let before = previous {
                output += " " + (applies ? seamed(piece, raw: raw, after: before) : piece)
            } else {
                output = piece
            }
            previous = (raw, piece)
        }
        return output
    }

    /// `piece` after `before`, its first word lowered when the pause between them is inside a sentence.
    private func seamed(_ piece: String, raw: String, after before: (raw: String, trimmed: String)) -> String {
        // A line break at the pause, or a sentence that ended before it.
        if before.raw.last?.isNewline == true || raw.first?.isNewline == true || Self.endsSentence(before.trimmed) {
            return piece
        }
        // A piece that opens with a quote or a bracket keeps its capital: a quoted sentence starts with one.
        guard piece.first?.isUppercase == true else { return piece }
        let word = Self.core(piece.prefix { !$0.isWhitespace })
        guard !word.isEmpty, !keepsCapital(word) else { return piece }
        let key = before.trimmed + "\u{1}" + piece
        if let lowered = decisions.withLock({ $0[key] }) {
            return lowered ? Self.lowered(piece) : piece
        }
        // The tagger reads the two results as one text, the word as recognized.
        let context = before.trimmed + " " + piece
        let start = before.trimmed.utf16.count + 1
        let range = String.Index(utf16Offset: start, in: context)
            ..< String.Index(utf16Offset: start + word.utf16.count, in: context)
        // A hesitation ("Um", "Euh") is no name, and the spell checker may not know it.
        let lowered = FillerWords.isFiller(String(word), language: language)
            || (!isName(context, range) && knowsWord(word.lowercased()) == true)
        decisions.withLock { $0[key] = lowered }
        return lowered ? Self.lowered(piece) : piece
    }

    /// Whether `word` (a capitalized word after a pause) keeps its capital whatever the context.
    private func keepsCapital(_ word: Substring) -> Bool {
        // A capital past the first letter ("PR", "McDonald's"), a digit or a symbol ("GPT-4", "C#").
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        if word.contains(where: { !$0.isLetter && !Self.apostrophes.contains($0) && $0 != "-" }) { return true }
        if english, word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return true }
        // A letter alone is a letter ("plan B", "dash P"), unless it is a word of the language ("A", "À").
        if word.count == 1, !oneLetterWords.contains(word.lowercased()) { return true }
        return capitalized.contains(word.lowercased())
    }

    /// The words of one letter that a pause may lower.
    private var oneLetterWords: Set<String> { english ? ["a"] : ["a", "à", "y"] }

    /// Whether `text` ends a sentence: a closing mark, past closing quotes and brackets.
    static func endsSentence(_ text: String) -> Bool {
        let end = text.reversed().drop { closers.contains($0) }.first
        return end.map { ".!?…".contains($0) } ?? false
    }

    /// `word` without the quotes, brackets and marks around it.
    static func core(_ word: some StringProtocol) -> Substring {
        var core = Substring(word)
        while let first = core.first, openers.contains(first) { core = core.dropFirst() }
        while let last = core.last, closers.contains(last) || ".,;:!?…".contains(last) { core = core.dropLast() }
        return core
    }

    private static func lowered(_ piece: String) -> String {
        guard let first = piece.first else { return piece }
        return first.lowercased() + piece.dropFirst()
    }

    static let openers: Set<Character> = ["\"", "“", "‘", "'", "(", "[", "{", "«", "¿", "¡"]
    static let closers: Set<Character> = ["\"", "”", "’", "'", ")", "]", "}", "»"]
    static let apostrophes: Set<Character> = ["'", "’"]
}

/// `NLTagger`'s names (people, places, organizations) in dictation's language, one question at a time.
private final class NameTagger: Sendable {
    private let tagger: Mutex<NLTagger>
    private let language: NLLanguage

    init(language: String) {
        tagger = Mutex(NLTagger(tagSchemes: [.nameType]))
        self.language = NLLanguage(rawValue: DictationLanguage.languageCode(of: language))
    }

    func isName(in text: String, at range: Range<String.Index>) -> Bool {
        tagger.withLock { tagger in
            tagger.string = text
            tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
            let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType)
            return tag == .personalName || tag == .placeName || tag == .organizationName
        }
    }
}

extension SystemSpelling {
    /// `knows`, waiting at most `timeout` for the spell checker; nil when it did not answer in time. Not on `queue`.
    static func knows(_ word: String, language: String?, within timeout: Duration) -> Bool? {
        let answer = SpellingAnswer()
        queue.async { answer.set(knows(word, language: language)) }
        return answer.wait(timeout)
    }
}

private final class SpellingAnswer: Sendable {
    private let value = Mutex<Bool?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func set(_ known: Bool) {
        value.withLock { $0 = known }
        done.signal()
    }

    func wait(_ timeout: Duration) -> Bool? {
        guard done.wait(timeout: .now() + timeout.timeInterval) == .success else { return nil }
        return value.withLock { $0 }
    }
}
