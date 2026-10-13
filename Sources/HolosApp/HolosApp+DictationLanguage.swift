import Foundation
import HolosCore
import HolosAppModel
import HolosSpeech

/// The dictation language and the languages on offer (docs/design.md "Dictation language and recognizer"): dictation
/// offers both of Apple's recognizers' languages and uses the recognizer its language needs; meetings offer
/// `SpeechTranscriber`'s only.
extension HolosAppDelegate {
    var assetState: String? {
        get { dictationLanguageState.assetStatus }
        set { dictationLanguageState.assetStatus = newValue }
    }
    var recognizerLocales: RecognizerLocales? {
        get { dictationLanguageState.locales }
        set { dictationLanguageState.locales = newValue }
    }
    var localeGroups: [[String]] { dictationLanguageState.dictationGroups }
    var meetingLocaleGroups: [[String]] { dictationLanguageState.meetingGroups }
    var languagesTask: Task<Void, Never>? {
        get { dictationLanguageState.languageTask }
        set { dictationLanguageState.languageTask = newValue }
    }
    /// The dictation language, chosen in Settings; until then, the supported one closest to the user's
    /// languages (`RecognizerLocales.preferredDictation`). An active dictation keeps its own language (invariant 5).
    /// Actions that use the language await `loadLanguages` before accepting the provisional `standard` default.
    var locale: String { activeDictationLanguage ?? resolvedLocale ?? DictationLanguage.standard }
    var languageName: String { DictationLanguage.name(of: locale) }

    /// Not while a dictation, install, or enable is in progress: a change applies from the next dictation.
    var canChangeLanguage: Bool { !isBusy && !enabling && !installingAssets }

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
        dictationLanguageState.refreshAssets { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.recognizerLocales?.isComplete != true { await self.loadLanguages() }
                let locale = self.locale, backend = self.dictationBackend
                let state = (try? await self.checkDictationAssets(locale: locale, backend: backend)) ?? "unknown"
                guard !Task.isCancelled else { return }
                // Invariant 3: a changed configuration is checked again by the same coalesced refresh.
                guard self.matchesDictationConfiguration(locale: locale, backend: backend) else { continue }
                self.assetState = state
                self.updateSettings()
                self.resumeDeferredDictationSetup()
                return
            }
        }
    }

    /// Enable and Settings share an in-flight request for the same configuration.
    func checkDictationAssets(locale: String, backend: SpeechBackend) async throws -> String {
        try await dictationLanguageState.checkAssets(locale: locale, backend: backend) {
            try await AppleSpeechEngine.assetStatus(locale: locale, backend: backend)
        }
    }

    func prepareDictationModelInstall() {
        dictationLanguageState.invalidateAssetChecks()
        updateSettings()
    }

    func finishDictationModelInstall(locale: String, backend: SpeechBackend, name: String) {
        dictationLanguageState.invalidateAssetChecks()
        guard matchesDictationConfiguration(locale: locale, backend: backend) else { return refreshAssetState() }
        assetState = "installed"
        show("Speech model for \(name) ready; enable dictation when ready")
        resumeDeferredDictationSetup()
    }

    func finishDictationModelInstallFailure(_ error: Error, locale: String, backend: SpeechBackend) {
        dictationLanguageState.invalidateAssetChecks()
        if Task.isCancelled || error is CancellationError { return }
        guard matchesDictationConfiguration(locale: locale, backend: backend) else { return refreshAssetState() }
        enableWhenSpeechModelInstalled = false
        refreshAssetState()
        show("Asset setup failed: \(error.localizedDescription)")
    }

    /// Invariant 3: every asynchronous asset result, including an error or install completion, belongs to this pair.
    func matchesDictationConfiguration(locale: String, backend: SpeechBackend) -> Bool {
        self.locale == locale && dictationBackend == backend
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
