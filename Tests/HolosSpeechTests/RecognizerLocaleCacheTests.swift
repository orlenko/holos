import HolosCore
import Testing
@testable import HolosSpeech

@Test func laterInventoryRequestsKeepTheBackendOfWorkingLiveDictation() {
    let cache = RecognizerLocaleCache()
    let known = RecognizerLocales(speech: ["en_CA"], dictation: ["en_CA", "ru_RU", "uk_UA"])
    #expect(cache.remember(known).backend(for: "en-CA") == .speech)
    let replay = cache.remember(RecognizerLocales(speech: [], dictation: known.dictation))
    #expect(replay.backend(for: "en-CA") == .speech)
    #expect(replay.backend(for: "ru-RU") == .dictation)
    #expect(cache.remember(.unknown) == known)
}

@Test func laterInventoryRequestsRecoverLanguagesMissingAtStartup() {
    let cache = RecognizerLocaleCache()
    #expect(!cache.remember(RecognizerLocales(speech: ["en_CA"], dictation: [])).isComplete)
    let recovered = cache.remember(RecognizerLocales(speech: [], dictation: ["ru_RU", "uk_UA"]))
    #expect(recovered.isComplete)
    #expect(recovered.speech == ["en-CA"])
    #expect(recovered.backend(for: "uk-UA") == .dictation)
}
