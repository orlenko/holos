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
    /// `DictationLanguage.standard`, and a later call tries again). Retains known languages and retries an empty
    /// backend until both lists are populated (invariants 1 and 2).
    func loadLanguages() async {
        if let recognizerLocales, recognizerLocales.isComplete { return }
        if let languagesTask { return await languagesTask.value }
        let task = Task { [weak self] in
            let discovered = await AppleSpeechEngine.recognizerLocales()
            guard let self else { return }
            let loaded = discovered.retainingKnownLocales(from: self.recognizerLocales ?? .unknown)
            self.languagesTask = nil
            let before = (self.resolvedLocale, self.dictationBackend)
            // Invariants 1 and 2: publish the cached lists and both picker projections together.
            self.recognizerLocales = loaded  // the controller takes them when dictation is enabled (`enable`)
            self.localeGroups = DictationLanguage.groups(loaded.dictationLocales)
            self.meetingLocaleGroups = DictationLanguage.groups(loaded.speech)
            // The default language, or the recognizer of a saved one, may have changed from the provisional one;
            // enabling uses the new one.
            if (self.resolvedLocale, self.dictationBackend) != before {
                self.assetState = nil  // invariant 3
                self.refreshAssetState()
            }
            self.synchronizeDictationLanguage()  // invariants 4 and 5
            self.rebuildMenu()
            self.languagesLoaded()
        }
        languagesTask = task
        await task.value
    }

    func refreshAssetState() {
        Task { [weak self] in
            guard let self else { return }
            if self.recognizerLocales?.isComplete != true { await self.loadLanguages() }
            let locale = self.locale, backend = self.dictationBackend
            let state = (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: backend)) ?? "unknown"
            // Invariant 3: a later language load may also change the recognizer of this same locale.
            guard self.locale == locale, self.dictationBackend == backend else { return }
            self.assetState = state
            self.updateSettings()
        }
    }

    /// Applies a recovered default between utterances, preserving a language chosen explicitly in Settings.
    @discardableResult
    func synchronizeDictationLanguage() -> Bool {
        guard enabled, canChangeLanguage,
              controller.locale != locale || controller.recognizers.backend(for: locale) != dictationBackend else {
            return false
        }
        changeLanguage(to: locale, persist: false)
        return true
    }

    func changeLanguage(to identifier: String, persist: Bool = true) {
        guard (!persist || identifier != locale), canChangeLanguage else {
            updateSettings()  // puts a refused choice back in Settings
            return
        }
        if persist { UserDefaults.standard.set(identifier, forKey: "dictationLocale") }
        controller.locale = identifier
        controller.recognizers = recognizerLocales ?? .unknown
        controller.contextualStrings = dictationVocabulary(language: identifier)
        assetState = nil  // invariant 3
        if enabled {
            // Invariant 4: a recovered default, like an explicit choice, rechecks the selected recognizer's assets.
            disable()
            enable()
        } else {
            show("Dictation language: \(languageName)")
            refreshAssetState()
        }
    }
}
