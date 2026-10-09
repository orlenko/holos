import Foundation
import NaturalLanguage
import Synchronization

/// Joins the recognizer's results for dictation (docs/design.md "Pauses inside a sentence"). Apple's speech
/// transcriber gives one result per stretch of speech between pauses and writes each as a sentence of its own, with a
/// capital first word, so a pause in the middle of a sentence leaves a capital there ("we are cleaning up our big |
/// Pull request"). Where the text before a pause does not end a sentence (a closing mark, past closing quotes,
/// brackets and spaces, or a line break at the pause), the first word after it is lowered, unless the result opens
/// with a quote or a bracket, or the word keeps its capital anywhere: "I" and its contractions in English; a word with
/// another capital, a digit or a symbol ("PR", "macOS", "GPT-4"); a letter alone ("plan B"), but for the words of one
/// letter ("A", French "À"); a word of a term of the word list, of a learned correction's meant phrase or of a
/// person's name (`terms`) written with a capital; a name the language tagger finds in the two results around the
/// pause (`NLTagger`, people, places and organizations: "with | Alice tomorrow"); and a word whose lowercase form the
/// spell checker of the dictation language does not know ("Kubernetes", "Monday" in English).
///
/// The spell checker is a service another process runs, and a call may stall, so joining never waits for it
/// (`SeamSpelling`): a word it has not answered for yet keeps its capital. A result still being recognized is decided
/// again at each revision; a final one is decided once, with what is known then, and keeps that decision for the
/// utterance, so text already committed stays a prefix of the text that follows.
///
/// Only English and French dictation is changed: other languages capitalize other words (German nouns), and are joined
/// as before.
public final class DictationSeams: Sendable {
    /// Whether the word at a range of a text is a name.
    typealias NameCheck = @Sendable (String, Range<String.Index>) -> Bool

    /// One result of the recognizer, and whether it is final.
    public struct Piece: Sendable, Equatable {
        public var text: String
        public var isFinal: Bool

        public init(_ text: String, isFinal: Bool = true) {
            self.text = text
            self.isFinal = isFinal
        }
    }

    public let language: String
    private let english: Bool
    private let applies: Bool
    /// Lowercased words written with a capital in `terms`.
    private let capitalized: Set<String>
    private let spelling: SeamSpelling
    private let isName: NameCheck
    /// The decision at each pause before a final result, by the results around it: true when the word is lowered.
    private let decisions = Mutex<[String: Bool]>([:])

    /// For dictation in `language` (a locale identifier). `terms`: the word list's terms, learned corrections' meant
    /// phrases, and people's names (`terms(wordList:corrections:names:)`).
    public convenience init(language: String, terms: [String] = []) {
        let tagger = NameTagger.shared(language: language)
        self.init(language: language, terms: terms, spelling: .shared(language: language),
                  isName: { tagger.isName(in: $0, at: $1) })
    }

    init(language: String, terms: [String], spelling: SeamSpelling, isName: @escaping NameCheck) {
        self.language = language
        let code = DictationLanguage.languageCode(of: language)
        english = code == "en"
        applies = Self.languages.contains(code)
        capitalized = Set(terms.flatMap { term in
            term.split(whereSeparator: \.isWhitespace).map(Self.core).filter { $0.first?.isUppercase == true }
                .map { $0.lowercased() }
        })
        self.spelling = spelling
        self.isName = isName
    }

    /// The languages whose sentences keep capitals for names alone: English and French.
    static let languages: Set<String> = ["en", "fr"]

    /// The words whose capitals stay after a pause: the word list's terms, learned corrections' meant phrases, and
    /// people's names.
    public static func terms(wordList: [String], corrections: CorrectionList, names: [String] = []) -> [String] {
        wordList + corrections.entries.map(\.meant) + names
    }

    /// Final results (`pieces`, in order) as one text (`join(_: [Piece])`).
    public func join(_ pieces: [String]) -> String {
        join(pieces.map { Piece($0) })
    }

