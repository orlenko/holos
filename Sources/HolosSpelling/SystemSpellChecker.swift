import AppKit
import HolosCore

/// `NSSpellChecker` as the process's spell checker: the app and `voiceislocal` install it at launch
/// (`SystemSpelling.install`). `SystemSpelling` calls it one call at a time on `SystemSpelling.queue`: it is shared by
/// the whole process, not documented as thread-safe, and each call asks another process, which may stall.
///
/// Invariants:
/// 1. `knows` and `dictionaries` run on `SystemSpelling.queue` only, so the cached `tag` and `available` are read and
///    written there alone (the reason their `nonisolated(unsafe)` is safe).
public struct SystemSpellChecker: SpellChecking {
    /// Read on `SystemSpelling.queue` only.
    nonisolated(unsafe) private static var tag: Int?
    nonisolated(unsafe) private static var available: [String]?

    public init() {}

    /// Whether the spell checker knows `word` in `language` (see `dictionaries`); true when it has no dictionary
    /// for it. Call on `SystemSpelling.queue`.
    public func knows(_ word: String, language: String?) -> Bool {
        dispatchPrecondition(condition: .onQueue(SystemSpelling.queue))
        guard let dictionaries = dictionaries(for: language) else { return true }
        let checker = NSSpellChecker.shared
        let tag = Self.tag ?? NSSpellChecker.uniqueSpellDocumentTag()
        Self.tag = tag
        return dictionaries.contains { dictionary in
            checker.checkSpelling(of: word, startingAt: 0, language: dictionary, wrap: false,
                                  inSpellDocumentWithTag: tag, wordCount: nil).location == NSNotFound
        }
    }

    /// The spell checker's languages for dictation in `language`: its identifier ("en_US") or language ("en") when
    /// the spell checker has it, English and French when nil; nil when it has none of them. Call on
    /// `SystemSpelling.queue`.
    public func dictionaries(for language: String?) -> [String]? {
        let available = Self.available ?? NSSpellChecker.shared.availableLanguages
        Self.available = available
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
}
