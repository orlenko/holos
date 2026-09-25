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

    /// "fr-CA" for "fr_CA", the form Holos saves and hands to the recognizer.
    public static func identifier(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "-")
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