    /// The results (`pieces`, in order) as one text: each trimmed, empty ones left out, one space between, and the
    /// first word after a pause inside a sentence lowered (see the type).
    public func join(_ pieces: [Piece]) -> String {
        var output = ""
        var previous: (raw: String, trimmed: String)?
        // A line break in a result of whitespace alone, since the last result with text.
        var lineBreak = false
        for piece in pieces {
            let trimmed = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                lineBreak = lineBreak || piece.text.contains(where: \.isNewline)
                continue
            }
            if let before = previous {
                let breaks = lineBreak || Self.breaksLine(after: before.raw, before: piece.text)
                output += " " + (applies && !breaks
                    ? seamed(trimmed, isFinal: piece.isFinal, after: before.trimmed) : trimmed)
            } else {
                output = trimmed
            }
            previous = (piece.text, trimmed)
            lineBreak = false
        }
        return output
    }

    /// Asks the spell checker, and waits at most `budget` for it, about the words the pauses between `pieces` may
    /// lower, so that joining them afterwards knows them: Run Again, which has its results at once.
    public func prepare(_ pieces: [String], within budget: Duration = .seconds(2)) async {
        guard applies else { return }
        let words = pieces.dropFirst().compactMap { raw -> String? in
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard piece.first?.isUppercase == true else { return nil }
            let word = Self.core(piece.prefix { !$0.isWhitespace })
            return word.isEmpty || keepsCapital(word) ? nil : word.lowercased()
        }
        await spelling.prepare(words, within: budget)
    }

    /// `piece` (trimmed) after the text `before`, its first word lowered when the pause is inside a sentence.
    private func seamed(_ piece: String, isFinal: Bool, after before: String) -> String {
        guard !Self.endsSentence(before) else { return piece }
        // A piece that opens with a quote or a bracket keeps its capital: a quoted sentence starts with one.
        guard piece.first?.isUppercase == true else { return piece }
        let word = Self.core(piece.prefix { !$0.isWhitespace })
        guard !word.isEmpty, !keepsCapital(word) else { return piece }
        let key = before + "\u{1}" + piece
        if isFinal, let lowered = decisions.withLock({ $0[key] }) {
            return lowered ? Self.lowered(piece) : piece
        }
        // The tagger reads the two results as one text, the word as recognized.
        let context = before + " " + piece
        let start = before.utf16.count + 1
        let range = String.Index(utf16Offset: start, in: context)
            ..< String.Index(utf16Offset: start + word.utf16.count, in: context)
        // A hesitation ("Um", "Euh") is no name, and the spell checker may not know it.
        let lowered = FillerWords.isFiller(String(word), language: language)
            || (!isName(context, range) && spelling.knows(word.lowercased()) == true)
        if isFinal {
            // The first decision stands, whatever the spell checker answers later.
            let kept = decisions.withLock { decisions in
                if let earlier = decisions[key] { return earlier }
                decisions[key] = lowered
                return lowered
            }
            return kept ? Self.lowered(piece) : piece
        }
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

    /// Whether `text` ends a sentence: a closing mark, past closing quotes, brackets and spaces in any order (French
    /// « C’est fini. » has a space, often a no-break one, before its closing quote).
    static func endsSentence(_ text: String) -> Bool {
        let end = text.reversed().drop { closers.contains($0) || $0.isWhitespace }.first
        return end.map { ".!?…".contains($0) } ?? false
    }

    /// Whether the whitespace at the end of `before` or at the start of `after`, the raw results around a pause, has
    /// a line break.
    static func breaksLine(after before: String, before after: String) -> Bool {
        before.reversed().prefix(while: \.isWhitespace).contains(where: \.isNewline)
            || after.prefix(while: \.isWhitespace).contains(where: \.isNewline)
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

    static let openers: Set<Character> = ["\"", "“", "‘", "'", "(", "[", "{", "«", "‹", "¿", "¡"]
    static let closers: Set<Character> = ["\"", "”", "’", "'", ")", "]", "}", "»", "›"]
    static let apostrophes: Set<Character> = ["'", "’"]
}

/// Whether the lowercase form of a word is a word of a language, for `DictationSeams`, without ever waiting: answers
/// come from a cache; a word not in it is asked on `queue` (one lookup per word, however often it is asked meanwhile)
/// and is unknown (nil) until the answer comes. One per language, for the whole process, so later dictations know the
/// words earlier ones asked about.
final class SeamSpelling: Sendable {
    private struct State {
        var answers: [String: Bool] = [:]
        var asked: Set<String> = []
    }

    private let state = Mutex(State())
    private let queue: DispatchQueue?
    private let lookup: @Sendable (String) -> Bool

    /// `lookup` says whether a lowercase word is known; it may block, and runs on `queue`, or on the spot when
    /// `queue` is nil (tests).
    init(queue: DispatchQueue?, lookup: @escaping @Sendable (String) -> Bool) {
        self.queue = queue
        self.lookup = lookup
    }

    private static let instances = Mutex<[String: SeamSpelling]>([:])

    /// The system spell checker's answers for `language` (`SystemSpelling`).
    static func shared(language: String) -> SeamSpelling {
        instances.withLock { instances in
            if let known = instances[language] { return known }
            let made = SeamSpelling(queue: SystemSpelling.queue) { SystemSpelling.knows($0, language: language) }
            instances[language] = made
            return made
        }
    }

    /// The answer for `word` if there is one; otherwise asks for it (once) and returns nil. Never waits.
    func knows(_ word: String) -> Bool? {
        let (answer, ask) = state.withLock { state -> (Bool?, Bool) in
            if let answer = state.answers[word] { return (answer, false) }
            return (nil, state.asked.insert(word).inserted)
        }
        guard ask else { return answer }
        guard let queue else {
            let known = lookup(word)
            record(word, known)
            return known
        }
        queue.async { [self] in record(word, lookup(word)) }
        return nil
    }

    /// Asks for each of `words` not answered yet, and waits until the answers came or `budget` ran out.
    func prepare(_ words: [String], within budget: Duration) async {
        for word in words { _ = knows(word) }
        await settled(within: budget)
    }

    /// Waits until every question asked so far is answered (the queue is serial), or `budget` ran out.
    func settled(within budget: Duration = .seconds(2)) async {
        guard let queue else { return }
        let once = OnceContinuation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.start(continuation)
                queue.async { once.resume() }
                DispatchQueue.global().asyncAfter(deadline: .now() + budget.timeInterval) { once.resume() }
            }
        } onCancel: {
            once.resume()
        }
    }

    private func record(_ word: String, _ known: Bool) {
        state.withLock { $0.answers[word] = known }
    }
}

