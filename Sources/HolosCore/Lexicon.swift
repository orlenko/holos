import AppKit
import Foundation
import Synchronization

/// The words the dictation language knows, for the guard on a model's fix (`AIFixGuard`): a real word ("bat",
/// "teeth", "wanted", "Windows") says something, so a fix may replace it only by a listed homophone or a taught pair
/// said there; a word the language does not know ("Onobunto", "bundu") is a mishearing, which a close-sounding word
/// may replace. A word is real when the system spell checker knows it in the dictation language, lowercased or
/// capitalized (proper nouns: "Mary"), when it has a digit, or when it is a word of a meant phrase the speaker taught.
/// Answers are cached, so each distinct word of a chunk asks the spell checker at most once.
public final class Lexicon: Sendable {
    private let taught: Set<String>
    private let lookup: @Sendable (String) -> Bool
    private let cache = Mutex<[String: Bool]>([:])

    /// The system spell checker's dictionary for `language` (a locale identifier; English and French when nil), and
    /// the words of `taught`, the meant phrases of learned corrections. With no dictionary for the language, every
    /// word is real: only homophones and taught pairs may then change a word.
    public convenience init(language: String?, taught: [String] = []) {
        let languages = SystemSpelling.dictionaries(for: language)
        self.init(taught: taught) { word in
            guard let languages else { return true }
            return languages.contains { SystemSpelling.knows(word, language: $0) }
        }
    }

    /// `lookup` says whether a word, as spelled (case included), is known.
    init(taught: [String] = [], lookup: @escaping @Sendable (String) -> Bool) {
        self.taught = Set(taught.flatMap { AIFixGuard.words(in: $0) })
        self.lookup = lookup
    }

    /// Whether `word` (as `AIFixGuard.words` gives it: lowercased, plain apostrophes) is a real word.
    public func isWord(_ word: String) -> Bool {
        if let known = cache.withLock({ $0[word] }) { return known }
        let known = word.contains(where: \.isNumber) || taught.contains(word) || lookup(word)
            || lookup(word.prefix(1).uppercased() + word.dropFirst())
        cache.withLock { $0[word] = known }
        return known
    }
}

/// `NSSpellChecker`, one call at a time: it is shared by the whole process and not documented as thread-safe.
enum SystemSpelling {
    private static let lock = Mutex(())
    /// `knows` reads it before taking `lock`, since the first read runs its initializer.
    private static let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private static let available = lock.withLock { _ in NSSpellChecker.shared.availableLanguages }

    /// The spell checker's languages for dictation in `language`: its identifier ("en_US") or language ("en") when
    /// the spell checker has it, English and French when nil; nil when it has none of them.
    static func dictionaries(for language: String?) -> [String]? {
        func dictionary(_ identifier: String) -> String? {
            let underscored = identifier.replacingOccurrences(of: "-", with: "_")
            if available.contains(underscored) { return underscored }
            let code = DictationLanguage.languageCode(of: identifier)
            if available.contains(code) { return code }
            return available.first { DictationLanguage.languageCode(of: $0) == code }
        }
        let found = (language.map { [$0] } ?? ["en", "fr"]).compactMap(dictionary)
        return found.isEmpty ? nil : found
    }

    static func knows(_ word: String, language: String) -> Bool {
        let tag = tag
        return lock.withLock { _ in
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                inSpellDocumentWithTag: tag, wordCount: nil).location == NSNotFound
        }
    }
}
