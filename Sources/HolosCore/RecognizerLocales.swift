import Foundation

/// The languages each of Apple's recognizers supports, and which one dictation uses for a language
/// (docs/design.md "Dictation language and recognizer"). `SpeechTranscriber` (`.speech`) has the progressive preset
/// meetings and dictation were built on; `DictationTranscriber` (`.dictation`) supports many more languages (Russian,
/// Ukrainian). Dictation offers both lists; meetings offer `speech` only.
public struct RecognizerLocales: Sendable, Equatable {
    /// `SpeechTranscriber`'s languages, as `DictationLanguage.identifier` spells them, sorted.
    public let speech: [String]
    /// `DictationTranscriber`'s languages, spelled and sorted the same way.
    public let dictation: [String]

    public init(speech: [String], dictation: [String]) {
        self.speech = Set(speech.map(DictationLanguage.identifier)).sorted()
        self.dictation = Set(dictation.map(DictationLanguage.identifier)).sorted()
    }

    /// Neither list is known (not loaded, or the load failed).
    public static let unknown = RecognizerLocales(speech: [], dictation: [])

    /// Both lists are empty: the load failed or found nothing, so a later load should try again.
    public var isEmpty: Bool { speech.isEmpty && dictation.isEmpty }

    /// Both recognizers have returned supported languages; an empty side must be retried.
    public var isComplete: Bool { !speech.isEmpty && !dictation.isEmpty }

    /// A temporarily empty response keeps that recognizer's last known languages while the missing side is retried.
    public func retainingKnownLocales(from previous: RecognizerLocales) -> RecognizerLocales {
        RecognizerLocales(speech: speech.isEmpty ? previous.speech : speech,
                         dictation: dictation.isEmpty ? previous.dictation : dictation)
    }

    /// Every language dictation can use: both lists together, for the dictation language picker.
    public var dictationLocales: [String] { Set(speech + dictation).sorted() }

    /// The recognizer dictation uses for `locale`: `.speech` when `SpeechTranscriber` has it, else `.dictation` when
    /// `DictationTranscriber` has it; then the same by language alone ("ru" when `DictationTranscriber` has
    /// "ru-RU"), `.speech` first. `.speech` when neither has the language (or the lists are unknown), so the
    /// recognizer reports it as unsupported as before.
    public func backend(for locale: String) -> SpeechBackend {
        let wanted = DictationLanguage.identifier(locale)
        if speech.contains(wanted) { return .speech }
        if dictation.contains(wanted) { return .dictation }
        if speech.contains(where: { DictationLanguage.sameLanguage($0, wanted) }) { return .speech }
        if dictation.contains(where: { DictationLanguage.sameLanguage($0, wanted) }) { return .dictation }
        return .speech
    }

    /// The dictation language for someone who has not picked one: `DictationLanguage.preferred` over every
    /// dictation language, except that a language `SpeechTranscriber` has is taken from its list, so its region
    /// follows the same rules over the languages that recognizer has ("en-CA" stays a `.speech` language even when
    /// `DictationTranscriber` adds regions).
    public func preferredDictation(preferredLanguages: [String], region: String? = nil) -> String {
        let any = DictationLanguage.preferred(supported: dictationLocales, preferredLanguages: preferredLanguages,
                                              region: region)
        guard speech.contains(where: { DictationLanguage.sameLanguage($0, any) }) else { return any }
        return DictationLanguage.preferred(supported: speech, preferredLanguages: preferredLanguages, region: region)
    }

    /// The meeting language that stands in for the dictation language `dictation` when no meeting language was
    /// chosen: a supported region of `dictation` when meetings have its language, else the `speech` language closest
    /// to the user's (`DictationLanguage.preferred`). Nil until the speech list is known.
    public func meetingLanguage(dictation: String, preferredLanguages: [String], region: String? = nil) -> String? {
        guard !speech.isEmpty else { return nil }
        if speech.contains(where: { DictationLanguage.sameLanguage($0, dictation) }) {
            return DictationLanguage.preferred(supported: speech, preferredLanguages: [dictation], region: region)
        }
        let preferred = DictationLanguage.preferred(supported: speech, preferredLanguages: preferredLanguages, region: region)
        return speech.contains(preferred) ? preferred : speech[0]
    }

    /// `preferredDictation` for this Mac: the user's preferred languages and region.
    public func preferredDictationForSystem() -> String {
        preferredDictation(preferredLanguages: Locale.preferredLanguages, region: Locale.current.region?.identifier)
    }

    /// `meetingLanguage` for this Mac: the user's preferred languages and region.
    public func meetingLanguageForSystem(dictation: String) -> String? {
        meetingLanguage(dictation: dictation, preferredLanguages: Locale.preferredLanguages,
                        region: Locale.current.region?.identifier)
    }
}