/// A continuation resumed by whichever comes first.
private final class OnceContinuation: Sendable {
    private struct State {
        var done = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<Void, Never>) {
        let done = state.withLock { state -> Bool in
            if !state.done { state.continuation = continuation }
            return state.done
        }
        if done { continuation.resume() }
    }

    func resume() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.done = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}

/// `NLTagger`'s names (people, places, organizations) in dictation's language, one question at a time. One per
/// language for the whole process; its model is loaded in the background when it is made.
final class NameTagger: Sendable {
    private let tagger: Mutex<NLTagger>
    private let language: NLLanguage

    private init(language: String) {
        tagger = Mutex(NLTagger(tagSchemes: [.nameType]))
        self.language = NLLanguage(rawValue: DictationLanguage.languageCode(of: language))
    }

    private static let instances = Mutex<[String: NameTagger]>([:])

    static func shared(language: String) -> NameTagger {
        let code = DictationLanguage.languageCode(of: language)
        let (tagger, made) = instances.withLock { instances -> (NameTagger, Bool) in
            if let known = instances[code] { return (known, false) }
            let made = NameTagger(language: code)
            instances[code] = made
            return (made, true)
        }
        if made {
            DispatchQueue.global(qos: .utility).async {
                let text = "Alice"
                _ = tagger.isName(in: text, at: text.startIndex..<text.endIndex)
            }
        }
        return tagger
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
