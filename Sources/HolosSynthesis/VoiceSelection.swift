import Foundation

/// Finding a voice by the names `say -v` and `voices list` print, and ranking installed voices.
/// Pure: callers pass the installed voices and the user's language settings.
public enum VoiceSelection {
    public static let premiumVoicesHint =
        "Download Premium voices in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices."

    public static func qualityRank(_ quality: String) -> Int {
        switch quality {
        case "premium": 3
        case "enhanced": 2
        case "default": 1
        default: 0
        }
    }

    /// The voice for `query`: an identifier, a name as `say -v` prints it ("Ava (Premium)",
    /// "Eddy (English (US))"), a plain name ("Ava"), or a name with a quality ("Evan (Premium)").
    /// An exact name wins over a looser match, as in `say`; among several voices with the same
    /// name, the one in `language` (then the highest quality) wins.
    public static func match(_ query: String, in voices: [VoiceDescriptor],
                             language: String? = nil) -> VoiceDescriptor? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = voices.first(where: { $0.id == trimmed }) { return exact }
        if let folded = voices.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) { return folded }
        let wanted = normalized(trimmed)
        let names = displayNames(voices)

        var candidates = voices.filter { normalized($0.name) == wanted || normalized(names[$0.id] ?? "") == wanted }
        if candidates.isEmpty, let (base, suffix) = splitSuffix(trimmed) {
            let wantedBase = normalized(base)
            let suffixName = normalized(suffix)
            if ["premium", "enhanced", "default"].contains(suffixName) {
                candidates = voices.filter { normalized(baseName(of: $0)) == wantedBase && $0.quality == suffixName }
            } else {
                candidates = voices.filter {
                    normalized(baseName(of: $0)) == wantedBase && languageMatches(suffix, voiceLanguage: $0.language)
                }
            }
        }
        if candidates.isEmpty {
            candidates = voices.filter { normalized(baseName(of: $0)) == wanted }
        }
        let languageCode = language.flatMap(Self.languageCode)
        return candidates.min { lhs, rhs in
            let lhsLanguage = languageCode != nil && Self.languageCode(lhs.language) == languageCode
            let rhsLanguage = languageCode != nil && Self.languageCode(rhs.language) == languageCode
            if lhsLanguage != rhsLanguage { return lhsLanguage }
            return rankedBefore(lhs, rhs, systemDefault: nil)
        }
    }

    /// The best voice for `language`: premium over enhanced over default, then a region the user
    /// prefers, then the voice macOS itself uses for the language. Novelty and Personal Voices are
    /// never chosen. Nil when no voice speaks the language.
    public static func best(language: String, in voices: [VoiceDescriptor],
                            preferredLanguages: [String] = [], currentRegion: String? = nil,
                            systemDefault: String? = nil) -> VoiceDescriptor? {
        guard let code = languageCode(language) else { return nil }
        let requested = normalizedTag(language)
        let preferred = preferredLanguages.map(normalizedTag)
        func regionRank(_ voice: VoiceDescriptor) -> Int {
            let tag = normalizedTag(voice.language)
            if requested.contains("-") && tag == requested { return 0 }
            if let index = preferred.firstIndex(of: tag) { return 1 + index }
            if let currentRegion, regionCode(voice.language) == currentRegion.uppercased() { return 1_000 }
            return 2_000
        }
        let candidates = voices.filter { !$0.novelty && !$0.personal && languageCode($0.language) == code }
        return candidates.min { lhs, rhs in
            let lhsQuality = qualityRank(lhs.quality), rhsQuality = qualityRank(rhs.quality)
            if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
            let lhsRegion = regionRank(lhs), rhsRegion = regionRank(rhs)
            if lhsRegion != rhsRegion { return lhsRegion < rhsRegion }
            return rankedBefore(lhs, rhs, systemDefault: systemDefault)
        }
    }

    /// Names as `voices list` prints them: the voice's own name, followed by its language when
    /// several voices share that name in different languages (as `say -v '?'` does).
    public static func displayNames(_ voices: [VoiceDescriptor]) -> [String: String] {
        var languagesByName: [String: Set<String>] = [:]
        for voice in voices { languagesByName[voice.name, default: []].insert(voice.language) }
        let english = Locale(identifier: "en_US")
        var result: [String: String] = [:]
        for voice in voices {
            if (languagesByName[voice.name]?.count ?? 0) > 1 {
                let language = english.localizedString(forIdentifier: voice.language.replacingOccurrences(of: "-", with: "_"))
                    ?? voice.language
                result[voice.id] = "\(voice.name) (\(language))"
            } else {
                result[voice.id] = voice.name
            }
        }
        return result
    }

    /// Premium first, then the system's own voice, then fuller models over compact ones.
    private static func rankedBefore(_ lhs: VoiceDescriptor, _ rhs: VoiceDescriptor,
                                     systemDefault: String?) -> Bool {
        let lhsQuality = qualityRank(lhs.quality), rhsQuality = qualityRank(rhs.quality)
        if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
        if let systemDefault, (lhs.id == systemDefault) != (rhs.id == systemDefault) {
            return lhs.id == systemDefault
        }
        let lhsSmall = lhs.id.contains("super-compact"), rhsSmall = rhs.id.contains("super-compact")
        if lhsSmall != rhsSmall { return !lhsSmall }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id < rhs.id
    }

    /// "Ava (Premium)" -> "Ava"; names without a quality suffix are unchanged.
    static func baseName(of voice: VoiceDescriptor) -> String {
        for suffix in [" (Premium)", " (Enhanced)"] where voice.name.hasSuffix(suffix) {
            return String(voice.name.dropLast(suffix.count))
        }
        return voice.name
    }

    /// "Eddy (English (US))" -> ("Eddy", "English (US)").
    static func splitSuffix(_ text: String) -> (String, String)? {
        guard text.hasSuffix(")"), let open = openingParenthesis(of: text) else { return nil }
        let base = text[..<open].trimmingCharacters(in: .whitespaces)
        let suffix = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !base.isEmpty, !suffix.isEmpty else { return nil }
        return (base, String(suffix))
    }

    private static func openingParenthesis(of text: String) -> String.Index? {
        var depth = 0
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            if text[index] == ")" { depth += 1 }
            if text[index] == "(" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// Whether "English (US)", "English (United States)", "English", or "en-US" describes the
    /// voice language "en-US".
    static func languageMatches(_ description: String, voiceLanguage: String) -> Bool {
        if normalizedTag(description) == normalizedTag(voiceLanguage) { return true }
        guard let code = languageCode(voiceLanguage) else { return false }
        let english = Locale(identifier: "en_US")
        let languagePart: String
        let regionPart: String?
        if let (base, region) = splitSuffix(description) {
            languagePart = base
            regionPart = region
        } else {
            languagePart = description
            regionPart = nil
        }
        guard normalized(english.localizedString(forLanguageCode: code) ?? "") == normalized(languagePart) else {
            return false
        }
        guard let regionPart else { return true }
        guard let region = regionCode(voiceLanguage) else { return false }
        let wanted = normalized(regionPart)
        let aliases: [String: String] = ["uk": "GB", "usa": "US"]
        return normalized(region) == wanted || aliases[wanted] == region
            || normalized(english.localizedString(forRegionCode: region) ?? "") == wanted
    }

    static func languageCode(_ tag: String) -> String? {
        let code = Locale.Language(identifier: tag).languageCode?.identifier
        return code.map { $0.lowercased() }
    }

    static func regionCode(_ tag: String) -> String? {
        Locale.Language(identifier: tag).region?.identifier.uppercased()
    }

    private static func normalizedTag(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
