import Foundation
import HolosCore
import HolosSpeech

/// The dictation language and the languages on offer (docs/design.md "Dictation language and recognizer"): dictation
/// offers both of Apple's recognizers' languages and uses the recognizer its language needs; meetings offer
/// `SpeechTranscriber`'s only.
extension HolosAppDelegate {
    /// The dictation language, or nil while there is no saved choice and the supported languages have not loaded.
    var resolvedLocale: String? {
        DictationLanguage.resolvedForSystem(saved: UserDefaults.standard.string(forKey: "dictationLocale"),
                                            recognizers: recognizerLocales)
    }

    /// The meeting languages chosen in the meeting start panel (the recorder transcribes live in the first; the others,
    /// at most two, are detected after the recording, docs/meeting/languages.md §4.14); until then, the dictation
    /// language when meetings can use it, else the closest one they can (`RecognizerLocales.meetingLanguage`). Nil
    /// while that is not known yet (the languages have not loaded): the start panel keeps Start off until it is.
    var meetingLocales: [String]? {
        get {
            let fallback = resolvedLocale.flatMap { dictation in
                recognizerLocales?.meetingLanguageForSystem(dictation: dictation)
            }
            return DictationLanguage.meetingLocales(
                saved: UserDefaults.standard.stringArray(forKey: MeetingAppState.localesKey), dictation: fallback)
        }
        set { UserDefaults.standard.set(newValue, forKey: MeetingAppState.localesKey) }
    }

    /// The recognizer the dictation language needs (`RecognizerLocales.backend(for:)`): whose speech model is checked
    /// and installed, and which the controller uses. `.speech` while the languages have not loaded.
    var dictationBackend: SpeechBackend { (recognizerLocales ?? .unknown).backend(for: locale) }

    /// Loads the languages Apple's recognizers support, for Setup, the menu, the meeting start panel, and the
    /// default language; returns once they are loaded (or could not be: the default is then
    /// `DictationLanguage.standard`, and a later call tries again). Loads them once.
    func loadLanguages() async {
        if let recognizerLocales, !recognizerLocales.isEmpty { return }
        if let languagesTask { return await languagesTask.value }
        let task = Task { [weak self] in
            let loaded = await AppleSpeechEngine.recognizerLocales()
            guard let self else { return }
            self.languagesTask = nil
            let before = (self.locale, self.dictationBackend)
            // Also when empty: the default is then known to be `standard`, so what waited for it can go on.
            self.recognizerLocales = loaded  // the controller takes them when dictation is enabled (`enable`)
            if !loaded.dictationLocales.isEmpty {
                self.localeGroups = DictationLanguage.groups(loaded.dictationLocales)
            }
            if !loaded.speech.isEmpty { self.meetingLocaleGroups = DictationLanguage.groups(loaded.speech) }
            // The default language, or the recognizer of a saved one, may have changed from the provisional one;
            // enabling uses the new one.
            if (self.locale, self.dictationBackend) != before {
                self.assetState = nil
                self.refreshAssetState()
            }
            self.rebuildMenu()
            self.languagesLoaded()
        }
        languagesTask = task
        await task.value
    }
}
