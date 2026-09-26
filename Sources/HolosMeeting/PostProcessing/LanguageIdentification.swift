import Foundation
import HolosCore
import NaturalLanguage

/// `LanguageMerge.Scorer` over Apple's `NLLanguageRecognizer`, constrained to the candidates' languages
/// (docs/meeting-design.md §4.14). On device; no text leaves the process. One instance serves one merge, from one task:
/// the recognizer is reset for every text.
final class NaturalLanguageScorer {
    private let recognizer = NLLanguageRecognizer()

    /// The probability that `text` is in each of `languages`, among those languages only: the recognizer's
    /// hypotheses for the candidates' languages, normalized to sum to 1. Candidates the recognizer cannot tell apart
    /// (the same language) share their language's probability; when it has no hypothesis for any of them, every
    /// candidate gets the same share.
    func probabilities(of text: String, among languages: [String]) -> [String: Double] {
        guard !languages.isEmpty else { return [:] }
        let mapped = languages.map(Self.naturalLanguage)
        let distinct = Array(Set(mapped))
        recognizer.reset()
        recognizer.languageConstraints = distinct
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: distinct.count)
        let total = distinct.reduce(0.0) { $0 + (hypotheses[$1] ?? 0) }
        var result: [String: Double] = [:]
        for (language, natural) in zip(languages, mapped) {
            guard total > 0, total.isFinite else {
                result[language] = 1 / Double(languages.count)
                continue
            }
            let sharing = Double(mapped.filter { $0 == natural }.count)
            result[language] = (hypotheses[natural] ?? 0) / total / sharing
        }
        return result
    }

    /// `probabilities` as a `LanguageMerge.Scorer`.
    var scorer: LanguageMerge.Scorer {
        { [self] text, languages in probabilities(of: text, among: languages) }
    }

    /// The recognizer's language for a locale identifier: its language code ("fr" for "fr-CA"), with Chinese split
    /// by script (simplified for zh-CN and zh-Hans, traditional for zh-TW, zh-HK, and zh-Hant).
    static func naturalLanguage(_ identifier: String) -> NLLanguage {
        let code = DictationLanguage.languageCode(of: identifier)
        guard code == "zh" else { return NLLanguage(rawValue: code) }
        let maximal = Locale.Language(identifier: DictationLanguage.identifier(identifier)).maximalIdentifier
        return Locale.Language(identifier: maximal).script?.identifier == "Hant" ? .traditionalChinese
            : .simplifiedChinese
    }
}
