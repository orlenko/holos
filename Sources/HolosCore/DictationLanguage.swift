import Foundation

/// The language dictation listens for: a locale identifier Apple's speech transcriber supports, chosen in Setup.
/// Meetings use the same identifiers, list, and default (their own choice is made in the meeting start panel).
public enum DictationLanguage {
    /// The last resort: when none of the user's languages is supported, or the supported list is not known yet.
    public static let standard = "en-CA"

    /// The supported language closest to the user's, for someone who has not picked one. For each preferred language
    /// in order: the same language, script and region ("fr-CH"); else the same language in the system region when the
    /// preference names none ("fr" in Canada: "fr-CA"); else in its main region ("fr-FR" for "fr-CH"); else in any
    /// other region, by identifier. `standard` only when no preferred language is supported at all (or `supported` is
    /// empty).
    public static func preferred(supported: [String], preferredLanguages: [String], region: String? = nil) -> String {
        let candidates = Set(supported.map(identifier)).sorted().map { (identifier: $0, tag: Tag($0)) }
        for preference in preferredLanguages {
            let wanted = Tag(identifier(preference))
            guard !wanted.language.isEmpty else { continue }
            let same = candidates.filter { $0.tag.language == wanted.language && $0.tag.script == wanted.script }
            guard let any = same.first else { continue }
            let regions = [wanted.region ?? region?.uppercased(), wanted.likelyRegion].compactMap { $0 }
            for region in regions {
                if let match = same.first(where: { $0.tag.region == region }) { return match.identifier }
            }
            return any.identifier
        }
        return standard
    }

    /// `preferred` for this Mac: the user's preferred languages and region.
    public static func preferredForSystem(supported: [String]) -> String {
        preferred(supported: supported, preferredLanguages: Locale.preferredLanguages,
                  region: Locale.current.region?.identifier)
    }

    /// The dictation language: the saved choice, else the default (`preferred`). Nil while the default is not known
    /// yet (`supported` nil: the supported languages have not loaded), so an action that uses the language (an
    /// install, a meeting start) waits instead of taking `standard` for a user whose language is another. An empty
    /// `supported` (the list could not be loaded) gives `standard`.
    public static func resolved(saved: String?, supported: [String]?, preferredLanguages: [String],
                                region: String? = nil) -> String? {
        if let saved, !saved.isEmpty { return saved }
        guard let supported else { return nil }
        return preferred(supported: supported, preferredLanguages: preferredLanguages, region: region)
    }

    /// `resolved` for this Mac: the user's preferred languages and region.
    public static func resolvedForSystem(saved: String?, supported: [String]?) -> String? {
        resolved(saved: saved, supported: supported, preferredLanguages: Locale.preferredLanguages,
                 region: Locale.current.region?.identifier)
    }

    /// The meeting languages: the saved ones (blanks left out), else the dictation language (`resolved`); nil while
    /// that is not known yet.
    public static func meetingLocales(saved: [String]?, dictation: String?) -> [String]? {
        if let saved = saved?.filter({ !$0.isEmpty }), !saved.isEmpty { return saved }
        return dictation.map { [$0] }
    }

    // MARK: - Meeting languages (docs/meeting-design.md §4.14)

    /// At most this many meeting languages: the one the meeting is transcribed in live, and two more that
    /// post-processing transcribes the audio in again and chooses from.
    public static let maximumMeetingLanguages = 3

    /// Whether two identifiers name the same language in the same script ("fr-CA" and "fr-FR", but not "zh-CN" and
    /// "zh-TW"): language detection cannot tell such a pair apart.
    public static func sameLanguage(_ first: String, _ second: String) -> Bool {
        let a = Tag(identifier(first))
        let b = Tag(identifier(second))
        return !a.language.isEmpty && a.language == b.language && a.script == b.script
    }

