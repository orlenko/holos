import Foundation

/// The searchable voice inventory for Reading and Settings (docs/design.md "Reading section").
/// Automatic voice selection keeps its own ranking; browsing sorts by name, then region and quality.
public struct ReadingVoiceList: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let id: String
        public let name: String
        public let languageCode: String
        public let languageName: String
        public let localeName: String
        public let quality: String
        public let languageTag: String

        public init(id: String, name: String, languageCode: String, languageName: String,
                    localeName: String, quality: String, languageTag: String) {
            self.id = id
            self.name = name
            self.languageCode = languageCode
            self.languageName = languageName
            self.localeName = localeName
            self.quality = quality
            self.languageTag = languageTag
        }

        public var qualityTitle: String {
            switch quality {
            case "natural": "Natural"
            case "premium": "Premium"
            case "enhanced": "Enhanced"
            default: "System"
            }
        }

        public var detail: String { "\(localeName) · \(qualityTitle)" }
        public var title: String { "\(name) (\(qualityTitle)), \(localeName)" }
        fileprivate var searchText: String { "\(name) \(detail) \(languageName) \(languageTag) \(languageCode)" }
    }

    public struct Language: Sendable, Equatable {
        public let code: String
        public let name: String

        public init(code: String, name: String) {
            self.code = code
            self.name = name
        }
    }

    public let items: [Item]
    public let languages: [Language]

    public init(voices: [VoiceDescriptor], installed: Set<NaturalVoicePack>) {
        let english = Locale(identifier: "en_US")
        let descriptors = voices.filter { !$0.novelty } + NaturalVoiceCatalog.voices(installed: installed).map(\.descriptor)
        items = descriptors.map { voice in
            let code = VoiceSelection.languageCode(voice.language) ?? voice.language
            var name = voice.name
            for suffix in [" (Premium)", " (Enhanced)", " (Natural)"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            return Item(id: voice.id, name: name, languageCode: code,
                        languageName: english.localizedString(forLanguageCode: code) ?? code,
                        localeName: english.localizedString(forIdentifier: voice.language.replacingOccurrences(of: "-", with: "_"))
                            ?? voice.language,
                        quality: voice.quality, languageTag: voice.language)
        }.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let localeOrder = lhs.localeName.localizedStandardCompare(rhs.localeName)
            if localeOrder != .orderedSame { return localeOrder == .orderedAscending }
            let lhsRank = lhs.quality == "natural" ? 4 : VoiceSelection.qualityRank(lhs.quality)
            let rhsRank = rhs.quality == "natural" ? 4 : VoiceSelection.qualityRank(rhs.quality)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return lhs.id < rhs.id
        }
        var byCode: [String: String] = [:]
        for item in items { byCode[item.languageCode] = item.languageName }
        languages = byCode.map { Language(code: $0.key, name: $0.value) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.code < $1.code : order == .orderedAscending
        }
    }

    /// Every search word must occur in the voice's name, language, region, or quality. The language filter includes
    /// all regions of that language. Whitespace, case, accents and width do not affect matching.
    public func matching(query: String, language: String?) -> [Item] {
        let words = VoiceSelection.normalized(query).split(separator: " ")
        return items.filter { item in
            guard language == nil || item.languageCode == language else { return false }
            let text = VoiceSelection.normalized(item.searchText)
            return words.allSatisfy { text.contains($0) }
        }
    }
}
