import Foundation

/// What `voiceislocal eval cloud --vocabulary` tells the model (docs/reference-evaluation.md, "Cloud reference").
///
/// - `keywords[]` (gpt-transcribe only): people's names, then the words of the user's corrections (the meant words, as
///   `CorrectionList.vocabulary(languages:)` lists them for the meeting's languages), once each ignoring case, at
///   most `maxKeywords`. A term with a line break, "<" or ">" is left out: OpenAI rejects the whole request for it.
/// - `prompt`: "A meeting in English and French. People: Maria Chen, Jim Park. Terms: Kubernetes, Ubuntu." — the
///   languages, then as many names and terms as fit in `maxPromptCharacters` (whisper-1 reads only 224 tokens).
///
/// Without `--vocabulary` there is neither; the meeting's languages are always sent as `languages[]` (or `language`).
public enum CloudVocabulary {
    public static let maxKeywords = 100
    public static let maxPromptCharacters = 800

    public struct Built: Sendable, Equatable {
        public var prompt: String?
        public var keywords: [String]
    }

    public static func build(languages: [String], names: [String], terms: [String]) -> Built {
        var seen = Set<String>()
        var cleanNames: [String] = []
        var cleanTerms: [String] = []
        for (list, isName) in [(names, true), (terms, false)] {
            for raw in list {
                let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, term.count <= 100, !term.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" }),
                      seen.insert(term.lowercased()).inserted else { continue }
                if isName { cleanNames.append(term) } else { cleanTerms.append(term) }
            }
        }
        let keywords = Array((cleanNames + cleanTerms).prefix(maxKeywords))
        let languageNames = languageNames(languages)
        var prompt = languageNames.isEmpty ? "A meeting." : "A meeting in \(listed(languageNames))."
        func appendList(_ label: String, _ items: [String]) {
            var kept: [String] = []
            for item in items {
                let candidate = prompt + " \(label): " + (kept + [item]).joined(separator: ", ") + "."
                if candidate.count > maxPromptCharacters { break }
                kept.append(item)
            }
            if !kept.isEmpty { prompt += " \(label): " + kept.joined(separator: ", ") + "." }
        }
        appendList("People", cleanNames)
        appendList("Terms", cleanTerms)
        return Built(prompt: cleanNames.isEmpty && cleanTerms.isEmpty ? nil : prompt, keywords: keywords)
    }

    /// ISO 639-1 codes of locale identifiers ("fr-CA" → "fr"), once each, in order.
    public static func languageCodes(_ locales: [String]) -> [String] {
        var codes: [String] = []
        for locale in locales {
            let code = Locale(identifier: locale).language.languageCode?.identifier
                ?? String(locale.prefix { $0.isLetter }).lowercased()
            if !code.isEmpty, !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    static func languageNames(_ locales: [String]) -> [String] {
        let english = Locale(identifier: "en")
        return languageCodes(locales).map { english.localizedString(forLanguageCode: $0) ?? $0 }
    }

    static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