    /// The meeting's languages as the recorder and post-processing take them: each as "fr-CA", in order, without
    /// blanks or repeats, leaving out one that is the same language as an earlier one (`sameLanguage`), and at most
    /// `maximumMeetingLanguages`. The first is the language the meeting is transcribed in live.
    public static func meetingLanguages(_ identifiers: [String]) -> [String] {
        var kept: [String] = []
        for raw in identifiers {
            let candidate = identifier(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !candidate.isEmpty, !kept.contains(where: { sameLanguage($0, candidate) || $0 == candidate }) else {
                continue
            }
            kept.append(candidate)
            if kept.count == maximumMeetingLanguages { break }
        }
        return kept
    }

    /// A comma-separated list ("fr-CA,en-CA"), for a command-line option: the entries, trimmed, without blanks.
    public static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Why `identifiers` cannot be a meeting's languages as given (a repeat, two regions of one language, more than
    /// `maximumMeetingLanguages`, none at all), for a command that refuses rather than drops; nil when they can.
    public static func meetingLanguagesProblem(_ identifiers: [String]) -> String? {
        let cleaned = identifiers.map { identifier($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "Name at least one language, like fr-CA." }
        guard cleaned.count <= maximumMeetingLanguages else {
            return "A meeting can have at most \(maximumMeetingLanguages) languages."
        }
        for (index, candidate) in cleaned.enumerated() {
            if let earlier = cleaned[..<index].first(where: { sameLanguage($0, candidate) || $0 == candidate }) {
                return earlier == candidate ? "\(candidate) is listed twice."
                    : "\(earlier) and \(candidate) are the same language; list one of them."
            }
        }
        return nil
    }

    /// A locale identifier's language, script (filled in when implied: "zh-CN" is Hans), and region.
    private struct Tag {
        var language: String
        var script: String?
        var region: String?
        /// The region the language is mostly spoken in with this script ("FR" for French, "TW" for zh-Hant).
        var likelyRegion: String?

        init(_ identifier: String) {
            let language = Locale.Language(identifier: identifier)
            self.language = language.languageCode?.identifier.lowercased() ?? ""
            script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier
            region = language.region?.identifier.uppercased()
            let base = [self.language, script].compactMap { $0 }.joined(separator: "-")
            likelyRegion = Locale.Language(identifier: Locale.Language(identifier: base).maximalIdentifier)
                .region?.identifier.uppercased()
        }
    }

    /// "fr-CA" for "fr_CA", "fr-ca", or "FR_ca", the form Holos saves, compares, and hands to the recognizer: hyphens,
    /// and BCP 47 case (language lowercase, a four-letter script titlecase, a two-letter region uppercase, everything
    /// else lowercase, "zh-Hans-CN", "es-419"), so two spellings of one locale are one identifier. Keywords after "@"
    /// are kept as given.
    public static func identifier(_ raw: String) -> String {
        let keywords = raw.firstIndex(of: "@")
        let tag = raw[..<(keywords ?? raw.endIndex)].replacingOccurrences(of: "_", with: "-")
        var afterSingleton = false
        let subtags = tag.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { index, part in
            let subtag = String(part)
            let letters = subtag.allSatisfy { $0.isASCII && $0.isLetter }
            // The language, and everything after an extension or private-use singleton ("-u-", "-x-"), is lowercase.
            if index == 0 || afterSingleton { return subtag.lowercased() }
            if subtag.count == 1 {
                afterSingleton = true
                return subtag.lowercased()
            }
            if letters, subtag.count == 4 { return subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased() }
            if letters, subtag.count == 2 { return subtag.uppercased() }
            return subtag.lowercased()
        }
        return subtags.joined(separator: "-") + (keywords.map { String(raw[$0...]) } ?? "")
    }

    /// "fr" for "fr-CA", "fr_FR", or "fr".
    public static func languageCode(of identifier: String) -> String {
        String(identifier.prefix { $0.isLetter }).lowercased()
    }

    /// "French (Canada)" in the user's own language; the identifier when macOS has no name for it.
    public static func name(of identifier: String, in display: Locale = .current) -> String {
        display.localizedString(forIdentifier: self.identifier(identifier)) ?? identifier
    }

    /// The identifiers for a picker, without duplicates: English variants first, then French, then the rest, each
    /// group sorted by name.
    public static func ordered(_ identifiers: [String], in display: Locale = .current) -> [String] {
        Set(identifiers.map(identifier)).sorted {
            (group($0), name(of: $0, in: display), $0) < (group($1), name(of: $1, in: display), $1)
        }
    }

    /// `ordered`, split into its English, French and other groups, leaving out empty ones; a picker puts a separator
    /// between them.
    public static func groups(_ identifiers: [String], in display: Locale = .current) -> [[String]] {
        let sorted = ordered(identifiers, in: display)
        return (0...2).map { rank in sorted.filter { group($0) == rank } }.filter { !$0.isEmpty }
    }

    private static func group(_ identifier: String) -> Int {
        switch languageCode(of: identifier) {
        case "en": 0
        case "fr": 1
        default: 2
        }
    }
}
