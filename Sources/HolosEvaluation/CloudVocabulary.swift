import Foundation
import HolosCore

/// What `voiceislocal eval cloud --vocabulary` tells the model (docs/reference-evaluation.md, "Cloud reference").
///
/// The same sources, in the same order, as the recognizer's meeting vocabulary (`RecognizerVocabulary.meeting`): the
/// word list (`words.json`), then people's names, then the words of the user's corrections (the meant words, as
/// `CorrectionList.vocabulary(languages:)` lists them for the meeting's languages), each once ignoring case and
/// spacing, so a long correction list never pushes a word-list term or a name out.
///
/// - `keywords[]` (gpt-transcribe only): those strings, at most `maxKeywords` (the recognizer's own limit; OpenAI
///   documents none, and rejects a form of about 1,000 parts). A string with a line break, "<" or ">" is left out,
///   as OpenAI asks (it rejects the whole request for one), and so is one over `maxLength` characters.
/// - `prompt`: "A meeting in English and French. Terms: Keycloak, Urban Sky. People: Maria Chen, Jim Park. Other
///   words: Kubernetes." — the languages, then the kept strings in order, as many as fit in `maxPromptCharacters`
///   (whisper-1 reads only 224 tokens); the first that does not fit ends the prompt.
///
/// Without `--vocabulary` there is neither; the meeting's languages are always sent as `languages[]` (or `language`).
public enum CloudVocabulary {
    public static let maxKeywords = RecognizerVocabulary.maximumStrings
    public static let maxLength = RecognizerVocabulary.maximumLength
    public static let maxPromptCharacters = 800

    public struct Built: Sendable, Equatable {
        public var prompt: String?
        public var keywords: [String]
    }

    public static func build(languages: [String], wordList: [String], names: [String], terms: [String]) -> Built {
        var seen = Set<String>()
        var groups: [[String]] = [[], [], []]
        var count = 0
        for (index, list) in [wordList, names, terms].enumerated() {
            for raw in list where count < maxKeywords {
                // Before cleaning: a line break would otherwise become a space, and the term would still be sent.
                guard !raw.contains(where: { $0 == "<" || $0 == ">" }),
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline),
                      let term = WordList.cleaned(raw), term.count <= maxLength,
                      seen.insert(term.lowercased()).inserted else { continue }
                groups[index].append(term)
                count += 1
            }
        }
        let keywords = groups.flatMap { $0 }
        let languageNames = languageNames(languages)
        var prompt = languageNames.isEmpty ? "A meeting." : "A meeting in \(listed(languageNames))."
        var full = false
        func appendList(_ label: String, _ items: [String]) {
            guard !full else { return }
            var kept: [String] = []
            for item in items {
                let candidate = prompt + " \(label): " + (kept + [item]).joined(separator: ", ") + "."
                if candidate.count > maxPromptCharacters { full = true; break }
                kept.append(item)
            }
            if !kept.isEmpty { prompt += " \(label): " + kept.joined(separator: ", ") + "." }
        }
        appendList("Terms", groups[0])
        appendList("People", groups[1])
        appendList("Other words", groups[2])
        return Built(prompt: keywords.isEmpty ? nil : prompt, keywords: keywords)
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
