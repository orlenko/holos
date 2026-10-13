import Testing
@testable import HolosSpeech

/// Invariants:
/// 1. The one waiting query is resumed once; releasing before it starts also completes that later query.
actor HeldLocaleQuery {
    private var released = false
    private var continuation: CheckedContinuation<[String], Never>?

    func wait() async -> [String] {
        if released { return ["ru_RU"] }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume(returning: ["ru_RU"])
        continuation = nil
    }
}

@Test func completedLocaleQueriesKeepTheirSupportedLanguages() async {
    let locales = await AppleSpeechEngine.boundedLocales { ["en_CA", "ru_RU"] }
    #expect(locales == ["en_CA", "ru_RU"])
}

@Test(.timeLimit(.minutes(1))) func aHungLocaleQueryReturnsAnEmptyRetryableList() async {
    let query = HeldLocaleQuery()
    let locales = await AppleSpeechEngine.boundedLocales(timeout: .milliseconds(10)) { await query.wait() }
    await query.release()
    #expect(locales.isEmpty)
}

@Test @MainActor func aCancelledLocaleQueryDoesNotAskThePlatform() async {
    let query = Task {
        await AppleSpeechEngine.boundedLocales {
            Issue.record("A cancelled request must not query the platform")
            return ["ru_RU"]
        }
    }
    query.cancel()
    #expect(await query.value.isEmpty)
}
